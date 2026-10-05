// asm.y — assembler for the native backend's x86-64 dialect.
// asm_assemble(text, debug) -> {ok, bytes: [byte], error, times} (times:
// per-phase us/heap rows for `ycc --time`; debug is `ycc -g`, which adds a
// symbol table — see debug_syms — and, from the text's `.file`/`.loc`
// line markers, DWARF line info — see debug_lines).
// ycc_assemble(text, debug) -> the driver's wrapper (see its note at the bottom).
// Only what native.y/arch_x64.y emit is accepted; anything else is a loud
// error with a line number — never a silent miscompile.
// Two passes: (1) parse + encode, recording fixups and label positions;
// (1b) relax the branches to their shortest form that reaches (asm_relax);
// (2) resolve labels and patch. All jumps/calls use rel32 unless a branch
// relaxes to rel8, so instruction lengths are known by the end of (1b).
//
// The only constraint on this file is the twin: every def here has a
// statement-for-statement twin in src/c/asm.c (see PORTING.md), and both
// compilers must emit byte-identical programs (the `make ycc` gate).
// Nothing in the LANGUAGE is restricted here.

import tags from "./tags.y";
import enc from "./enc64.y";
import elf from "./elf.y";
import dwarf from "./dwarf.y";

// A per-phase row of `ycc --time`, and what asm_assemble returns.
type Timing = { name: str, us: long, heap: long };
type AsmOut = { ok: bool, bytes: [byte], error: str, times: [Timing] };
// A parsed number, and parse_operand's result (an Operand: enc64.y).
type AsmNum = { ok: bool, v: long };
type OpRes = { ok: bool, op: Operand, error: str };
// A label: its section (0 .text, 1 .rodata, 2 .bss), offset there, and the
// number of items emitted before it (asm_relax recomputes the offset from
// that, since relaxing a branch moves everything after it).
type AsmLabel = { name: str, sec: long, off: long, at_item: long };
// Pass 1: a line's bytes, where they go and the fixups pass 2 patches
// in; what a content line yields; the state threaded from line to line
// (asm_assemble_line). `br` is the branch this instruction is — 0 for jmp, the
// long form's condition byte for a jcc, -1 for everything else — so
// asm_relax can re-encode a grower without re-parsing its line. Pass 2: an
// item's patched bytes.
type AsmItem = { sec: long, off: long, len: long, kind: str, bytes: [byte], fix: [Fixup], br: long };
type AsmContent = { err: str, sec: long, offs: [long], item: AsmItem };
type AsmSt = { sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str };
type AsmBytes = { bytes: [byte], err: str };

// NOTE: the master note for every "nested ifs, not `&&`/`||`" comment in
// this file (and its C twin). `&&` and `||` are short-circuiting and fully
// legal: the def below uses one, and types.y's typeof_logic accepts ANY
// operand types and returns bool. The ladder style stays only because the
// C twin mirrors these arms statement for statement (PORTING.md) — it is
// house style, not a rule.
// NOTE: str `<`/`<=`/`>`/`>=` order lexicographically by UNSIGNED byte
// (types.y typeof_cmp -> native.y gen_str_cmp -> the y_str_cmp stub), so
// the one-character range tests below are exact.
// A decimal digit.
def is_digit_ch(c: byte) -> bool {
    c >= c'0' && c <= c'9'
};

// An octal digit.
def is_oct_ch(c: byte) -> bool {
    c >= c'0' && c <= c'7'
};

// A letter or `_`.
def is_alpha_ch(c: byte) -> bool {
    c == c'_' || (c >= c'A' && c <= c'Z') || (c >= c'a' && c <= c'z')
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
            v = v * 10 + c - c'0';
        } else {
            ok = false;
        };
        i = i + 1;
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
    // One slice per FIELD, not one per character. The loop used to take
    // s[i:i + 1] and append it, so every byte of every operand allocated a
    // throwaway 1-byte string -- ycc's single largest allocation site, at
    // ~10% of all heap. Tracking where the field starts slices each field
    // once instead, with the same bytes in the same order.
    let start = 0;
    let i = 0;
    let n = len(s);
    while (i < n) {
        let b = byte_at(s, i);
        if (b == c'(') { depth++ };
        if (b == c')') { depth-- };
        if (b == c',') {
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

// `%fs:N`: the thread-local word at N (a thread's heap block, its word 3
// its own address; arch_x64.y). Tried only once no register matches.
def parse_operand_fs(t: str) -> OpRes {
    let r = parse_num(t[4:]);
    if (!r.ok) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad fs operand '" + t + "'" }
    } else {
        { ok: true, op: { k: K.fs, n: 0, size: 64, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: r.v, rip: false, lbl: "" }, error: "" }
    }
};

def parse_operand_reg(t: str) -> OpRes {
    // (split: %-gate above narrows; this body sees registers, and
    // `%fs:N`, which no register name matches.)
    let n = enc.reg_num(t);
    if (n < 0) {
        if (t[0:4] == "%fs:") {
            parse_operand_fs(t)
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
        let a = s[0:dash + 1];
        let b = s[dash + 2:];
        { ok: true, op: { k: K.diff, n: 0, size: 0, v: 0, a: a, b: b, name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "" }
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
    let inside = t[open + 1:len(t) - 1];
    let parts = split_ops(inside);
    if (head != "") {
        parse_mem_head(t, head, parts)
    } else {
        parse_mem_regs(t, parts, 0)
    }
};

def parse_mem_head(t: str, head: str, parts: [str]) -> OpRes {
    // (split: non-empty head narrows; rip-label vs numeric displacement.)
    if (is_num_text(head)) {
        parse_mem_disp(t, head, parts)
    } else {
        parse_mem_rip(t, head, parts)
    }
};

def parse_mem_rip(t: str, head: str, parts: [str]) -> OpRes {
    // label(%rip) — mem-shape built ONLY here.
    // NOTE: nested ifs, not `||` (see is_digit_ch note).
    if (len(parts) != 1) {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad rip-relative '" + t + "'" }
    } else if (parts[0] != "%rip") {
        { ok: false, op: { k: K.bad, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: 0, idx: 0, scale: 0, disp: 0, rip: false, lbl: "" }, error: "bad rip-relative '" + t + "'" }
    } else {
        { ok: true, op: { k: K.mem, n: 0, size: 0, v: 0, a: "", b: "", name: "", base: -1, idx: -1, scale: 1, disp: 0, rip: true, lbl: head }, error: "" }
    }
};

def parse_mem_disp(t: str, head: str, parts: [str]) -> OpRes {
    // numeric displacement head: parse_num cannot fail (is_num_text held).
    let r = parse_num(head);
    parse_mem_regs(t, parts, r.v)
};

def parse_mem_regs(t: str, parts: [str], disp: long) -> OpRes {
    // NOTE: nested ifs, not `||` (see is_digit_ch note).
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
    // NOTE: nested ifs, not `||`/`&&` (see is_digit_ch note).
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
def decode_str(s: str) -> {ok: bool, bytes: [byte], error: str} {
    let out: [byte] = [];
    let i = 0;
    let n = len(s);
    let err = "";
    while (i < n) {
        let c = s[i];
        if (c != c'\\') {                // '\\'
            out += c;
            i = i + 1;
        } else if (i + 1 >= n) {
            // a backslash as the last byte: no escape follows it
            err = "bad escape '\\'";
            i = n;
        } else {
            let e = s[i + 1];
            if (e == c'n') {            // 'n', the letter of \n
                out += c'\n';
                i = i + 2;
            } else if (e == c't') {      // 't', the letter of \t
                out += c'\t';
                i = i + 2;
            } else if (e == c'r') {      // 'r', the letter of \r
                out += c'\r';
                i = i + 2;
            } else if (e == c'\\') {      // '\\'
                out += c'\\';
                i = i + 2;
            } else if (e == c'\x22') {      // '"'
                out += c'\x22';
                i = i + 2;
            } else if (is_oct_ch(e)) {
                // NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;`
                // tails (see parser.y parse_binary note).
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

def decode_oct(s: str, k: long, n: long) -> {v: long, k: long, err: str} {
    // Octal escape starting after the backslash (e is already known-octal).
    // Returns {v, k (pos after digits), err}. Split from decode_str: the
    // `{ok,bytes,error}` shape is built ONLY in decode_str.
    // NOTE: `0;` tails (see parser.y parse_binary note).
    let e = s[k - 1];
    let v = e - c'0';
    let kk = k;
    let nd = 1;
    while (nd < 3) {
        if (kk < n) {
            let d = s[kk];
            if (is_oct_ch(d)) {
                v = v * 8 + d - c'0';
                kk = kk + 1;
                nd = nd + 1;
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
// Pass 1 threads a plain labels LIST (cheap amortized pushes); resolving
// every fixup (plus the old duplicate scan) against that list is O(F·L) —
// minutes on big programs (7k labels × 11k refs). This index makes queries
// O(1): flat [{name,sec,off}] with name "" marking empty slots, put-if-
// absent (first wins, matching linear-scan order). Plain Y only (arrays,
// longs, strings, ord) — nothing the C twin's yv.c lacks already.

def hash_str(s: str) -> long {
    // byte_at, not ord(s[i:i + 1]): the slice allocated a throwaway string
    // per character, and the tree shaker hashes ~191k names per compile
    // through this (native.y namemap_build/namemap_get).
    //
    // No `% 1000000007` per byte. That is a 64-bit idiv -- twenty-odd
    // instructions -- and with it a lookup in either table cost 509
    // instructions a call, 2.6% of everything ycc executes. Both users
    // take the result modulo a table size, so any well-spread 32-bit
    // value is as good as a prime: masking to 32 bits keeps `h * 31` from
    // overflowing (it cannot exceed 2^37), and the final shift-xor spreads
    // the high bits down into the low ones the modulo keeps.
    let h = 0;
    let i = 0;
    let n = len(s);
    while (i < n) {
        h = (h * 31 + byte_at(s, i)) & 4294967295;
        i = i + 1;
    };
    h ^ (h >> 13)
};

def labmap_new(cap: long) -> [AsmLabel] {
    let m: [AsmLabel] = [];
    let i = 0;
    while (i < cap) {
        m += { name: "", sec: 0, off: 0, at_item: 0 };
        i = i + 1;
    };
    m
};

def labmap_put(m: [AsmLabel], name: str, sec: long, off: long) -> { map: [AsmLabel], dup: bool } {
    let cap = len(m);
    let i = hash_str(name) % cap;
    let dup = false;
    let done = false;
    let n = 0;
    while (done == false) {
        let e = m[i];
        if (e.name == "") {
            m[i] = { name: name, sec: sec, off: off, at_item: 0 };
            done = true;
        } else if (e.name == name) {
            dup = true;
            done = true;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; }
        };
        n = n + 1;
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
    while (done == false) {
        let e = m[i];
        if (e.name == "") {
            done = true;
        } else if (e.name == name) {
            found_sec = e.sec;
            found_off = e.off;
            done = true;
        } else {
            i = i + 1;
            if (i >= cap) { i = 0; }
        };
        n = n + 1;
        if (n > cap) { done = true; }
    };
    { sec: found_sec, off: found_off }
};

// Build the index from pass-1 labels; reports the first duplicate name
// ("" when clean). Replaces the old O(L^2) definition-site scans — our
// emitter only feeds unique labels, and no test pins dup positions.
def labmap_build(labels: [AsmLabel]) -> { map: [AsmLabel], dup: str } {
    let cap = len(labels) * 2 + 16;
    let m = labmap_new(cap);
    let dup = "";
    let i = 0;
    while (i < len(labels)) {
        let e = labels[i];
        let r = labmap_put(m, e.name, e.sec, e.off);
        m = r.map;
        if (r.dup) { dup = e.name; }
        i = i + 1;
    };
    { map: m, dup: dup }
};

def label_addr(lmap: [AsmLabel], code_len: long, pad: long, name: str) -> {ok: bool, addr: long} {
    let e = labmap_get(lmap, name);
    if (e.sec < 0) {
        { ok: false, addr: 0 }
    } else if (e.sec == 0) {
        { ok: true, addr: e.off }
    } else {
        { ok: true, addr: code_len + pad + e.off }
    }
};

// ── pass 1: parse lines into items ─────────────────────────────────────

def asm_assemble(text: str, debug: bool) -> AsmOut {
    let t0 = clock_us();
    let h0 = heap_used();
    let lines = split(text, "\n");
    let t1 = clock_us();
    let h1 = heap_used();
    let items: [AsmItem] = [];
    let labels: [AsmLabel] = [];
    let sec = 0;
    let offs = [0, 0, 0];
    let li = 0;
    let err = "";
    // NOTE: threaded STATE record (see note below): sec/offs/items/labels/err
    // rebound across 6+ arms merge through the flow-insensitive env. Threading
    // one {sec,offs,items,labels,err} value through per-line callees keeps a
    // single key set everywhere.
    // NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails.
    while (li < len(lines)) {
        if (err != "") {
            li = len(lines);
        } else {
            let st = asm_assemble_line(lines, li, sec, offs, items, labels, err);
            sec = st.sec;
            offs = st.offs;
            items = st.items;
            labels = st.labels;
            err = st.err;
        };
        li = li + 1;
    };
    let tr0 = clock_us();
    let hr0 = heap_used();
    if (err != "") {
        { ok: false, bytes: [], error: err,
          times: [ { name: "a:split", us: t1 - t0, heap: h1 - h0 },
                   { name: "a:encode", us: tr0 - t1, heap: hr0 - h1 } ] }
    } else {
        asm_relax(items, labels, debug);
        let tr1 = clock_us();
        let hr1 = heap_used();
        let lk = asm_link(items, labels, debug);
        let t3 = clock_us();
        let h3 = heap_used();
        let tl: [Timing] =
            [ { name: "a:split", us: t1 - t0, heap: h1 - h0 },
              { name: "a:encode", us: tr0 - t1, heap: hr0 - h1 },
              { name: "a:relax", us: tr1 - tr0, heap: hr1 - hr0 },
              { name: "a:link", us: t3 - tr1, heap: h3 - hr1 } ];
        let lsub = lk.times;
        let k = 0;
        while (k < len(lsub)) {
            let le = lsub[k];
            tl += le;
            k = k + 1;
        };
        { ok: lk.ok, bytes: lk.bytes, error: lk.error, times: tl }
    }
};

// Per-line state threading for asm_assemble (see note above): one STATE
// record {sec,offs,items,labels,err} threaded through per-class callees.
// Each callee reads ONLY its inputs and returns the full STATE — single key
// set everywhere, no merged-shape rebinds.
def asm_assemble_line(lines: [str], li: long, sec: long, offs: [long], items: [AsmItem], labels: [AsmLabel], err: str) -> AsmSt {
    let line = trim(lines[li]);
    let lno = li + 1;
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
    // `label:` definition line.
    // NOTE: nested ifs, not `||` (see is_digit_ch note).
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
    // NOTE: nested ifs, not `||` (see is_digit_ch note).
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
    // The item builder does `offs[sec] = offs[sec] + len` IN PLACE, and
    // arrays are REFERENCE values in both toolchains (yv.c's ya_push/ya_set
    // mutate the shared array; see AGENTS.md), so offs[sec] read AFTER
    // asm_content is the POST-item offset: the label would land on its own
    // item's bytes (ystr_nl -> 't' of "true"). Bind the pre-item offset
    // FIRST. `at_item` is the same position in the item list -- asm_relax
    // re-derives the offset from it, so it must count the items *before* this
    // line's, not after.
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
    // NOTE: nested ifs, not `||` (see is_digit_ch note).
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
    // NOTE: `0;` tails (see parser.y parse_binary note).
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
    // NOTE: `0;` tails (see parser.y parse_binary note).
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
    } else if (dir == ".zero") {
        asm_zero(line, lno, sec, offs, rest)
    } else if (dir == ".loc") {
        asm_loc(lno, sec, offs, rest)
    } else if (dir == ".file") {
        asm_file(lno, sec, offs, rest)
    } else {
        { err: "L" + tostring(lno) + ": unsupported directive '" + dir + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    }
};

// ── -g: line-number directives ─────────────────────────────────────────
// GNU as's own (native.y emits them under -g, see dbg_lines): `.file N
// "path"` names file N, `.loc N LINE` says the code that follows comes
// from LINE of file N. Neither adds a byte. A .loc is an empty item at its
// .text offset (kind "loc", fix = [file, line] in the `off` fields); a
// .file one outside every section (sec -1: never laid out) with N in
// `off` and the path in its fix's `lbl`. asm_link hands both to dwarf.y
// (debug_lines).
def asm_loc(lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    let sp = index_of(rest, " ");
    let fs = rest;
    let ls = "";
    if (sp > 0) {
        fs = rest[0:sp];
        ls = trim(rest[sp + 1:]);
    }
    if (!is_num_text(fs) || !is_num_text(ls) || tonum(fs) < 1 || tonum(ls) < 0) {
        { err: "L" + tostring(lno) + ": bad .loc '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else if (sec != 0) {
        { err: "L" + tostring(lno) + ": .loc outside .text", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let fx = [{ off: tonum(fs), kind: "file", lbl: "", lbl2: "" },
                  { off: tonum(ls), kind: "line", lbl: "", lbl2: "" }];
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
    if (!is_num_text(ns) || tonum(ns) < 1 || asm_strdata_bad(q) || !d.ok) {
        { err: "L" + tostring(lno) + ": bad .file '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let fx = [{ off: 0, kind: "file", lbl: from_bytes(d.bytes), lbl2: "" }];
        { err: "", sec: sec, offs: offs, item: { sec: -1, off: tonum(ns), len: 0, kind: "file", bytes: [], fix: fx, br: -1 } }
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
    if (rest == ".rodata") { false }
    else if (rest == ".text") { false }
    else if (rest == ".bss") { false }
    else { true }
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
    if (asm_quad_bad(rest)) {
        asm_quad_err(line, lno, sec, offs, rest)
    } else {
        asm_quad_go(sec, offs, rest)
    }
};

def asm_quad_bad(rest: str) -> bool {
    // NOTE: `!is_num_text(rest)` is fine — `!` (an `un` node) needs a bool
    // operand (types.y typeof_expr's "un" arm) and is_num_text returns one.
    // The range test below stays a separate arm because the two causes need
    // different messages (see asm_quad_err).
    if (!is_num_text(rest)) { true }
    else if (tonum(rest) < 0) { true }
    else { false }
};

def asm_quad_err(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    // (split: error shape built ONLY here — one message per cause.)
    // NOTE: nested ifs (see is_digit_ch note); both arms share the key set.
    if (!is_num_text(rest)) {
        { err: "L" + tostring(lno) + ": bad .quad value '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        { err: "L" + tostring(lno) + ": negative .quad value", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    }
};

def asm_quad_go(sec: long, offs: [long], rest: str) -> AsmContent {
    // (split: data-item shape built ONLY here.)
    let bytes = enc.le64(tonum(rest));
    let item: AsmItem = { sec: sec, off: offs[sec], len: len(bytes), kind: "data", bytes: bytes, fix: [], br: -1 };
    offs[sec] = offs[sec] + len(bytes);
    { err: "", sec: sec, offs: offs, item: item }
};

// .zero N: N zero bytes. In .bss they only reserve space (no file bytes).
def asm_zero(line: str, lno: long, sec: long, offs: [long], rest: str) -> AsmContent {
    if (asm_quad_bad(rest)) {
        { err: "L" + tostring(lno) + ": bad .zero size '" + rest + "'", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
    } else {
        let n = tonum(rest);
        let zb: [byte] = [];
        if (sec != 2) {
            let i = 0;
            while (i < n) {
                zb += 0;
                i = i + 1;
            };
        }
        let item: AsmItem = { sec: sec, off: offs[sec], len: n, kind: "data", bytes: zb, fix: [], br: -1 };
        offs[sec] = offs[sec] + n;
        { err: "", sec: sec, offs: offs, item: item }
    }
};

def asm_insn(line: str, lno: long, sec: long, offs: [long]) -> AsmContent {
    let sp = index_of(line, " ");
    let tab = index_of(line, "\t");
    let cut = sp;
    // NOTE: nested ifs, not `||` (see is_digit_ch note); `0;` tails.
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
            // NOTE: `0;` tails (see parser.y parse_binary note): `ok = false`
            // is bool-typed; the else-arm is void-typed.
            if (!(r.ok)) {
                ok = false;
            } else {
                ops += r.op;
            };
            i = i + 1;
        };
        if (!ok) {
            { err: "L" + tostring(lno) + ": bad operand", sec: sec, offs: offs, item: { sec: -1, off: 0, len: 0, kind: "", bytes: [], fix: [], br: -1 } }
        } else {
            asm_encode(mn, ops, lno, sec, offs)
        }
    } else {
        asm_encode(mn, ops, lno, sec, offs)
    }
};

def asm_encode(mn: str, ops: [Operand], lno: long, sec: long, offs: [long]) -> AsmContent {
    // The encoder writes the instruction into a scratch it fills through a
    // cursor (enc64.y "the byte sink"): one array for the line, instead of
    // the two or three little ones each concat step allocated. Branches are
    // asked for in the short (rel8) form; asm_relax grows the ones that turn
    // out to be out of range.
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

// ── branch relaxation ──────────────────────────────────────────────────
// A branch within rel8 of its target is two bytes instead of five or six, and
// 54% of the branches in ycc.y are (measured on ycc.y compiled by this
// compiler: 8,053 of 14,832, and the short form is 53,661 bytes of branch
// against 83,596 for the long form of every one of them). Which ones is not
// known while encoding — an instruction's length has to be settled before the
// addresses are, and a branch's target is usually not where it is yet — so
// pass 1 asks for the short form everywhere
// and this pass grows what does not reach: a grower is three or four bytes
// longer, which moves everything after it, so the distances are recomputed
// and the rest retested. Growth is monotone, so the rounds end at a fixpoint;
// measured on ycc.y it takes 4 rounds and 6,780 grows, and a round is one
// sweep of the items plus a re-encode per grower.
//
// RELAX_ROUNDS bounds the work. Hitting it is not a wrong answer — every branch
// still gets re-encoded long, which is exactly what the assembler emitted
// before — so the bound costs size, never correctness.
let RELAX_ROUNDS = 8;

def asm_relax(items: [AsmItem], labels: [AsmLabel], debug: bool) -> long {
    // The rounds walk two compact arrays of the items' lengths and sections
    // rather than the records: an AsmItem is seven words, and streaming 13 MB
    // of them four times over was most of this pass (measured 47 ms for ycc.y
    // before this, against 9 ms after). One sweep builds the arrays; a branch
    // index list (there are 15k branches to 234k items) keeps the rounds off
    // the records entirely, and `cum` holds the round's frozen offsets.
    let lens: [long] = [];
    let secs: [long] = [];
    let brs: [long] = [];
    let i = 0;
    while (i < len(items)) {
        lens += items[i].len;
        secs += items[i].sec;
        if (items[i].br >= 0 && items[i].sec == 0) { brs += i; };
        i = i + 1;
    };
    let cum: [long] = [];
    let rlmap = relax_map(labels);
    let rounds = 0;
    let again = true;
    while (again && rounds < RELAX_ROUNDS) {
        rounds = rounds + 1;
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
    let cap = len(labels) * 2 + 16;
    let m = labmap_new(cap);
    let i = 0;
    while (i < len(labels)) {
        let r = labmap_put(m, labels[i].name, 0, i);
        m = r.map;
        i = i + 1;
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
        let i = 0;
        while (i < len(lens)) {
            if (i < len(cum)) { cum[i] = at; } else { cum += at; };
            if (secs[i] == 0) { at = at + lens[i]; };
            i = i + 1;
        };
        let j = 0;
        while (j < len(labels)) {
            let lb = labels[j];
            if (lb.sec == 0) {
                labels[j] = { name: lb.name, sec: 0, off: cum[lb.at_item], at_item: lb.at_item };
            };
            j = j + 1;
        };
    };
    // The branches, against the FROZEN offsets: growth is permanent, so a
    // branch that fits in this round's layout but is pushed out of range by a
    // grower earlier in the same sweep must wait for the next round, or the
    // sweep cascades and every branch ends up long (measured: 14,680 grown in
    // one round that way, against 6,673 with the frozen layout, and 140 short
    // branches at the end instead of 8,047).
    let grew = false;
    let k = 0;
    while (k < len(brs)) {
        let i = brs[k];
        // len 2 is the short form; a grower is already long.
        if (lens[i] == 2) {
            let it = items[i];
            let fx = it.fix[0];
            let li = relax_target(rlmap, fx.lbl);
            let here = 0;
            if (first) { here = it.off; } else { here = cum[i]; };
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
        k = k + 1;
    };
    grew
};

// The label a branch names, or -1 when the map does not have it.
def relax_target(rlmap: [AsmLabel], lbl: str) -> long {
    let e = labmap_get(rlmap, lbl);
    if (e.sec < 0) { -1 } else { e.off }
};

// Re-encode item `i` in the long form, from what it recorded (`br`) and what
// its fixup names. Returns the new length.
def relax_grow(items: [AsmItem], i: long, lens: [long], lbl: str) -> long {
    let it = items[i];
    let buf = enc.scratch();
    let r = enc.enc_branch_long(buf, 0, it.br, lbl);
    items[i] = { sec: it.sec, off: it.off, len: r.at, kind: it.kind, bytes: buf[0:r.at], fix: r.fix, br: it.br };
    lens[i] = r.at;
    r.at
};

// The bound case: every branch long, which is the pre-relaxation encoding.
def relax_all_long(items: [AsmItem], labels: [AsmLabel], lens: [long]) -> long {
    let n = 0;
    let i = 0;
    while (i < len(lens)) {
        let it = items[i];
        if (it.sec == 0 && it.br >= 0 && lens[i] != 2) {
            relax_grow(items, i, lens, it.fix[0].lbl);
            n = n + 1;
        };
        i = i + 1;
    };
    n
};

// The final placement: the labels at the final lengths (always -- pass 2
// measures every fixup against them), and the item offsets too, but only for
// -g: they are one record rebuild per item, and the line table is their only
// reader.
def relax_place(items: [AsmItem], labels: [AsmLabel], lens: [long], secs: [long], debug: bool) -> long {
    let offs: [long] = [0, 0, 0];
    let i = 0;
    let j = 0;
    while (i < len(lens)) {
        while (j < len(labels) && labels[j].at_item <= i) {
            let lb = labels[j];
            labels[j] = { name: lb.name, sec: lb.sec, off: offs[lb.sec], at_item: lb.at_item };
            j = j + 1;
        };
        let s = secs[i];
        if (s >= 0) {
            if (debug) {
                let it = items[i];
                items[i] = { sec: it.sec, off: offs[s], len: it.len, kind: it.kind, bytes: it.bytes, fix: it.fix, br: it.br };
            };
            offs[s] = offs[s] + lens[i];
        };
        i = i + 1;
    };
    while (j < len(labels)) {
        let lb = labels[j];
        labels[j] = { name: lb.name, sec: lb.sec, off: offs[lb.sec], at_item: lb.at_item };
        j = j + 1;
    };
    offs[0]
};

// ── pass 2: layout, fixups, ELF ────────────────────────────────────────

def asm_link(items: [AsmItem], labels: [AsmLabel], debug: bool) -> AsmOut {
    // section sizes
    let lt0 = clock_us();
    let lh0 = heap_used();
    let code_len = 0;
    let ro_len = 0;
    let bss_len = 0;
    let bss_data = false;
    // NOTE: `0;` tails (see parser.y parse_binary note). `it.len` reads go
    // through the bare hole (tnone unifies — see types.y typeof_def note).
    // elf_build takes the rodata bytes and sizes that segment itself; the
    // rodata length only places the .bss.
    foreach (it in items) {
        if (it.sec == 0) { code_len = code_len + it.len; }
        else if (it.sec == 1) { ro_len = ro_len + it.len; }
        else if (it.sec == 2) {
            bss_len = bss_len + it.len;
            if (len(it.bytes) > 0) { bss_data = true; };
        };
    };
    // A .bss label resolves like a rodata one, past the mapped image (see
    // elf_bss_from_ro), so the fixups below only know two sections.
    let labs: [AsmLabel] = labels;
    if (bss_len > 0) {
        let bshift = elf.elf_bss_from_ro(code_len, ro_len, bss_len);
        labs = [];
        foreach (lb in labels) {
            if (lb.sec == 2) { labs += { name: lb.name, sec: 1, off: bshift + lb.off, at_item: lb.at_item }; }
            else { labs += lb; };
        };
    };
    let lm = labmap_build(labs);
    let lt1 = clock_us();
    let lh1 = heap_used();
    let lmap = lm.map;
    let start = labmap_get(lmap, "_start");
    if (lm.dup != "") {
        { ok: false, bytes: [], error: "duplicate label '" + lm.dup + "'",
          times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (start.sec != 0) {
        { ok: false, bytes: [], error: "no _start label (empty program?)",
          times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else if (bss_data) {
        { ok: false, bytes: [], error: "data or code in .bss",
          times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
    } else {
        // No padding between the code and the rodata (mirrors elf.y): the
        // loader zero-fills the last page of the mapping instead, so a
        // rodata label's offset is exactly code_len + its own offset.
        let pad = 0;
        let code: [byte] = [];
        let ro: [byte] = [];
        let err = "";
        let i = 0;
        // NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails.
        while (i < len(items)) {
            if (err != "") {
                i = len(items);
            } else {
                let it = items[i];
                if (it.sec == 0) {
                    let r = patch_item(code, it, lmap, code_len, pad);
                    // NOTE: `0;` tails (see note above): str-arm vs [byte]-arm.
                    if (r.err != "") {
                        err = r.err;
                    } else {
                        code = r.bytes;
                    };
                } else if (it.sec == 1) {
                    // `ro += it.bytes` appends every element in place (the
                    // array header never moves), so no per-byte loop here.
                    ro += it.bytes;
                };
                i = i + 1;
            };
        };
        if (err != "") {
            { ok: false, bytes: [], error: err,
              times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 } ] }
        } else {
            let lt2 = clock_us();
            let lh2 = heap_used();
            let syms: [ElfSym] = [];
            let dsecs: [ElfSec] = [];
            if (debug) {
                syms = debug_syms(labels, code_len, bss_len);
                dsecs = debug_lines(items, code_len, elf.elf_code_off(bss_len));
            };
            let eb = elf.elf_build(code, ro, start.off, bss_len, syms, dsecs);
            let lt3 = clock_us();
            let lh3 = heap_used();
            { ok: true, bytes: eb, error: "",
              times: [ { name: "l:labmap", us: lt1 - lt0, heap: lh1 - lh0 },
                       { name: "l:patch", us: lt2 - lt1, heap: lh2 - lh1 },
                       { name: "l:elf", us: lt3 - lt2, heap: lh3 - lh2 } ] }
        }
    }
};

def patch_item(code: [byte], it: AsmItem, lmap: [AsmLabel], code_len: long, pad: long) -> AsmBytes {
    let bytes = it.bytes;
    let err = "";
    // NOTE: single gate (see asm_strdata note): insn-vs-other shapes
    // never mix in one chain.
    if (it.kind != "insn") {
        patch_item_finish(code, bytes, err)
    } else {
        patch_item_loop(code, it, lmap, code_len, pad, bytes, err)
    }
};

def patch_item_loop(code: [byte], it: AsmItem, lmap: [AsmLabel], code_len: long, pad: long, bytes: [byte], err: str) -> AsmBytes {
    let base = len(code);
    let fxlist = it.fix;
    let f = 0;
    // NOTE: nested ifs, not `&&` (see is_digit_ch note); `0;` tails.
    while (f < len(fxlist)) {
        if (err != "") {
            f = len(fxlist);
        } else {
            let fx = fxlist[f];
            // at is instruction-relative: bytes is the ITEM's list, and the
            // rel target is relative to the instruction END (base + it.len).
            let at = fx.off;
            // NOTE: nested ifs, not `||` (see is_digit_ch note).
            // NOTE: thread callee results (see note above): the callee's
            // {bytes,err} is the only path the patched bytes take to the
            // caller, so both arms must rebind `bytes` (and `err`).
            if (fx.kind == "rel32" || fx.kind == "rip32") {
                let rr = patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at);
                bytes = rr.bytes;
                if (rr.err != "") { err = rr.err; }
            } else if (fx.kind == "rel8") {
                let r8 = patch_item_rel8(lmap, code_len, pad, fx, bytes, base, it, at);
                bytes = r8.bytes;
                if (r8.err != "") { err = r8.err; }
            } else {
                let rk = patch_item_kind2(lmap, code_len, pad, fx, bytes, base, it, at);
                bytes = rk.bytes;
                if (rk.err != "") { err = rk.err; }
            };
            f = f + 1;
        };
    };
    patch_item_finish(code, bytes, err)
};

def patch_item_kind2(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem, at: long) -> AsmBytes {
    // (split: non-rel32 kinds; `{bytes,err}` built ONLY here + callees.)
    if (fx.kind == "rip32") {
        patch_item_rel(lmap, code_len, pad, fx, bytes, base, it, at)
    } else {
        patch_item_diff(lmap, code_len, pad, fx, bytes, base, it)
    }
};

def patch_item_rel(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem, at: long) -> AsmBytes {
    // rel32/rip32: target - address past the instruction.
    // NOTE: fx/it stay BARE holes (see types.y typeof_def note): single
    // reads unify.
    let t = label_addr(lmap, code_len, pad, fx.lbl);
    if (!t.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }
    } else {
        let v = t.addr - (base + it.len);
        { bytes: patch32(bytes, at, v), err: "" }
    }
};

def patch_item_rel8(lmap: [AsmLabel], code_len: long, pad: long, fx: Fixup, bytes: [byte], base: long, it: AsmItem, at: long) -> AsmBytes {
    // rel8: the same displacement in one byte, for a branch that relaxed.
    // asm_relax only leaves one of these in range, so the value fits by
    // construction (it grew the item otherwise); the truncation is still a
    // byte store, not a silent 32-bit write past the instruction.
    // NOTE: fx/it stay BARE holes (see types.y typeof_def note).
    let t = label_addr(lmap, code_len, pad, fx.lbl);
    if (!t.ok) {
        { bytes: bytes, err: "undefined label '" + fx.lbl + "'" }
    } else {
        let v = t.addr - (base + it.len);
        { bytes: patch8(bytes, at, v), err: "" }
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

def patch8(bytes: [byte], at: long, v: long) -> [byte] {
    // The low byte of a rel8 displacement, which is two's complement: v + 256
    // before the modulo because Y's % truncates toward zero and a negative
    // displacement must land on its high byte (v - 128 stores 128, not -128).
    bytes[at] = (v + 256) % 256;
    bytes
};

// ── -g: the symbol table ───────────────────────────────────────────────
// A function symbol starts at every label a body begins with: `_start`,
// a runtime helper (`y_*`) or a compiled def (`yfn_<uid>_<name>`). Jump
// targets (`yL_*`) and the arch prelude's internal labels (`yse_loop`,
// `ysj_sum`, ...) belong to the function before them, and rodata strings
// get no symbol. In the .bss, the globals (`yg_*`) and the allocator's
// `y_heap` cells are data symbols. Each symbol is sized up to the next
// one in its section (the last one to the section end), which is exactly
// what perf and valgrind need to attribute an address.
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
    let i = first;
    while (i < len(out)) {
        let e = out[i];
        let nxt = end;
        if (i + 1 < len(out)) {
            let n = out[i + 1];
            nxt = n.off;
        };
        e.size = nxt - e.off;
        i = i + 1;
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
// The `.file` table and the `.loc` rows (asm_file/asm_loc) as dwarf.y's
// sections. Rows are flat (offset, file, line) triples in text order; a
// `.file N` fills slot N-1 of the table ("?" stands in for a number never
// named). No row -- a text without markers -- means no sections at all.
def debug_lines(items: [AsmItem], code_len: long, code_off: long) -> [ElfSec] {
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
        dwarf.dwarf_sections(files, rows, 4194304 + code_off, code_len, asm_cwd())
    }
};

// The working directory, recorded as the compile unit's DW_AT_comp_dir
// (as GNU as does): the raw getcwd syscall fills buf and returns the
// path's length with its NUL, or a negative errno -- "." then.
def asm_cwd() -> str {
    let buf: [byte] = [];
    let i = 0;
    while (i < 4096) {
        buf += 0;
        i = i + 1;
    };
    let n = syscall(79, ptr_addr(&buf[0]), 4096);
    if (n > 1) { from_bytes(buf[0:n - 1]) } else { "." }
};

// Convenience for the driver: text in, bytes out. The driver writes the
// bytes straight through the write syscall (NUL-safe). The old `octal`
// RENDERING was removed: it cost O(n^2) string building (one malloc+copy
// per byte) and nothing read it — it dominated -o time. The field itself
// stays in the record shape (always "") so the shape does not change.
def ycc_assemble(asm_text: str, debug: bool) -> {ok: bool, bytes: [byte], octal: str, error: str, times: [Timing]} {
    let r = asm_assemble(asm_text, debug);
    if (!r.ok) {
        { ok: false, bytes: [], octal: "", error: r.error, times: r.times }
    } else {
        { ok: true, bytes: r.bytes, octal: "", error: "", times: r.times }
    }
};

export { asm_assemble, ycc_assemble, labmap_new, labmap_put, labmap_get, hash_str };
