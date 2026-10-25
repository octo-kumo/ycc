// asm.y — assemble the shared machine IR to x86-64 or AArch64.

import hostos from "./host_linux.y";
import tags from "./tags.y";
import enc from "./enc64.y";
import armenc from "./enc_a64.y";
import elf from "./elf.y";
import kelf from "./kelf.y";
import pe from "./pe.y";
import dwarf from "./dwarf.y";
import insn from "./ir.y";
import lbl from "./labels.y";
import seal from "./seal.y";

// A per-phase row of `ycc --time`, and what asm_assemble returns.
type Timing = { name: str, us: long, heap: long };
type AsmOut = { ok: bool, bytes: [byte], error: str, times: [Timing] };
// asm_assemble's own return: AsmOut plus the item count (see ycc_assemble).
type AsmOutI = { ok: bool, bytes: [byte], error: str, times: [Timing], items: long };
// A parsed number, and parse_operand's result (an Operand: enc64.y).
type AsmNum = { ok: bool, v: long };
type AsmAddr = { ok: bool, addr: long };
type OpRes = { ok: bool, op: Operand, error: str };
// A label: its section (0 .text, 1 .rodata, 2 .bss), offset there, and the
// number of items emitted before it (asm_relax recomputes the offset from
// that, since relaxing a branch moves everything after it).
type AsmLabel = { name: str, sec: long, off: long, at_item: long };
type AsmItem = { sec: long, off: long, len: long, kind: str, bytes: [byte], fix: [Fixup], br: long };
type AsmContent = { err: str, sec: long, offs: [long], item: AsmItem };
type AsmSt = { sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str };
type LinkPart = { ir: [long], txt: [str], text: str, fno: long, loc: bool };
// A part after its text has been split into lines: exactly one of `lines` and
// `ir` is set.
type Seg = { lines: [str], ir: [long], txt: [str], fno: long, loc: bool };
// The state the IR path threads: asm_st widened with the line counter, which
// is per part now.
type IrSt = { sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str, lno: long };
type AsmBytes = { bytes: [byte], err: str };

def is_digit_ch(c: byte) -> bool {
    c >= '0' && c <= '9'
};

// An octal digit.
def is_oct_ch(c: byte) -> bool {
    c >= '0' && c <= '7'
};

// A letter or `_`.
def is_alpha_ch(c: byte) -> bool {
    c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
};

// parse a decimal integer (optional leading -). Returns {ok, v}.
def parse_num(s: str) -> AsmNum {
    let neg = false;
    let i = 0;
    if (s[0:1] == "-") {
        neg = true;
        i = 1;
    }
    if (i >= len(s)) {
        { ok: false, v: 0 }
    } else {
        parse_num_go(s, i, neg)
    }
};

def parse_num_go(s: str, i: long, neg: bool) -> AsmNum {
    let v = 0;
    let ok = true;
    while (i < len(s)) {
        let c = s[i];
        if (is_digit_ch(c)) {
            v = v * 10 + c - '0';
        } else {
            ok = false;
        };
        i++;
    };
    { ok: ok, v: if (neg) { 0 - v } else { v } }
};

def is_num_text(s: str) -> bool {
    parse_num(s).ok
};

// Split operands on top-level commas (ignore commas inside parens).
def split_ops(s: str) -> [str] {
    let out: [str] = [];
    let depth = 0;
    let start = 0;
    let i = 0;
    let n = len(s);
    while (i < n) {
        let b = s[i];
        if (b == '(') { depth++ };
        if (b == ')') { depth-- };
        if (b == ',') {
            if (depth == 0) {
                out += trim(s[start:i]);
                start = i + 1;
            }
        }
        i ++;
    };
    out += trim(s[start:n]);
    out
};

def parse_operand(t: str) -> OpRes {
    // NOTE: dispatch by SHAPE into dedicated callees (see parser.y
    // parse_type_tail note): each callee builds ONE op shape, so branch
    // gates never compare disjoint literals ({ok:false,op:{}} vs reg/lbl).
    if (t == "") {
        parse_operand_empty(t)
    } else {
        parse_operand_nonempty(t)
    }
};

def parse_operand_empty(t: str) -> OpRes {
    { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "empty operand" }
};

def parse_operand_nonempty(t: str) -> OpRes {
    // `*%reg` — register-indirect call/jump target (closure code pointers).
    if (t[0:1] == "*") {
        parse_operand_ind(t)
    } else if (t[0:1] == "%") {
        parse_operand_reg(t)
    } else {
        parse_operand_noreg(t)
    }
};

def parse_operand_ind(t: str) -> OpRes {
    // (split: *-gate above narrows; the rest must be a 64-bit register.)
    let r = t[1:];
    let n = enc.reg_num(r);
    if (n < 0) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "unknown register '" + r + "'" }
    } else {
        { ok: true, op: { k: K.ind, n: n, size: enc.reg_size(r), v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "" }
    }
};

def parse_operand_fs(t: str) -> OpRes {
    parse_operand_seg(t, 0)
};

def parse_operand_seg(t: str, seg: long) -> OpRes {
    let r = parse_num(t[4:]);
    if (!r.ok) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad segment operand '" + t + "'" }
    } else {
        { ok: true, op: { k: K.fs, n: seg, size: 64, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: r.v, rip: false, lbl: "" }, error: "" }
    }
};

def parse_operand_reg(t: str) -> OpRes {
    // (split: %-gate above narrows; this body sees registers, and
    // `%fs:N`, which no register name matches.)
    let n = enc.reg_num(t);
    if (n < 0) {
        if (t[0:4] == "%fs:") {
            parse_operand_fs(t)
        } else if (t[0:4] == "%gs:") {
            parse_operand_seg(t, 1)
        } else {
            { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "unknown register '" + t + "'" }
        }
    } else {
        { ok: true, op: { k: K.reg, n: n, size: enc.reg_size(t), v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "" }
    }
};

def parse_operand_noreg(t: str) -> OpRes {
    if (t[0:1] == "$") {
        parse_operand_imm(t)
    } else {
        parse_operand_memlbl(t)
    }
};

def parse_operand_imm(t: str) -> OpRes {
    // (split: $-gate above narrows; strips the $ and parses the immediate.)
    parse_imm(t[1:])
};

def parse_operand_memlbl(t: str) -> OpRes {
    if (index_of(t, "(") >= 0) {
        parse_mem(t)
    } else {
        { ok: true, op: { k: K.lbl, n: 0, size: 0, v: 0, a: "", b: "", name: t, base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "" }
    }
};

def parse_imm(s: str) -> OpRes {
    // $a-b label difference, else decimal number
    let dash = index_of(s[1:], "-");
    if (len(s) > 0) {
        parse_imm_alpha(s, dash)
    } else {
        parse_imm_num(s)
    }
};

def parse_imm_alpha(s: str, dash: long) -> OpRes {
    // (split: len>0 narrows; this body checks the alpha gate only.)
    if (is_alpha_ch(s[0])) {
        parse_imm_diff(s, dash)
    } else {
        parse_imm_num(s)
    }
};

def parse_imm_diff(s: str, dash: long) -> OpRes {
    // (split: alpha-gate above narrows; diff-shape built ONLY here.)
    if (dash >= 0) {
        { ok: true, op: { k: K.diff, n: 0, size: 0, v: 0, a: (s[0:dash + 1]), b: (s[dash + 2:]), name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "" }
    } else {
        parse_imm_num(s)
    }
};

def parse_imm_num(s: str) -> OpRes {
    // (split from parse_imm: the label-diff gate above narrows; this body
    // sees plain decimal immediates only.)
    let r = parse_num(s);
    if (r.ok) {
        { ok: true, op: { k: K.imm, n: 0, size: 0, v: r.v, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "" }
    } else {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad immediate '" + s + "'" }
    }
};

def parse_mem(t: str) -> OpRes {
    // dispatch by SHAPE (see parse_operand note): `8(%rbp)` has a head,
    // `(%rbx,%rcx,1)` does not.
    let open = index_of(t, "(");
    let head = trim(t[0:open]);
    let parts = split_ops((t[open + 1:len(t) - 1]));
    if (head != "") {
        parse_mem_head(t, head, parts)
    } else {
        parse_mem_regs(t, parts, 0)
    }
};

def parse_mem_head(t: str, head: str, parts: [str]) -> OpRes {
    // (split: non-empty head narrows; a numeric displacement, a rip-relative
    // label, or a label with a byte offset into a table.)
    if (is_num_text(head)) {
        parse_mem_disp(t, head, parts)
    } else {
        let plus = index_of(head, "+");
        if (plus < 0) {
            parse_mem_rip(t, head, parts)
        } else {
            parse_mem_ripoff(t, head, trim(head[plus + 1:]), parts)
        }
    }
};

def parse_mem_ripoff(t: str, head: str, off: str, parts: [str]) -> OpRes {
    if (!is_num_text(off)) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad table offset '" + off + "'" }
    } else {
        parse_mem_ripdisp(t, head, 0, parts)
    }
};

def parse_mem_rip(t: str, head: str, parts: [str]) -> OpRes {
    parse_mem_ripdisp(t, head, 0, parts)
};

// placeholder

def parse_mem_ripdisp(t: str, lbl: str, disp: long, parts: [str]) -> OpRes {
    if (len(parts) != 1) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad rip-relative '" + t + "'" }
    } else if (parts[0] != "%rip") {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad rip-relative '" + t + "'" }
    } else {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: -1, idx: -1, scale: 1, disp: disp, rip: true, lbl: lbl }, error: "" }
    }
};

def parse_mem_disp(t: str, head: str, parts: [str]) -> OpRes {
    // numeric displacement head: parse_num cannot fail (is_num_text held).
    parse_mem_regs(t, parts, parse_num(head).v)
};

def parse_mem_regs(t: str, parts: [str], disp: long) -> OpRes {
    if (len(parts) < 1) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad memory '" + t + "'" }
    } else if (len(parts) > 3) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad memory '" + t + "'" }
    } else {
        let bn = enc.reg_num(parts[0]);
        if (bn < 0) {
            { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad base register '" + t + "'" }
        } else {
            mem_rest(t, parts, disp, bn)
        }
    }
};

def mem_rest(t: str, parts: [str], disp: long, bn: long) -> OpRes {
    if (len(parts) == 1) {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: bn, idx: -1, scale: 1, disp: disp, rip: false, lbl: "" }, error: "" }
    } else {
        let xn = enc.reg_num(parts[1]);
        if (xn < 0) {
            { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad index register '" + t + "'" }
        } else if (xn == 4) {
            { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "rsp cannot be index '" + t + "'" }
        } else {
            mem_scale(t, parts, disp, bn, xn)
        }
    }
};

def mem_scale(t: str, parts: [str], disp: long, bn: long, xn: long) -> OpRes {
    let scale = 1;
    if (len(parts) == 3) {
        mem_scaleThree(t, parts, disp, bn, xn)
    } else {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: bn, idx: xn, scale: scale, disp: disp, rip: false, lbl: "" }, error: "" }
    }
};

def mem_scaleThree(t: str, parts: [str], disp: long, bn: long, xn: long) -> OpRes {
    // (split: 3-part gate above narrows; scale-shape built ONLY here.)
    let r = parse_num(parts[2]);
    if (!(r.ok)) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad scale '" + t + "'" }
    } else {
        mem_scaleVal(t, r.v, disp, bn, xn)
    }
};

def mem_scaleVal(t: str, v: long, disp: long, bn: long, xn: long) -> OpRes {
    // (split: numeric scale narrows; mem-shape built ONLY here.)
    if (v == 1) {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: bn, idx: xn, scale: 1, disp: disp, rip: false, lbl: "" }, error: "" }
    } else if (v == 2) {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: bn, idx: xn, scale: 2, disp: disp, rip: false, lbl: "" }, error: "" }
    } else if (v == 4) {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: bn, idx: xn, scale: 4, disp: disp, rip: false, lbl: "" }, error: "" }
    } else if (v == 8) {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: bn, idx: xn, scale: 8, disp: disp, rip: false, lbl: "" }, error: "" }
    } else {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad scale '" + t + "'" }
    }
};

// Decode a quoted GAS string (no surrounding quotes in s).
// Handles \\ \" \n \t \r and \ooo octal. Returns {ok, bytes, error}.
def decode_str(s: str) -> { ok: bool, bytes: [byte], error: str } {
    let out: [byte] = [];
    let i = 0;
    let n = len(s);
    let err = "";
    while (i < n) {
        let c = s[i];
        if (c != '\\') {                // '\\'
            out += c;
            i++;
        } else if (i + 1 >= n) {
            // a backslash as the last byte: no escape follows it
            err = "bad escape '\\'";
            i = n;
        } else {
            let e = s[i + 1];
            if (e == 'n') {            // 'n', the letter of \n
                out += '\n';
                i += 2;
            } else if (e == 't') {      // 't', the letter of \t
                out += '\t';
                i += 2;
            } else if (e == 'r') {      // 'r', the letter of \r
                out += '\r';
                i += 2;
            } else if (e == '\\') {      // '\\'
                out += '\\';
                i += 2;
            } else if (e == '\x22') {      // '"'
                out += '\x22';
                i += 2;
            } else if (is_oct_ch(e)) {
                let oct = decode_oct(s, i + 2, n);
                if (oct.err != "") {
                    err = oct.err;
                } else {
                    out += oct.v;
                };
                i = oct.k;
            } else {
                err = "bad escape '\\" + s[i + 1:i + 2] + "'";
                i = n;
            };
        };
    };
    { ok: err == "", bytes: out, error: err }
};

def decode_oct(s: str, k: long, n: long) -> { v: long, k: long, err: str } {
    let v = (s[k - 1]) - '0';
    let kk = k;
    let nd = 1;
    while (nd < 3) {
        if (kk < n) {
            let d = s[kk];
            if (is_oct_ch(d)) {
                v = v * 8 + d - '0';
                kk = kk + 1;
                nd++;
            } else {
                kk = n + 1;
            };
        } else {
            nd = 3;
        };
    };
    if (v > 255) {
        { v: 0, k: kk, err: "octal escape out of range" }
    } else {
        { v: v, k: kk, err: "" }
    }
};

// ── label index (hash table: name -> {sec, off}) ─────────────────────────

def hash_str(s: str) -> long {
    let h = 0;
    for i in 0..len(s) {
        h = (h * 31 + s[i]) & 4294967295;
    };
    h ^ (h >> 13)
};

def labmap_new(cap: long) -> [AsmLabel] {
    let m: [AsmLabel] = [];
    for i in 0..cap {
        m += { name: "", sec: 0, off: 0, at_item: 0 };
    };
    m
};

def labmap_put(m: [AsmLabel], name: str, sec: long, off: long) -> { map: [AsmLabel], dup: bool } {
    let cap = len(m);
    let i = hash_str(name) % cap;
    let dup = false;
    let done = false;
    let n = 0;
    while (!done) {
        let e = m[i];
        if (e.name.length == 0) {
            m[i] = { name: name, sec: sec, off: off, at_item: 0 };
            done = true;
        } else if (e.name == name) {
            dup = true;
            done = true;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; }
        };
        n++;
        if (n > cap) { done = true; }
    };
    { map: m, dup: dup }
};

def labmap_get(m: [AsmLabel], name: str) -> { sec: long, off: long } {
    let cap = len(m);
    let i = hash_str(name) % cap;
    let found_sec = -1;
    let found_off = 0;
    let done = false;
    let n = 0;
    while (!done) {
        let e = m[i];
        if (e.name.length == 0) {
            done = true;
        } else if (e.name == name) {
            found_sec = e.sec;
            found_off = e.off;
            done = true;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; }
        };
        n++;
        if (n > cap) { done = true; }
    };
    { sec: found_sec, off: found_off }
};

// Build the index from pass-1 labels; reports the first duplicate name
// ("" when clean). Replaces the old O(L^2) definition-site scans — our
// emitter only feeds unique labels, and no test pins dup positions.
def labmap_build(labels: [AsmLabel]) -> { map: [AsmLabel], dup: str } {
    let m = labmap_new((len(labels) * 2 + 16));
    let dup = "";
    for i in 0..len(labels) {
        let e = labels[i];
        let r = labmap_put(m, e.name, e.sec, e.off);
        m = r.map;
        if (r.dup) { dup = e.name; }
    };
    { map: m, dup: dup }
};

def label_addr(lmap: [AsmLabel], code_len: long, pad: long, name: str) -> AsmAddr {
    let e = labmap_get(lmap, name);
    if (e.sec < 0) {
        // `tab+8`: the eighth byte of a table, which is how one label serves a
        // whole coefficient table. Only on a miss, so the cost is nothing on
        // every jump and every ordinary rip reference.
        let plus = index_of(name, "+");
        if (plus > 0) {
            label_addr_off(lmap, code_len, pad, name, plus)
        } else {
            { ok: false, addr: 0 }
        }
    } else if (e.sec == 0) {
        { ok: true, addr: e.off }
    } else {
        { ok: true, addr: code_len + pad + e.off }
    }
};

// The `name+off` half of label_addr. It re-reads `name` rather than taking the
// two halves, so the lookup key is the same string the label map holds.
def label_addr_off(lmap: [AsmLabel], code_len: long, pad: long, name: str, plus: long) -> AsmAddr {
    let off = trim(name[plus + 1:]);
    if (!is_num_text(off)) {
        { ok: false, addr: 0 }
    } else {
        let e = labmap_get(lmap, name[0:plus]);
        if (e.sec < 0) {
            { ok: false, addr: 0 }
        } else if (e.sec == 0) {
            { ok: true, addr: e.off + tolong(off) ! }
        } else {
            { ok: true, addr: code_len + pad + e.off + tolong(off) ! }
        }
    }
};

// ── pass 1: parse lines into items ─────────────────────────────────────

let asm_a64_sealed = false;
let asm_a64_want_listing = false;
let asm_a64_listing = "";

def asm_assemble(parts: [LinkPart], debug: bool, seal_key: long = 0) -> AsmOutI {
    asm_a64_sealed = seal_key != 0;
    armenc.set_signals(asm_a64_sealed);
    if (target_is_aarch64()) {
        let prefix = part_text(".text\ny_a64_syscall:\n    a64_runtime\ny_a64_mapped_syscall:\n    a64_mapped\ny_a64_raw_syscall:\n    a64_raw\n");
        parts = [prefix] + parts;
    };
    let t0 = clock_us();
    let h0 = heap_used();
    // The text parts' lines, up front: the split is its own phase (a:split),
    // as it was when the whole assembly was one string.
    let segs: [Seg] = [];
    let pi = 0;
    while (pi < len(parts)) {
        let p = parts[pi];
        if (len(p.text) > 0) {
            segs += { lines: split(p.text, "\n"), ir: [], txt: [], fno: 0,
                loc: false };
        } else {
            segs += { lines: [], ir: p.ir, txt: p.txt, fno: p.fno,
                loc: p.loc };
        };
        pi++;
    };
    let t1 = clock_us();
    let h1 = heap_used();
    // Pass 1: every piece turned into items, in order -- the text parts a line
    // at a time, an IR part item by item.
    let st = asm_ir_st(0, [0, 0, 0], [], [], "", 0);
    let err = "";
    pi = 0;
    while (pi < len(segs)) {
        if (err != "") {
            pi = len(segs);
        } else {
            let sg = segs[pi];
            if (len(sg.ir) > 0) {
                let r = asm_ir_items(sg.ir, sg.txt, sg.fno, sg.loc, st.sec,
                    st.offs, st.items, st.labels, st.err,
                    st.lno + 1);
                st = asm_ir_st(r.sec, r.offs, r.items, r.labels, r.err, r.lno);
            } else {
                let lines = sg.lines;
                let li = 0;
                while (li < len(lines) && st.err == "") {
                    st = asm_st_seg(st, lines, li);
                    li++;
                };
            };
            pi++;
        };
    };
    let items = st.items;
    let labels = st.labels;
    if (asm_a64_want_listing && target_is_aarch64() && st.err == "") {
        asm_a64_listing = asm_render_a64(items, labels);
    };
    err = st.err;
    let tr0 = clock_us();
    let hr0 = heap_used();
    if (err != "") {
        { ok: false, bytes: [], error: err, items: 0,
            times: [ { name: "a:split", us: t1 - t0, heap: h1 - h0 },
                { name: "a:encode", us: tr0 - t1, heap: hr0 - h1 } ] }
    } else {
        asm_relax(items, labels, debug);
        let tr1 = clock_us();
        let hr1 = heap_used();
        let lk = asm_link(items, labels, debug, seal_key);
        let t3 = clock_us();
        let h3 = heap_used();
        let tl: [Timing] =
        [ { name: "a:split", us: t1 - t0, heap: h1 - h0 },
            { name: "a:encode", us: tr0 - t1, heap: hr0 - h1 },
            { name: "a:relax", us: tr1 - tr0, heap: hr1 - hr0 },
            { name: "a:link", us: t3 - tr1, heap: h3 - hr1 } ];
        lk.times.foreach((le) => {
            tl += le;
        });
        { ok: lk.ok, bytes: lk.bytes, error: lk.error, items: len(items),
            times: tl }
    }
};


def a64_listing(parts: [LinkPart], debug: bool) -> { ok: bool, text: str, error: str } {
    asm_a64_want_listing = true;
    asm_a64_listing = "";
    let r = asm_assemble(parts, debug);
    asm_a64_want_listing = false;
    { ok: r.ok, text: asm_a64_listing, error: r.error }
};

def a64_section(sec: long) -> str {
    if (sec == 0) { ".text\n" } else if (sec == 1) { ".section .rodata\n" } else { ".bss\n" }
};

def asm_render_a64(items: [AsmItem], labels: [AsmLabel]) -> str {
    let lmap = labmap_build(labels).map;
    let names: [str] = [];
    for i in 0..len(items) + 1 { names += ""; };
    foreach (lb in labels) { names[lb.at_item] += a64_section(lb.sec) + lb.name + ":\n"; };
    let out: [str] = [".arch armv8-a\n.globl _start\n.bss\ny_bss_lo:\n"];
    for i in 0..len(items) {
        out += names[i];
        let it = items[i];
        if (it.sec < 0) { continue; };
        out += a64_section(it.sec);
        if (it.kind == "file") {
            // File/line metadata is carried by the executable's DWARF writer.
            continue;
        };
        if (it.sec == 2) { out += ".zero " + tostring(it.len) + "\n"; continue; };
        let at = 0;
        while (at < len(it.bytes)) {
            let found = false;
            foreach (fx in it.fix) {
                if (fx.off == at) {
                    found = true;
                    if (fx.kind == "a64branch") {
                        out += (if ((it.bytes[at + 3] & 128) != 0) { "bl " } else { "b " }) + fx.lbl + "\n";
                        at += 4;
                    } else if (fx.kind == "a64addr" || fx.kind == "a64diff") {
                        let reg = tostring(it.bytes[at] & 31);
                        for k in 0..4 {
                            let op = if (k == 0) { "movz" } else { "movk" };
                            let value = if (fx.kind == "a64addr") {
                                "#:abs_g" + tostring(k) + (if (k < 3) { "_nc:" } else { ":" }) + fx.lbl
                            } else {
                                "#" + tostring(((labmap_get(lmap, fx.lbl).off - labmap_get(lmap, fx.lbl2).off) >>> (16 * k)) & 65535)
                            };
                            out += op + " x" + reg + ", " + value + (if (fx.kind == "a64diff" && k > 0) { ", lsl #" + tostring(16 * k) } else { "" }) + "\n";
                        };
                        at += 16;
                    } else {
                        out += ".quad " + fx.lbl + "\n";
                        at += 8;
                    };
                };
            };
            if (!found) {
                if (it.kind == "insn") {
                    let w = 0;
                    for k in 0..4 { w |= it.bytes[at + k] << (8 * k); };
                    out += ".inst " + tostring(w) + "\n";
                    at += 4;
                } else {
                    out += ".byte " + tostring(it.bytes[at]) + "\n";
                    at++;
                };
            };
        };
    };
    out += names[len(items)];
    out += ".bss\ny_bss_hi:\n.section .note.GNU-stack,\"\",%progbits\n";
    join(out, "")
};

// One text line through the text path, on the IR path's state (the line
// counter it advances is what an IR_TEXT item's error names).
def asm_st_seg(st: IrSt, lines: [str], li: long) -> IrSt {
    let r = asm_assemble_line(lines, li, st.lno, st.sec, st.offs, st.items,
        st.labels, st.err);
    asm_ir_st(r.sec, r.offs, r.items, r.labels, r.err, st.lno + 1)
};
def asm_assemble_line(lines: [str], li: long, lbase: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    let line = trim(lines[li]);
    let lno = lbase + li + 1;
    if (line == "") {
        asm_state(sec, offs, items, labels, err)
    } else if (line[0:1] == "#") {
        asm_state_err(sec, offs, items, labels, lno, "unexpected comment (backend bug)")
    } else if (line[len(line) - 1:] == ":") {
        asm_labdef(line, lno, sec, offs, items, labels, err)
    } else if (line[0:1] == ".") {
        asm_dirline(line, lno, sec, offs, items, labels, err)
    } else {
        asm_maybe_labline(line, lno, sec, offs, items, labels, err)
    }
};

def asm_state(sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    { sec: sec, offs: offs, items: items, labels: labels, err: err }
};

def asm_state_err(sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], lno: long, msg: str) -> AsmSt {
    { sec: sec, offs: offs, items: items, labels: labels, err: "L" + tostring(lno) + ": " + msg }
};

def asm_labdef(line: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    let nm = trim(line[0:len(line) - 1]);
    if (nm == "") {
        asm_state_err(sec, offs, items, labels, lno, "bad label")
    } else if (index_of(nm, " ") >= 0) {
        asm_state_err(sec, offs, items, labels, lno, "bad label")
    } else {
        asm_labdef_go(nm, lno, sec, offs, items, labels, err)
    }
};

def asm_labdef_go(nm: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    // NOTE: no definition-site duplicate scan (was O(L^2)): duplicates are
    // detected once at index build (labmap_build reports the name).
    labels += { name: nm, sec: sec, off: offs[sec], at_item: len(items) };
    asm_state(sec, offs, items, labels, err)
};

def asm_dirline(line: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    let r = asm_directive(line, lno, sec, offs);
    if (r.err != "") {
        asm_state(r.sec, r.offs, items, labels, r.err)
    } else {
        items += r.item;
        asm_state(r.sec, r.offs, items, labels, err)
    }
};

def asm_maybe_labline(line: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    // maybe `label: rest` (rodata emits `ystr_N: .string ...`); otherwise a
    // plain instruction. NOTE: misnomer fixed: the else-arm assembles an
    // INSTRUCTION (asm_insnline), not a directive.
    let ci = index_of(line, ":");
    // a `%` before it: an operand's `%fs:N`, not a label
    if (ci > 0 && index_of(line[0:ci], "%") < 0) {
        asm_labline(line, lno, sec, offs, items, labels, err, ci)
    } else {
        asm_insnline(line, lno, sec, offs, items, labels, err)
    }
};

def asm_insnline(line: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {

    let r = asm_content(line, lno, sec, offs);
    if (r.err != "") {
        asm_state(r.sec, r.offs, items, labels, r.err)
    } else {
        items += r.item;
        asm_state(r.sec, r.offs, items, labels, err)
    }
};

def asm_labline(line: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str, ci: long) -> AsmSt {
    let nm = trim(line[0:ci]);
    let rest = trim(line[ci + 1:]);
    if (nm == "") {
        asm_state_err(sec, offs, items, labels, lno, "bad label")
    } else if (index_of(nm, " ") >= 0) {
        asm_state_err(sec, offs, items, labels, lno, "bad label")
    } else if (rest == "") {
        asm_state_err(sec, offs, items, labels, lno, "bad label")
    } else {
        asm_labline_go(nm, rest, lno, sec, offs, items, labels, err)
    }
};

def asm_labline_go(nm: str, rest: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    // NOTE: no definition-site duplicate scan (see asm_labdef_go note).
    asm_labline_content(nm, rest, lno, sec, offs, items, labels, err)
};

def asm_labline_content(nm: str, rest: str, lno: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    let lab_off = offs[sec];
    let lab_at = len(items);
    let r = asm_content(rest, lno, sec, offs);
    if (r.err != "") {
        asm_state(r.sec, r.offs, items, labels, r.err)
    } else {
        items += r.item;
        labels += { name: nm, sec: sec, off: lab_off, at_item: lab_at };
        asm_state(r.sec, r.offs, items, labels, err)
    }
};

def asm_content(line: str, lno: long, sec: long, offs: [long]) -> AsmContent {
    if (line[0:1] == ".") {
        asm_directive(line, lno, sec, offs)
    } else {
        asm_insn(line, lno, sec, offs)
    }
};

def asm_strdata(line: str, lno: long, sec: long, offs: [long], rest: str, nul: bool) -> AsmContent {
    // .string/.ascii quoted payload (split from asm_directive: dir-gate above
    // narrows; data-item shape built ONLY here).
    // NOTE: single gate on a BOOL (str narrowing is exact — see
    // parse_type_arrow note): error-vs-success shapes never mix in one chain.
    if (asm_strdata_bad(rest)) {
        asm_strdata_err(line, lno, sec, offs)
    } else {
        asm_strdata_go(line, lno, sec, offs, rest[1:len(rest) - 1], nul)
    }
};

def asm_strdata_bad(rest: str) -> bool {
    if (len(rest) < 2) { true }
    else if (rest[0:1] != "\"") { true }
    else if (rest[len(rest) - 1:] != "\"") { true }
    else { false }
};

def asm_strdata_err(line: str, lno: long, sec: long, offs: [long]) -> AsmContent {
    // (split: error shape `{err,sec,offs,item:{}}` built ONLY here.)
    { err: "L" + tostring(lno) + ": bad string literal", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
};

def asm_strdata_go(line: str, lno: long, sec: long, offs: [long], payload: str, nul: bool) -> AsmContent {
    let d = decode_str(payload);
    if (!(d.ok)) {
        { err: "L" + tostring(lno) + ": " + d.error, sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        asm_strdata_emit(sec, offs, d.bytes, nul)
    }
};

def asm_strdata_emit(sec: long, offs: [long], bytes: [byte], nul: bool) -> AsmContent {
    if (target_is_aarch64() && sec == 0) {
        if (len(bytes) == 3 && bytes[0] == 243 && bytes[1] == 72 && bytes[2] == 171) {
            let out = enc.le32(0xb4000081); // cbz x1, .+16
            out += enc.le32(0xf80084e0); // str x0, [x7], #8
            out += enc.le32(0xd1000421); // sub x1, x1, #1
            out += enc.le32(0xb5ffffc1); // cbnz x1, .-8
            return asm_strdata_item(sec, offs, out);
        };
    };
    let bb = bytes;
    if (nul) {
        bb += 0;
    };
    asm_strdata_item(sec, offs, bb)
};

def asm_strdata_item(sec: long, offs: [long], bb: [byte]) -> AsmContent {
    let item: AsmItem = { sec: sec, off: offs[sec], len: len(bb), kind: "data", bytes: bb, fix: [], br: -1 };
    offs[sec] = offs[sec] + len(bb);
    { err: "", sec: sec, offs: offs, item: item }
};

def asm_directive(line: str, lno: long, sec: long, offs: [long]) -> AsmContent {
    let sp = index_of(line, " ");
    let dir = line;
    let rest = "";
    if (sp >= 0) {
        dir = line[0:sp];
        rest = trim(line[sp + 1:]);
    };
    if (dir == ".text") {
        { err: "", sec: 0, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else if (dir == ".globl") {
        { err: "", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else if (dir == ".string") {
        asm_strdata(line, lno, sec, offs, rest, true)
    } else if (dir == ".ascii") {
        asm_strdata(line, lno, sec, offs, rest, false)
    } else if (dir == ".section") {
        asm_section(line, lno, sec, offs, rest)
    } else if (dir == ".quad") {
        asm_quad(line, lno, sec, offs, rest)
    } else if (dir == ".byte") {
        asm_byte(line, lno, sec, offs, rest)
    } else if (dir == ".zero") {
        asm_zero(line, lno, sec, offs, rest)
    } else if (dir == ".align") {
        asm_align(line, lno, sec, offs, rest)
    } else if (dir == ".loc") {
        asm_loc(lno, sec, offs, rest)
    } else if (dir == ".file") {
        asm_file(lno, sec, offs, rest)
    } else {
        { err: "L" + tostring(lno) + ": unsupported directive '" + dir + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    }
};

// ── -g: line-number directives ─────────────────────────────────────────
def asm_loc(lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    let sp = index_of(rest, " ");
    let fs = rest;
    let ls = "";
    if (sp > 0) {
        fs = rest[0:sp];
        ls = trim(rest[sp + 1:]);
    }
    if (!is_num_text(fs) || !is_num_text(ls) || tolong(fs) ! < 1 || tolong(ls) ! < 0) {
        { err: "L" + tostring(lno) + ": bad .loc '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else if (sec != 0) {
        { err: "L" + tostring(lno) + ": .loc outside .text", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let fx = [{ off: tolong(fs) !, kind: "file", lbl: "", lbl2: "" },
            { off: tolong(ls) !, kind: "line", lbl: "", lbl2: "" }];
        { err: "", sec: sec, offs: offs, item: { sec: 0, off: offs[0], len: 0, kind: "loc", bytes: [], fix: fx, br: -1 } }
    }
};

def asm_file(lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    let sp = index_of(rest, " ");
    let ns = rest;
    let q = "";
    if (sp > 0) {
        ns = rest[0:sp];
        q = trim(rest[sp + 1:]);
    }
    let d = decode_str("");
    if (!asm_strdata_bad(q)) {
        d = decode_str(q[1:len(q) - 1]);
    }
    if (!is_num_text(ns) || tolong(ns) ! < 1 || asm_strdata_bad(q) || !d.ok) {
        { err: "L" + tostring(lno) + ": bad .file '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        { err: "", sec: sec, offs: offs, item: { sec: -1, off: tolong(ns) !, len: 0, kind: "file", bytes: [], fix: ([{ off: 0, kind: "file", lbl: from_bytes(d.bytes), lbl2: "" }]), br: -1 } }
    }
};

// .section payload (split from asm_directive: dir-gate above narrows).
// NOTE: single bool gate (see asm_strdata note): marker-vs-error never mix.
def asm_section(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    if (asm_section_bad(rest)) {
        asm_section_err(line, lno, sec, offs, rest)
    } else {
        asm_section_go(sec, offs, rest)
    }
};

def asm_section_bad(rest: str) -> bool {
    !(rest in [".rodata", ".text", ".bss"])
};

def asm_section_err(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    // (split: error shape built ONLY here.)
    { err: "L" + tostring(lno) + ": unsupported section '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
};

def asm_section_go(sec: long, offs: [long], rest: str) -> AsmContent {
    // (split: marker shape `{err,sec,offs,item:{sec}}` built ONLY here.)
    // NOTE: both arms share the key set — teq holds.
    if (rest == ".rodata") {
        { err: "", sec: 1, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else if (rest == ".bss") {
        { err: "", sec: 2, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        { err: "", sec: 0, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    }
};

// .quad payload: single non-negative long, 8 bytes little-endian (string headers).
def asm_quad(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    // NOTE: single bool gate (see asm_strdata note).
    if (is_num_text(rest)) {
        asm_quad_go(sec, offs, rest)
    } else if (len(rest) > 0 && !contains_ch(rest, ' ')) {
        asm_quad_lbl(sec, offs, rest)
    } else {
        asm_quad_err(line, lno, sec, offs, rest)
    }
};

def asm_quad_bad(rest: str) -> bool {
    if (!is_num_text(rest)) { true } else { false }
};

def contains_ch(s: str, c: byte) -> bool {
    let i = 0;
    let out = false;
    while (i < len(s) && !out) {
        if (s[i] == c) { out = true; };
        i += 1;
    };
    out
};

def asm_quad_lbl(sec: long, offs: [long], lbl: str) -> AsmContent {
    let bytes: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
    let item: AsmItem = { sec: sec, off: offs[sec], len: 8, kind: "data",
        bytes: bytes, fix: [fixup(0, "abs64", lbl, "")], br: -1 };
    offs[sec] = offs[sec] + 8;
    { err: "", sec: sec, offs: offs, item: item }
};

def asm_quad_err(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    // One cause, one message — see asm_quad_bad on why there is no second.
    { err: "L" + tostring(lno) + ": bad .quad value '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
};

def asm_quad_go(sec: long, offs: [long], rest: str) -> AsmContent {
    let bytes = enc.le64(parse_num(rest).v);
    let item: AsmItem = { sec: sec, off: offs[sec], len: len(bytes), kind: "data", bytes: bytes, fix: [], br: -1 };
    offs[sec] = offs[sec] + len(bytes);
    { err: "", sec: sec, offs: offs, item: item }
};

// .byte a,b,c: one to any number of decimal bytes (0..255). The emitter
// uses it for opaque data and bytecode; GNU as reads the same spelling.
def asm_byte(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    let parts = split(rest, ",");
    let out: [byte] = [];
    let bad = false;
    let i = 0;
    while (i < len(parts) && !bad) {
        let t = trim(parts[i]);
        let r = parse_num(t);
        if (!r.ok || r.v < 0 || r.v > 255) {
            bad = true;
        } else {
            out += enc.byte_of(r.v, 0);
        };
        i += 1;
    };
    if (bad) {
        { err: "L" + tostring(lno) + ": bad .byte list '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let item: AsmItem = { sec: sec, off: offs[sec], len: len(out), kind: "data", bytes: out, fix: [], br: -1 };
        offs[sec] = offs[sec] + len(out);
        { err: "", sec: sec, offs: offs, item: item }
    }
};

// .zero N: N zero bytes. In .bss they only reserve space (no file bytes).
def asm_zero(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    if (asm_quad_bad(rest)) {
        { err: "L" + tostring(lno) + ": bad .zero size '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let n = tolong(rest) !;
        let zb: [byte] = [];
        if (sec != 2) {
            for i in 0..n {
                zb += 0;
            };
        }
        let item: AsmItem = { sec: sec, off: offs[sec], len: n, kind: "data", bytes: zb, fix: [], br: -1 };
        offs[sec] = offs[sec] + n;
        { err: "", sec: sec, offs: offs, item: item }
    }
};

def asm_align(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    if (asm_quad_bad(rest)) {
        { err: "L" + tostring(lno) + ": bad .align size '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let n = tolong(rest) !;
        let cur = offs[sec];
        let pad = 0;
        if (n > 0 && cur % n != 0) { pad = n - cur % n; };
        let zb: [byte] = [];
        if (sec != 2) {
            for i in 0..pad {
                zb += 0;
            };
        }
        let item: AsmItem = { sec: sec, off: cur, len: pad, kind: "data", bytes: zb, fix: [], br: -1 };
        offs[sec] = cur + pad;
        { err: "", sec: sec, offs: offs, item: item }
    }
};

def asm_insn(line: str, lno: long, sec: long, offs: [long]) -> AsmContent {
    let sp = index_of(line, " ");
    let tab = index_of(line, "\t");
    let cut = sp;
    if (tab >= 0) {
        if (sp < 0) { cut = tab; }
        else if (tab < sp) { cut = tab; }
        ;
    };
    let mn = line;
    let rest = "";
    if (cut >= 0) {
        mn = line[0:cut];
        rest = trim(line[cut + 1:]);
    };
    let ops: [Operand] = [];
    if (rest != "") {
        let texts = split_ops(rest);
        let i = 0;
        let ok = true;
        while (i < len(texts)) {
            let r = parse_operand(texts[i]);
            if (!(r.ok)) {
                ok = false;
            } else {
                ops += r.op;
            };
            i++;
        };
        if (!ok) {
            { err: "L" + tostring(lno) + ": bad operand in '" + line + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
        } else {
            asm_encode(mn, ops, lno, sec, offs)
        }
    } else {
        asm_encode(mn, ops, lno, sec, offs)
    }
};

def asm_encode(mn: str, ops: [Operand], lno: long, sec: long, offs: [long]) -> AsmContent {
    if (target_is_aarch64()) { return asm_a64_encode(mn, ops, "L" + tostring(lno), sec, offs); };
    let buf = enc.scratch();
    let r = enc.enc_insn(buf, 0, mn, ops, false);
    if (r.err != "") {
        { err: "L" + tostring(lno) + ": " + r.err + " in '" + mn + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let blen = r.at;
        let item = { sec: sec, off: offs[sec], len: blen, kind: "insn", bytes: buf[0:blen], fix: r.fix, br: r.br };
        offs[sec] = offs[sec] + blen;
        { err: "", sec: sec, offs: offs, item: item }
    }
};

def asm_a64_encode(mn: str, ops: [Operand], where: str, sec: long, offs: [long]) -> AsmContent {
    let r = armenc.a64_encode(mn, ops);
    let blen = len(r.bytes);
    let item: AsmItem = { sec: sec, off: offs[sec], len: blen, kind: "insn", bytes: r.bytes, fix: r.fix, br: -1 };
    offs[sec] += blen;
    { err: if (r.err == "") { "" } else { where + ": " + r.err }, sec: sec, offs: offs, item: item }
};

// ── the IR path: the emitter's items ─────────────────────────────────────

// One operand of kind `k` at word `wp`, as the encoder's Operand: the same
// shape parse_operand builds for the same instruction, so enc64 is unchanged.
def ir_operand(ir: [long], wp: long, k: long) -> Operand {
    if (k == insn.O_REG) {
        { k: K.reg, n: ir[wp], size: ir[wp + 1], v: 0, a: "", b: "", name: "",
            base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }
    } else if (k == insn.O_IND) {
        { k: K.ind, n: ir[wp], size: ir[wp + 1], v: 0, a: "", b: "", name: "",
            base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }
    } else if (k == insn.O_IMM) {
        { k: K.imm, n: 0, size: 0, v: ir[wp], a: "", b: "", name: "", base: 0,
            idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }
    } else if (k == insn.O_LBL) {
        { k: K.lbl, n: 0, size: 0, v: 0, a: "", b: "",
            name: lbl.lname(ir[wp]), base: 0, idx: 0, scale: 0, disp: 0,
            rip: false, lbl: "" }
    } else if (k == insn.O_DIFF) {
        { k: K.diff, n: 0, size: 0, v: 0, a: lbl.lname(ir[wp]),
            b: lbl.lname(ir[wp + 1]), name: "", base: 0, idx: 0, scale: 0,
            disp: 0, rip: false, lbl: "" }
    } else if (k == insn.O_MEM || k == insn.O_MEM0) {
        let ml = ir[wp + 4];
        if (ml >= 0) {
            { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "",
                base: -1, idx: -1, scale: 1, disp: 0, rip: true,
                lbl: lbl.lname(ml) }
        } else {
            let disp = ir[wp + 3];
            if (k == insn.O_MEM0) { disp = 0; };
            { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "",
                base: ir[wp], idx: ir[wp + 1], scale: ir[wp + 2],
                disp: disp, rip: false, lbl: "" }
        }
    } else {
        // O_FS: the %fs:N word (a thread's own heap block)
        { k: K.fs, n: 0, size: 64, v: 0, a: "", b: "", name: "", base: 0,
            idx: 0, scale: 0, disp: ir[wp], rip: false, lbl: "" }
    }
};

// Where an error in an item is reported: an item has no line of assembly text
// to name, so it is the body's label and the item's number in it.
def ir_where(lblname: str, n: long) -> str {
    if (lblname == "") { "item " + tostring(n) } else { lblname + "+" + tostring(n) }
};

def ir_enc_item(ir: [long], at: long, sec: long, offs: [long], where: str) -> AsmContent {
    let f = ir[at];
    let fo = insn.ir_form(f);
    let kinds = fo.kinds;
    let ops: [Operand] = [];
    let wp = at + 1;
    for ki in 0..len(kinds) {
        let kind = kinds[ki];
        ops += ir_operand(ir, wp, kind);
        wp = wp + insn.ir_kind_words(kind);
    };
    if (target_is_aarch64()) { return asm_a64_encode(fo.mn, ops, where, sec, offs); };
    // The encoder writes into the same scratch the text path uses, and a
    // branch is asked for in the short form: asm_relax grows the ones that
    // turn out to be out of range.
    let buf = enc.scratch();
    let r = enc.enc_form(buf, 0, f, fo.mn, ops, false);
    if (r.err != "") {
        { err: where + ": " + r.err + " in '" + fo.mn + "'", sec: sec,
            offs: offs,
            item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let blen = r.at;
        let item = { sec: sec, off: offs[sec], len: blen, kind: "insn",
            bytes: buf[0:blen], fix: r.fix, br: r.br };
        offs[sec] = offs[sec] + blen;
        { err: "", sec: sec, offs: offs, item: item }
    }
};

// ── a line of hand-written assembly, as an item ─────────────────────────
def ir_parse_line(line: str) -> [long] {
    let none: [long] = [];
    let t = trim(line);
    if (len(line) == 0 || (line[0] != 32 && line[0] != 9) || len(t) == 0 || t[0] == '.') {
        none
    } else {
        let sp = index_of(t, " ");
        let mn = t;
        let rest = "";
        if (sp >= 0) {
            mn = t[0:sp];
            rest = trim(t[sp + 1:]);
        };
        let ops: [Operand] = [];
        let ok = true;
        if (rest != "") {
            let texts = split_ops(rest);
            let i = 0;
            while (ok && i < len(texts)) {
                let r = parse_operand(texts[i]);
                if (r.ok) { ops += r.op; } else { ok = false; };
                i++;
            };
        };
        let out = none;
        if (ok) {
            let nf = insn.ir_nforms();
            let f = 0;
            while (len(out) == 0 && f < nf) {
                let fo = insn.ir_form(f);
                if (fo.mn == mn && len(fo.kinds) == len(ops)) {
                    let item = ir_item_of(f, fo.kinds, ops);
                    if (len(item) > 0 && ir_same_as_line(item, line)) { out = item; };
                };
                f++;
            };
        };
        out
    }
};

// Form `f`'s item for `ops`, or [] when an operand is not of the kind the form
// takes. Fields an operand does not use stay 0 (unpack_body's convention), and
// an O_MEM0 operand's displacement is -1, as the emitter writes it.
def ir_item_of(f: long, kinds: [long], ops: [Operand]) -> [long] {
    let w: [long] = [0, 0, 0, 0, 0, 0, 0];
    let wp = 0;
    let ok = true;
    let i = 0;
    while (ok && i < len(kinds)) {
        let k = kinds[i];
        let o = ops[i];
        if (k == insn.O_REG && o.k == K.reg) {
            w[wp] = o.n;
            w[wp + 1] = o.size;
        } else if (k == insn.O_IND && o.k == K.ind) {
            w[wp] = o.n;
            w[wp + 1] = o.size;
        } else if (k == insn.O_IMM && o.k == K.imm) {
            w[wp] = o.v;
        } else if (k == insn.O_LBL && o.k == K.lbl) {
            w[wp] = lbl.lbl_new(o.name);
        } else if (k == insn.O_DIFF && o.k == K.diff) {
            w[wp] = lbl.lbl_new(o.a);
            w[wp + 1] = lbl.lbl_new(o.b);
        } else if ((k == insn.O_MEM || k == insn.O_MEM0) && o.k == K.mem) {
            if (o.rip) {
                w[wp] = -1;
                w[wp + 1] = -1;
                w[wp + 2] = 1;
                w[wp + 3] = o.disp;
                w[wp + 4] = lbl.lbl_new(o.lbl);
            } else {
                w[wp] = o.base;
                w[wp + 1] = o.idx;
                w[wp + 2] = o.scale;
                w[wp + 3] = k == insn.O_MEM0 ? -1 : o.disp;
                w[wp + 4] = -1;
            };
        } else if (k == insn.O_FS && o.k == K.fs && o.n == 0) {
            w[wp] = o.disp;
        } else {
            ok = false;
        };
        wp = wp + insn.ir_kind_words(k);
        i++;
    };
    if (ok) {
        let item: [long] = [];
        item = insn.ir_push(item, f, w[0], w[1], w[2], w[3], w[4], w[5], w[6]);
        item
    } else {
        let none: [long] = [];
        none
    }
};

// The item stands for the line: the same text under -S, and the same bytes,
// fixups and branch class out of the assembler.
def ir_same_as_line(item: [long], line: str) -> bool {
    let none: [str] = [];
    // trailing blanks say nothing (math.s has some); -S drops them
    let tl = line;
    while (len(tl) > 0 && (tl[len(tl) - 1] == 32 || tl[len(tl) - 1] == 9)) { tl = tl[0:len(tl) - 1]; };
    if (insn.ir_render(item, none, 0, 0) != tl) {
        false
    } else {
        let noi: [AsmItem] = [];
        let nol: [AsmLabel] = [];
        let st = asm_assemble_line([line], 0, 0, 0, [0, 0, 0], noi, nol, "");
        let r = ir_enc_item(item, 0, 0, [0, 0, 0], "");
        if (st.err != "" || r.err != "" || len(st.items) != 1 || len(st.labels) != 0) {
            false
        } else {
            let a = st.items[0];
            let b = r.item;
            let same = a.sec == b.sec && a.len == b.len && a.kind == b.kind && a.br == b.br
                && len(a.fix) == len(b.fix) && len(a.bytes) == len(b.bytes);
            let i = 0;
            while (same && i < len(a.bytes)) {
                if (a.bytes[i] != b.bytes[i]) { same = false; };
                i++;
            };
            i = 0;
            while (same && i < len(a.fix)) {
                let fa = a.fix[i];
                let fb = b.fix[i];
                if (fa.off != fb.off || fa.kind != fb.kind || fa.lbl != fb.lbl || fa.lbl2 != fb.lbl2) { same = false; };
                i++;
            };
            same
        }
    }
};

// A label definition (IR_LABEL): the AsmLabel asm_labdef_go builds, with the
// name from the label table rather than from the line.
def asm_ir_label(id: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel]) -> [AsmLabel] {
    labels += { name: lbl.lname(id), sec: sec, off: offs[sec],
        at_item: len(items) };
    labels
};

// A .loc marker (IR_LOC): the item asm_loc builds, with the numbers read from
// the item instead of from a line. No sec check: a body is all .text.
def asm_ir_loc(file: long, line: long, sec: long, offs: [long], fno: long) -> AsmContent {
    let fx = [{ off: file + fno, kind: "file", lbl: "", lbl2: "" },
        { off: line, kind: "line", lbl: "", lbl2: "" }];
    { err: "", sec: 0, offs: offs,
        item: { sec: 0, off: offs[0], len: 0, kind: "loc", bytes: [], fix: fx, br: -1 } }
};

// One part's items. `txt` holds the raw lines the IR_TEXT items index (the
// emitter's comment lines), `lno` the assembly line counter, which an
// IR_TEXT item's line error names as before.
def asm_ir_items(ir: [long], txt: [str], fno: long, loc: bool, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str, lno: long) -> IrSt {
    let at = 0;
    let n = 0;
    let cur = "";
    while (at < len(ir)) {
        let f = ir[at];
        if (f == insn.IR_LABEL) {
            if (target_is_aarch64() && sec == 0 && at + insn.IR_W < len(ir)) {
                let nf = ir[at + insn.IR_W];
                let code = nf < insn.IR_LABEL || nf == insn.IR_LOC;
                if (nf == insn.IR_TEXT) {
                    let line = trim(txt[ir[at + insn.IR_W + 1]]);
                    code = len(line) > 0 && line[:1] != "." && line[:1] != "#";
                };
                if (code && !lbl.lname(ir[at + 1]).ends_with("_end") && offs[0] % 4 != 0) {
                    let pad = asm_align(".align 4", lno, sec, offs, "4");
                    offs = pad.offs;
                    items += pad.item;
                };
            };
            labels = asm_ir_label(ir[at + 1], sec, offs, items, labels);
            cur = lbl.lname(ir[at + 1]);
            if (target_is_aarch64() && cur == "_start" && !asm_a64_sealed) {
                let entry = asm_a64_encode("a64_entry", [], "_start", sec, offs);
                offs = entry.offs;
                items += entry.item;
            };
        } else if (f == insn.IR_LOC) {
            // A marker nobody asked for is no item at all (see LinkPart.loc)
            if (loc) {
                let r = asm_ir_loc(ir[at + 1], ir[at + 2], sec, offs, fno);
                offs = r.offs;
                items += r.item;
            };
        } else if (f == insn.IR_TEXT) {
            // A line of assembly text (the emitter's comment lines): the text
            // path, so it is read -- and refused -- exactly as it was.
            let i = ir[at + 1];
            let line = "";
            if (i >= 0 && i < len(txt)) { line = txt[i]; };
            let st = asm_assemble_line([line], 0, lno, sec, offs, items,
                labels, err);
            sec = st.sec;
            offs = st.offs;
            items = st.items;
            labels = st.labels;
            err = st.err;
            lno++;
        } else {
            let r = ir_enc_item(ir, at, sec, offs, ir_where(cur, n));
            offs = r.offs;
            if (r.err != "") {
                err = r.err;
            } else {
                items += r.item;
            };
        };
        at += insn.IR_W;
        n++;
    };
    { sec: sec, offs: offs, items: items, labels: labels, err: err, lno: lno }
};

def part_ir(ir: [long], txt: [str], fno: long, loc: bool) -> LinkPart {
    { ir: ir, txt: txt, text: "", fno: fno, loc: loc }
};

def part_text(text: str) -> LinkPart {
    { ir: [], txt: [], text: text, fno: 0, loc: false }
};

def asm_ir_st(sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str, lno: long) -> IrSt {
    { sec: sec, offs: offs, items: items, labels: labels, err: err, lno: lno }
};

// ── branch relaxation ──────────────────────────────────────────────────
let RELAX_ROUNDS = 8;

def asm_relax(items: [AsmItem], labels: [AsmLabel], debug: bool) -> void {
    let lens: [long] = [];
    let secs: [long] = [];
    let brs: [long] = [];
    items.foreach((e, i) => {
        lens += e.len;
        secs += e.sec;
        if (e.br >= 0 && e.sec == 0) { brs += i; };
    });
    let cum: [long] = [];
    let rlmap = relax_map(labels);
    let rounds = 0;
    let again = true;
    while (again && rounds < RELAX_ROUNDS) {
        rounds++;
        // Round 1 has nothing to place: pass 1 laid the items and the labels
        // out with every branch short, which is exactly this round's frozen
        // layout.
        again = relax_round(items, labels, rlmap, lens, secs, brs, cum, rounds == 1);
    };
    if (again) { relax_all_long(items, labels, lens); };
    // One last placement, at the final lengths: the rounds place the labels
    // from the lengths they started with, so the last round's growers leave
    // every label stale by what they added -- and every label-relative fixup
    // (rel32, rip32, imm32diff) is measured against these.
    relax_place(items, labels, lens, secs, debug);
    rounds
};

// The relaxation's own name -> label map, built once. It is the assembler's
// labmap with `off` carrying the label's INDEX in `labels` rather than an
// address: an address moves every round (that is the whole point) while an
// index does not, so one build serves every round instead of one per round.
def relax_map(labels: [AsmLabel]) -> [AsmLabel] {
    let m = labmap_new((len(labels) * 2 + 16));
    for i in 0..len(labels) {
        m = (labmap_put(m, labels[i].name, 0, i)).map;
    };
    m
};

// One round: place the .text labels (unless `first`, when pass 1's offsets
// are already this round's), then grow every short branch whose target is out
// of range. Returns true if anything grew.
def relax_round(items: [AsmItem], labels: [AsmLabel], rlmap: [AsmLabel], lens: [long], secs: [long], brs: [long], cum: [long], first: bool) -> bool {
    if (!first) {
        // cum[k] is where item k starts in .text at the current lengths; the
        // label before item `at_item` is therefore at cum[at_item].
        let at = 0;
        lens.foreach((e, i) => {
            if (i < len(cum)) { cum[i] = at; } else { cum += at; };
            if (secs[i] == 0) { at += e; };
        });
        for j in 0..len(labels) {
            let lb = labels[j];
            if (lb.sec == 0) {
                labels[j] = { name: lb.name, sec: 0, off: cum[lb.at_item], at_item: lb.at_item };
            };
        };
    };
    let grew = false;
    brs.foreach((i) => {
        // len 2 is the short form; a grower is already long.
        if (lens[i] == 2) {
            let it = items[i];
            let fx = it.fix[0];
            let li = relax_target(rlmap, fx.lbl);
            let here = 0;
            here = first ? it.off : cum[i];
            // An unknown target is pass 2's error to report, and a target
            // outside .text has no address to measure yet: grow both, so
            // nothing here can be wrong in a way pass 2 would not catch.
            if (li >= 0 && labels[li].sec == 0) {
                let d = labels[li].off - (here + 2);
                if (d < -128 || d > 127) {
                    relax_grow(items, i, lens, fx.lbl);
                    grew = true;
                };
            } else {
                relax_grow(items, i, lens, fx.lbl);
                grew = true;
            };
        };
    });
    grew
};

// The label a branch names, or -1 when the map does not have it.
def relax_target(rlmap: [AsmLabel], lbl: str) -> long {
    let e = labmap_get(rlmap, lbl);
    if (e.sec < 0) { -1 } else { e.off }
};

// Re-encode item `i` in the long form, from what it recorded (`br`) and what
// its fixup names. Returns the new length.
def relax_grow(items: [AsmItem], i: long, lens: [long], lbl: str) -> void {
    let it = items[i];
    let buf = enc.scratch();
    let r = enc.enc_branch_long(buf, 0, it.br, lbl);
    items[i] = { sec: it.sec, off: it.off, len: r.at, kind: it.kind, bytes: buf[0:r.at], fix: r.fix, br: it.br };
    lens[i] = r.at;
    r.at
};

// The bound case: every branch long, which is the pre-relaxation encoding.
def relax_all_long(items: [AsmItem], labels: [AsmLabel], lens: [long]) -> void {
    let n = 0;
    lens.foreach((e, i) => {
        let it = items[i];
        if (it.sec == 0 && it.br >= 0 && e != 2) {
            relax_grow(items, i, lens, it.fix[0].lbl);
            n++;
        };
    });
    n
};

// The final placement: the labels at the final lengths (always -- pass 2
// measures every fixup against them), and the item offsets too, but only for
// -g: they are one record rebuild per item, and the line table is their only
// reader.
def relax_place(items: [AsmItem], labels: [AsmLabel], lens: [long], secs: [long], debug: bool) -> void {
    let offs: [long] = [0, 0, 0];
    let i = 0;
    let j = 0;
    while (i < len(lens)) {
        while (j < len(labels) && labels[j].at_item <= i) {
            let lb = labels[j];
            labels[j] = { name: lb.name, sec: lb.sec, off: offs[lb.sec], at_item: lb.at_item };
            j++;
        };
        let s = secs[i];
        if (s >= 0) {
            if (debug) {
                let it = items[i];
                items[i] = { sec: it.sec, off: offs[s], len: it.len, kind: it.kind, bytes: it.bytes, fix: it.fix, br: it.br };
            };
            offs[s] = offs[s] + lens[i];
        };
        i++;
    };
    while (j < len(labels)) {
        let lb = labels[j];
        labels[j] = { name: lb.name, sec: lb.sec, off: offs[lb.sec], at_item: lb.at_item };
        j++;
    };
    offs[0]
};

// ── pass 2: layout, fixups, ELF ────────────────────────────────────────

let asm_a64_base = 0;
// The opt-in --obfuscate-map text: label addresses, kept out of the binary.
let asm_obf_map = "";
let asm_map_on = false;
def asm_map_enable(v: bool) -> void { asm_map_on = v; };

type SealPad = { items: [AsmItem], labels: [AsmLabel] };

// The text part's .align and the relaxation pass can disagree by the trailing
// bytes of the stub (the pad is measured before a later text addition). Insert
// one explicit data item in front of a sealed boundary label, so the boundary
// is on a page in the final layout regardless of that disagreement.
def seal_pad(items: [AsmItem], labels: [AsmLabel], name: str, page: long) -> SealPad {
    let ci = -1;
    for i in 0..len(labels) {
        if (labels[i].name == name) { ci = i; };
    };
    if (ci < 0) { return { items: items, labels: labels }; };
    let off = labels[ci].off;
    let pad = page - off % page;
    if (pad == page) { return { items: items, labels: labels }; };
    let at = labels[ci].at_item;
    let zeros: [byte] = [];
    for z in 0..pad { zeros += 0; };
    let pi: AsmItem = { sec: 0, off: 0, len: pad, kind: "data", bytes: zeros,
        fix: [], br: -1 };
    let ni: [AsmItem] = [];
    let k = 0;
    while (k < len(items)) {
        if (k == at) { ni += pi; };
        ni += items[k];
        k += 1;
    };
    if (at >= len(items)) { ni += pi; };
    let nl: [AsmLabel] = [];
    for j in 0..len(labels) {
        let lb = labels[j];
        let a = lb.at_item;
        if (a >= at) { a += 1; };
        nl += { name: lb.name, sec: lb.sec, off: lb.off, at_item: a };
    };
    let lens: [long] = [];
    let secs: [long] = [];
    for j in 0..len(ni) { lens += ni[j].len; secs += ni[j].sec; };
    relax_place(ni, nl, lens, secs, false);
    { items: ni, labels: nl }
};

def asm_link(items: [AsmItem], labels: [AsmLabel], debug: bool, seal_key: long) -> AsmOut {
    asm_obf_map = "";
    if (seal_key != 0) {
        let page = if (target_is_aarch64()) { 65536 } else { 4096 };
        let a = seal_pad(items, labels, "y_obf_clear_end", page);
        items = a.items;
        labels = a.labels;
        let b = seal_pad(items, labels, "y_obf_code_end", page);
        items = b.items;
        labels = b.labels;
    };
    // section sizes
    let lt0 = clock_us();
    let lh0 = heap_used();
    let code_len = 0;
    let ro_len = 0;
    let bss_len = 0;
    let bss_data = false;
    foreach (it in items) {
        if (it.sec == 0) { code_len += it.len; }
        else if (it.sec == 1) { ro_len += it.len; }
        else if (it.sec == 2) {
            bss_len += it.len;
            if (len(it.bytes) > 0) { bss_data = true; };
        };
    };
    if (target_is_aarch64()) { asm_a64_base = asm_image_base(bss_len, seal_key != 0); };
    let labs: [AsmLabel] = [];
    if (bss_len > 0) {
        labs += { name: "y_bss_lo", sec: 2, off: 0, at_item: 0 };
    };
    labs += labels;
    if (bss_len > 0) {
        labs += { name: "y_bss_hi", sec: 2, off: bss_len, at_item: len(items) };
    };
    if (bss_len > 0) {
        let bshift = asm_bss_shift(code_len, ro_len, bss_len);
        let shifted: [AsmLabel] = [];
        foreach (lb in labs) {
            if (lb.sec == 2) { shifted += { name: lb.name, sec: 1, off: bshift + lb.off, at_item: lb.at_item }; }
            else { shifted += lb; };
        };
        labs = shifted;
    };
    let lm = labmap_build(labs);
    let lt1 = clock_us();
    let lh1 = heap_used();
    let lmap = lm.map;
    let start_name = "_start";
    if (seal_key != 0) { start_name = "y_obf_start"; };
    let start = labmap_get(lmap, start_name);
    let clear = labmap_get(lmap, "y_obf_clear_end");
    let code_end = labmap_get(lmap, "y_obf_code_end");
    let iend = labmap_get(lmap, "y_obf_image_end");
    let dstart = labmap_get(lmap, "y_obf_data_start");
    let macs = labmap_get(lmap, "y_obf_macs");
    let mcount = labmap_get(lmap, "y_obf_mac_count");
    let preg = labmap_get(lmap, "y_pe_region");
    let plen = labmap_get(lmap, "y_pe_len");
    let phx = labmap_get(lmap, "y_obf_hash_expect");
    if (lm.dup != "") {
        { ok: false, bytes: [], error: "duplicate label '" + lm.dup + "'",
            times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (start.sec != 0) {
        let why = "no _start label (empty program?)";
        if (seal_key != 0) { why = "no y_obf_start label in a sealed image"; };
        { ok: false, bytes: [], error: why,
            times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (seal_key != 0 && target_is_windows()
        && (preg.sec != 0 || plen.sec != 0 || phx.sec != 0
        || preg.off < start.off || preg.off > code_len
        || plen.off < 0 || plen.off + 8 > code_len
        || phx.off < 0 || phx.off + 8 > code_len)) {
        { ok: false, bytes: [],
            error: "the PE seal has no region/length/hash labels (region=" + tostring(preg.off) + " len=" + tostring(plen.off) + " hash=" + tostring(phx.off) + " code=" + tostring(code_len) + ")",
            times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (seal_key != 0 && !target_is_windows() && (clear.sec != 0
        || code_end.sec != 0 || iend.sec != 1 || dstart.sec != 1
        || clear.off < 0 || clear.off > code_len
        || code_end.off < clear.off || code_end.off > code_len
        || iend.off != ro_len || dstart.off < 0 || dstart.off > ro_len
        || macs.sec != 0 || mcount.sec != 0 || macs.off < 0
        || macs.off + 65536 > clear.off || mcount.off + 8 > clear.off)) {
        { ok: false, bytes: [], error: "the sealed image is not 8-byte aligned (clear=" + tostring(clear.off) + " code=" + tostring(code_len) + " iend=" + tostring(iend.off) + " ro=" + tostring(ro_len) + " csec=" + tostring(clear.sec) + " isec=" + tostring(iend.sec) + ")",
            times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (seal_key != 0 && !target_is_windows()
        && (clear.off % (if (target_is_aarch64()) { 65536 } else { 4096 }) != 0
        || code_end.off % (if (target_is_aarch64()) { 65536 } else { 4096 }) != 0
        || dstart.off % (if (target_is_aarch64()) { 65536 } else { 4096 }) != 0)) {
        let page = if (target_is_aarch64()) { 65536 } else { 4096 };
        { ok: false, bytes: [], error: "the sealed image is not page-aligned (clear=" + tostring(clear.off) + " code_end=" + tostring(code_end.off) + " page=" + tostring(page) + ")",
            times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (bss_data) {
        { ok: false, bytes: [], error: "data or code in .bss",
            times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else {
        // No padding between the code and the rodata (mirrors elf.y): the
        // loader zero-fills the last page of the mapping instead, so a
        // rodata label's offset is exactly code_len + its own offset.
        let pad = 0;
        let image_base = asm_image_base(bss_len, seal_key != 0);
        let code: [byte] = [];
        let ro: [byte] = [];
        let err = "";
        let i = 0;
        while (i < len(items)) {
            if (err != "") {
                i = len(items);
            } else {
                let it = items[i];
                if (it.sec == 0) {
                    let r = patch_item(code, it, lmap, code_len, pad, image_base);
                    if (r.err != "") {
                        err = r.err;
                    } else {
                        code = r.bytes;
                    };
                } else if (it.sec == 1) {
                    let r = patch_item(ro, it, lmap, code_len, pad, image_base);
                    if (r.err != "") {
                        err = r.err;
                    } else {
                        ro = r.bytes;
                    };
                };
                i++;
            };
        };
        if (err != "") {
            { ok: false, bytes: [], error: err,
                times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
        } else {
            if (seal_key != 0 && target_is_windows()) {
                // The PE stub is plaintext up to y_pe_region; everything after
                // it (code and .rodata) is one ciphertext stream. The stub
                // hashes, decrypts and jumps _start.
                let first = len(code) - preg.off;
                let rec = seal.recipe(seal_key);
                seal.crypt_range(code, preg.off, first, seal_key, 0, rec);
                seal.crypt_range(ro, 0, len(ro), seal_key, first, rec);
                let all = code[preg.off:] + ro;
                let ih = seal.hash_image(seal_key, all, 0, len(all));
                code = patch64(code, plen.off, first + len(ro));
                code = patch64(code, phx.off, ih);
            } else if (seal_key != 0) {
                let first = len(code) - clear.off;
                let page = if (target_is_aarch64()) { 65536 } else { 4096 };
                let cpart = len(code) - clear.off;
                let total = cpart + len(ro);
                let npages = (total + page - 1) / page;
                if (npages > 8192) {
                    return { ok: false, bytes: [],
                        error: "sealed image too large for the per-page MAC table (" + tostring(npages) + " pages)",
                        times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] };
                };
                let mkey = seal_key ^ seal.MAC_DOMAIN;
                code = patch64(code, mcount.off, npages);
                let pi = 0;
                while (pi < npages) {
                    let at = pi * page;
                    let n = page;
                    if (total - at < page) { n = total - at; };
                    let chunk: [byte] = [];
                    if (at < cpart) {
                        chunk = code[clear.off + at:clear.off + at + n];
                    } else {
                        let r0 = at - cpart;
                        chunk = ro[r0:r0 + n];
                    };
                    let mac = seal.hash_image(mkey, chunk, 0, n);
                    code = patch64(code, macs.off + 8 * pi, mac);
                    pi += 1;
                };
                let rec = seal.recipe(seal_key);
                seal.crypt_range(code, clear.off, first, seal_key, 0, rec);
                seal.crypt_range(ro, 0, len(ro), seal_key, first, rec);
                // The image hash is over the ciphertext the loader will read:
                // code from clear_end, then the contiguous .rodata.
                let all = code[clear.off:] + ro;
                let ih = seal.hash_image(seal_key, all, 0, len(all));
                let hx = labmap_get(lmap, "y_obf_hash_expect");
                if (hx.sec != 0 || hx.off < 0 || hx.off + 8 > clear.off) {
                    return { ok: false, bytes: [],
                        error: "no room for the image hash in the loader",
                        times: [ { name: "l:labmap", us: lt1 - lt0,
                            heap: lh1 - lh0 } ] };
                };
                code = patch64(code, hx.off, ih);
            };
            let lt2 = clock_us();
            let lh2 = heap_used();
            let syms: [ElfSym] = [];
            let dsecs: [ElfSec] = [];
            if (debug) {
                syms = debug_syms(labels, code_len, bss_len);
                dsecs = debug_lines(items, code_len, asm_image_base(bss_len));
            };
            let eb = asm_image(code, ro, start.off, bss_len, syms, dsecs, items, labels, seal_key != 0);
            if (asm_map_on) {
                let abase = asm_image_base(bss_len, seal_key != 0);
                let mm = "";
                foreach (lb in labels) {
                    if (lb.name == "_start" || lb.name[:4] == "yfn_"
                        || lb.name[:6] == "y_obf_") {
                        if (lb.sec == 0 || lb.sec == 1) {
                            let a = abase + lb.off;
                            if (lb.sec == 1) { a = abase + code_len + lb.off; };
                            mm += tostring(a) + " " + lb.name + "\n";
                        };
                    };
                };
                asm_obf_map = mm;
            };
            let lt3 = clock_us();
            let lh3 = heap_used();
            { ok: true, bytes: eb, error: "",
                times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 },
                    { name: "l:patch", us: lt2 - lt1, heap: lh2 - lh1 },
                    { name: asm_link_row(), us: lt3 - lt2, heap: lh3 - lh2 } ] }
        }
    }
};

// ── the object writer ───────────────────────────────────────────────────

// Where the code sits in the image, which the DWARF line table hangs off: on
// ELF the base plus the header size the ELF writer chose (the code's file
// offset, since the first segment is mapped at the base), on PE the image
// base plus the .text section's RVA.
def asm_image_base(bss_len: long, sealed: bool = false) -> long {
    if (target_is_windows()) { pe.pe_text_base() }
    else if (target_is_kernel()) { kelf.kelf_base() + kelf.kelf_code_off() }
    else { 4194304 + elf.elf_code_off(bss_len, sealed) }
};

// Where the .bss section starts, as an offset from the rodata's start.  The
// three writers round it differently (a page plus a page on ELF, the section
// alignment on PE, the page after the image on the kernel's ELF32), so the
// fixups must measure against the one that will place the bytes.
def asm_bss_shift(code_len: long, ro_len: long, bss_len: long) -> long {
    if (target_is_windows()) { pe.pe_bss_from_ro(code_len, ro_len, bss_len) }
    else if (target_is_kernel()) { kelf.kelf_bss_from_ro(code_len, ro_len) }
    else { elf.elf_bss_from_ro(code_len, ro_len) }
};

// The `ycc --time` row name for the writer, so the table names the format it
// actually ran.
def asm_link_row() -> str {
    if (target_is_windows()) { "l:pe" }
    else if (target_is_kernel()) { "l:kelf" }
    else { "l:elf" }
};

def asm_image(code: [byte], ro: [byte], entry_off: long, bss_len: long, syms: [ElfSym], dsecs: [ElfSec], items: [AsmItem], labels: [AsmLabel],
        sealed: bool = false) -> [byte] {
    if (target_is_windows()) {
        pe_image(code, ro, entry_off, bss_len, syms, dsecs, items, labels, sealed)
    } else if (target_is_kernel()) {
        // No -g on a kernel image (ycc refuses the combination): the two
        // debug writers here are ELF64/DWARF64, and an ELF32 kernel with a
        // 64-bit line table would be worse than no line table.
        kelf.kelf_build(code, ro, entry_off, bss_len)
    } else {
        elf.elf_build(code, ro, entry_off, bss_len, syms, dsecs, sealed)
    }
};

// The PE writer, fed what it needs in its own shapes.  `syms`/`dsecs` are the
// ELF-shaped records the -g pass above builds (debug_syms, dwarf.y's
// dwarf_sections): the same facts re-typed, because Y records are exact and a
// record goes only where its own type is expected.
def pe_image(code: [byte], ro: [byte], entry_off: long, bss_len: long, syms: [ElfSym], dsecs: [ElfSec], items: [AsmItem], labels: [AsmLabel], sealed: bool = false) -> [byte] {
    let un = pe_unwind(items, labels);
    let dsecs2: [PeSecHdr] = [];
    let ddata: [[byte]] = [];
    dsecs.foreach((ds) => {
        dsecs2 += pe.pe_sec(ds.name, len(ds.data), 0, 0, 1073741888);
        ddata += ds.data;
    });
    let coff = pe_coff_syms(syms);
    // Windows has no syscall for randomness, sockets or the console: those
    // arrive as imports (see pe.y's import table).
    pe.pe_build(code, ro, entry_off, bss_len, un.pdata, un.xdata, dsecs2, ddata,
        coff, pe.pe_imports(), sealed)
};

def patch_item(code: [byte], it: AsmItem, lmap: [AsmLabel], code_len: long,
        pad: long, image_base: long) -> AsmBytes {
    let bytes = it.bytes;
    let err = "";
    // NOTE: single gate (see asm_strdata note): insn-vs-other shapes
    // never mix in one chain.
    if (it.kind != "insn") {
        // A data item's absolute label word is the only fixup a table needs;
        // the value is the image base plus the section-relative address.
        let f = 0;
        while (f < len(it.fix) && err == "") {
            let fx = it.fix[f];
            if (fx.kind == "abs64") {
                let t = label_addr(lmap, code_len, pad, fx.lbl);
                if (!t.ok) {
                    err = "undefined label '" + fx.lbl + "'";
                } else {
                    bytes = patch64(bytes, fx.off, t.addr + image_base);
                };
            };
            f++;
        };
        patch_item_finish(code, bytes, err)
    } else {
        patch_item_loop(code, it, lmap, code_len, pad, image_base, bytes, err)
    }
};

def patch_item_loop(code: [byte], it: AsmItem, lmap: [AsmLabel], code_len: long, pad: long, image_base: long, bytes: [byte], err: str) -> AsmBytes {
    let base = len(code);
    let fxlist = it.fix;
    let f = 0;
    while (f < len(fxlist)) {
        if (err != "") {
            f = len(fxlist);
        } else {
            let fx = fxlist[f];
            // at is instruction-relative: bytes is the ITEM's list, and the
            // rel target is relative to the instruction END (base + it.len).
            let at = fx.off;
            if (fx.kind == "rel32" || fx.kind == "rip32") {
                let rr = patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at);
                bytes = rr.bytes;
                if (rr.err != "") { err = rr.err; }
            } else if (fx.kind == "rel8") {
                let r8 = patch_item_rel8(lmap, code_len, pad, fx, bytes, base, it, at);
                bytes = r8.bytes;
                if (r8.err != "") { err = r8.err; }
            } else {
                let rk = patch_item_kind2(lmap, code_len, pad, fx, bytes, base, it, at, image_base);
                bytes = rk.bytes;
                if (rk.err != "") { err = rk.err; }
            };
            f++;
        };
    };
    patch_item_finish(code, bytes, err)
};

def pe_no_abs(kind: str) -> bool {
    if (kind in ["rel32", "rel8", "rip32", "imm32diff"]) { true }
    else { false }
};

def patch_item_kind2(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem, at: long, image_base: long) -> AsmBytes {
    // (split: non-rel32 kinds; `{bytes,err}` built ONLY here + callees.)
    if (fx.kind == "a64branch" || fx.kind == "a64addr" || fx.kind == "a64diff") {
        patch_item_a64(lmap, code_len, pad, fx, bytes, base, at)
    } else if (fx.kind == "rip32") {
        patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at)
    } else if (fx.kind == "abs64") {
        patch_item_abs64(lmap, code_len, pad, fx, bytes, at, image_base)
    } else if (!pe_no_abs(fx.kind)) {
        // rel32 and rel8 never reach here (patch_item_loop handles them); what
        // is left is the diff form, or a kind no no-relocation image can hold.
        { bytes: bytes, err: "absolute fixup kind '" + fx.kind + "' has no representation in a no-relocation image" }
    } else {
        patch_item_diff(lmap, code_len, pad, fx, bytes, base, it)
    }
};

def patch_item_a64(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, at: long) -> AsmBytes {
    let t = label_addr(lmap, code_len, pad, fx.lbl);
    if (!t.ok) { return { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }; };
    let v = t.addr;
    if (fx.kind == "a64addr") { v += asm_a64_base; };
    if (fx.kind == "a64branch") {
        let d = v - (base + at);
        if (d % 4 != 0 || d < -134217728 || d >= 134217728) {
            return { bytes: bytes, err: "AArch64 branch out of range or unaligned: " + fx.lbl };
        };
        let op = (bytes[at + 3] << 24) & 0xfc000000;
        bytes = patch32(bytes, at, op | ((d >> 2) & 0x3ffffff));
    } else {
        if (fx.kind == "a64diff") {
            let t2 = label_addr(lmap, code_len, pad, fx.lbl2);
            if (!t2.ok) { return { bytes: bytes, err: "undefined label '" + fx.lbl2 + "'" }; };
            v -= t2.addr;
        };
        for i in 0..4 {
            let d = bytes[at + 4 * i] & 31;
            let op = if (i == 0) { 0xd2800000 } else { 0xf2800000 | (i << 21) };
            bytes = patch32(bytes, at + 4 * i, op | (((v >>> (16 * i)) & 65535) << 5) | d);
        };
    };
    { bytes: bytes, err: "" }
};

def patch_item_rel(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem, at: long) -> AsmBytes {
    // rel32/rip32: target - address past the instruction.
    // NOTE: fx/it stay BARE holes (see types.y typeof_def note): single
    // reads unify.
    let t = label_addr(lmap, code_len, pad, fx.lbl);
    if (!t.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }
    } else {
        // label_addr has already added `tab+8(%rip)`'s 8, so this is the
        // target less the address past the instruction.
        { bytes: patch32(bytes, at, (t.addr - (base + it.len))), err: "" }
    }
};

def patch_item_rel8(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem, at: long) -> AsmBytes {
    let t = label_addr(lmap, code_len, pad, fx.lbl);
    if (!t.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }
    } else {
        { bytes: patch8(bytes, at, (t.addr - (base + it.len))), err: "" }
    }
};

def patch_item_abs64(lmap: [AsmLabel], code_len: long, pad: long,
        fx: Fixup, bytes: [byte], at: long, image_base: long) -> AsmBytes {
    let t = label_addr(lmap, code_len, pad, fx.lbl);
    if (!t.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }
    } else {
        { bytes: patch64(bytes, at, t.addr + image_base), err: "" }
    }
};

def patch_item_diff(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem) -> AsmBytes {
    // (split: diff-shape fixups only; `{bytes,err}` built ONLY here.)
    // NOTE: fx/it stay BARE holes (see types.y typeof_def note): single
    // reads unify.
    let ta = label_addr(lmap, code_len, pad, fx.lbl);
    if (!ta.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }
    } else {
        let dd = patch_item_diff2(lmap, code_len, pad, fx, bytes, ta.addr);
        { bytes: dd.bytes, err: dd.err }
    }
};

def patch_item_diff2(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], ta: long) -> AsmBytes {
    let tb = label_addr(lmap, code_len, pad, fx.lbl2);
    if (!tb.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl2 + "'" }
    } else {
        { bytes: patch32(bytes, fx.off, ta - tb.addr), err: "" }
    }
};

def patch_item_finish(code: [byte], bytes: [byte], err: str) -> AsmBytes {
    // In place: `code + bytes` built a fresh copy of the whole code buffer
    // per instruction (O(n^2) arena; ~30 GB on the self-compile).
    code += bytes;
    { bytes: code, err: err }
};

def patch32(bytes: [byte], at: long, v: long) -> [byte] {
    let b = enc.le32(v);
    bytes[at] = b[0];
    bytes[at + 1] = b[1];
    bytes[at + 2] = b[2];
    bytes[at + 3] = b[3];
    bytes
};

def patch64(bytes: [byte], at: long, v: long) -> [byte] {
    let out = bytes;
    let i = 0;
    while (i < 8) {
        out[at + i] = (v >>> (8 * i)) & 255;
        i += 1;
    };
    out
};

def patch8(bytes: [byte], at: long, v: long) -> [byte] {
    // The low byte of a rel8 displacement, which is two's complement: v + 256
    // before the modulo because Y's % truncates toward zero and a negative
    // displacement must land on its high byte (v - 128 stores 128, not -128).
    bytes[at] = (v + 256) % 256;
    bytes
};

// ── PE unwind data (.pdata and .xdata) ──────────────────────────────────

// What one function's prologue turned out to be: its extent, whether it
// establishes a frame pointer, the total bytes it takes off the stack and
// where that is in effect from, and one (prolog offset, register number) per
// callee-saved register it pushed.
type PeFrame = { start: long, end: long, first: long, last: long, fp: bool, fp_off: long, alloc: long, alloc_off: long, pushes: [long], prolog: long };
// What pe_unwind hands back, and what pe_prologue_insn threads the prologue
// scan through (go: false ends the prologue at that instruction).
type PeUnwind = { pdata: [byte], xdata: [byte] };
type PePro = { go: bool, fp: bool, fp_off: long, alloc: long, alloc_off: long, pushes: [long], prolog: long };

// The two unwind sections, or two empty arrays when there is nothing to say.
def pe_unwind(items: [AsmItem], labels: [AsmLabel]) -> PeUnwind {
    pe_unwind_bytes(pe_frames(items, labels), 0)
};

def pe_frames(items: [AsmItem], labels: [AsmLabel]) -> [PeFrame] {
    let out: [PeFrame] = [];
    for i in 0..len(labels) {
        let lb = labels[i];
        if (lb.sec == 0 && is_sym_label(lb.name, 0)) {
            out += { start: lb.off, end: 0, first: lb.at_item, last: 0, fp: false, fp_off: 0, alloc: 0, alloc_off: 0, pushes: [], prolog: 0 };
        };
    };
    pe_frame_prologues(items, out)
};

def pe_nonvol(reg: long) -> bool {
    reg == 3 || reg == 5 || reg == 6 || reg == 7 || (reg >= 12 && reg <= 15)
};

def pe_frame_prologues(items: [AsmItem], frames: [PeFrame]) -> [PeFrame] {
    let n = len(frames);
    for i in 0..n {
        let stop = 0;
        let last = len(items);
        if (i + 1 < n) {
            stop = frames[i + 1].start;
            last = frames[i + 1].first;
        };
        frames[i] = pe_prologue(items, frames[i], stop, last);
    };
    frames
};

def pe_prologue(items: [AsmItem], f: PeFrame, stop: long, last: long) -> PeFrame {
    let alloc = 0;
    let alloc_off = 0;
    let pushes: [long] = [];
    let prolog = 0;
    let fp = false;
    let fp_off = 0;
    let at = 0;
    let k = f.first;
    let open = true;
    while (open && k < last) {
        let it = items[k];
        k = k + 1;
        if (it.sec == 0) {
            let r = pe_prologue_insn(it, at, fp, fp_off, alloc, alloc_off, pushes, prolog);
            if (r.go) {
                fp = r.fp;
                fp_off = r.fp_off;
                alloc = r.alloc;
                alloc_off = r.alloc_off;
                pushes = r.pushes;
                prolog = r.prolog;
                at = r.prolog;
            } else {
                open = false;
            };
        };
    };
    f.end = stop;
    f.fp = fp;
    f.fp_off = fp_off;
    f.alloc = alloc;
    f.alloc_off = alloc_off;
    f.pushes = pushes;
    f.prolog = prolog;
    f
};

// One prologue instruction, as {go} (it belonged to the prologue) or {go:
// false, ...} (it did not).  `off` is the instruction's offset within the
// function; the CodeOffset a code carries is that instruction's last byte
// plus one, which is where the effect is in force.
def pe_prologue_insn(it: AsmItem, off: long, fp: bool, fp_off: long, alloc: long, alloc_off: long, pushes: [long], prolog: long) -> PePro {
    let b = it.bytes;
    let n = len(b);
    let done = off + it.len;
    let no = { go: false, fp: fp, fp_off: fp_off, alloc: alloc, alloc_off: alloc_off, pushes: pushes, prolog: prolog };
    if (n < 1) {
        no
    } else if (b[0] == 0x55 || (b[0] >= 0x50 && b[0] <= 0x57)) {
        // push %reg (no REX: rax..rdi)
        pe_prologue_push(b[0] - 0x50, done, fp, fp_off, alloc, done, pushes, prolog)
    } else if (b[0] == 0x41 && n >= 2 && b[1] >= 0x50 && b[1] <= 0x57) {
        // push %r8..%r15
        pe_prologue_push(b[1] - 0x50 + 8, done, fp, fp_off, alloc, done, pushes, prolog)
    } else if (n >= 3 && b[0] == 0x48 && b[1] == 0x89 && b[2] == 0xe5) {
        // mov %rsp,%rbp: the frame register, established HERE -- so its code
        // carries this instruction's offset, not the prologue's end, which
        // may be several pushes and a `sub` later.
        { go: true, fp: true, fp_off: done, alloc: alloc, alloc_off: alloc_off, pushes: pushes, prolog: done }
    } else if (n == 4 && b[0] == 0x48 && b[1] == 0x83 && b[2] == 0xec) {
        // sub $imm8,%rsp
        { go: true, fp: fp, fp_off: fp_off, alloc: alloc + b[3], alloc_off: done, pushes: pushes, prolog: done }
    } else if (n == 7 && b[0] == 0x48 && b[1] == 0x81 && b[2] == 0xec) {
        // sub $imm32,%rsp
        let sz = enc.le32(b[3]);
        let v = sz[0] + 256 * sz[1] + 65536 * sz[2] + 16777216 * sz[3];
        if (v < 0) { no } else { { go: true, fp: fp, fp_off: fp_off, alloc: alloc + v, alloc_off: done, pushes: pushes, prolog: done } }
    } else {
        no
    }
};

// A push: 8 bytes off the stack either way, and -- for a register Win64
// considers nonvolatile -- a UWOP_PUSH_NONVOL whose CodeOffset is where that
// register becomes unreadable.  The pack is offset * 16 + register, which
// keeps a frame's whole code list flat.
def pe_prologue_push(reg: long, done: long, fp: bool, fp_off: long, alloc: long, alloc_off: long, pushes: [long], prolog: long) -> PePro {
    let np = pushes;
    let na = alloc;
    if (pe_nonvol(reg)) {
        // A nonvolatile push gets UWOP_PUSH_NONVOL, which ALREADY says RSP
        // went down by eight; counting it in the allocation as well would
        // describe the same eight bytes twice and unwind 8 bytes too far.
        np = pushes + [(done + 1) * 16 + reg];
    } else {
        // A volatile push has no code of its own (that is what MASM's
        // .allocstack 8 is for), so the allocation is what covers it.
        na = alloc + 8;
    };
    { go: true, fp: fp, fp_off: fp_off, alloc: na, alloc_off: done, pushes: np, prolog: done }
};

// One RUNTIME_FUNCTION per frame and one UNWIND_INFO per frame, the .pdata
// entry naming the .xdata offset.  With no frames both sections are empty and
// pe_build leaves them out.
def pe_unwind_bytes(frames: [PeFrame], xbase: long) -> PeUnwind {
    let pdata: [byte] = [];
    let xdata: [byte] = [];
    frames.foreach((f) => {
        pdata = push_le32(pdata, f.start);
        pdata = push_le32(pdata, f.end);
        pdata = push_le32(pdata, xbase + len(xdata));
        xdata = pe_unwind_info(xdata, f);
    });
    { pdata: pdata, xdata: xdata }
};

def pe_codes(f: PeFrame) -> [long] {
    let g: [[long]] = [];
    for i in 0..len(f.pushes) {
        // the push is packed as offset*16 + register (pe_prologue_push), and
        // the register is OpInfo, i.e. the HIGH nibble: multiply by 16.
        let packed = f.pushes[i];
        g += [[(packed / 16) + (packed % 16) * 4096]];
    };
    if (f.fp) { g += [[f.fp_off + 1 + 3 * 256]]; };
    if (f.alloc > 0) { g += pe_alloc(f.alloc, f.alloc_off); };
    pe_codes_sorted(g, 0)
};

def pe_alloc(size: long, off: long) -> [[long]] {
    if (size >= 8 && size <= 128) {
        [[off + 1 + (2 + (size / 8 - 1) * 16) * 256]]
    } else if (size > 128) {
        [[off + 1 + 1 * 256, size / 8]]
    } else {
        []
    }
};

// Insertion sort by descending CodeOffset (the low byte of a group's first
// slot). A frame has at most nine groups.
def pe_codes_sorted(g: [[long]], i: long) -> [long] {
    let out: [[long]] = [];
    for at in i..len(g) {
        let cur = g[at];
        let j = len(out);
        out += cur;                       // the slot to insert into
        while (j > 0 && (out[j - 1][0] % 256) < (cur[0] % 256)) {
            out[j] = out[j - 1];
            j = j - 1;
        };
        out[j] = cur;
    };
    let slots: [long] = [];
    out.foreach((e) => {
        for q in 0..len(e) { slots += e[q]; };
    });
    slots
};

// One UNWIND_INFO: the 4-byte header, the codes, then the padding to an even
// slot count. With no flags there is no trailing handler or chained-info
// DWORD, so a function with no codes is exactly 4 bytes.
def pe_unwind_info(xdata: [byte], f: PeFrame) -> [byte] {
    let c = pe_codes(f);
    let n = len(c);
    xdata += 1;                          // Version 1, no flags
    xdata += f.prolog % 256;
    xdata += n % 256;
    // FrameRegister RBP (5) in the low nibble, the scaled offset (0 for
    // `mov %rsp,%rbp`) in the high one.
    if (f.fp) { xdata += 5; } else { xdata += 0; };
    for i in 0..n {
        xdata += c[i] % 256;
        xdata += c[i] / 256 % 256;
    };
    if (n % 2 == 1) {
        xdata += 0;
        xdata += 0;
    };
    xdata
};

// ── PE -g: the COFF symbol table ────────────────────────────────────────
def pe_coff_syms(syms: [ElfSym]) -> [byte] {
    let out: [byte] = [];
    let strtab: [byte] = [];
    syms.foreach((s) => {
        out = pe_coff_sym(out, s.name, s.off, pe_coff_secnum(s.sec));
    });
    let tail: [byte] = [];
    tail = push_le32(tail, len(strtab) + len(out));
    tail = push_bytes(tail, strtab);
    push_bytes(out, tail)
};

def pe_coff_secnum(sec: long) -> long {
    if (sec == 2) { 2 } else { 1 }
};

// The 8-byte name field, zero-padded.  A name of 8 bytes or more goes in the
// string table behind a zero field, and none of ours is that long -- the
// renamed `yfn_<uid>_<name>` symbols are shortened by sym_name first, which
// is what keeps them short.
def pe_coff_sym(out: [byte], nm: str, val: long, secnum: long) -> [byte] {
    let i = 0;
    let n = len(nm);
    while (i < 8) {
        if (i < n) { out += nm[i]; } else { out += 0; };
        i++;
    };
    out = push_le32(out, val);
    out = push_le16(out, secnum);
    out = push_le16(out, 32);            // Type: IMAGE_SYM_DTYPE_FUNCTION << 4
    out += 3;                            // StorageClass: STATIC
    out += 0;                            // NumberOfAuxSymbols
    out
};
// ── -g: the symbol table ───────────────────────────────────────────────
def debug_syms(labels: [AsmLabel], code_len: long, bss_len: long) -> [ElfSym] {
    let out: [ElfSym] = [];
    out = debug_syms_sec(out, labels, 0, code_len);
    out = debug_syms_sec(out, labels, 2, bss_len);
    out
};

def debug_syms_sec(out: [ElfSym], labels: [AsmLabel], sec: long, end: long) -> [ElfSym] {
    let first = len(out);
    foreach (lb in labels) {
        if (lb.sec == sec) {
            if (is_sym_label(lb.name, sec)) {
                out += { name: sym_name(lb.name), sec: sec, off: lb.off, size: 0 };
            };
        };
    };
    // labels arrive in definition order, so offsets only grow
    for i in first..len(out) {
        let e = out[i];
        let nxt = end;
        if (i + 1 < len(out)) {
            nxt = (out[i + 1]).off;
        };
        e.size = nxt - e.off;
    };
    out
};

def is_sym_label(name: str, sec: long) -> bool {
    if (sec == 0) {
        name == "_start" || name.starts_with("y_") || name.starts_with("yfn_")
    } else {
        name.starts_with("yg_") || name.starts_with("y_")
    }
};

// The source name behind a label: `yfn_12_foo$3` -> `foo`, `yg_0_n$7` ->
// `n`; runtime names (`y_print_long`) stay as they are. The uid and
// rename's `$N` change from build to build, so they would only make
// profiles of two builds harder to line up.
def sym_name(lbl: str) -> str {
    let s = lbl;
    if (s.starts_with("yfn_")) {
        s = after_uid(s, 4);
    } else if (s.starts_with("yg_")) {
        s = after_uid(s, 3);
    };
    let d = last_index_of(s, "$");
    if (d > 0) {
        let k = d + 1;
        let digits = k < len(s);
        while (k < len(s)) {
            if (!is_digit_ch(s[k])) { digits = false; };
            k = k + 1;
        };
        if (digits) { s = s[0:d]; };
    };
    s
};

// `s` minus its `<prefix><digits>_` head, or `s` itself when the shape
// does not match.
def after_uid(s: str, k: long) -> str {
    let i = k;
    while (i < len(s) && is_digit_ch(s[i])) { i = i + 1; };
    if (i > k && i < len(s) && s[i:i + 1] == "_") {
        s[i + 1:]
    } else {
        s
    }
};

// ── -g: line info ──────────────────────────────────────────────────────
def debug_lines(items: [AsmItem], code_len: long, code_addr: long) -> [ElfSec] {
    let files: [str] = [];
    let rows: [long] = [];
    foreach (it in items) {
        let k = it.kind;
        if (k == "loc") {
            let fx = it.fix;
            rows += it.off;
            rows += fx[0].off;
            rows += fx[1].off;
        } else if (k == "file") {
            let fx = it.fix;
            while (len(files) < it.off) { files += "?"; };
            files[it.off - 1] = fx[0].lbl;
        };
    };
    if (len(rows) == 0) {
        let none_s: [ElfSec] = [];
        none_s
    } else {
        dwarf.dwarf_sections(files, rows, code_addr, code_len, asm_cwd())
    }
};

// The working directory, recorded as the compile unit's DW_AT_comp_dir
// (as GNU as does): the raw getcwd syscall fills buf and returns the
// path's length with its NUL, or a negative errno -- "." then.
def asm_cwd() -> str {
    let buf: [byte] = [];
    for i in 0..4096 {
        buf += 0;
    };
    let n = syscall(hostos.nr(79), ptr_addr(&buf[0]), 4096);
    if (n > 1) { from_bytes(buf[0:n - 1]) } else { "." }
};

def ycc_assemble(parts: [LinkPart], debug: bool, seal_key: long = 0) -> { ok: bool, bytes: [byte], octal: str, error: str, times: [Timing], items: long } {
    let r = asm_assemble(parts, debug, seal_key);
    if (!r.ok) {
        { ok: false, bytes: [], octal: "", error: r.error, times: r.times, items: 0 }
    } else {
        { ok: true, bytes: r.bytes, octal: "", error: "", times: r.times, items: r.items }
    }
};

def asm_map_text() -> str { asm_obf_map };

export { a64_listing, asm_assemble, ycc_assemble, part_ir, part_text, LinkPart, ir_parse_line,
    labmap_new, labmap_put, labmap_get, hash_str, asm_map_text, asm_map_enable,
    split_ops, parse_operand, asm_directive, asm_strdata, asm_quad, asm_section,
    ir_operand, is_num_text };
