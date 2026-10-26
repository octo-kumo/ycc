// wasm_lower.y — lower the shared machine IR to wasm for the web target.
//
// The model: a chunk is one wasm function (param i32 entry)
// whose body is a dispatch loop (loop + br_table over cases).  A branch
// inside a chunk is a br to the case's block; a transfer to another chunk is
// a tail call (return_call); call pushes a token and tail-calls, ret pops it
// and does return_call_indirect.  So the wasm stack never grows and every
// Y control transfer is one tail call.
//
// Registers live in i64/f64 locals inside a chunk and in wasm globals between
// chunks; the Y stack stays in linear memory exactly as the Linux program
// keeps it.  The flag state of S6 lives in its own locals (fop/fsz/fa/fb/fr/
// fx/fy/fcf), which producers write when a backward liveness pass says the
// flags can be read, and which a consumer either folds into the exact
// comparison (when the producer is known statically in the same straight-line
// run) or asks the internal $cond function for.
import we from "./wasm_enc.y";
import asm from "./asm.y";
import xenc from "./enc64.y";
import tags from "./tags.y";

// Globals, in the order wasm_link.y declares them (the indices are the ABI
// between the writer and this lowering).
const G_R0 = 0;
const G_X0 = 16;
const G_FS = 32;
const G_FOP = 33;
const G_FSZ = 34;
const G_FA = 35;
const G_FB = 36;
const G_FR = 37;
const G_FX = 38;
const G_FY = 39;
const G_FCF = 40;
const G_PC = 41;
const G_WHY = 42;
const G_FUEL = 43;
const G_Q = 44;
const G_RM = 45;

// Locals inside a chunk function: param e (0), r0..r15, x0..x15, the case
// selector, temporaries, then the flag state.  wasm_enc groups the vector.
const L_E = 0;
const L_R0 = 1;
const L_X0 = 17;
const L_S = 33;
const L_TA = 34;
const L_TB = 35;
const L_TR = 36;
const L_TM = 37;
const L_T0 = 38;
const L_T1 = 39;
const L_FT0 = 40;
const L_FT1 = 41;
const L_TI0 = 42;
const L_TI1 = 43;
const L_TI2 = 44;
// S6's flag state (the same shape as the $f* globals, so a suspension is a
// copy in and out).
const L_FOP = 45;
const L_FSZ = 46;
const L_FA = 47;
const L_FB = 48;
const L_FR = 49;
const L_FX = 50;
const L_FY = 51;
const L_FCF = 52;
// SSE temporaries: dst, src, result.
const L_FD = 53;
const L_FS = 54;
const L_FR2 = 55;
const L_T2 = 56;

// S7 tokens: 2^40 + chunk * 2^20 + case.
const TOKEN_BASE = 1099511627776;
const TOKEN_CHUNK = 1048576;
const TOKEN_MASK = 1048575;

// S6 op codes inside the flag state.
const FOP_ADD = 1;
const FOP_SUB = 2;
const FOP_LOGIC = 3;
const FOP_INC = 4;
const FOP_DEC = 5;
const FOP_NEG = 6;
const FOP_SHL = 7;
const FOP_SHR = 8;
const FOP_SAR = 9;
const FOP_IMUL = 10;
const FOP_UCOMI = 11;
const FOP_BSRZ = 12;
const FOP_BSRNZ = 13;

// Liveness bits: bit 0 = some flag is live, bit 1 = CF is live (what an
// INC/DEC has to save).
const FL_ANY = 1;
const FL_CF = 2;

let wl_err = "";
let wl_cond_fi = 0;

def wl_fail(msg: str) -> void {
    if (wl_err == "") { wl_err = msg; };
};

def wl_token(chunk: long, kase: long) -> long {
    TOKEN_BASE + chunk * TOKEN_CHUNK + kase
};

def wl_mask(sz: long) -> long {
    if (sz >= 64) { -1 } else { (1 << sz) - 1 }
};

// The most negative value of a size, and the most positive one.
def wl_minv(sz: long) -> long { (wl_mask(sz) >>> 1) + 1 };
def wl_maxv(sz: long) -> long { wl_mask(sz) >>> 1 };

// The bits of x86's default NaN (0xFFF8000000000000 = -(2^51)), as a signed
// long.  Note 2^51, not 2^52: the mantissa's quiet bit is bit 51.
def wl_default_nan() -> long { -2251799813685248 };
// The quiet bit of a double (0x0008000000000000).
def wl_quiet_bit() -> long { 2251799813685248 };

def wl_locals() -> [long] {
    let out: [long] = [];
    for i in 0..16 { out += we.VT_I64; };
    for i in 0..16 { out += we.VT_F64; };
    out += we.VT_I32;
    for i in 0..6 { out += we.VT_I64; };
    for i in 0..2 { out += we.VT_F64; };
    for i in 0..3 { out += we.VT_I32; };
    out += we.VT_I32;   // fop
    out += we.VT_I32;   // fsz
    out += we.VT_I64;   // fa
    out += we.VT_I64;   // fb
    out += we.VT_I64;   // fr
    out += we.VT_F64;   // fx
    out += we.VT_F64;   // fy
    out += we.VT_I32;   // fcf
    out += we.VT_F64;   // fd
    out += we.VT_F64;   // fs
    out += we.VT_F64;   // fr2
    out += we.VT_I64;   // t2
    out
};

// ── label lookup and data addresses ──────────────────────────────────────
def wl_lab_index(ctx: WCtx, name: str) -> long {
    let e = asm.labmap_get(ctx.lmap, name);
    if (e.sec < 0) { -1 } else { e.off }
};

// A label plus an optional +N, the form the assembler accepts on a miss.
def wl_lab_split(name: str) -> { nm: str, extra: long } {
    let plus = index_of(name, "+");
    if (plus > 0) {
        let o = tolong(name[plus + 1:]);
        if (o != none) { { nm: name[0:plus], extra: o! } }
        else { { nm: name, extra: 0 } }
    } else {
        { nm: name, extra: 0 }
    }
};

def wl_lab_value(ctx: WCtx, name: str, where: str, allow_code: bool) -> long {
    let sp = wl_lab_split(name);
    let idx = wl_lab_index(ctx, sp.nm);
    if (idx < 0) {
        wl_fail("web: undefined label '" + sp.nm + "' at " + where);
        0
    } else {
        let l = ctx.labels[idx];
        if (l.code) {
            if (allow_code && sp.extra == 0) { wl_token(l.chunk, l.kase) }
            else {
                if (sp.extra != 0) { wl_fail("web: a code address difference has no meaning on --target=web (" + name + " at " + where + ")"); }
                else { wl_fail("web: " + name + " is code and is read as data at " + where + " (" + l.name + ")"); };
                0
            }
        } else {
            l.addr + sp.extra
        }
    }
};

// The address of a memory operand, as i64, without wrapping.
def wl_addr(ctx: WCtx, op: Operand, where: str, allow_code: bool) -> void {
    if (op.k == K.mem) {
        if (op.rip) {
            wb_const_i64(wl_lab_value(ctx, op.lbl, where, allow_code));
        } else {
            wb_const_i64(op.disp);
            if (op.base >= 0) {
                wb_local_get(L_R0 + op.base);
                wb_op("i64.add");
            };
            if (op.idx >= 0) {
                wb_local_get(L_R0 + op.idx);
                if (op.scale != 1) {
                    wb_const_i64(op.scale);
                    wb_op("i64.mul");
                };
                wb_op("i64.add");
            };
        }
    } else if (op.k == K.fs) {
        wb_global_get(G_FS);
        if (op.disp != 0) {
            wb_const_i64(op.disp);
            wb_op("i64.add");
        };
    } else if (op.k == K.lbl) {
        wb_const_i64(wl_lab_value(ctx, op.name, where, allow_code));
    } else if (op.k == K.imm) {
        wb_const_i64(op.v);
    } else {
        wl_fail("web: bad memory operand at " + where);
        wb_const_i64(0);
    };
};

// TM holds a byte address; validate it when checked and wrap it to wasm32.
def wl_addr_from_tm(ctx: WCtx) -> void {
    if (ctx.checked) {
        wb_local_get(L_TM);
        wb_const_i64(32);
        wb_op("i64.shr_u");
        wb_op("i64.eqz");
        wb_if("chk");
        wb_else();
        wb_const_i32(11);
        wb_call(ctx.trap_fi);
        wb_unreachable();
        wb_end();
    };
    wb_local_get(L_TM);
    wb_op("i32.wrap_i64");
};

def wl_addr_tm(ctx: WCtx, op: Operand, where: str, allow_code: bool) -> void {
    wl_addr(ctx, op, where, allow_code);
    wb_local_set(L_TM);
    wl_addr_from_tm(ctx);
};

// The checked-address guard on a register holding a byte address (the Y stack
// pointer around push/pop and the call tokens).
def wl_chk_local(ctx: WCtx, n: long) -> void {
    if (ctx.checked) {
        wb_local_get(n);
        wb_const_i64(32);
        wb_op("i64.shr_u");
        wb_op("i64.eqz");
        wb_if("chkr");
        wb_else();
        wb_const_i32(11);
        wb_call(ctx.trap_fi);
        wb_unreachable();
        wb_end();
    };
};

def wl_load_name(sz: long, signed: bool) -> str {
    if (sz >= 64) { "i64.load" }
    else if (sz == 32) { if (signed) { "i64.load32_s" } else { "i64.load32_u" } }
    else if (sz == 16) { if (signed) { "i64.load16_s" } else { "i64.load16_u" } }
    else { if (signed) { "i64.load8_s" } else { "i64.load8_u" } }
};

def wl_store_name(sz: long) -> str {
    if (sz >= 64) { "i64.store" }
    else if (sz == 32) { "i64.store32" }
    else if (sz == 16) { "i64.store16" }
    else { "i64.store8" }
};

def wl_load_tm(sz: long, signed: bool) -> void {
    wb_local_get(L_TM);
    wb_op("i32.wrap_i64");
    wb_mem(wl_load_name(sz, signed), 0, 0);
};

// The extension a *signed* value of size sz needs inside an i64.
def wl_sx(sz: long) -> void {
    if (sz == 8) { wb_op("i64.extend8_s"); }
    else if (sz == 16) { wb_op("i64.extend16_s"); }
    else if (sz == 32) { wb_op("i64.extend32_s"); };
};

// ── operands as values ───────────────────────────────────────────────────
def wl_reg(op: Operand) -> bool {
    op.k == K.reg || op.k == K.ind
};

def wl_xmm(op: Operand) -> bool {
    (op.k == K.reg || op.k == K.ind) && op.size == 128
};

def wl_get(ctx: WCtx, op: Operand, sz: long, where: str) -> void {
    if (wl_reg(op)) {
        wb_local_get(L_R0 + op.n);
        if (sz < 64) {
            wb_const_i64(wl_mask(sz));
            wb_op("i64.and");
        };
    } else if (op.k == K.imm) {
        wb_const_i64(op.v & wl_mask(sz));
    } else if (op.k == K.diff) {
        wb_const_i64(wl_lab_value(ctx, op.a, where, false) - wl_lab_value(ctx, op.b, where, false));
    } else if (op.k == K.lbl) {
        wb_const_i64(wl_lab_value(ctx, op.name, where, true));
    } else if (op.k == K.mem || op.k == K.fs) {
        wl_addr_tm(ctx, op, where, false);
        wb_mem(wl_load_name(sz, false), 0, 0);
    } else {
        wl_fail("web: unsupported operand in '" + where + "'");
        wb_const_i64(0);
    };
};

// Store the i64 on the stack in register operand op at size sz.  A 16- or
// 8-bit write merges into the old value, exactly as x86 does.
def wl_put_reg(op: Operand, sz: long) -> void {
    if (sz >= 64) {
        wb_local_set(L_R0 + op.n);
    } else if (sz == 32) {
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_R0 + op.n);
    } else {
        wb_local_set(L_T0);
        wb_local_get(L_R0 + op.n);
        wb_const_i64(~wl_mask(sz));
        wb_op("i64.and");
        wb_local_get(L_T0);
        wb_const_i64(wl_mask(sz));
        wb_op("i64.and");
        wb_op("i64.or");
        wb_local_set(L_R0 + op.n);
    };
};

def wl_get_f(ctx: WCtx, op: Operand, where: str) -> void {
    if (wl_xmm(op)) {
        wb_local_get(L_X0 + op.n);
    } else if (op.k == K.mem || op.k == K.fs) {
        wl_addr_tm(ctx, op, where, false);
        wb_mem("f64.load", 0, 0);
    } else {
        wl_fail("web: bad xmm operand at " + where);
        wb_const_f64(0);
    };
};

def wl_put_f(op: Operand, where: str) -> void {
    if (wl_xmm(op)) {
        wb_local_set(L_X0 + op.n);
    } else {
        wl_fail("web: bad xmm destination at " + where);
        wb_op("drop");
    };
};

// The size an item's operands imply: a register's own size first, else the
// mnemonic's suffix.
def wl_size(it: WItem) -> long {
    // The LAST register operand: AT&T puts the destination last, and a shift's
    // count is %cl (8 bits) whatever the operand size is.
    let sz = -1;
    for i in 0..len(it.ops) {
        let op = it.ops[i];
        if (wl_reg(op)) { sz = op.size; };
    };
    if (sz > 0) { return sz; };
    let mn = it.mn;
    if (mn == "movb" || mn == "cmpb" || mn == "testb" || mn == "movzbq" || mn == "movsbq") { 8 }
    else if (mn == "movw" || mn == "movzwq" || mn == "movswq") { 16 }
    else if (mn == "movl" || mn == "movslq" || mn == "bswapl") { 32 }
    else { 64 }
};

// ── the flag state and its liveness (S6) ────────────────────────────────
// The producer knowledge for the "same straight-line run" fast path.  It is
// dropped at every case start (a label is a join) and whenever a producer's
// effect on the flags is only known at run time (a %cl shift).
let fl_have = false;
let fl_op = 0;
let fl_sz = 64;

// Per-case and per-item liveness of wl_chunk_body's analysis, in the same
// order as the chunk's item positions.
let wl_live_before: [long] = [];
let wl_live_after: [long] = [];
let wl_live_in: [long] = [];
let wl_fentry = false;
let wl_cur_live = 0;

def wl_fl_reset() -> void { fl_have = false; };

// What an instruction does to the flags.
type WFC = { kd: long, fop: long, prev: long };
// kd: 0 none, 1 producer, 2 producer that leaves undefined flags (div),
// 3 conditional branch, 4 setcc, 5 unconditional transfer.
def wl_fclass(it: WItem) -> WFC {
    let mr = it.mn;
    if (mr == "add") { { kd: 1, fop: FOP_ADD, prev: 0 } }
    else if (mr == "sub") { { kd: 1, fop: FOP_SUB, prev: 0 } }
    else if (mr == "and" || mr == "or" || mr == "xor") { { kd: 1, fop: FOP_LOGIC, prev: 0 } }
    else if (mr == "cmp") { { kd: 1, fop: FOP_SUB, prev: 0 } }
    else if (mr == "test") { { kd: 1, fop: FOP_LOGIC, prev: 0 } }
    else if (mr == "inc") { { kd: 1, fop: FOP_INC, prev: 1 } }
    else if (mr == "dec") { { kd: 1, fop: FOP_DEC, prev: 1 } }
    else if (mr == "neg") { { kd: 1, fop: FOP_NEG, prev: 0 } }
    else if (mr == "imul") { { kd: 1, fop: FOP_IMUL, prev: 0 } }
    else if (mr == "shl" || mr == "sal" || mr == "shr" || mr == "sar") {
        let fop = if (mr == "shl" || mr == "sal") { FOP_SHL }
            else if (mr == "shr") { FOP_SHR } else { FOP_SAR };
        let op = it.ops[0];
        if (op.k == K.imm && (op.v & 63) == 0) { { kd: 0, fop: 0, prev: 0 } }
        else if (op.k == K.imm) { { kd: 1, fop: fop, prev: 0 } }
        else { { kd: 1, fop: fop, prev: 2 } }
    }
    else if (mr == "idiv" || mr == "div") { { kd: 2, fop: 0, prev: 0 } }
    else if (mr == "bsr") { { kd: 1, fop: FOP_BSRZ, prev: 0 } }
    else if (mr == "ucomisd") { { kd: 1, fop: FOP_UCOMI, prev: 0 } }
    else if (wl_jcc_cc(mr).ok) { { kd: 3, fop: 0, prev: 0 } }
    else if (wl_setcc_cc(mr).ok) { { kd: 4, fop: 0, prev: 0 } }
    else if (mr == "jmp" || mr == "call" || mr == "ret" || mr == "ud2" || mr == "int3") {
        { kd: 5, fop: 0, prev: 0 }
    }
    else { { kd: 0, fop: 0, prev: 0 } }
};

def wl_uses_cf(cc: long) -> bool {
    cc == 6 || cc == 7 || cc == 8 || cc == 9
};

def wl_target_case(ctx: WCtx, op: Operand) -> long {
    if (op.k != K.lbl) { return -1; };
    let idx = wl_lab_index(ctx, op.name);
    if (idx < 0) { return -1; };
    let l = ctx.labels[idx];
    if (!l.code) { return -1; };
    l.kase
};

// The backward dataflow of S6.  Flags are live wherever a consumer may read
// them; a producer kills them; a jcc uses them and passes them on to both its
// target case and its fall-through.  An external entry case (case 0, a call
// return point, a cross-chunk jump target, an address-taken label) with flags
// live-in is the compile error S6 asks for: the state cannot survive a wasm
// call boundary.
// The live state handed on at the fall-through, and the state at case 0 of
// this chunk (both from wl_live_run).
let wl_tail = 0;
let wl_case0 = 0;

// wl_live_run: the dataflow alone.  tail is the state needed at case 0 of the
// chunk this one falls through into (0 when the flags are dead there), which
// is the state after the last item.
def wl_live_run(ctx: WCtx, ch: WChunk, items: [WItem], tail: long) -> void {
    let n = len(ch.items);
    wl_tail = tail;
    let nc0 = len(ch.cases);
    let nc = len(ch.cases);
    wl_live_before = [];
    wl_live_after = [];
    wl_live_in = [];
    for i in 0..n { wl_live_before += 0; wl_live_after += 0; };
    for k in 0..nc { wl_live_in += 0; };
    let kinds: [long] = [];
    let prevs: [long] = [];
    let targets: [long] = [];
    for p in 0..n {
        let it = items[ch.items[p]];
        let fc = wl_fclass(it);
        kinds += fc.kd;
        prevs += fc.prev;
        let t = -1;
        if (fc.kd == 3) { t = wl_target_case(ctx, it.ops[0]); }
        else if (it.mn == "jmp") { if (len(it.ops) > 0) { t = wl_target_case(ctx, it.ops[0]); }; };
        targets += t;
    };
    let pass = 0;
    let changed = true;
    while (changed && pass < 200) {
        changed = false;
        pass++;
        let p = n - 1;
        while (p >= 0) {
            let it = items[ch.items[p]];
            let kd = kinds[p];
            let hard = kd == 5;
            let fall = 0;
            if (!hard) {
                if (p + 1 < n) { fall = wl_live_before[p + 1]; }
                else { fall = wl_tail; };
            };
            let tgt = 0;
            let t = targets[p];
            if (t >= 0 && t < nc) {
                let at = ch.cases[t];
                if (at < n) { tgt = wl_live_before[at]; };
            };
            let lb = fall;
            let la = fall;
            if (kd == 1) {
                la = fall;
                // An inc/dec reads the old CF only when CF is live after it;
                // a %cl shift reads the whole old state when its count is 0.
                lb = 0;
                if (prevs[p] == 2) { lb = fall; }
                else if (prevs[p] == 1 && (fall & FL_CF) != 0) { lb = fall; };
            } else if (kd == 2) {
                la = fall;
                lb = 0;
            } else if (kd == 3) {
                let cc = wl_jcc_cc(it.mn).cc;
                let use = FL_ANY;
                if (wl_uses_cf(cc)) { use = use | FL_CF; };
                lb = fall | tgt | use;
                la = fall;
            } else if (kd == 4) {
                let cc = wl_setcc_cc(it.mn).cc;
                let use = FL_ANY;
                if (wl_uses_cf(cc)) { use = use | FL_CF; };
                lb = fall | use;
                la = fall;
            } else if (kd == 5) {
                // An unconditional jump carries the flags to its target case;
                // every other transfer kills them (call/ret/ud2/int3).
                lb = tgt;
                la = 0;
            };
            if (lb != wl_live_before[p]) { wl_live_before[p] = lb; changed = true; };
            if (la != wl_live_after[p]) { wl_live_after[p] = la; changed = true; };
            p--;
        };
    };
    for k in 0..nc0 {
        let at = ch.cases[k];
        let v = 0;
        if (at < n) { v = wl_live_before[at]; };
        wl_live_in[k] = v;
    };
    wl_case0 = 0;
    if (len(wl_live_in) > 0) { wl_case0 = wl_live_in[0]; };
};

// wl_analyze: wl_live_run plus S6's checks -- an external entry case with
// flags live-in is the compile error, and any internal one makes the prologue
// reload the flag state from the globals.
def wl_analyze(ctx: WCtx, ch: WChunk, items: [WItem], tail: long) -> void {
    wl_live_run(ctx, ch, items, tail);
    let nc = len(ch.cases);
    wl_fentry = false;
    for k in 0..nc {
        let ex = 0;
        if (k < len(ctx.ext)) { ex = ctx.ext[k]; };
        if (wl_live_in[k] != 0) {
            if (ex != 0) {
                let nm = "case " + tostring(k);
                if (k < len(ch.labels) && len(ch.labels[k]) > 0) { nm = ch.labels[k][0]; };
                wl_fail("web: flags are live into " + nm + " across a call or jump (not supported on --target=web)");
                return;
            };
            wl_fentry = true;
        };
    };
};

// The reverse pre-pass's entry point: the state at this chunk's case 0, given
// the state the next chunk's case 0 needs (a cap split hands the flags on).
def wl_tail_live(ctx: WCtx, ch: WChunk, items: [WItem], tail: long) -> long {
    wl_live_run(ctx, ch, items, tail);
    wl_case0
};

// Record the flag state a producer leaves, when a consumer can read it.
def wl_frec(fop: long, sz: long) -> void {
    fl_have = false;
    if (wl_cur_live == 0) { return; };
    wb_const_i32(fop);
    wb_local_set(L_FOP);
    wb_const_i32(sz);
    wb_local_set(L_FSZ);
    wb_local_get(L_TA);
    wb_local_set(L_FA);
    wb_local_get(L_TB);
    wb_local_set(L_FB);
    wb_local_get(L_TR);
    wb_local_set(L_FR);
    fl_have = true;
    fl_op = fop;
    fl_sz = sz;
};

// An inc/dec reads the CF of the state it replaces when CF is live after it.
def wl_fsave_cf(ctx: WCtx) -> void {
    if ((wl_cur_live & FL_CF) != 0) {
        if (fl_have) { wl_fv_cf(); }
        else { wl_call_cond(6); };
        wb_local_set(L_FCF);
    };
};

// zf from r
def wl_fv_zf() -> void {
    wb_local_get(L_FR);
    wb_op("i64.eqz");
};

// sf: bit sz-1 of r
def wl_fv_sf() -> void {
    wb_local_get(L_FR);
    wb_const_i32(fl_sz - 1);
    wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1);
    wb_op("i64.and");
    wb_op("i64.eqz");
    wb_op("i32.eqz");
};

// pf: even parity of r's low byte, as i32 (1 = even)
def wl_fv_pf() -> void {
    wb_local_get(L_FR);
    wb_const_i64(255);
    wb_op("i64.and");
    wb_local_set(L_T1);
    wb_local_get(L_T1); wb_const_i64(4); wb_op("i64.shr_u");
    wb_local_get(L_T1); wb_op("i64.xor"); wb_local_set(L_T1);
    wb_local_get(L_T1); wb_const_i64(2); wb_op("i64.shr_u");
    wb_local_get(L_T1); wb_op("i64.xor"); wb_local_set(L_T1);
    wb_local_get(L_T1); wb_const_i64(1); wb_op("i64.shr_u");
    wb_local_get(L_T1); wb_op("i64.xor"); wb_local_set(L_T1);
    wb_local_get(L_T1);
    wb_const_i64(1);
    wb_op("i64.and");
    wb_op("i64.eqz");
};

// sign of ((x ^ r) & (y ^ r)) at bit sz-1
def wl_fv_of_xy(x: long, y: long) -> void {
    wb_local_get(x); wb_local_get(L_FR); wb_op("i64.xor");
    wb_local_get(y); wb_local_get(L_FR); wb_op("i64.xor");
    wb_op("i64.and");
    wb_const_i32(fl_sz - 1);
    wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and");
    wb_op("i64.eqz"); wb_op("i32.eqz");
};

// The 64-bit signed multiply's overflow: $imul_of, from a and b in locals
// la/lb (S6's helper, which avoids a div_s of MIN by -1).
def wl_emit_imul_of(la: long, lb: long) -> void {
    wb_local_get(la);
    wb_op("i64.eqz");
    wb_local_get(lb);
    wb_op("i64.eqz");
    wb_op("i32.or");
    wb_if_r("imo", we.VT_I32);
    wb_const_i32(0);
    wb_else();
    wb_local_get(la);
    wb_const_i64(-1);
    wb_op("i64.eq");
    wb_if_r("imo_a", we.VT_I32);
    wb_local_get(lb);
    wb_const_i64(wl_minv(64));
    wb_op("i64.eq");
    wb_else();
    wb_local_get(lb);
    wb_const_i64(-1);
    wb_op("i64.eq");
    wb_if_r("imo_b", we.VT_I32);
    wb_local_get(la);
    wb_const_i64(wl_minv(64));
    wb_op("i64.eq");
    wb_else();
    wb_local_get(la); wb_local_get(lb); wb_op("i64.mul");
    wb_local_get(la); wb_op("i64.div_s");
    wb_local_get(lb); wb_op("i64.ne");
    wb_end();
    wb_end();
    wb_end();
};

def wl_fv_of() -> void {
    if (fl_op == FOP_ADD) {
        wl_fv_of_xy(L_FA, L_FB);
    } else if (fl_op == FOP_SUB) {
        wb_local_get(L_FA); wb_local_get(L_FB); wb_op("i64.xor");
        wb_local_get(L_FA); wb_local_get(L_FR); wb_op("i64.xor");
        wb_op("i64.and");
        wb_const_i32(fl_sz - 1); wb_op("i64.extend_i32_u");
        wb_op("i64.shr_u"); wb_const_i64(1); wb_op("i64.and");
        wb_op("i64.eqz"); wb_op("i32.eqz");
    } else if (fl_op == FOP_INC || fl_op == FOP_DEC) {
        wb_local_get(L_FR);
        wb_const_i64(if (fl_op == FOP_INC) { wl_minv(fl_sz) } else { wl_maxv(fl_sz) });
        wb_op("i64.eq");
    } else if (fl_op == FOP_NEG) {
        wb_local_get(L_FA);
        wb_const_i64(wl_minv(fl_sz));
        wb_op("i64.eq");
    } else if (fl_op == FOP_SHL) {
        wb_local_get(L_FB); wb_const_i64(1); wb_op("i64.eq");
        wb_if("shl1");
        wl_fv_cf();
        wl_fv_sf();
        wb_op("i32.xor");
        wb_else();
        wb_const_i32(0);
        wb_end();
    } else if (fl_op == FOP_SHR) {
        wb_local_get(L_FB); wb_const_i64(1); wb_op("i64.eq");
        wb_if("shr1");
        wl_fv_sf();
        wb_else();
        wb_const_i32(0);
        wb_end();
    } else if (fl_op == FOP_IMUL) {
        if (fl_sz >= 64) {
            wl_emit_imul_of(L_FA, L_FB);
        } else {
            wb_local_get(L_FA); wb_local_get(L_FB); wb_op("i64.mul");
            wb_local_set(L_T1);
            wb_local_get(L_T1);
            wl_sx(fl_sz);
            wb_local_get(L_T1);
            wb_op("i64.ne");
        };
    } else {
        wb_const_i32(0);
    };
};

// cf
def wl_fv_cf() -> void {
    if (fl_op == FOP_ADD) {
        wb_local_get(L_FR); wb_local_get(L_FA); wb_op("i64.lt_u");
    } else if (fl_op == FOP_SUB) {
        wb_local_get(L_FA); wb_local_get(L_FB); wb_op("i64.lt_u");
    } else if (fl_op == FOP_LOGIC) {
        wb_const_i32(0);
    } else if (fl_op == FOP_INC || fl_op == FOP_DEC) {
        wb_local_get(L_FCF);
    } else if (fl_op == FOP_NEG) {
        wb_local_get(L_FA); wb_op("i64.eqz"); wb_op("i32.eqz");
    } else if (fl_op == FOP_SHL) {
        wb_local_get(L_FA);
        wb_const_i32(fl_sz);
        wb_op("i64.extend_i32_u");
        wb_local_get(L_FB);
        wb_op("i64.sub");
        wb_op("i64.shr_u");
        wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    } else if (fl_op == FOP_SHR || fl_op == FOP_SAR) {
        wb_local_get(L_FA);
        wb_local_get(L_FB);
        wb_const_i64(1);
        wb_op("i64.sub");
        wb_op("i64.shr_u");
        wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    } else if (fl_op == FOP_IMUL) {
        wl_fv_of();
    } else {
        wb_const_i32(0);
    };
};

// UCOMI: x in FX, y in FY.
def wl_fv_uc_u() -> void {
    wb_local_get(L_FX); wb_local_get(L_FX); wb_op("f64.ne");
    wb_local_get(L_FY); wb_local_get(L_FY); wb_op("f64.ne");
    wb_op("i32.or");
};

def wl_fv_ucf() -> void {
    if (fl_op == FOP_UCOMI) {
        wl_fv_uc_u();
        wb_if_r("ucf", we.VT_I32);
        wb_const_i32(1);
        wb_else();
        wb_local_get(L_FX); wb_local_get(L_FY); wb_op("f64.lt");
        wb_end();
    } else {
        wl_fv_cf();
    };
};

def wl_fv_ucz() -> void {
    if (fl_op == FOP_UCOMI) {
        wl_fv_uc_u();
        wb_if_r("ucz", we.VT_I32);
        wb_const_i32(1);
        wb_else();
        wb_local_get(L_FX); wb_local_get(L_FY); wb_op("f64.eq");
        wb_end();
    } else {
        wl_fv_zf();
    };
};

def wl_fv_ucpf() -> void {
    if (fl_op == FOP_UCOMI) { wl_fv_uc_u(); } else { wl_fv_pf(); };
};

def wl_fv_ucsf() -> void {
    if (fl_op == FOP_UCOMI) { wb_const_i32(0); } else { wl_fv_sf(); };
};

// The i32 condition for cc, from the specialised producer.
def wl_cond_emit(cc: long) -> void {
    if (cc == 0) { wl_fv_ucz(); }
    else if (cc == 1) { wl_fv_ucz(); wb_op("i32.eqz"); }
    else if (cc == 2) { wl_fv_ucsf(); wl_fv_of(); wb_op("i32.ne"); }
    else if (cc == 3) { wl_fv_ucsf(); wl_fv_of(); wb_op("i32.eq"); }
    else if (cc == 4) { wl_fv_ucz(); wl_fv_ucsf(); wl_fv_of(); wb_op("i32.ne"); wb_op("i32.or"); }
    else if (cc == 5) { wl_fv_ucz(); wb_op("i32.eqz"); wl_fv_ucsf(); wl_fv_of(); wb_op("i32.eq"); wb_op("i32.and"); }
    else if (cc == 6) { wl_fv_ucf(); }
    else if (cc == 7) { wl_fv_ucf(); wb_op("i32.eqz"); }
    else if (cc == 8) { wl_fv_ucf(); wl_fv_ucz(); wb_op("i32.or"); }
    else if (cc == 9) { wl_fv_ucf(); wb_op("i32.eqz"); wl_fv_ucz(); wb_op("i32.eqz"); wb_op("i32.and"); }
    else if (cc == 10) { wl_fv_ucsf(); }
    else if (cc == 11) { wl_fv_ucsf(); wb_op("i32.eqz"); }
    else if (cc == 12) { wl_fv_ucpf(); }
    else { wl_fv_ucpf(); wb_op("i32.eqz"); };
};

// The general consumer: $cond(cc, op, size, a, b, r, x, y, fcf) (S6).
def wl_call_cond(cc: long) -> void {
    wb_const_i32(cc);
    wb_local_get(L_FOP);
    wb_local_get(L_FSZ);
    wb_local_get(L_FA);
    wb_local_get(L_FB);
    wb_local_get(L_FR);
    wb_local_get(L_FX);
    wb_local_get(L_FY);
    wb_local_get(L_FCF);
    wb_call(wl_cond_fi);
};

// The target case's flags are live: hand them to the globals so a
// suspension can resume at that case.
def wl_fl_stash() -> void {
    wb_local_get(L_FOP); wb_global_set(G_FOP);
    wb_local_get(L_FSZ); wb_global_set(G_FSZ);
    wb_local_get(L_FA); wb_global_set(G_FA);
    wb_local_get(L_FB); wb_global_set(G_FB);
    wb_local_get(L_FR); wb_global_set(G_FR);
    wb_local_get(L_FX); wb_global_set(G_FX);
    wb_local_get(L_FY); wb_global_set(G_FY);
    wb_local_get(L_FCF); wb_global_set(G_FCF);
};

def wl_fl_load() -> void {
    wb_global_get(G_FOP); wb_local_set(L_FOP);
    wb_global_get(G_FSZ); wb_local_set(L_FSZ);
    wb_global_get(G_FA); wb_local_set(L_FA);
    wb_global_get(G_FB); wb_local_set(L_FB);
    wb_global_get(G_FR); wb_local_set(L_FR);
    wb_global_get(G_FX); wb_local_set(L_FX);
    wb_global_get(G_FY); wb_local_set(L_FY);
    wb_global_get(G_FCF); wb_local_set(L_FCF);
};

// ── control transfers ────────────────────────────────────────────────────
def wl_sync() -> void {
    for i in 0..16 {
        wb_local_get(L_R0 + i);
        wb_global_set(G_R0 + i);
    };
    for i in 0..16 {
        wb_local_get(L_X0 + i);
        wb_global_set(G_X0 + i);
    };
};

// $fuel -= 1; when it runs out, hand the machine back to JS with the PC of
// the transfer's target (S8's preemption point).  fl asks for the flag
// state to go to the globals too, for a resume case that reads it.
def wl_fuel(ctx: WCtx, tchunk: long, tkase: long, fl: bool) -> void {
    wb_global_get(G_FUEL);
    wb_const_i32(1);
    wb_op("i32.sub");
    wb_global_set(G_FUEL);
    wb_global_get(G_FUEL);
    wb_const_i32(0);
    wb_op("i32.le_s");
    wb_if("fuel");
    wb_const_i32(2);
    wb_global_set(G_WHY);
    wb_const_i64(wl_token(tchunk, tkase));
    wb_global_set(G_PC);
    if (fl) { wl_fl_stash(); };
    wl_sync();
    wb_return();
    wb_end();
};

// The prologue's fuel point: the entry case is in $e, not a constant.
def wl_fuel_entry(ctx: WCtx) -> void {
    wb_global_get(G_FUEL);
    wb_const_i32(1);
    wb_op("i32.sub");
    wb_global_set(G_FUEL);
    wb_global_get(G_FUEL);
    wb_const_i32(0);
    wb_op("i32.le_s");
    wb_if("fuel0");
    wb_const_i32(2);
    wb_global_set(G_WHY);
    wb_const_i64(TOKEN_BASE + ctx.chunk * TOKEN_CHUNK);
    wb_local_get(L_E);
    wb_op("i64.extend_i32_u");
    wb_op("i64.add");
    wb_global_set(G_PC);
    wl_sync();
    wb_return();
    wb_end();
};

def wl_br_case(ctx: WCtx, j: long, cond: bool) -> void {
    if (j > ctx.kase) {
        if (cond) { wb_br_if("b" + tostring(j)); }
        else { wb_br("b" + tostring(j)); };
    } else {
        let fl = false;
        if (j < len(wl_live_in)) { fl = (wl_live_in[j] & FL_ANY) != 0; };
        if (cond) {
            wb_if("bk");
            wb_const_i32(j);
            wb_local_set(L_S);
            wl_fuel(ctx, ctx.chunk, j, fl);
            wb_br("L");
            wb_end();
        } else {
            wb_const_i32(j);
            wb_local_set(L_S);
            wl_fuel(ctx, ctx.chunk, j, fl);
            wb_br("L");
        };
    };
};

// A transfer to another chunk: leave the machine in globals, tail-call.
def wl_cross(ctx: WCtx, tchunk: long, tkase: long) -> void {
    wl_sync();
    wl_fuel(ctx, tchunk, tkase, false);
    wb_const_i32(tkase);
    wb_return_call(ctx.chunk_fi0 + tchunk);
};

def wl_push_token(ctx: WCtx, tok: long) -> void {
    wb_local_get(L_R0 + 4);
    wl_chk_local(ctx, L_R0 + 4);
    wb_const_i64(8);
    wb_op("i64.sub");
    wb_local_set(L_R0 + 4);
    wb_local_get(L_R0 + 4);
    wb_op("i32.wrap_i64");
    wb_const_i64(tok);
    wb_mem("i64.store", 3, 0);
};

// Decode a token in local n and tail-call the chunk it names (S7).
def wl_decode_indirect(ctx: WCtx, n: long) -> void {
    wb_local_get(n);
    wb_const_i64(40);
    wb_op("i64.shr_u");
    wb_const_i64(1);
    wb_op("i64.ne");
    wb_if("tokbad");
    wb_const_i32(11);
    wb_call(ctx.trap_fi);
    wb_unreachable();
    wb_end();
    wb_local_get(n);
    wb_const_i64(TOKEN_MASK);
    wb_op("i64.and");
    wb_op("i32.wrap_i64");
    wb_local_get(n);
    wb_const_i64(20);
    wb_op("i64.shr_u");
    wb_const_i64(TOKEN_MASK);
    wb_op("i64.and");
    wb_op("i32.wrap_i64");
    wb_return_call_indirect(ctx.chunk_ty, 0);
};

def wl_trap(ctx: WCtx, sig: long) -> void {
    wb_const_i32(sig);
    wb_call(ctx.trap_fi);
    wb_unreachable();
};

// The trap body inside an if (no fall-through: the block stays unreachable).
def wl_trap_in_if(ctx: WCtx, sig: long) -> void {
    wb_const_i32(sig);
    wb_call(ctx.trap_fi);
    wb_unreachable();
};

def wl_syscall(ctx: WCtx) -> void {
    let next_tok = wl_token(ctx.chunk, ctx.kase + 1);
    let fl = false;
    if (ctx.kase + 1 < len(wl_live_in)) { fl = (wl_live_in[ctx.kase + 1] & FL_ANY) != 0; };
    // Step 1: every register this chunk wrote, the flags when the resume
    // point can read them, to the globals -- the kernel may snapshot us.
    wl_sync();
    if (fl) { wl_fl_stash(); };
    wb_const_i64(next_tok);
    wb_global_set(G_PC);
    wb_local_get(L_R0);
    wb_local_get(L_R0 + 7);
    wb_local_get(L_R0 + 6);
    wb_local_get(L_R0 + 2);
    wb_local_get(L_R0 + 10);
    wb_local_get(L_R0 + 8);
    wb_local_get(L_R0 + 9);
    wb_call(ctx.sys_fi);
    wb_local_set(L_R0);
    wb_const_i64(next_tok);
    wb_local_set(L_R0 + 1);
    wb_const_i64(0);
    wb_local_set(L_R0 + 11);
    wb_global_get(G_WHY);
    wb_const_i32(0);
    wb_op("i32.ne");
    wb_if("yield");
    wl_sync();
    wb_return();
    wb_end();
};

// ── ALU with a recorded flag producer ────────────────────────────────────
def wl_alu(ctx: WCtx, it: WItem, fop: long, opname: str) -> void {
    let sz = wl_size(it);
    let src = it.ops[0];
    let dst = it.ops[1];
    if (wl_reg(dst)) {
        wl_get(ctx, dst, sz, it.where);
        wb_local_set(L_TA);
        wl_get(ctx, src, sz, it.where);
        wb_local_set(L_TB);
        wb_local_get(L_TA);
        wb_local_get(L_TB);
        wb_op(opname);
        if (sz < 64) {
            wb_const_i64(wl_mask(sz));
            wb_op("i64.and");
        };
        wb_local_set(L_TR);
        wl_frec(fop, sz);
        wb_local_get(L_TR);
        wl_put_reg(dst, sz);
    } else {
        wl_addr(ctx, dst, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wb_mem(wl_load_name(sz, false), 0, 0);
        wb_local_set(L_TA);
        wl_get(ctx, src, sz, it.where);
        wb_local_set(L_TB);
        wb_local_get(L_TA);
        wb_local_get(L_TB);
        wb_op(opname);
        if (sz < 64) {
            wb_const_i64(wl_mask(sz));
            wb_op("i64.and");
        };
        wb_local_set(L_TR);
        wl_frec(fop, sz);
        wl_addr_from_tm(ctx);
        wb_local_get(L_TR);
        wb_mem(wl_store_name(sz), 0, 0);
    };
};

// cmp/test: a flag producer that writes nothing.
def wl_cmp(ctx: WCtx, it: WItem, fop: long, opname: str) -> void {
    let sz = wl_size(it);
    let a = it.ops[0];
    let b = it.ops[1];
    if (wl_reg(b)) {
        wl_get(ctx, b, sz, it.where);
        wb_local_set(L_TA);
    } else {
        wl_addr(ctx, b, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wb_mem(wl_load_name(sz, false), 0, 0);
        wb_local_set(L_TA);
    };
    wl_get(ctx, a, sz, it.where);
    wb_local_set(L_TB);
    wb_local_get(L_TA);
    wb_local_get(L_TB);
    wb_op(opname);
    if (sz < 64) {
        wb_const_i64(wl_mask(sz));
        wb_op("i64.and");
    };
    wb_local_set(L_TR);
    wl_frec(fop, sz);
};

def wl_shift(ctx: WCtx, it: WItem, fop: long, opname: str) -> void {
    let sz = wl_size(it);
    let src = it.ops[0];
    let dst = it.ops[1];
    let imm = src.k == K.imm;
    let c0 = if (imm) { src.v & (if (sz >= 64) { 63 } else { 31 }) } else { 0 };
    if (imm && c0 == 0) {
        // A shift by zero does not touch the flags at all; the destination
        // still receives its own value.
        wl_get(ctx, dst, sz, it.where);
        wl_put_reg(dst, sz);
        return;
    };
    wl_get(ctx, src, 64, it.where);
    wb_const_i64(if (sz >= 64) { 63 } else { 31 });
    wb_op("i64.and");
    wb_local_set(L_TB);
    wl_get(ctx, dst, sz, it.where);
    wb_local_set(L_TA);
    if (fop == FOP_SAR && sz < 64) {
        wb_local_get(L_TA);
        wl_sx(sz);
    } else {
        wb_local_get(L_TA);
    };
    wb_local_get(L_TB);
    wb_op(opname);
    if (sz < 64) {
        wb_const_i64(wl_mask(sz));
        wb_op("i64.and");
    };
    wb_local_set(L_TR);
    if (imm) {
        wl_frec(fop, sz);
    } else {
        // A runtime count: the flags change only when the masked count is
        // not zero, so the state is written conditionally and cannot be
        // folded at compile time.
        fl_have = false;
        wb_local_get(L_TB);
        wb_const_i64(0);
        wb_op("i64.ne");
        wb_if("sh0");
        if (wl_cur_live != 0) {
            wb_const_i32(fop); wb_local_set(L_FOP);
            wb_const_i32(sz); wb_local_set(L_FSZ);
            wb_local_get(L_TA); wb_local_set(L_FA);
            wb_local_get(L_TB); wb_local_set(L_FB);
            wb_local_get(L_TR); wb_local_set(L_FR);
        };
        wb_end();
    };
    wb_local_get(L_TR);
    wl_put_reg(dst, sz);
};

def wl_incdec(ctx: WCtx, it: WItem, fop: long, delta: long) -> void {
    let sz = wl_size(it);
    let dst = it.ops[0];
    if (wl_reg(dst)) {
        wl_get(ctx, dst, sz, it.where);
        wb_local_set(L_TA);
        wl_fsave_cf(ctx);
        wb_local_get(L_TA);
        wb_const_i64(delta);
        wb_op("i64.add");
        if (sz < 64) {
            wb_const_i64(wl_mask(sz));
            wb_op("i64.and");
        };
        wb_local_set(L_TR);
        wl_frec(fop, sz);
        wb_local_get(L_TR);
        wl_put_reg(dst, sz);
    } else {
        wl_addr(ctx, dst, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wb_mem(wl_load_name(sz, false), 0, 0);
        wb_local_set(L_TA);
        wl_fsave_cf(ctx);
        wb_local_get(L_TA);
        wb_const_i64(delta);
        wb_op("i64.add");
        if (sz < 64) {
            wb_const_i64(wl_mask(sz));
            wb_op("i64.and");
        };
        wb_local_set(L_TR);
        wl_frec(fop, sz);
        wl_addr_from_tm(ctx);
        wb_local_get(L_TR);
        wb_mem(wl_store_name(sz), 0, 0);
    };
};

// ── mov, lea, push/pop ───────────────────────────────────────────────────
def wl_mov(ctx: WCtx, it: WItem) -> void {
    let sz = wl_size(it);
    let a = it.ops[0];
    let b = it.ops[1];
    if (wl_xmm(b)) {
        if (wl_xmm(a) || a.k == K.mem || a.k == K.fs) {
            wl_get_f(ctx, a, it.where);
            wl_put_f(b, it.where);
        } else {
            wl_get(ctx, a, 64, it.where);
            wb_op("f64.reinterpret_i64");
            wl_put_f(b, it.where);
        };
    } else if (wl_xmm(a)) {
        if (b.k == K.mem || b.k == K.fs) {
            wl_addr_tm(ctx, b, it.where, false);
            wl_get_f(ctx, a, it.where);
            wb_mem("f64.store", 0, 0);
        } else {
            wl_get_f(ctx, a, it.where);
            wb_op("i64.reinterpret_f64");
            wl_put_reg(b, 64);
        };
    } else if (wl_reg(b)) {
        wl_get(ctx, a, sz, it.where);
        wl_put_reg(b, sz);
    } else {
        wl_addr_tm(ctx, b, it.where, false);
        wl_get(ctx, a, sz, it.where);
        wb_mem(wl_store_name(sz), 0, 0);
    };
};

def wl_movx(ctx: WCtx, it: WItem, ssz: long, signed: bool) -> void {
    let a = it.ops[0];
    let b = it.ops[1];
    if (wl_reg(a)) {
        wb_local_get(L_R0 + a.n);
        wb_const_i64(wl_mask(ssz));
        wb_op("i64.and");
        if (signed) { wl_sx(ssz); };
    } else {
        wl_addr_tm(ctx, a, it.where, false);
        wb_mem(wl_load_name(ssz, signed), 0, 0);
    };
    wl_put_reg(b, 64);
};

def wl_push(ctx: WCtx, it: WItem) -> void {
    let a = it.ops[0];
    wl_get(ctx, a, 64, it.where);
    wb_local_set(L_T0);
    wb_local_get(L_R0 + 4);
    wl_chk_local(ctx, L_R0 + 4);
    wb_const_i64(8);
    wb_op("i64.sub");
    wb_local_set(L_R0 + 4);
    wb_local_get(L_R0 + 4);
    wb_op("i32.wrap_i64");
    wb_local_get(L_T0);
    wb_mem("i64.store", 3, 0);
};

def wl_pop(ctx: WCtx, it: WItem) -> void {
    let a = it.ops[0];
    wb_local_get(L_R0 + 4);
    wl_chk_local(ctx, L_R0 + 4);
    wb_op("i32.wrap_i64");
    wb_mem("i64.load", 3, 0);
    wb_local_set(L_T0);
    wb_local_get(L_R0 + 4);
    wb_const_i64(8);
    wb_op("i64.add");
    wb_local_set(L_R0 + 4);
    wb_local_get(L_T0);
    wl_put_reg(a, 64);
};

def wl_lea(ctx: WCtx, it: WItem) -> void {
    let dst = it.ops[1];
    wl_addr(ctx, it.ops[0], it.where, true);
    wl_put_reg(dst, dst.size);
};

def wl_setcc(ctx: WCtx, it: WItem, cc: long) -> void {
    if (fl_have) { wl_cond_emit(cc); }
    else { wl_call_cond(cc); };
    wb_op("i64.extend_i32_u");
    wl_put_reg(it.ops[0], 8);
};

def wl_xchg(ctx: WCtx, it: WItem) -> void {
    let ma = it.ops[0];
    let mb = it.ops[1];
    if (wl_reg(ma) && wl_reg(mb)) {
        wl_get(ctx, ma, 64, it.where);
        wb_local_set(L_T0);
        wl_get(ctx, mb, 64, it.where);
        wb_local_set(L_T1);
        wb_local_get(L_T1);
        wl_put_reg(ma, 64);
        wb_local_get(L_T0);
        wl_put_reg(mb, 64);
    } else if (wl_reg(ma)) {
        // reg <- mem
        wl_addr_tm(ctx, mb, it.where, false);
        wb_mem("i64.load", 3, 0);
        wb_local_set(L_T0);
        wl_addr(ctx, mb, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wl_get(ctx, ma, 64, it.where);
        wb_mem("i64.store", 3, 0);
        wb_local_get(L_T0);
        wl_put_reg(ma, 64);
    } else {
        // mem <- reg
        wl_addr_tm(ctx, ma, it.where, false);
        wb_mem("i64.load", 3, 0);
        wb_local_set(L_T0);
        wl_addr(ctx, ma, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wl_get(ctx, mb, 64, it.where);
        wb_mem("i64.store", 3, 0);
        wb_local_get(L_T0);
        wl_put_reg(mb, 64);
    };
};

// ── SSE (S5) ─────────────────────────────────────────────────────────────
// The exact NaN rule: quiet(dst) if dst was NaN, else quiet(src) if src was
// NaN, else x86's default NaN.
def wl_nan_fix() -> void {
    wb_local_get(L_FR2); wb_local_get(L_FR2); wb_op("f64.ne");
    wb_if("nan");
    wb_local_get(L_FD); wb_local_get(L_FD); wb_op("f64.ne");
    wb_if("nand");
    wb_local_get(L_FD); wb_op("i64.reinterpret_f64");
    wb_const_i64(wl_quiet_bit());
    wb_op("i64.or");
    wb_op("f64.reinterpret_i64");
    wb_local_set(L_FR2);
    wb_else();
    wb_local_get(L_FS); wb_local_get(L_FS); wb_op("f64.ne");
    wb_if("nans");
    wb_local_get(L_FS); wb_op("i64.reinterpret_f64");
    wb_const_i64(wl_quiet_bit());
    wb_op("i64.or");
    wb_op("f64.reinterpret_i64");
    wb_local_set(L_FR2);
    wb_else();
    wb_const_i64(wl_default_nan());
    wb_op("f64.reinterpret_i64");
    wb_local_set(L_FR2);
    wb_end();
    wb_end();
    wb_end();
};

def wl_sse_arith(ctx: WCtx, it: WItem, opname: str) -> void {
    let src = it.ops[0];
    let dst = it.ops[1];
    wl_get_f(ctx, dst, it.where);
    wb_local_set(L_FD);
    wl_get_f(ctx, src, it.where);
    wb_local_set(L_FS);
    wb_local_get(L_FD);
    wb_local_get(L_FS);
    wb_op(opname);
    wb_local_set(L_FR2);
    wl_nan_fix();
    wb_local_get(L_FR2);
    wl_put_f(dst, it.where);
};

def wl_sqrtsd(ctx: WCtx, it: WItem) -> void {
    let src = it.ops[0];
    let dst = it.ops[1];
    wl_get_f(ctx, src, it.where);
    wb_local_set(L_FS);
    wb_local_get(L_FS);
    wb_local_set(L_FD);
    wb_local_get(L_FS);
    wb_op("f64.sqrt");
    wb_local_set(L_FR2);
    wl_nan_fix();
    wb_local_get(L_FR2);
    wl_put_f(dst, it.where);
};

def wl_sse_bits(ctx: WCtx, it: WItem, opname: str) -> void {
    let src = it.ops[0];
    let dst = it.ops[1];
    wl_get_f(ctx, dst, it.where);
    wb_op("i64.reinterpret_f64");
    wl_get_f(ctx, src, it.where);
    wb_op("i64.reinterpret_f64");
    wb_op(opname);
    wb_op("f64.reinterpret_i64");
    wl_put_f(dst, it.where);
};

def wl_ucomisd(ctx: WCtx, it: WItem) -> void {
    let src = it.ops[0];
    let dst = it.ops[1];
    wl_get_f(ctx, dst, it.where);
    wb_local_set(L_FX);
    wl_get_f(ctx, src, it.where);
    wb_local_set(L_FY);
    fl_have = false;
    if (wl_cur_live != 0) {
        wb_const_i32(FOP_UCOMI); wb_local_set(L_FOP);
        wb_const_i32(64); wb_local_set(L_FSZ);
        wb_const_i64(0); wb_local_set(L_FA);
        wb_const_i64(0); wb_local_set(L_FB);
        wb_const_i64(0); wb_local_set(L_FR);
        wb_const_i32(0); wb_local_set(L_FCF);
        fl_have = true;
        fl_op = FOP_UCOMI;
        fl_sz = 64;
    };
};

def wl_cvtsi2sd(ctx: WCtx, it: WItem) -> void {
    let src = it.ops[0];
    let dst = it.ops[1];
    let ssz = if (wl_reg(src)) { src.size } else { 64 };
    if (wl_reg(src)) {
        wb_local_get(L_R0 + src.n);
        if (ssz < 64) {
            wb_const_i64(wl_mask(ssz));
            wb_op("i64.and");
            wl_sx(ssz);
        };
    } else {
        wl_addr_tm(ctx, src, it.where, false);
        wb_mem(wl_load_name(ssz, true), 0, 0);
    };
    wb_op("f64.convert_i64_s");
    wl_put_f(dst, it.where);
};

// NaN and out-of-range give INT_MIN, as x86's indefinite integer does.
def wl_cvttsd2si(ctx: WCtx, it: WItem) -> void {
    let src = it.ops[0];
    let dst = it.ops[1];
    let ssz = if (wl_reg(dst)) { dst.size } else { 64 };
    let bits = if (ssz == 32) { 32 } else { 64 };
    let lim = if (bits == 32) { 4703607502818349056 } else { 4890909195324358656 };
    let minv = if (bits == 32) { 2147483648 } else { wl_minv(64) };
    wl_get_f(ctx, src, it.where);
    wb_local_set(L_FD);
    wb_local_get(L_FD); wb_local_get(L_FD); wb_op("f64.eq");
    wb_local_get(L_FD);
    wb_const_f64(lim);
    wb_op("f64.lt");
    wb_op("i32.and");
    wb_local_get(L_FD);
    wb_const_f64(lim);
    wb_op("f64.neg");
    wb_op("f64.ge");
    wb_op("i32.and");
    wb_if_r("cvt", we.VT_I64);
    wb_local_get(L_FD);
    if (bits == 32) { wb_op("i32.trunc_f64_s"); wb_op("i64.extend_i32_u"); }
    else { wb_op("i64.trunc_f64_s"); };
    wb_else();
    wb_const_i64(minv);
    wb_end();
    if (ssz == 32) {
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_T0);
        wb_local_get(L_T0);
        wl_put_reg(dst, 32);
    } else {
        wl_put_reg(dst, 64);
    };
};

def wl_bswap(ctx: WCtx, it: WItem, sz: long) -> void {
    let a = it.ops[0];
    wl_get(ctx, a, sz, it.where);
    wb_local_set(L_T0);
    if (sz >= 64) {
        wb_local_get(L_T0); wb_const_i64(71777214294589695); wb_op("i64.and");
        wb_const_i64(8); wb_op("i64.shl");
        wb_local_get(L_T0); wb_const_i64(8); wb_op("i64.shr_u");
        wb_const_i64(71777214294589695); wb_op("i64.and");
        wb_op("i64.or"); wb_local_set(L_T0);
        wb_local_get(L_T0); wb_const_i64(281470681808895); wb_op("i64.and");
        wb_const_i64(16); wb_op("i64.shl");
        wb_local_get(L_T0); wb_const_i64(16); wb_op("i64.shr_u");
        wb_const_i64(281470681808895); wb_op("i64.and");
        wb_op("i64.or"); wb_local_set(L_T0);
        wb_local_get(L_T0); wb_const_i64(32); wb_op("i64.shl");
        wb_local_get(L_T0); wb_const_i64(32); wb_op("i64.shr_u");
        wb_op("i64.or");
    } else {
        wb_local_get(L_T0); wb_const_i64(16711935); wb_op("i64.and");
        wb_const_i64(8); wb_op("i64.shl");
        wb_local_get(L_T0); wb_const_i64(8); wb_op("i64.shr_u");
        wb_const_i64(16711935); wb_op("i64.and");
        wb_op("i64.or"); wb_local_set(L_T0);
        wb_local_get(L_T0); wb_const_i64(65535); wb_op("i64.and");
        wb_const_i64(16); wb_op("i64.shl");
        wb_local_get(L_T0); wb_const_i64(16); wb_op("i64.shr_u");
        wb_const_i64(65535); wb_op("i64.and");
        wb_op("i64.or");
    };
    if (sz >= 64) { wl_put_reg(a, 64); } else { wl_put_reg(a, 32); };
};

def wl_bsr(ctx: WCtx, it: WItem) -> void {
    let sz = wl_size(it);
    let src = it.ops[0];
    let dst = it.ops[1];
    if (!wl_reg(dst)) {
        wl_fail("web: bsr needs a register destination (" + it.where + ")");
        return;
    };
    wl_get(ctx, src, sz, it.where);
    wb_local_set(L_T0);
    wb_local_get(L_T0);
    wb_op("i64.eqz");
    wb_if("bsrz");
    fl_have = false;
    if (wl_cur_live != 0) {
        wb_const_i32(FOP_BSRZ); wb_local_set(L_FOP);
        wb_const_i32(sz); wb_local_set(L_FSZ);
        wb_local_get(L_T0); wb_local_set(L_FA);
        wb_const_i64(0); wb_local_set(L_FB);
        wb_const_i64(0); wb_local_set(L_FR);
    };
    wb_else();
    wb_const_i64(if (sz >= 64) { 63 } else { 31 });
    wb_local_get(L_T0);
    wb_op("i64.clz");
    wb_op("i64.sub");
    wb_local_set(L_TR);
    wb_local_get(L_TR);
    wl_put_reg(dst, 64);
    fl_have = false;
    if (wl_cur_live != 0) {
        wb_const_i32(FOP_BSRNZ); wb_local_set(L_FOP);
        wb_const_i32(sz); wb_local_set(L_FSZ);
        wb_local_get(L_T0); wb_local_set(L_FA);
        wb_const_i64(0); wb_local_set(L_FB);
        wb_local_get(L_TR); wb_local_set(L_FR);
    };
    wb_end();
};

// ── idiv / div (S5's 128-bit helpers and their trap edges) ───────────────
def wl_div(ctx: WCtx, it: WItem, signed: bool) -> void {
    let sz = wl_size(it);
    let src = it.ops[0];
    wl_get(ctx, src, sz, it.where);
    wb_local_set(L_T0);
    wb_local_get(L_T0);
    wb_op("i64.eqz");
    wb_if("dz");
    wl_trap_in_if(ctx, 8);
    wb_end();
    if (sz >= 64) {
        if (signed) {
            wb_local_get(L_R0 + 2);
            wb_local_get(L_R0);
            wb_const_i64(63);
            wb_op("i64.shr_s");
            wb_op("i64.eq");
        } else {
            wb_local_get(L_R0 + 2);
            wb_op("i64.eqz");
        };
        wb_if("dfast");
        if (signed) {
            wb_local_get(L_R0);
            wb_const_i64(wl_minv(64));
            wb_op("i64.eq");
            wb_local_get(L_T0);
            wb_const_i64(-1);
            wb_op("i64.eq");
            wb_op("i32.and");
            wb_if("dovf");
            wl_trap_in_if(ctx, 8);
            wb_end();
        };
        wb_local_get(L_R0);
        wb_local_get(L_T0);
        wb_op(if (signed) { "i64.div_s" } else { "i64.div_u" });
        wb_local_set(L_T1);
        wb_local_get(L_R0);
        wb_local_get(L_T0);
        wb_op(if (signed) { "i64.rem_s" } else { "i64.rem_u" });
        wb_local_set(L_T2);
        wb_local_get(L_T1);
        wb_local_set(L_R0);
        wb_local_get(L_T2);
        wb_local_set(L_R0 + 2);
        wb_else();
        wb_local_get(L_R0 + 2);
        wb_local_get(L_R0);
        wb_local_get(L_T0);
        wb_call(if (signed) { ctx.divs_fi } else { ctx.divu_fi });
        wb_global_get(G_Q);
        wb_local_set(L_R0);
        wb_global_get(G_RM);
        wb_local_set(L_R0 + 2);
        wb_end();
    } else {
        wb_local_get(L_R0 + 2);
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_T1);
        wb_local_get(L_R0);
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_T2);
        if (signed) {
            wb_local_get(L_T2);
            wb_const_i64(31);
            wb_op("i64.shr_u");
            wb_const_i64(1);
            wb_op("i64.and");
            wb_const_i64(0);
            wb_op("i64.sub");
            wb_const_i64(4294967295);
            wb_op("i64.and");
        } else {
            wb_const_i64(0);
        };
        wb_local_get(L_T1);
        wb_op("i64.eq");
        wb_if("dfast32");
        if (signed) {
            wb_local_get(L_T2);
            wb_const_i64(wl_mask(32));
            wb_op("i64.and");
            wb_op("i64.extend32_s");
            wb_local_set(L_TA);
            wb_local_get(L_T0);
            wb_op("i64.extend32_s");
            wb_local_set(L_TB);
            wb_local_get(L_TA);
            wb_const_i64(wl_minv(64));
            wb_op("i64.eq");
            wb_local_get(L_TB);
            wb_const_i64(-1);
            wb_op("i64.eq");
            wb_op("i32.and");
            wb_if("dovf32");
            wl_trap_in_if(ctx, 8);
            wb_end();
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.div_s");
            wb_local_set(L_T1);
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.rem_s");
            wb_local_set(L_T2);
        } else {
            wb_local_get(L_T2);
            wb_local_set(L_TA);
            wb_local_get(L_T0);
            wb_local_set(L_TB);
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.div_u");
            wb_local_set(L_T1);
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.rem_u");
            wb_local_set(L_T2);
        };
        wb_local_get(L_T1);
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_R0);
        wb_local_get(L_T2);
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_R0 + 2);
        wb_else();
        wb_local_get(L_T1);
        wb_const_i64(32);
        wb_op("i64.shl");
        wb_local_get(L_T2);
        wb_op("i64.or");
        wb_local_set(L_TA);
        if (signed) {
            wb_local_get(L_T0);
            wb_op("i64.extend32_s");
            wb_local_set(L_TB);
            wb_local_get(L_TA);
            wb_const_i64(wl_minv(64));
            wb_op("i64.eq");
            wb_local_get(L_TB);
            wb_const_i64(-1);
            wb_op("i64.eq");
            wb_op("i32.and");
            wb_if("dovfw");
            wl_trap_in_if(ctx, 8);
            wb_end();
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.div_s");
            wb_local_set(L_T1);
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.rem_s");
            wb_local_set(L_T2);
            wb_local_get(L_T1);
            wb_const_i64(2147483647);
            wb_op("i64.gt_s");
            wb_local_get(L_T1);
            wb_const_i64(-2147483648);
            wb_op("i64.lt_s");
            wb_op("i32.or");
        } else {
            wb_local_get(L_T0);
            wb_local_set(L_TB);
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.div_u");
            wb_local_set(L_T1);
            wb_local_get(L_TA);
            wb_local_get(L_TB);
            wb_op("i64.rem_u");
            wb_local_set(L_T2);
            wb_local_get(L_T1);
            wb_const_i64(4294967295);
            wb_op("i64.gt_u");
        };
        wb_if("dovfq");
        wl_trap_in_if(ctx, 8);
        wb_end();
        wb_local_get(L_T1);
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_R0);
        wb_local_get(L_T2);
        wb_const_i64(4294967295);
        wb_op("i64.and");
        wb_local_set(L_R0 + 2);
        wb_end();
    };
    // idiv/div leave the flags undefined: a consumer after one must not use
    // a stale state, so the producer knowledge is dropped.
    fl_have = false;
};

// ── one instruction ──────────────────────────────────────────────────────
type WCC = { ok: bool, cc: long };

def wl_jcc_cc(mn: str) -> WCC {
    if (mn == "je" || mn == "jz") { { ok: true, cc: 0 } }
    else if (mn == "jne" || mn == "jnz") { { ok: true, cc: 1 } }
    else if (mn == "jl") { { ok: true, cc: 2 } }
    else if (mn == "jge") { { ok: true, cc: 3 } }
    else if (mn == "jle") { { ok: true, cc: 4 } }
    else if (mn == "jg") { { ok: true, cc: 5 } }
    else if (mn == "jb" || mn == "jc") { { ok: true, cc: 6 } }
    else if (mn == "jae" || mn == "jnc") { { ok: true, cc: 7 } }
    else if (mn == "jbe") { { ok: true, cc: 8 } }
    else if (mn == "ja") { { ok: true, cc: 9 } }
    else if (mn == "js") { { ok: true, cc: 10 } }
    else if (mn == "jns") { { ok: true, cc: 11 } }
    else if (mn == "jp") { { ok: true, cc: 12 } }
    else if (mn == "jnp") { { ok: true, cc: 13 } }
    else { { ok: false, cc: 0 } }
};

def wl_setcc_cc(mn: str) -> WCC {
    if (mn == "sete" || mn == "setz") { { ok: true, cc: 0 } }
    else if (mn == "setne" || mn == "setnz") { { ok: true, cc: 1 } }
    else if (mn == "setl") { { ok: true, cc: 2 } }
    else if (mn == "setge") { { ok: true, cc: 3 } }
    else if (mn == "setle") { { ok: true, cc: 4 } }
    else if (mn == "setg") { { ok: true, cc: 5 } }
    else if (mn == "setb" || mn == "setc") { { ok: true, cc: 6 } }
    else if (mn == "setae" || mn == "setnc") { { ok: true, cc: 7 } }
    else if (mn == "setbe") { { ok: true, cc: 8 } }
    else if (mn == "seta") { { ok: true, cc: 9 } }
    else if (mn == "sets") { { ok: true, cc: 10 } }
    else if (mn == "setns") { { ok: true, cc: 11 } }
    else if (mn == "setp") { { ok: true, cc: 12 } }
    else if (mn == "setnp") { { ok: true, cc: 13 } }
    else { { ok: false, cc: 0 } }
};

def wl_call_direct(ctx: WCtx, it: WItem) -> void {
    let op = it.ops[0];
    let idx = wl_lab_index(ctx, op.name);
    if (idx < 0) {
        wl_fail("web: undefined label '" + op.name + "' at " + it.where);
    } else {
        let l = ctx.labels[idx];
        if (!l.code) {
            wl_fail("web: call to data label '" + op.name + "' at " + it.where);
        } else {
            wl_push_token(ctx, wl_token(ctx.chunk, ctx.kase + 1));
            wl_sync();
            wb_const_i32(l.kase);
            wb_return_call(ctx.chunk_fi0 + l.chunk);
        };
    };
};

def wl_jmp_target(ctx: WCtx, it: WItem) -> void {
    let op = it.ops[0];
    let idx = wl_lab_index(ctx, op.name);
    if (idx < 0) {
        wl_fail("web: undefined label '" + op.name + "' at " + it.where);
    } else {
        let l = ctx.labels[idx];
        if (!l.code) {
            wl_fail("web: jump to data label '" + op.name + "' at " + it.where);
        } else if (l.chunk == ctx.chunk) {
            wl_br_case(ctx, l.kase, false);
        } else {
            wl_cross(ctx, l.chunk, l.kase);
        };
    };
};

def wl_ret(ctx: WCtx, extra: long) -> void {
    wb_local_get(L_R0 + 4);
    wl_chk_local(ctx, L_R0 + 4);
    wb_op("i32.wrap_i64");
    wb_mem("i64.load", 3, 0);
    wb_local_set(L_T0);
    wb_local_get(L_R0 + 4);
    wb_const_i64(8 + extra);
    wb_op("i64.add");
    wb_local_set(L_R0 + 4);
    wl_sync();
    wl_decode_indirect(ctx, L_T0);
};

// jmp *%r / call *%r (and the memory forms): the token in T1.
def wl_ind_target(ctx: WCtx, op: Operand, where: str) -> long {
    if (op.k == K.ind) { L_R0 + op.n }
    else {
        wl_addr_tm(ctx, op, where, false);
        wb_mem("i64.load", 3, 0);
        wb_local_set(L_T1);
        L_T1
    }
};

def wl_fuel_reg(ctx: WCtx, n: long) -> void {
    wb_global_get(G_FUEL);
    wb_const_i32(1);
    wb_op("i32.sub");
    wb_global_set(G_FUEL);
    wb_global_get(G_FUEL);
    wb_const_i32(0);
    wb_op("i32.le_s");
    wb_if("fuelr");
    wb_const_i32(2);
    wb_global_set(G_WHY);
    wb_local_get(n);
    wb_global_set(G_PC);
    wl_sync();
    wb_return();
    wb_end();
};

def wl_neg(ctx: WCtx, it: WItem) -> void {
    let sz = wl_size(it);
    let a = it.ops[0];
    if (wl_reg(a)) {
        wl_get(ctx, a, sz, it.where);
        wb_local_set(L_TA);
        wb_const_i64(0);
        wb_local_get(L_TA);
        wb_op("i64.sub");
        if (sz < 64) { wb_const_i64(wl_mask(sz)); wb_op("i64.and"); };
        wb_local_set(L_TR);
        wl_frec(FOP_NEG, sz);
        wb_local_get(L_TR);
        wl_put_reg(a, sz);
    } else {
        wl_addr(ctx, a, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wb_mem(wl_load_name(sz, false), 0, 0);
        wb_local_set(L_TA);
        wb_const_i64(0);
        wb_local_get(L_TA);
        wb_op("i64.sub");
        if (sz < 64) { wb_const_i64(wl_mask(sz)); wb_op("i64.and"); };
        wb_local_set(L_TR);
        wl_frec(FOP_NEG, sz);
        wl_addr_from_tm(ctx);
        wb_local_get(L_TR);
        wb_mem(wl_store_name(sz), 0, 0);
    };
};

def wl_not(ctx: WCtx, it: WItem) -> void {
    let sz = wl_size(it);
    let a = it.ops[0];
    if (wl_reg(a)) {
        wl_get(ctx, a, sz, it.where);
        wb_const_i64(-1);
        wb_op("i64.xor");
        if (sz < 64) { wb_const_i64(wl_mask(sz)); wb_op("i64.and"); };
        wl_put_reg(a, sz);
    } else {
        wl_addr(ctx, a, it.where, false);
        wb_local_set(L_TM);
        wl_addr_from_tm(ctx);
        wb_mem(wl_load_name(sz, false), 0, 0);
        wb_const_i64(-1);
        wb_op("i64.xor");
        if (sz < 64) { wb_const_i64(wl_mask(sz)); wb_op("i64.and"); };
        wb_local_set(L_T0);
        wl_addr_from_tm(ctx);
        wb_local_get(L_T0);
        wb_mem(wl_store_name(sz), 0, 0);
    };
};

def wl_item(ctx: WCtx, it: WItem) -> void {
    if (wl_err != "") { return; };
    let mn = it.mn;
    let jc = wl_jcc_cc(mn);
    let sc = wl_setcc_cc(mn);
    if (mn == "push") { wl_push(ctx, it); }
    else if (mn == "pop") { wl_pop(ctx, it); }
    else if (mn == "call") {
        if (it.ops[0].k == K.lbl) {
            wl_call_direct(ctx, it);
        } else {
            let n = wl_ind_target(ctx, it.ops[0], it.where);
            wl_push_token(ctx, wl_token(ctx.chunk, ctx.kase + 1));
            wl_sync();
            wl_decode_indirect(ctx, n);
        };
    } else if (mn == "jmp") {
        if (it.ops[0].k == K.lbl) {
            wl_jmp_target(ctx, it);
        } else {
            let n = wl_ind_target(ctx, it.ops[0], it.where);
            wl_sync();
            wl_fuel_reg(ctx, n);
            wl_decode_indirect(ctx, n);
        };
    } else if (mn == "ret") {
        if (len(it.ops) > 0) { wl_ret(ctx, it.ops[0].v); } else { wl_ret(ctx, 0); };
    } else if (jc.ok) {
        let op = it.ops[0];
        let idx = wl_lab_index(ctx, op.name);
        if (idx < 0) {
            wl_fail("web: undefined label '" + op.name + "' at " + it.where);
        } else {
            let l = ctx.labels[idx];
            if (!l.code) {
                wl_fail("web: jump to data label '" + op.name + "' at " + it.where);
            } else {
                if (fl_have) { wl_cond_emit(jc.cc); }
                else { wl_call_cond(jc.cc); };
                if (l.chunk == ctx.chunk) {
                    wl_br_case(ctx, l.kase, true);
                } else {
                    wb_if("xj");
                    wl_cross(ctx, l.chunk, l.kase);
                    wb_end();
                };
            };
        };
    } else if (sc.ok) {
        wl_setcc(ctx, it, sc.cc);
    } else if (mn == "syscall") {
        wl_syscall(ctx);
    } else if (mn == "ud2") {
        wl_trap(ctx, 4);
    } else if (mn == "int3") {
        wl_trap(ctx, 5);
    } else if (mn == "nop" || mn == "pause" || mn == "cld") {
        // nothing
    } else if (mn == "rep_stosq") {
        // rep stosq (F3 48 AB): [rdi] = rax, rcx times, rdi += 8 each.  The
        // shared region runtime writes these three bytes itself (arch/
        // regions.s), because the encoder has no rep prefix.
        wb_block("rsout");
        wb_loop("rs");
        wb_local_get(L_R0 + 1);
        wb_op("i64.eqz");
        wb_br_if("rsout");
        wb_local_get(L_R0 + 7);
        wl_chk_local(ctx, L_R0 + 7);
        wb_op("i32.wrap_i64");
        wb_local_get(L_R0);
        wb_mem("i64.store", 3, 0);
        wb_local_get(L_R0 + 7);
        wb_const_i64(8);
        wb_op("i64.add");
        wb_local_set(L_R0 + 7);
        wb_local_get(L_R0 + 1);
        wb_const_i64(1);
        wb_op("i64.sub");
        wb_local_set(L_R0 + 1);
        wb_br("rs");
        wb_end();
        wb_end();
    } else if (mn == "mov" || mn == "movq" || mn == "movl" || mn == "movw" || mn == "movb") {
        wl_mov(ctx, it);
    } else if (mn == "movzbq") {
        wl_movx(ctx, it, 8, false);
    } else if (mn == "movzwq") {
        wl_movx(ctx, it, 16, false);
    } else if (mn == "movsbq") {
        wl_movx(ctx, it, 8, true);
    } else if (mn == "movswq") {
        wl_movx(ctx, it, 16, true);
    } else if (mn == "movslq") {
        wl_movx(ctx, it, 32, true);
    } else if (mn == "lea") {
        wl_lea(ctx, it);
    } else if (mn == "add") {
        wl_alu(ctx, it, FOP_ADD, "i64.add");
    } else if (mn == "sub") {
        wl_alu(ctx, it, FOP_SUB, "i64.sub");
    } else if (mn == "and") {
        wl_alu(ctx, it, FOP_LOGIC, "i64.and");
    } else if (mn == "or") {
        wl_alu(ctx, it, FOP_LOGIC, "i64.or");
    } else if (mn == "xor") {
        wl_alu(ctx, it, FOP_LOGIC, "i64.xor");
    } else if (mn == "cmp") {
        wl_cmp(ctx, it, FOP_SUB, "i64.sub");
    } else if (mn == "test") {
        wl_cmp(ctx, it, FOP_LOGIC, "i64.and");
    } else if (mn == "imul") {
        wl_alu(ctx, it, FOP_IMUL, "i64.mul");
    } else if (mn == "shl" || mn == "sal") {
        wl_shift(ctx, it, FOP_SHL, "i64.shl");
    } else if (mn == "shr") {
        wl_shift(ctx, it, FOP_SHR, "i64.shr_u");
    } else if (mn == "sar") {
        wl_shift(ctx, it, FOP_SAR, "i64.shr_s");
    } else if (mn == "inc") {
        wl_incdec(ctx, it, FOP_INC, 1);
    } else if (mn == "dec") {
        wl_incdec(ctx, it, FOP_DEC, -1);
    } else if (mn == "neg") {
        wl_neg(ctx, it);
    } else if (mn == "not") {
        wl_not(ctx, it);
    } else if (mn == "xchg") {
        wl_xchg(ctx, it);
    } else if (mn == "bsr") {
        wl_bsr(ctx, it);
    } else if (mn == "bswapq") {
        wl_bswap(ctx, it, 64);
    } else if (mn == "bswapl") {
        wl_bswap(ctx, it, 32);
    } else if (mn == "idiv") {
        wl_div(ctx, it, true);
    } else if (mn == "div") {
        wl_div(ctx, it, false);
    } else if (mn == "cqo") {
        wb_local_get(L_R0);
        wb_const_i64(63);
        wb_op("i64.shr_s");
        wb_local_set(L_R0 + 2);
    } else if (mn == "movsd") {
        wl_mov(ctx, it);
    } else if (mn == "addsd") {
        wl_sse_arith(ctx, it, "f64.add");
    } else if (mn == "subsd") {
        wl_sse_arith(ctx, it, "f64.sub");
    } else if (mn == "mulsd") {
        wl_sse_arith(ctx, it, "f64.mul");
    } else if (mn == "divsd") {
        wl_sse_arith(ctx, it, "f64.div");
    } else if (mn == "sqrtsd") {
        wl_sqrtsd(ctx, it);
    } else if (mn == "ucomisd") {
        wl_ucomisd(ctx, it);
    } else if (mn == "cvtsi2sd") {
        wl_cvtsi2sd(ctx, it);
    } else if (mn == "cvttsd2si") {
        wl_cvttsd2si(ctx, it);
    } else if (mn == "xorpd") {
        wl_sse_bits(ctx, it, "i64.xor");
    } else if (mn == "andpd") {
        wl_sse_bits(ctx, it, "i64.and");
    } else if (mn == "orpd") {
        wl_sse_bits(ctx, it, "i64.or");
    } else if (mn == "cli" || mn == "sti" || mn == "hlt" || mn == "iretq" || mn == "outb" || mn == "inb" || mn == "lidt" || mn.starts_with("a64_")) {
        wl_fail("web: '" + mn + "' is a kernel/AArch64 instruction (" + it.where + ")");
    } else {
        wl_fail("web: unsupported instruction '" + mn + "' (" + it.where + ")");
    };
    // Every unconditional transfer ends the straight-line run whose flags a
    // consumer may fold; a conditional one does not touch the flags at all.
    if (mn == "jmp" || mn == "call" || mn == "ret" || mn == "ud2" || mn == "int3") {
        fl_have = false;
    };
};

// ── a whole chunk: prologue, dispatch loop, cases, exits ─────────────────
def wl_chunk_body(ctx: WCtx, ch: WChunk, items: [WItem], next_chunk: long) -> [byte] {
    wl_err = "";
    wl_cond_fi = ctx.cond_fi;
    wl_analyze(ctx, ch, items, ctx.tail);
    if (wl_err != "") {
        we.wb_reset([]);
        return we.wb_finish();
    };
    we.wb_reset(wl_locals());
    for i in 0..16 {
        wb_global_get(G_R0 + i);
        wb_local_set(L_R0 + i);
        wb_global_get(G_X0 + i);
        wb_local_set(L_X0 + i);
    };
    if (wl_fentry) { wl_fl_load(); };
    wb_local_get(L_E);
    wb_local_set(L_S);
    wl_fuel_entry(ctx);
    wb_loop("L");
    wb_block("trap");
    let n = ctx.ncases;
    let j = n - 1;
    while (j >= 0) {
        wb_block("b" + tostring(j));
        j--;
    };
    wb_local_get(L_S);
    let bnames: [str] = [];
    for k in 0..n { bnames += "b" + tostring(k); };
    wb_br_table(bnames, "trap");
    let k = 0;
    while (k < n && wl_err == "") {
        wb_end();
        wl_fl_reset();
        let ck: WCtx = { ...ctx, kase: k };
        let from = ch.cases[k];
        let to = len(ch.items);
        if (k + 1 < len(ch.cases)) { to = ch.cases[k + 1]; };
        let p = from;
        while (p < to && wl_err == "") {
            let it = items[ch.items[p]];
            if (it.kind == "loc") {
                wl_locrow(ctx.chunk_fi0 + ctx.chunk, we.wb_pos(), it.file, it.line);
            } else {
                wl_cur_live = if (p < len(wl_live_after)) { wl_live_after[p] } else { 0 };
                wl_item(ck, it);
            };
            p++;
        };
        k++;
    };
    if (wl_err == "") {
        wl_sync();
        if (next_chunk >= 0) {
            // The next chunk may be a cap split of this run and read the
            // flags at its case 0: hand them over in the globals.
            wl_fl_stash();
            wb_const_i32(0);
            wb_return_call(ctx.chunk_fi0 + next_chunk);
        } else {
            wb_const_i32(3);
            wb_global_set(G_WHY);
            wb_return();
        };
        wb_end();
        wb_const_i32(11);
        wb_call(ctx.trap_fi);
        wb_unreachable();
        wb_end();
        wb_unreachable();
    } else {
        wb_unreachable();
    };
    we.wb_finish()
};

// ── the internal helpers: $cond, $div128u, $div128s (S5/S6) ─────────────
// $cond(cc, op, size, a, b, r, x, y, fcf) -> i32
def wl_cond_body() -> [byte] {
    we.wb_reset([we.VT_I64, we.VT_I64, we.VT_I64, we.VT_I64, we.VT_I64,
        we.VT_I32, we.VT_I32, we.VT_I32, we.VT_I32, we.VT_I32, we.VT_I32]);
    let l_mask = 9;
    let l_a = 10;
    let l_b = 11;
    let l_r = 12;
    let l_t = 13;
    let l_cf = 14;
    let l_of = 15;
    let l_zf = 16;
    let l_sf = 17;
    let l_pf = 18;
    let l_u = 19;
    wb_local_get(2);
    wb_const_i32(64);
    wb_op("i32.ge_s");
    wb_if_r("cm", we.VT_I64);
    wb_const_i64(-1);
    wb_else();
    wb_const_i64(1);
    wb_local_get(2);
    wb_const_i32(63);
    wb_op("i32.and");
    wb_op("i64.extend_i32_u");
    wb_op("i64.shl");
    wb_const_i64(1);
    wb_op("i64.sub");
    wb_end();
    wb_local_set(l_mask);
    wb_local_get(3); wb_local_get(l_mask); wb_op("i64.and"); wb_local_set(l_a);
    wb_local_get(4); wb_local_get(l_mask); wb_op("i64.and"); wb_local_set(l_b);
    wb_local_get(5); wb_local_get(l_mask); wb_op("i64.and"); wb_local_set(l_r);
    wb_local_get(l_r); wb_op("i64.eqz"); wb_local_set(l_zf);
    wb_local_get(l_r);
    wb_local_get(2); wb_const_i32(1); wb_op("i32.sub"); wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_local_set(l_sf);
    wb_local_get(l_r); wb_const_i64(255); wb_op("i64.and"); wb_local_set(l_t);
    wb_local_get(l_t); wb_const_i64(4); wb_op("i64.shr_u");
    wb_local_get(l_t); wb_op("i64.xor"); wb_local_set(l_t);
    wb_local_get(l_t); wb_const_i64(2); wb_op("i64.shr_u");
    wb_local_get(l_t); wb_op("i64.xor"); wb_local_set(l_t);
    wb_local_get(l_t); wb_const_i64(1); wb_op("i64.shr_u");
    wb_local_get(l_t); wb_op("i64.xor"); wb_local_set(l_t);
    wb_local_get(l_t); wb_const_i64(1); wb_op("i64.and"); wb_op("i64.eqz");
    wb_local_set(l_pf);
    wb_local_get(1); wb_const_i32(FOP_UCOMI); wb_op("i32.eq");
    wb_if("cu");
    wb_local_get(6); wb_local_get(6); wb_op("f64.ne");
    wb_local_get(7); wb_local_get(7); wb_op("f64.ne");
    wb_op("i32.or");
    wb_local_set(l_u);
    wb_local_get(6); wb_local_get(7); wb_op("f64.ge"); wb_op("i32.eqz");
    wb_local_set(l_cf);
    wb_local_get(l_u); wb_local_set(l_pf);
    wb_local_get(l_u);
    wb_local_get(6); wb_local_get(7); wb_op("f64.eq");
    wb_op("i32.or");
    wb_local_set(l_zf);
    wb_const_i32(0); wb_local_set(l_sf);
    wb_const_i32(0); wb_local_set(l_of);
    wb_else();
    wb_const_i32(0); wb_local_set(l_cf);
    wb_local_get(1); wb_const_i32(FOP_ADD); wb_op("i32.eq");
    wb_if("cadd");
    wb_local_get(l_r); wb_local_get(l_a); wb_op("i64.lt_u"); wb_local_set(l_cf);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_SUB); wb_op("i32.eq");
    wb_if("csub");
    wb_local_get(l_a); wb_local_get(l_b); wb_op("i64.lt_u"); wb_local_set(l_cf);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_NEG); wb_op("i32.eq");
    wb_if("cneg");
    wb_local_get(l_a); wb_op("i64.eqz"); wb_op("i32.eqz"); wb_local_set(l_cf);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_INC); wb_op("i32.eq");
    wb_local_get(1); wb_const_i32(FOP_DEC); wb_op("i32.eq");
    wb_op("i32.or");
    wb_if("cinc");
    wb_local_get(8); wb_local_set(l_cf);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_SHL); wb_op("i32.eq");
    wb_if("cshl");
    wb_local_get(l_b); wb_op("i64.eqz");
    wb_if_r("cshl0", we.VT_I32);
    wb_const_i32(0);
    wb_else();
    wb_local_get(l_a);
    wb_local_get(2); wb_op("i64.extend_i32_u");
    wb_local_get(l_b); wb_op("i64.sub");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_end();
    wb_local_set(l_cf);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_SHR); wb_op("i32.eq");
    wb_local_get(1); wb_const_i32(FOP_SAR); wb_op("i32.eq");
    wb_op("i32.or");
    wb_if("cshr");
    wb_local_get(l_b); wb_op("i64.eqz");
    wb_if_r("cshr0", we.VT_I32);
    wb_const_i32(0);
    wb_else();
    wb_local_get(l_a);
    wb_local_get(l_b); wb_const_i64(1); wb_op("i64.sub");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_end();
    wb_local_set(l_cf);
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_const_i32(0); wb_local_set(l_of);
    wb_local_get(1); wb_const_i32(FOP_ADD); wb_op("i32.eq");
    wb_if("oadd");
    wb_local_get(l_a); wb_local_get(l_r); wb_op("i64.xor");
    wb_local_get(l_b); wb_local_get(l_r); wb_op("i64.xor");
    wb_op("i64.and");
    wb_local_get(2); wb_const_i32(1); wb_op("i32.sub");
    wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_SUB); wb_op("i32.eq");
    wb_if("osub");
    wb_local_get(l_a); wb_local_get(l_b); wb_op("i64.xor");
    wb_local_get(l_a); wb_local_get(l_r); wb_op("i64.xor");
    wb_op("i64.and");
    wb_local_get(2); wb_const_i32(1); wb_op("i32.sub");
    wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_INC); wb_op("i32.eq");
    wb_if("oinc");
    wb_local_get(l_r);
    wb_local_get(l_mask); wb_const_i64(1); wb_op("i64.shr_u"); wb_const_i64(1); wb_op("i64.add");
    wb_op("i64.eq");
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_DEC); wb_op("i32.eq");
    wb_if("odec");
    wb_local_get(l_r);
    wb_local_get(l_mask); wb_const_i64(1); wb_op("i64.shr_u");
    wb_op("i64.eq");
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_NEG); wb_op("i32.eq");
    wb_if("oneg");
    wb_local_get(l_a);
    wb_local_get(l_mask); wb_const_i64(1); wb_op("i64.shr_u"); wb_const_i64(1); wb_op("i64.add");
    wb_op("i64.eq");
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_SHL); wb_op("i32.eq");
    wb_if("oshl");
    wb_local_get(l_b); wb_const_i64(1); wb_op("i64.eq");
    wb_if_r("oshl1", we.VT_I32);
    wb_local_get(l_cf);
    wb_local_get(l_r);
    wb_local_get(2); wb_const_i32(1); wb_op("i32.sub"); wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_op("i32.xor");
    wb_else();
    wb_const_i32(0);
    wb_end();
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_SHR); wb_op("i32.eq");
    wb_if("oshr");
    wb_local_get(l_b); wb_const_i64(1); wb_op("i64.eq");
    wb_if_r("oshr1", we.VT_I32);
    wb_local_get(l_a);
    wb_local_get(2); wb_const_i32(1); wb_op("i32.sub"); wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and"); wb_op("i32.wrap_i64");
    wb_else();
    wb_const_i32(0);
    wb_end();
    wb_local_set(l_of);
    wb_else();
    wb_local_get(1); wb_const_i32(FOP_IMUL); wb_op("i32.eq");
    wb_if("oimul");
    wl_emit_imul_of(l_a, l_b);
    wb_local_set(l_of);
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    wb_end();
    let cc = 0;
    while (cc < 14) {
        wb_local_get(0); wb_const_i32(cc); wb_op("i32.eq");
        if (cc == 0) { wb_local_get(l_zf); }
        else if (cc == 1) { wb_local_get(l_zf); wb_op("i32.eqz"); }
        else if (cc == 2) { wb_local_get(l_sf); wb_local_get(l_of); wb_op("i32.ne"); }
        else if (cc == 3) { wb_local_get(l_sf); wb_local_get(l_of); wb_op("i32.eq"); }
        else if (cc == 4) { wb_local_get(l_zf); wb_local_get(l_sf); wb_local_get(l_of); wb_op("i32.ne"); wb_op("i32.or"); }
        else if (cc == 5) { wb_local_get(l_zf); wb_op("i32.eqz"); wb_local_get(l_sf); wb_local_get(l_of); wb_op("i32.eq"); wb_op("i32.and"); }
        else if (cc == 6) { wb_local_get(l_cf); }
        else if (cc == 7) { wb_local_get(l_cf); wb_op("i32.eqz"); }
        else if (cc == 8) { wb_local_get(l_cf); wb_local_get(l_zf); wb_op("i32.or"); }
        else if (cc == 9) { wb_local_get(l_cf); wb_op("i32.eqz"); wb_local_get(l_zf); wb_op("i32.eqz"); wb_op("i32.and"); }
        else if (cc == 10) { wb_local_get(l_sf); }
        else if (cc == 11) { wb_local_get(l_sf); wb_op("i32.eqz"); }
        else if (cc == 12) { wb_local_get(l_pf); }
        else { wb_local_get(l_pf); wb_op("i32.eqz"); };
        wb_op("i32.and");
        if (cc > 0) { wb_op("i32.or"); };
        cc++;
    };
    we.wb_finish()
};

// $div128u(hi, lo, d): unsigned 128/64, leaving the quotient in $q and the
// remainder in $rm; a quotient that does not fit in 64 bits traps (SIGFPE).
def wl_divu_body(trap_fi: long) -> [byte] {
    we.wb_reset([we.VT_I64, we.VT_I64, we.VT_I64, we.VT_I64, we.VT_I32]);
    let l_rem = 3;
    let l_q = 4;
    let l_bit = 5;
    let l_carry = 6;
    let l_i = 7;
    wb_local_get(2); wb_op("i64.eqz");
    wb_if("du0");
    wb_const_i32(8); wb_call(trap_fi); wb_unreachable();
    wb_end();
    wb_local_get(0); wb_local_get(2); wb_op("i64.ge_u");
    wb_if("duovf");
    wb_const_i32(8); wb_call(trap_fi); wb_unreachable();
    wb_end();
    wb_const_i64(0); wb_local_set(l_rem);
    wb_const_i64(0); wb_local_set(l_q);
    wb_const_i32(63); wb_local_set(l_i);
    wb_loop("du");
    wb_local_get(1);
    wb_local_get(l_i); wb_op("i64.extend_i32_u");
    wb_op("i64.shr_u");
    wb_const_i64(1); wb_op("i64.and");
    wb_local_set(l_bit);
    wb_local_get(l_rem); wb_const_i64(63); wb_op("i64.shr_u");
    wb_local_set(l_carry);
    wb_local_get(l_rem); wb_const_i64(1); wb_op("i64.shl");
    wb_local_get(l_bit); wb_op("i64.or");
    wb_local_set(l_rem);
    wb_local_get(l_carry); wb_op("i64.eqz"); wb_op("i32.eqz");
    wb_local_get(l_rem); wb_local_get(2); wb_op("i64.ge_u");
    wb_op("i32.or");
    wb_if("dusub");
    wb_local_get(l_rem); wb_local_get(2); wb_op("i64.sub"); wb_local_set(l_rem);
    wb_local_get(l_q);
    wb_const_i64(1);
    wb_local_get(l_i); wb_op("i64.extend_i32_u");
    wb_op("i64.shl");
    wb_op("i64.or");
    wb_local_set(l_q);
    wb_end();
    wb_local_get(l_i); wb_const_i32(1); wb_op("i32.sub"); wb_local_set(l_i);
    wb_local_get(l_i); wb_const_i32(0); wb_op("i32.ge_s");
    wb_br_if("du");
    wb_end();
    wb_local_get(l_q); wb_global_set(G_Q);
    wb_local_get(l_rem); wb_global_set(G_RM);
    we.wb_finish()
};

// $div128s(hi, lo, d): the signed form, with the same trap edges.
def wl_divs_body(trap_fi: long, divu_fi: long) -> [byte] {
    we.wb_reset([we.VT_I64, we.VT_I64, we.VT_I64, we.VT_I32, we.VT_I32]);
    let l_hi = 3;
    let l_lo = 4;
    let l_d = 5;
    let l_neg = 6;
    let l_dneg = 7;
    wb_local_get(0); wb_const_i64(0); wb_op("i64.lt_s"); wb_local_set(l_neg);
    wb_local_get(l_neg);
    wb_if("dsneg");
    wb_local_get(1); wb_const_i64(-1); wb_op("i64.xor"); wb_const_i64(1); wb_op("i64.add");
    wb_local_set(l_lo);
    wb_local_get(0); wb_const_i64(-1); wb_op("i64.xor");
    wb_local_get(l_lo); wb_op("i64.eqz"); wb_op("i64.extend_i32_u");
    wb_op("i64.add");
    wb_local_set(l_hi);
    wb_else();
    wb_local_get(1); wb_local_set(l_lo);
    wb_local_get(0); wb_local_set(l_hi);
    wb_end();
    wb_local_get(2); wb_const_i64(0); wb_op("i64.lt_s"); wb_local_set(l_dneg);
    wb_local_get(l_dneg);
    wb_if("dsdneg");
    wb_const_i64(0); wb_local_get(2); wb_op("i64.sub"); wb_local_set(l_d);
    wb_else();
    wb_local_get(2); wb_local_set(l_d);
    wb_end();
    wb_local_get(l_hi); wb_local_get(l_lo); wb_local_get(l_d);
    wb_call(divu_fi);
    wb_local_get(l_neg); wb_local_get(l_dneg); wb_op("i32.ne");
    wb_if("dsqneg");
    wb_global_get(G_Q);
    wb_const_i64(wl_minv(64));
    wb_op("i64.gt_u");
    wb_if("dsovf1");
    wb_const_i32(8); wb_call(trap_fi); wb_unreachable();
    wb_end();
    wb_const_i64(0); wb_global_get(G_Q); wb_op("i64.sub"); wb_global_set(G_Q);
    wb_else();
    wb_global_get(G_Q);
    wb_const_i64(wl_minv(64));
    wb_op("i64.ge_u");
    wb_if("dsovf2");
    wb_const_i32(8); wb_call(trap_fi); wb_unreachable();
    wb_end();
    wb_end();
    wb_local_get(l_neg);
    wb_if("dsrem");
    wb_const_i64(0); wb_global_get(G_RM); wb_op("i64.sub"); wb_global_set(G_RM);
    wb_end();
    we.wb_finish()
};

// ── the ABI exports (S3): resume, ctx_save, ctx_load, set_fuel, why ─────
def wl_resume_body(chunk_ty: long, trap_fi: long) -> [byte] {
    we.wb_reset([]);
    wb_local_get(0);
    wb_const_i64(40);
    wb_op("i64.shr_u");
    wb_const_i64(1);
    wb_op("i64.ne");
    wb_if("tokbad");
    wb_const_i32(11);
    wb_call(trap_fi);
    wb_unreachable();
    wb_end();
    wb_local_get(0);
    wb_const_i64(TOKEN_MASK);
    wb_op("i64.and");
    wb_op("i32.wrap_i64");
    wb_local_get(0);
    wb_const_i64(20);
    wb_op("i64.shr_u");
    wb_const_i64(TOKEN_MASK);
    wb_op("i64.and");
    wb_op("i32.wrap_i64");
    wb_return_call_indirect(chunk_ty, 0);
    we.wb_finish()
};

def wl_ctx_save_body() -> [byte] {
    we.wb_reset([]);
    for i in 0..16 {
        wb_local_get(0);
        wb_global_get(G_R0 + i);
        wb_mem("i64.store", 3, i * 8);
    };
    for i in 0..16 {
        wb_local_get(0);
        wb_global_get(G_X0 + i);
        wb_mem("f64.store", 3, 128 + i * 8);
    };
    wb_local_get(0); wb_global_get(G_FS); wb_mem("i64.store", 3, 256);
    wb_local_get(0); wb_global_get(G_PC); wb_mem("i64.store", 3, 264);
    wb_local_get(0); wb_global_get(G_FOP); wb_mem("i32.store", 2, 272);
    wb_local_get(0); wb_global_get(G_FSZ); wb_mem("i32.store", 2, 280);
    wb_local_get(0); wb_global_get(G_FA); wb_mem("i64.store", 3, 288);
    wb_local_get(0); wb_global_get(G_FB); wb_mem("i64.store", 3, 296);
    wb_local_get(0); wb_global_get(G_FR); wb_mem("i64.store", 3, 304);
    wb_local_get(0); wb_global_get(G_FX); wb_mem("f64.store", 3, 312);
    wb_local_get(0); wb_global_get(G_FY); wb_mem("f64.store", 3, 320);
    wb_local_get(0); wb_global_get(G_FCF); wb_mem("i32.store", 2, 328);
    for k in 0..22 {
        wb_local_get(0);
        wb_const_i64(0);
        wb_mem("i64.store", 3, 336 + k * 8);
    };
    we.wb_finish()
};

def wl_ctx_load_body() -> [byte] {
    we.wb_reset([]);
    for i in 0..16 {
        wb_local_get(0);
        wb_mem("i64.load", 3, i * 8);
        wb_global_set(G_R0 + i);
    };
    for i in 0..16 {
        wb_local_get(0);
        wb_mem("f64.load", 3, 128 + i * 8);
        wb_global_set(G_X0 + i);
    };
    wb_local_get(0); wb_mem("i64.load", 3, 256); wb_global_set(G_FS);
    wb_local_get(0); wb_mem("i64.load", 3, 264); wb_global_set(G_PC);
    wb_local_get(0); wb_mem("i32.load", 2, 272); wb_global_set(G_FOP);
    wb_local_get(0); wb_mem("i32.load", 2, 280); wb_global_set(G_FSZ);
    wb_local_get(0); wb_mem("i64.load", 3, 288); wb_global_set(G_FA);
    wb_local_get(0); wb_mem("i64.load", 3, 296); wb_global_set(G_FB);
    wb_local_get(0); wb_mem("i64.load", 3, 304); wb_global_set(G_FR);
    wb_local_get(0); wb_mem("f64.load", 3, 312); wb_global_set(G_FX);
    wb_local_get(0); wb_mem("f64.load", 3, 320); wb_global_set(G_FY);
    wb_local_get(0); wb_mem("i32.load", 2, 328); wb_global_set(G_FCF);
    we.wb_finish()
};

def wl_set_fuel_body() -> [byte] {
    we.wb_reset([]);
    wb_local_get(0);
    wb_global_set(G_FUEL);
    we.wb_finish()
};

def wl_set_why_body() -> [byte] {
    we.wb_reset([]);
    wb_local_get(0);
    wb_global_set(G_WHY);
    we.wb_finish()
};

def wl_why_body() -> [byte] {
    we.wb_reset([]);
    wb_global_get(G_WHY);
    we.wb_finish()
};

// ── -g: the ysrc mapping ─────────────────────────────────────────────────
// One row per .loc: (function index, byte offset in the body, file, line).
// The file number is 1-based into the program's .file table.
let wl_locrows: [WLocRow] = [];

def wl_locrow(fi: long, at: long, file: long, line: long) -> void {
    wl_locrows += { func: fi, at: at, file: file, line: line };
};

def wl_locs_reset() -> void { wl_locrows = []; };
def wl_probe_reset() -> void { wl_err = ""; fl_have = false; };
def wl_locs() -> [WLocRow] { wl_locrows };

export { G_R0, G_X0, G_FS, G_FOP, G_FSZ, G_FA, G_FB, G_FR, G_FX, G_FY,
    G_FCF, G_PC, G_WHY, G_FUEL, G_Q, G_RM,
    TOKEN_BASE, TOKEN_CHUNK, TOKEN_MASK, FL_ANY, FL_CF,
    wl_err, wl_fail, wl_token, wl_locals, wl_jcc_cc, wl_setcc_cc,
    wl_fl_reset, wl_chunk_body, wl_tail_live, wl_cond_body, wl_divu_body, wl_divs_body,
    wl_resume_body, wl_ctx_save_body, wl_ctx_load_body,
    wl_set_fuel_body, wl_set_why_body, wl_why_body,
    wl_locs_reset, wl_locs, wl_probe_reset };
