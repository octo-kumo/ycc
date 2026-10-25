// wasm_enc.y — the WebAssembly binary writer: a byte buffer, LEB128, the
// section table, and a function-body builder with a control stack.
import shapes from "./wasm_shapes.y";

const VT_I32 = 0x7f;
const VT_I64 = 0x7e;
const VT_F64 = 0x7c;
const VT_FUNCREF = 0x70;

const SEC_CUSTOM = 0;
const SEC_TYPE = 1;
const SEC_IMPORT = 2;
const SEC_FUNC = 3;
const SEC_TABLE = 4;
const SEC_MEMORY = 5;
const SEC_GLOBAL = 6;
const SEC_EXPORT = 7;
const SEC_ELEMENT = 9;
const SEC_CODE = 10;
const SEC_DATA = 11;

const EK_FUNC = 0;
const EK_TABLE = 1;
const EK_MEMORY = 2;
const EK_GLOBAL = 3;

// The context layout (S3/abi.js): the host copies this 512-byte block.
const CTX_R0 = 0;
const CTX_X0 = 128;
const CTX_FS = 256;
const CTX_PC = 264;
const CTX_FOP = 272;
const CTX_FSZ = 280;
const CTX_FA = 288;
const CTX_FB = 296;
const CTX_FR = 304;
const CTX_FX = 312;
const CTX_FY = 320;
const CTX_FCF = 328;
const CTX_RESERVED = 336;
const CTX_SIZE = 512;

def wleb(v: long) -> [long] {
    let out: [long] = [];
    let x = v;
    let more = true;
    while (more) {
        let b = x & 127;
        x = x >>> 7;
        if (x != 0) { b = b | 128; } else { more = false; };
        out += b;
    };
    out
};

def wsleb(v: long) -> [long] {
    let out: [long] = [];
    let x = v;
    let more = true;
    while (more) {
        let b = x & 127;
        x = x >> 7;
        if ((x == 0 && (b & 64) == 0) || (x == -1 && (b & 64) != 0)) { more = false; } else { b = b | 128; };
        out += b;
    };
    out
};

def wle64(v: long) -> [long] {
    let out: [long] = [];
    for i in 0..8 { out += (v >>> (8 * i)) & 255; };
    out
};

def wstr(s: str) -> [long] {
    let out: [long] = wleb(len(s));
    for i in 0..len(s) { out += s[i]; };
    out
};

let wb_code: [byte] = [];
let wb_ctl: [str] = [];
let wb_err = "";

def wb_err_get() -> str { wb_err };
def wb_set_err(e: str) -> void { if (wb_err == "") { wb_err = e; }; };
// The offset of the next byte in the body being built, from the body's start
// (the local declarations included): what a -g ysrc row names.
def wb_pos() -> long { len(wb_code) };

def wb_reset(locals: [long]) -> void {
    wb_code = [];
    wb_ctl = [];
    wb_err = "";
    let groups: [long] = [];
    let i = 0;
    while (i < len(locals)) {
        let t = locals[i];
        let n = 1;
        while (i + n < len(locals) && locals[i + n] == t) { n++; };
        groups += n;
        groups += t;
        i += n;
    };
    wb_u32(len(groups) / 2);
    for k in 0..len(groups) { wb_u32(groups[k]); };
};

def wb_op(name: str) -> void {
    let c = shapes.wop_code(name);
    if (len(c) == 0) {
        wb_set_err("unknown wasm opcode '" + name + "'");
    } else {
        for i in 0..len(c) { wb_code += c[i]; }
    };
};

def wb_raw(v: long) -> void { wb_code += v & 255; };
// The LEB encoders write straight into the body: they run once per immediate
// (millions of times), so an intermediate array per call is a real cost.
def wb_u32(v: long) -> void {
    let x = v;
    let more = true;
    while (more) {
        let b = x & 127;
        x = x >>> 7;
        if (x != 0) { wb_code += b | 128; } else { wb_code += b; more = false; };
    };
};
def wb_s32(v: long) -> void { wb_sleb(v); };
def wb_s64(v: long) -> void { wb_sleb(v); };
def wb_sleb(v: long) -> void {
    let x = v;
    let more = true;
    while (more) {
        let b = x & 127;
        x = x >> 7;
        if ((x == 0 && (b & 64) == 0) || (x == -1 && (b & 64) != 0)) {
            wb_code += b;
            more = false;
        } else {
            wb_code += b | 128;
        };
    };
};

def wb_const_i32(v: long) -> void { wb_op("i32.const"); wb_s32(v); };
def wb_const_i64(v: long) -> void { wb_op("i64.const"); wb_s64(v); };
def wb_const_f64(bits: long) -> void {
    wb_op("f64.const");
    for i in 0..8 { wb_code += (bits >>> (8 * i)) & 255; };
};

def wb_local_get(n: long) -> void { wb_op("local.get"); wb_u32(n); };
def wb_local_set(n: long) -> void { wb_op("local.set"); wb_u32(n); };
def wb_local_tee(n: long) -> void { wb_op("local.tee"); wb_u32(n); };
def wb_global_get(n: long) -> void { wb_op("global.get"); wb_u32(n); };
def wb_global_set(n: long) -> void { wb_op("global.set"); wb_u32(n); };

def wb_mem(op: str, align: long, offset: long) -> void {
    wb_op(op);
    wb_u32(align);
    wb_u32(offset);
};

def wb_block(nm: str) -> void { wb_op("block"); wb_raw(0x40); wb_ctl += nm; };
def wb_loop(nm: str) -> void { wb_op("loop"); wb_raw(0x40); wb_ctl += nm; };
def wb_if(nm: str) -> void { wb_op("if"); wb_raw(0x40); wb_ctl += nm; };
// An if whose arms leave one value of type vt (0x7f i32, 0x7e i64, 0x7c f64).
def wb_if_r(nm: str, vt: long) -> void { wb_op("if"); wb_raw(vt); wb_ctl += nm; };
def wb_else() -> void { wb_op("else"); };
def wb_end() -> void {
    wb_op("end");
    if (len(wb_ctl) > 0) { wb_ctl = wb_ctl[0:len(wb_ctl) - 1]; };
};

def wb_depth(nm: str) -> long {
    let d = 0;
    let found = false;
    let i = len(wb_ctl) - 1;
    while (i >= 0 && !found) {
        if (wb_ctl[i] == nm) { d = len(wb_ctl) - 1 - i; found = true; };
        i--;
    };
    if (!found) { wb_set_err("branch to unknown frame '" + nm + "'"); };
    d
};

def wb_br(nm: str) -> void { wb_op("br"); wb_u32(wb_depth(nm)); };
def wb_br_if(nm: str) -> void { wb_op("br_if"); wb_u32(wb_depth(nm)); };
def wb_br_table(names: [str], dflt: str) -> void {
    wb_op("br_table");
    wb_u32(len(names));
    for i in 0..len(names) { wb_u32(wb_depth(names[i])); };
    wb_u32(wb_depth(dflt));
};

def wb_call(fi: long) -> void { wb_op("call"); wb_u32(fi); };
def wb_return_call(fi: long) -> void { wb_op("return_call"); wb_u32(fi); };
def wb_call_indirect(ty: long, table: long) -> void {
    wb_op("call_indirect"); wb_u32(ty); wb_u32(table);
};
def wb_return_call_indirect(ty: long, table: long) -> void {
    wb_op("return_call_indirect"); wb_u32(ty); wb_u32(table);
};
def wb_return() -> void { wb_op("return"); };
def wb_unreachable() -> void { wb_op("unreachable"); };
def wb_drop() -> void { wb_op("drop"); };

def wb_finish() -> [byte] {
    wb_code += 0x0b;
    wb_code
};

type WFunctype = { params: [long], results: [long] };
type WEncImport = { mod: str, nm: str, ty: long };
type WGlobalDef = { vt: long, init: [long] };
type WExportDef = { nm: str, kind: long, idx: long };
type WDataDef = { off: long, bytes: [byte] };
type WCustomDef = { nm: str, payload: [long] };

let we_types: [WFunctype] = [];
let we_imports: [WEncImport] = [];
let we_funcs: [long] = [];
let we_codes: [[byte]] = [];
let we_globals: [WGlobalDef] = [];
let we_exports: [WExportDef] = [];
let we_datas: [WDataDef] = [];
let we_customs: [WCustomDef] = [];
let we_mem_min = 1;
let we_mem_max = 65536;
let we_table_min = 0;
let we_table_max = 0;

def we_reset() -> void {
    we_types = [];
    we_imports = [];
    we_funcs = [];
    we_codes = [];
    we_globals = [];
    we_exports = [];
    we_datas = [];
    we_customs = [];
    we_mem_min = 1;
    we_mem_max = 65536;
    we_table_min = 0;
    we_table_max = 0;
};

def we_set_memory(min: long, max: long) -> void { we_mem_min = min; we_mem_max = max; };
def we_set_table(n: long) -> void { we_table_min = n; we_table_max = n; };

def wsame_types(a: [long], b: [long]) -> bool {
    if (len(a) != len(b)) { return false; };
    let ok = true;
    for i in 0..len(a) { if (a[i] != b[i]) { ok = false; }; };
    ok
};

def we_type(params: [long], results: [long]) -> long {
    let i = 0;
    let hit = -1;
    while (i < len(we_types)) {
        let t = we_types[i];
        if (wsame_types(t.params, params) && wsame_types(t.results, results)) { hit = i; i = len(we_types); }
        else { i++; };
    };
    if (hit >= 0) { hit } else {
        we_types += { params: params, results: results };
        len(we_types) - 1
    }
};

def we_import_func(mod: str, nm: str, ty: long) -> long {
    we_imports += { mod: mod, nm: nm, ty: ty };
    len(we_imports) - 1
};

def we_func(ty: long) -> long {
    we_funcs += ty;
    len(we_imports) + len(we_funcs) - 1
};

def we_code(body: [byte]) -> void { we_codes += [body]; };

def we_global_i32(v: long) -> void {
    let init: [long] = [0x41];
    init += wsleb(v);
    init += 0x0b;
    we_globals += { vt: VT_I32, init: init };
};
def we_global_i64(v: long) -> void {
    let init: [long] = [0x42];
    init += wsleb(v);
    init += 0x0b;
    we_globals += { vt: VT_I64, init: init };
};
def we_global_f64(bits: long) -> void {
    let init: [long] = [0x44];
    let b = wle64(bits);
    for i in 0..8 { init += b[i]; };
    init += 0x0b;
    we_globals += { vt: VT_F64, init: init };
};

def we_export(nm: str, kind: long, idx: long) -> void {
    we_exports += { nm: nm, kind: kind, idx: idx };
};
def we_data(off: long, bytes: [byte]) -> void {
    if (len(bytes) > 0) { we_datas += { off: off, bytes: bytes }; };
};
def we_custom(nm: str, text: str) -> void {
    let p: [long] = [];
    for i in 0..len(text) { p += text[i]; };
    we_customs += { nm: nm, payload: p };
};
def we_custom_bytes(nm: str, p: [long]) -> void { we_customs += { nm: nm, payload: p }; };

// The section builders write straight into [byte] buffers (packed arrays: one
// byte each), because a module is bytes, not words.
def bu32(b: [byte], v: long) -> [byte] {
    let x = v;
    let more = true;
    while (more) {
        let c = x & 127;
        x = x >>> 7;
        if (x != 0) { b += c | 128; } else { b += c; more = false; };
    };
    b
};
def bs64(b: [byte], v: long) -> [byte] {
    let x = v;
    let more = true;
    while (more) {
        let c = x & 127;
        x = x >> 7;
        if ((x == 0 && (c & 64) == 0) || (x == -1 && (c & 64) != 0)) {
            b += c;
            more = false;
        } else {
            b += c | 128;
        };
    };
    b
};
def bname(b: [byte], s: str) -> [byte] {
    let x = bu32(b, len(s));
    for i in 0..len(s) { x += s[i]; };
    x
};
def braw(b: [byte], src: [long]) -> [byte] {
    for i in 0..len(src) { b += src[i] & 255; };
    b
};

def wsec(id: long, payload: [byte]) -> [byte] {
    let out: [byte] = [];
    out += id;
    bu32(out, len(payload));
    for i in 0..len(payload) { out += payload[i]; };
    out
};

def we_finish(table_funcs: [long], names: [str], debug: bool) -> [byte] {
    let out: [byte] = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];
    let p: [byte] = [];
    bu32(p, len(we_types));
    foreach (t in we_types) {
        p += 0x60;
        bu32(p, len(t.params));
        foreach (x in t.params) { p += x; };
        bu32(p, len(t.results));
        foreach (x in t.results) { p += x; };
    };
    out += wsec(SEC_TYPE, p);
    p = [];
    bu32(p, len(we_imports));
    foreach (im in we_imports) {
        bname(p, im.mod);
        bname(p, im.nm);
        p += 0x00;
        bu32(p, im.ty);
    };
    out += wsec(SEC_IMPORT, p);
    p = [];
    bu32(p, len(we_funcs));
    foreach (ty in we_funcs) { bu32(p, ty); };
    out += wsec(SEC_FUNC, p);
    p = [];
    bu32(p, 1);
    p += VT_FUNCREF;
    p += 0x01;
    bu32(p, we_table_min);
    bu32(p, we_table_max);
    out += wsec(SEC_TABLE, p);
    p = [];
    bu32(p, 1);
    p += 0x01;
    bu32(p, we_mem_min);
    bu32(p, we_mem_max);
    out += wsec(SEC_MEMORY, p);
    p = [];
    bu32(p, len(we_globals));
    foreach (g in we_globals) {
        p += g.vt;
        p += 0x01;
        foreach (x in g.init) { p += x; };
    };
    out += wsec(SEC_GLOBAL, p);
    p = [];
    bu32(p, len(we_exports));
    foreach (e in we_exports) {
        bname(p, e.nm);
        p += e.kind;
        bu32(p, e.idx);
    };
    out += wsec(SEC_EXPORT, p);
    p = [];
    bu32(p, 1);
    p += 0x00;
    p += 0x41;
    p += 0x00;
    p += 0x0b;
    bu32(p, len(table_funcs));
    foreach (fi in table_funcs) { bu32(p, fi); };
    out += wsec(SEC_ELEMENT, p);
    p = [];
    bu32(p, len(we_codes));
    foreach (body in we_codes) {
        bu32(p, len(body));
        for i in 0..len(body) { p += body[i]; };
    };
    out += wsec(SEC_CODE, p);
    p = [];
    bu32(p, len(we_datas));
    foreach (d in we_datas) {
        p += 0x00;
        p += 0x41;
        bs64(p, d.off);
        p += 0x0b;
        bu32(p, len(d.bytes));
        for i in 0..len(d.bytes) { p += d.bytes[i]; };
    };
    out += wsec(SEC_DATA, p);
    foreach (c in we_customs) {
        let cp: [byte] = [];
        bname(cp, c.nm);
        for i in 0..len(c.payload) { cp += c.payload[i] & 255; };
        out += wsec(SEC_CUSTOM, cp);
    };
    if (debug) {
        // The name section: subsection 1, a vec of (function index, name).
        // Chunks are the only functions worth naming; the helpers keep their
        // numbers, so a diagnostic reads "name" for the code it names.
        let inner: [byte] = [];
        bu32(inner, len(names));
        for i in 0..len(names) {
            bu32(inner, len(we_imports) + i);
            bname(inner, names[i]);
        };
        let np: [byte] = [];
        bname(np, "name");
        np += 0x01;
        bu32(np, len(inner));
        for i in 0..len(inner) { np += inner[i]; };
        out += wsec(SEC_CUSTOM, np);
    };
    out
};

// ── the item model pass 1 hands the lowering ─────────────────────────────
// One flat list holds the code-path order (labels and instructions, the
// locations skipped for now); data lives in its own list because it becomes
// bytes in a segment, not cases.  A label carries both its section offset
// (off, for data sections) and its offset in the relocated text-data area
// (doff, for section-0 data labels).
type WItem = {
    kind: str,
    mn: str,
    ops: [Operand],
    name: str,
    sec: long,
    off: long,
    size: long,
    file: long,
    line: long,
    part: long,
    where: str
};

type WLabel = {
    name: str,
    sec: long,
    off: long,
    doff: long,
    code: bool,
    entry: bool,
    addr: long,
    chunk: long,
    kase: long,
    at: long,
    data_end: bool
};

// A chunk: items indexes the pass-1 item list; cases indexes items
// (case k runs from cases[k] to cases[k+1]-1); labels names each case for
// the -g name section.
type WChunk = {
    items: [long],
    cases: [long],
    labels: [[str]],
    // True when the chunk starts in the middle of a straight-line run (a cap
    // split): its case 0 is fallen into, not entered from another chunk, so
    // the flags can be handed on through the globals (S6).
    split_entry: bool
};

// Everything the lowering needs that is not the chunk itself.
type WCtx = {
    labels: [WLabel],
    lmap: [AsmLabel],
    checked: bool,
    chunk: long,
    kase: long,
    ncases: long,
    chunk_fi0: long,
    chunk_ty: long,
    trap_fi: long,
    sys_fi: long,
    cond_fi: long,
    divs_fi: long,
    divu_fi: long,
    token_base: long,
    debug: bool,
    // Per case: 1 when the case is an external entry (S6's rule).
    ext: [long],
    // The flag state the fall-through into the next chunk needs (S6): the
    // next chunk's case 0 live-in when that chunk is a cap split.
    tail: long
};

type WData = { sec: long, off: long, bytes: [byte], fix: [Fixup], size: long };

// One -g ysrc row: the function, the byte offset in its body, and the
// source position a .loc marker put there.
type WLocRow = { func: long, at: long, file: long, line: long };

export { VT_I32, VT_I64, VT_F64, VT_FUNCREF,
    SEC_CUSTOM, SEC_TYPE, SEC_IMPORT, SEC_FUNC, SEC_TABLE, SEC_MEMORY,
    SEC_GLOBAL, SEC_EXPORT, SEC_ELEMENT, SEC_CODE, SEC_DATA,
    EK_FUNC, EK_TABLE, EK_MEMORY, EK_GLOBAL,
    CTX_R0, CTX_X0, CTX_FS, CTX_PC, CTX_FOP, CTX_FSZ, CTX_FA, CTX_FB,
    CTX_FR, CTX_FX, CTX_FY, CTX_FCF, CTX_RESERVED, CTX_SIZE,
    wleb, wsleb, wle64, wstr,
    wb_err_get, wb_set_err, wb_pos, wb_reset, wb_op, wb_raw, wb_u32, wb_s32, wb_s64,
    wb_const_i32, wb_const_i64, wb_const_f64,
    wb_local_get, wb_local_set, wb_local_tee, wb_global_get, wb_global_set,
    wb_mem, wb_block, wb_loop, wb_if, wb_if_r, wb_else, wb_end, wb_depth,
    wb_br, wb_br_if, wb_br_table, wb_call, wb_return_call, wb_call_indirect,
    wb_return_call_indirect, wb_return, wb_unreachable, wb_drop, wb_finish,
    we_reset, we_set_memory, we_set_table, we_type, we_import_func, we_func,
    we_code, we_global_i32, we_global_i64, we_global_f64, we_export, we_data,
    we_custom, we_custom_bytes, we_finish, wsec };