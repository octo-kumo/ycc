// mstatic.y -- the static audits of src/y/std/math.y.
//
//   ytest math-repeats [--selftest]     the same computation written twice
//   ytest math-thresholds [--selftest]  every seam a comparison branches on
//   ytest math-coverage                 every def reachable from a checked root
//   ytest math-unroll                   the generated kernels, byte for byte
//
// All four read the module's text line by line, bracket-aware; none is a
// parser, and each says what it cannot see.
import fs;
import math;
import yt;
import yc;
import bigf;

def is_word(c: long) -> bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95 };

def is_alpha_(c: long) -> bool { (c >= 97 && c <= 122) || (c >= 65 && c <= 90) || c == 95 };

def is_space(c: long) -> bool { c == 32 || c == 9 || c == 10 || c == 13 };

def has(xs: [str], x: str) -> bool {
    foreach (e in xs) {
        if (e == x) { return true; };
    };
    false
};

def nospace(s: str) -> str {
    let o: [byte] = [];
    foreach (c in bytes(s)) {
        if (!is_space(c)) { o += c; };
    };
    from_bytes(o)
};

// s with the characters of `cs` stripped from both ends (Python's strip(cs))
def strip_chars(s: str, cs: str) -> str {
    let a = 0;
    let b = s.length;
    while (a < b && cs.contains(s[a:a + 1])) { a += 1; };
    while (b > a && cs.contains(s[b - 1:b])) { b -= 1; };
    s[a:b]
};

// The identifier starting at s[i] (s[i] a letter or _), or "".
def ident_at(s: str, i: long) -> str {
    if (i >= s.length || !is_alpha_(s[i])) { return ""; };
    let j = i + 1;
    while (j < s.length && is_word(s[j])) { j += 1; };
    s[i:j]
};

// `\s*(?:native\s+)?def\s+NAME` at the start of the line: NAME, or "".
def def_name(line: str) -> str {
    let t = line.trim_start();
    if (t.starts_with("native") && t.length > 6 && is_space(t[6])) { t = t[6:].trim_start(); };
    if (!t.starts_with("def") || t.length < 4 || !is_space(t[3])) { return ""; };
    ident_at(t, 3 + (t.length - 3 - t[3:].trim_start().length))
};

def count_char(s: str, c: long) -> long {
    let n = 0;
    foreach (b in bytes(s)) {
        if (b == c) { n += 1; };
    };
    n
};

def depth_of(s: str) -> long { count_char(s, 123) - count_char(s, 125) };

// A line without its `//` comment, a string literal's text left alone.
def strip_comment(line: str) -> str {
    let i = 0;
    while (i < line.length) {
        let c = line[i];
        if (c == 34) {
            let j = i + 1;
            while (j < line.length && line[j] != 34) { j += if (line[j] == 92) { 2 } else { 1 }; };
            i = j + 1;
        } else if (c == 47 && i + 1 < line.length && line[i + 1] == 47) {
            return line[0:i];
        } else {
            i += 1;
        };
    };
    line
};

// A line without anything from its first `//` (no string awareness).
def cut_comment(line: str) -> str {
    let i = line.index_of("//");
    if (i < 0) { line } else { line[0:i] }
};

/** A def and the lines of its body (number, comment-stripped text). */
type Fn = { name: str, line: long, nums: [long], body: [str] };

// Every def whose body spans lines (a one-line def has no body to read).
def functions(path: str, strings_aware: bool) -> [Fn] {
    let out: [Fn] = [];
    let cur: Fn = { name: "", line: 0, nums: [], body: [] };
    let inside = false;
    let depth = 0;
    let n = 0;
    foreach (raw in yt.read(path).split("\n")) {
        n += 1;
        let line = if (strings_aware) { strip_comment(raw) } else { cut_comment(raw) };
        if (!inside) {
            let name = def_name(line);
            if (name != "") {
                cur = { name: name, line: n, nums: [], body: [] };
                depth = depth_of(line);
                inside = depth > 0;
            };
        } else {
            cur.nums += n;
            cur.body += line;
            depth += depth_of(line);
            if (depth <= 0) {
                out += cur;
                inside = false;
            };
        };
    };
    out
};

// ── math-repeats: the same computation written twice under two names ─────
//
// The defect class is "a behaviour decided by an accident of expression
// order", and the accident can be in the SPELLING: two places meaning one thing,
// written differently, so a change reaches one and not the other -- sin_cos_k
// once computed x*x three times. BOUND ELSEWHERE is the report that gates: a
// `let` whose value is a computation, spelled out again in the same function
// instead of named (a name it reads written in between sets it aside: cbrt's
// Newton loop rebinds y). REPEATED and DIVERGENT (a*b against b*a) are reading
// lists, proved able to find their plants by --selftest. KNOWN is the ratchet.

let KNOWN_REPEATS = [["atan", "neg", "x<0.0",
    "the matching test is in the is_inf arm and this binding in the else arm, so only one of the two ever runs"]];

/** A bracketed group's text (`grp`), or a bare atom. */
type Atom = { text: str, grp: bool };

def atoms(s: str) -> [Atom] {
    let out: [Atom] = [];
    let buf = "";
    let i = 0;
    while (i < s.length) {
        let c = s[i];
        if (c == 40 || c == 91 || c == 123) {
            let j = i;
            let d = 0;
            let go = true;
            while (go && j < s.length) {
                let x = s[j];
                if (x == 40 || x == 91 || x == 123) { d += 1; }
                else if (x == 41 || x == 93 || x == 125) {
                    d -= 1;
                    if (d == 0) { go = false; };
                };
                if (go) { j += 1; };
            };
            if (buf.trim() != "") { out += { text: buf.trim(), grp: false }; };
            out += { text: s[i:if (j + 1 > s.length) { s.length } else { j + 1 }], grp: true };
            buf = "";
            i = j + 1;
        } else if (c == 32) {
            if (buf != "") { out += { text: buf, grp: false }; };
            buf = "";
            i += 1;
        } else {
            buf += s[i:i + 1];
            i += 1;
        };
    };
    if (buf != "") { out += { text: buf, grp: false }; };
    out
};

// Every bracketed group at any depth, outermost first.
def groups(s: str, depth: long) -> [str] {
    let out: [str] = [];
    if (depth > 12) { return out; };
    foreach (a in atoms(s)) {
        if (a.grp && a.text.length >= 2) {
            let inner = a.text[1:a.text.length - 1];
            if (inner.trim() != "") {
                out += inner.trim();
                out += self(inner, depth + 1);
            };
        };
    };
    out
};

def str_lt(a: str, b: str) -> bool {
    let n = if (a.length < b.length) { a.length } else { b.length };
    for i in 0..n {
        if (a[i] != b[i]) { return a[i] < b[i]; };
    };
    a.length < b.length
};

// Commutative operands sorted, spaces and redundant parens dropped.
def canon(text: str) -> str {
    let t = nospace(text);
    while (t.length >= 2 && t[0] == 40 && t[t.length - 1] == 41 && !t[1:t.length - 1].contains("(")
           && !t[1:t.length - 1].contains(")")) {
        t = t[1:t.length - 1];
    };
    foreach (op in ["*", "+"]) {
        let k = t.index_of(op, 1);
        if (k >= 1 && k + 1 < t.length) {
            let l = t[0:k];
            let r = t[k + 1:];
            let lr = l + r;
            if (!lr.contains("(") && !lr.contains("[") && !lr.contains("{")) {
                let a = canon(l);
                let b = canon(r);
                let lo = if (str_lt(b, a)) { b } else { a };
                let hi = if (str_lt(b, a)) { a } else { b };
                return op + "(" + lo + op + hi + ")";
            };
        };
    };
    t
};

def idents(s: str) -> [str] {
    let r: [str] = [];
    let i = 0;
    while (i < s.length) {
        if (is_alpha_(s[i]) && (i == 0 || !is_word(s[i - 1]))) {
            let w = ident_at(s, i);
            r += w;
            i += w.length;
        } else {
            i += 1;
        };
    };
    r
};

// The op a written name is followed by: [, =x (x not =), op=, ++, -- (after spaces).
def write_op(st: str, j: long) -> bool {
    let k = j;
    while (k < st.length && is_space(st[k])) { k += 1; };
    if (k >= st.length) { return false; };
    let c = st[k];
    if (c == 91) { return true; };
    if (c == 61) { return k + 1 < st.length && st[k + 1] != 61; };
    if (k + 1 < st.length) {
        let two = st[k:k + 2];
        if (has(["+=", "-=", "*=", "/=", "%=", "++", "--"], two)) { return true; };
    };
    false
};

// Names assigned on the body lines between a and b, inclusive.
def writes_between(f: Fn, a: long, b: long) -> [str] {
    let out: [str] = [];
    let lo = if (a <= b) { a } else { b };
    let hi = if (a <= b) { b } else { a };
    for x in 0..f.nums.length {
        let n = f.nums[x];
        if (n >= lo && n <= hi) {
            let st = f.body[x].trim();
            let head = "";
            if (st.starts_with("let") && st.length > 3 && is_space(st[3])) {
                let w = ident_at(st, 3 + (st.length - 3 - st[3:].trim_start().length));
                if (w != "" && write_op(st, st.index_of(w, 3) + w.length)) { head = w; };
            };
            if (head == "") {
                let w = ident_at(st, 0);
                if (w != "" && write_op(st, w.length)) { head = w; };
            };
            if (head != "") {
                out += head;
            } else {
                let p = 0;
                while (p < st.length) {
                    let found = false;
                    // the delimiter is consumed: an identifier right after a match's op is not one
                    if (" \t([,+-*/".contains(st[p:p + 1])) {
                        let w = ident_at(st, p + 1);
                        if (w != "" && write_op(st, p + 1 + w.length)) {
                            out += w;
                            let k = p + 1 + w.length;
                            while (k < st.length && is_space(st[k])) { k += 1; };
                            let two = if (k + 1 < st.length) { st[k:k + 2] } else { "" };
                            p = k + (if (st[k] == 91) { 1 } else if (st[k] == 61) { 2 } else if (two.length == 2) { 2 } else { 1 });
                            found = true;
                        };
                    };
                    if (!found) { p += 1; };
                };
            };
        };
    };
    out
};

// `let NAME = VALUE;` (the value up to the line's final `;`)
def binding(line: str) -> [str] {
    let st = line.trim();
    if (!st.starts_with("let") || st.length < 4 || !is_space(st[3]) || !st.ends_with(";")) { return []; };
    let rest = st[3:].trim_start();
    let name = ident_at(rest, 0);
    if (name == "") { return []; };
    let after = rest[name.length:].trim_start();
    if (!after.starts_with("=")) { return []; };
    let v = after[1:].trim_start();
    v = v[0:v.length - 1];
    if (v.trim() == "") { return []; };
    [name, v]
};

def plain_word(raw: str) -> bool {
    if (raw == "") { return false; };
    if (ident_at(raw, 0) == raw) { return true; };
    foreach (c in bytes(raw)) {
        if (!"-+0123456789.eExXabcdefABCDEF_".contains(chr(c))) { return false; };
    };
    true
};

// Whole-token occurrences of the value's text in the line.
def count_spelled(line: str, value: str) -> long {
    let flat = nospace(line);
    let body = strip_chars(nospace(value), "()");
    if (body == "") { return 0; };
    let n = 0;
    let k = flat.index_of(body);
    while (k >= 0) {
        let before_ok = k == 0 || !is_word(flat[k - 1]);
        let e = k + body.length;
        let after_ok = e >= flat.length || !is_word(flat[e]);
        if (before_ok && after_ok) { n += 1; };
        k = flat.index_of(body, k + 1);
    };
    n
};

def spelled(line: str, value: str) -> bool {
    if (count_spelled(line, value) > 0) { return true; };
    let cv = canon(value);
    foreach (g in groups(line, 0)) {
        if (canon(g) == cv) { return true; };
    };
    false
};

/** A BOUND ELSEWHERE finding. */
type Bound = { fname: str, vname: str, line: long, cval: str, hits: [long], aside: [long] };

def bound(path: str) -> [Bound] {
    let out: [Bound] = [];
    foreach (f in functions(path, true)) {
        for x in 0..f.nums.length {
            let b = binding(f.body[x]);
            if (b.length == 2 && !plain_word(nospace(b[1]))) {
                let n = f.nums[x];
                let clean: [long] = [];
                let aside: [long] = [];
                let rs = idents(b[1]);
                for y in 0..f.nums.length {
                    let m2 = f.nums[y];
                    if (m2 != n && spelled(f.body[y], b[1])) {
                        let ws = writes_between(f, n, m2);
                        let hit = false;
                        foreach (r in rs) {
                            if (has(ws, r)) { hit = true; };
                        };
                        if (hit) { aside += m2; } else { clean += m2; };
                    };
                };
                if (clean.length > 0) {
                    out += { fname: f.name, vname: b[0], line: n, cval: nospace(canon(b[1])), hits: clean, aside: aside };
                };
            };
        };
    };
    out
};

def repeated(path: str) -> long {
    let found = 0;
    foreach (f in functions(path, true)) {
        let body: [str] = [];
        foreach (l in f.body) {
            let t = l.trim();
            while (t.ends_with(";")) { t = t[0:t.length - 1].trim_end(); };
            body += t;
        };
        let cands: [str] = [];
        foreach (st in body) {
            if (st != "" && st != "{" && st != "}") {
                foreach (g in groups(st, 0)) {
                    let c = canon(g);
                    if (!has(["0", "1", "0.0", "1.0", ""], c) && !has(cands, g)) { cands += g; };
                };
            };
        };
        foreach (c in cands) {
            let total = 0;
            foreach (st in body) { total += count_spelled(st, c); };
            if (total > 1) { found += 1; };
        };
    };
    found
};

def divergent(path: str) -> long {
    let found = 0;
    foreach (f in functions(path, true)) {
        foreach (l in f.body) {
            let s = l.trim();
            while (s.ends_with(";")) { s = s[0:s.length - 1].trim_end(); };
            let seen_c: [str] = [];
            let seen_g: [str] = [];
            foreach (g in groups(s, 0)) {
                let c = canon(g);
                for k in 0..seen_c.length {
                    if (seen_c[k] == c && seen_g[k] != g) { found += 1; };
                };
                seen_c += c;
                seen_g += g;
            };
        };
    };
    found
};

def known_repeat(b: Bound) -> str {
    foreach (k in KNOWN_REPEATS) {
        if (k[0] == b.fname && k[1] == b.vname && k[2] == b.cval) { return k[3]; };
    };
    ""
};

def nums(xs: [long]) -> str {
    let s: [str] = [];
    foreach (x in xs) { s += tostring(x); };
    join(s, ", ")
};

def repeats_report(path: str, ok: [bool]) -> str {
    let out: [str] = [];
    let unknown: [Bound] = [];
    foreach (b in bound(path)) {
        let why = known_repeat(b);
        if (why == "") {
            unknown += b;
        } else {
            out += "  known   " + b.fname.pad_right(12) + " line " + tostring(b.line).pad_right(5) + " let " + b.vname + " = "
                + b.cval.pad_right(16) + " also on " + nums(b.hits) + " -- " + why;
        };
        if (b.aside.length > 0) {
            out += "  setaside " + b.fname.pad_right(11) + " line " + tostring(b.line).pad_right(5) + " " + b.cval.pad_right(16)
                + " also on " + nums(b.aside) + ", but a name it reads is written in between";
        };
    };
    foreach (b in unknown) {
        out += "  NEW     " + b.fname.pad_right(12) + " line " + tostring(b.line).pad_right(5) + " let " + b.vname + " = "
            + b.cval.pad_right(16) + " spelled out again on " + nums(b.hits);
    };
    out += "  " + tostring(unknown.length) + " finding(s) new, " + tostring(KNOWN_REPEATS.length) + " accepted, over " + path;
    if (unknown.length > 0) {
        out += "  A new one is a defect or needs a reason in KNOWN_REPEATS (mstatic.y). It is not";
        out += "  automatically wrong: see the false positives that header documents.";
    };
    ok[0] = unknown.length == 0;
    join(out, "\n")
};

// One of each thing the detectors claim to find: a finder that finds nothing
// has no evidence that it works.
def repeats_selftest(ok: [bool]) -> str {
    let plants = [["bound elsewhere", "def planted(x: float) -> float {\n    let s = x * (1.0 + x * x * f(x * x));\n    let w = x * x;\n    w + s\n};\n"],
                  ["commutative divergence", "def planted(a: float, b: float) -> float {\n    let p = (a * b) * (b * a);\n    p\n};\n"],
                  ["repeated", "def planted(a: float, b: float) -> float {\n    let p = a * b + (a * b) * 2.0;\n    p\n};\n"]];
    let out: [str] = [];
    let fails = 0;
    foreach (p in plants) {
        let path = yt.tmp("plant") + ".y";
        yt.write(path, p[1]);
        let bs = bound(path);
        let n = if (p[0] == "bound elsewhere") { bs.length } else if (p[0] == "repeated") { repeated(path) } else { divergent(path) };
        if (n == 0) {
            out += "  FAILED  " + p[0] + ": planted but NOT found -- the detector for it is broken";
            fails += 1;
        } else {
            out += "  ok      the '" + p[0] + "' detector finds its plant (" + tostring(n) + ")";
            let accepted = false;
            if (p[0] == "bound elsewhere") {
                foreach (b in bs) {
                    if (known_repeat(b) != "") { accepted = true; };
                };
            };
            if (accepted) {
                out += "  FAILED  " + p[0] + ": the plant was classified as a KNOWN finding";
                fails += 1;
            } else {
                out += "  ok      a '" + p[0] + "' plant classifies as NEW, not accepted";
            };
        };
        fs.remove_file(path);
    };
    ok[0] = fails == 0;
    join(out, "\n")
};

// ── math-thresholds: every seam a comparison branches on ─────────────────
//
// hypot_scaled once branched on `m < 1e154` where the truth is 9.4808e153, and
// a 20000-pair sweep could not find it: a SWEEP FINDS DEFECTS BY AREA, and a
// seam is a sliver. A threshold is only findable when something NAMES it. So
// every comparison of one of a function's own float PARAMETERS against a
// number or a named float constant is read out, and the nearest argument the
// ulp table carries is measured in ulps of it. Past LIMIT a seam's two branches
// have never been told apart; KNOWN_FAR says what pins the ones the table
// cannot reach (oracle seams inside exp_y and pow_y, which are not exported).

let LIMIT = 1000000.0;

let KNOWN_FAR = [["exp_y", "-745.133", "the ORACLE's underflow seam, exp_lo: t311_math_exp_asm.y runs math.exp and math.exp_y at exp_lo exactly"],
                 ["pow_y", "-1024.0", "the ORACLE's integer-path bound: t315_math_pow_asm.y covers both ends of +-1024"]];

// A decimal literal (-?digits[.digits][e-?digits]) as the nearest double: the
// digits and the power of ten exactly (bigf), then one rounding.
def parse_float(s: str) -> float {
    let neg = s.starts_with("-");
    let t = if (neg) { s[1:] } else { s };
    let mant = bigf.from_long(0);
    let scale = 0;
    let i = 0;
    let dot = false;
    while (i < t.length && ((t[i] >= 48 && t[i] <= 57) || t[i] == 46)) {
        if (t[i] == 46) { dot = true; } else {
            mant = bigf.add(bigf.mul(mant, bigf.from_long(10)), bigf.from_long(t[i] - 48));
            if (dot) { scale -= 1; };
        };
        i += 1;
    };
    if (i < t.length && (t[i] == 101 || t[i] == 69)) { scale += yt.num(t[i + 1:], 0); };
    while (scale > 0) {
        mant = bigf.mul(mant, bigf.from_long(10));
        scale -= 1;
    };
    while (scale < 0) {
        mant = bigf.div_small(mant, 10);
        scale += 1;
    };
    bigf.to_double(if (neg) { bigf.neg(mant) } else { mant })
};

// The number literal at s[i] (-?\d+\.?\d*(e-?\d+)?), or "".
def num_lit(s: str, i: long) -> str {
    let j = i;
    if (j < s.length && s[j] == 45) { j += 1; };
    let d0 = j;
    while (j < s.length && s[j] >= 48 && s[j] <= 57) { j += 1; };
    if (j == d0) { return ""; };
    if (j < s.length && s[j] == 46) {
        j += 1;
        while (j < s.length && s[j] >= 48 && s[j] <= 57) { j += 1; };
    };
    if (j < s.length && s[j] == 101) {
        let k = j + 1;
        if (k < s.length && s[k] == 45) { k += 1; };
        let k0 = k;
        while (k < s.length && s[k] >= 48 && s[k] <= 57) { k += 1; };
        if (k > k0) { j = k; };
    };
    s[i:j]
};

def named_constants(path: str) -> {str => float} {
    let out: {str => float} = {};
    foreach (l in yt.read(path).split("\n")) {
        if (l.starts_with("let ")) {
            let name = ident_at(l, 4);
            let rest = l[4 + name.length:];
            if (name != "" && rest.starts_with(": float = ")) {
                let lit = num_lit(rest, 10);
                if (lit != "" && rest[10 + lit.length:] == ";") { out[name] = parse_float(lit); };
            };
        };
    };
    out
};

/** A comparison against a number: function, line, text, value. */
type Th = { fn: str, line: long, text: str, v: float };

let OPS = ["<=", ">=", "==", "!=", "<", ">"];

def thresholds(path: str) -> [Th] {
    let consts = named_constants(path);
    let out: [Th] = [];
    let cur = "";
    let params: [str] = [];
    let n = 0;
    foreach (raw in yt.read(path).split("\n")) {
        n += 1;
        let line = cut_comment(raw);
        let dn = def_name(line);
        if (dn != "" && cur == "") {
            cur = dn;
            params = [];
            let a = raw.index_of("(");
            let b = raw.index_of(")", a + 1);
            if (a >= 0 && b > a && raw.contains("def")) {
                foreach (p in raw[a + 1:b].split(",")) {
                    let pc = p.index_of(":");
                    if (pc > 0 && p[pc + 1:].trim().starts_with("float")) {
                        let nm = p[0:pc].trim();
                        if (ident_at(nm, 0) == nm) { params += nm; };
                    };
                };
            };
        };
        // (^|[^\w.]) NAME \s* OP \s* (NUMBER | name); the left a parameter
        let i = 0;
        while (i < line.length) {
            let next = i + 1;
            if (is_alpha_(line[i]) && (i == 0 || !(is_word(line[i - 1]) || line[i - 1] == 46))) {
                let lhs = ident_at(line, i);
                let j = i + lhs.length;
                while (j < line.length && is_space(line[j])) { j += 1; };
                let op = "";
                foreach (o in OPS) {
                    if (op == "" && j + o.length <= line.length && line[j:j + o.length] == o) { op = o; };
                };
                next = i + lhs.length;
                if (op != "" && has(params, lhs)) {
                    let k = j + op.length;
                    while (k < line.length && is_space(line[k])) { k += 1; };
                    let lit = num_lit(line, k);
                    let st = line.trim();
                    let text = if (st.length > 60) { st[0:60] } else { st };
                    if (lit != "") {
                        out += { fn: if (cur == "") { "?" } else { cur }, line: n, text: text, v: parse_float(lit) };
                        next = k + lit.length;
                    } else {
                        let nm = ident_at(line, k);
                        if (nm != "" && nm in consts) {
                            out += { fn: if (cur == "") { "?" } else { cur }, line: n, text: text, v: consts[nm]! };
                            next = k + nm.length;
                        };
                    };
                };
            };
            i = next;
        };
        if (cur != "" && line.trim() == "};") { cur = ""; };
    };
    out
};

// How far the nearest table argument is from v, in steps of v (the key
// difference; one step is one ulp).
def nearest_ulps(v: float, args: [float]) -> float {
    let kv = math.fbits(v);
    let best = -1.0;
    foreach (a in args) {
        if (!math.is_nan(a) && !math.is_inf(a)) {
            let ka = math.fbits(a);
            let g = if ((ka < 0) == (kv < 0)) { tofloat(if (ka > kv) { ka - kv } else { kv - ka })! }
                else { tofloat(ka)! - tofloat(kv)! };
            if (g < 0.0) { g = 0.0 - g; };
            if (best < 0.0 || g < best) { best = g; };
        };
    };
    best
};

def fmt_g(x: float) -> str {
    let s = tostring(x);
    if (x != 0.0 && (x > 1e15 || x < -1e15 || (x < 1e-4 && x > -1e-4))) {
        // scientific, three digits: enough to read a seam by
        let e = 0;
        let m = if (x < 0.0) { 0.0 - x } else { x };
        while (m >= 10.0) { m = m / 10.0; e += 1; };
        while (m < 1.0) { m = m * 10.0; e -= 1; };
        let r = tostring(math.round(m * 100.0) / 100.0);
        s = (if (x < 0.0) { "-" } else { "" }) + r + "e" + tostring(e);
    };
    s
};

def thresholds_report(path: str, ok: [bool]) -> str {
    let ths = thresholds(path);
    let args: [float] = [];
    foreach (l in yt.lines(yt.read(yc.ROOT + "/test/math/ulp_table.txt"))) {
        let f = yt.words(l);
        if (f.length >= 3 && !l.starts_with("#")) {
            foreach (a in f[1:f.length - 1]) { args += math.bitsf(yt.num(a, 0)); };
        };
    };
    let vals: [float] = [];
    let first: [Th] = [];
    let uses: [long] = [];
    foreach (t in ths) {
        let k = -1;
        for i in 0..vals.length {
            if (math.fbits(vals[i]) == math.fbits(t.v)) { k = i; };
        };
        if (k < 0) {
            vals += t.v;
            first += t;
            uses += 1;
        } else {
            uses[k] += 1;
        };
    };
    let out: [str] = [];
    out += "  " + tostring(ths.length) + " comparisons against a number or a float constant, " + tostring(vals.length) + " distinct values";
    let edges = 0;
    let far: [str] = [];
    let rows = 0;
    let close = 0;
    for i in 0..vals.length {
        let v = vals[i];
        let plain = v == 0.0 || v == 1.0 || v == -1.0 || v == 2.0 || v == -2.0 || v == 0.5 || v == -0.5;
        if (!plain) {
            edges += 1;
            if (!math.is_nan(v) && !math.is_inf(v)) {
                rows += 1;
                let g = nearest_ulps(v, args);
                if (g <= LIMIT) {
                    close += 1;
                } else {
                    let known = false;
                    foreach (k in KNOWN_FAR) {
                        let t = parse_float(k[1]);
                        let d = t - v;
                        if (d < 0.0) { d = 0.0 - d; };
                        let tol = if (t < 0.0) { (0.0 - t) * 1e-6 } else { t * 1e-6 };
                        if (k[0] == first[i].fn && d <= tol) { known = true; };
                    };
                    out += "    " + fmt_g(v).pad_right(14) + " x" + tostring(uses[i]).pad_right(3) + fmt_g(g).pad_left(14) + "  "
                        + first[i].fn + " line " + tostring(first[i].line) + "  <-- FAR" + (if (known) { " (known)" } else { " *** NEW ***" });
                    if (!known) { far += first[i].fn + "'s threshold " + fmt_g(v) + " is " + fmt_g(g) + " ulps from anything in the table"; };
                };
            };
        };
    };
    out += "  " + tostring(edges) + " of those are at the edge of a domain (not 0, +-1, +-2, 0.5)";
    out += "  " + tostring(rows - close) + " of " + tostring(rows) + " edge thresholds have no table argument within 1e6 ulps of them.";
    foreach (f in far) {
        out += "  *** " + f + ". A defect beside that seam can hide there: the fix is a case -- the value,";
        out += "      its two neighbouring doubles, and a partner close enough for any second condition -- or a reason in KNOWN_FAR.";
    };
    ok[0] = far.length == 0;
    join(out, "\n")
};

def thresholds_selftest(ok: [bool]) -> str {
    let path = yt.tmp("plant") + ".y";
    yt.write(path, "\ndef planted(x: float) -> float {\n    if (x < 3.25e77) { 1.0 } else { 2.0 }\n};\n");
    let want = parse_float("3.25e77");
    let found: [Th] = [];
    foreach (t in thresholds(path)) {
        if (t.v == want) { found += t; };
    };
    fs.remove_file(path);
    ok[0] = found.length > 0;
    if (ok[0]) { "  ok      the extractor finds a planted comparison (" + found[0].fn + ", line " + tostring(found[0].line) + ")" }
    else { "  FAILED  the extractor did not find a planted comparison" }
};

// ── math-coverage: every def reachable from a checked root ────────────────
//
// The ulp table pins its names; most other defs are HELPERS, reached only
// through a pinned caller, where a wrong answer hides inside the final
// rounding. Roots: the table's names and every `math.NAME(` under test/y and
// test/std. A def outside the closure of the module's own call graph has no
// gate, unless it is an oracle twin pinned by a comparison (KNOWN_GAPS).
// Reachability is necessary, not sufficient: it once called fdot's
// length-mismatch path covered while no test asked for it.

let KNOWN_GAPS = ["exp_y", "log_y", "sin_y", "cos_y", "atan_y", "asin_y", "pow_y", "pow_int", "pow_pos",
                  "fdot_y", "fmax_y", "fmin_y", "fscale_y", "faxpy_y", "fsum_y"];

// The names called (NAME followed by optional spaces and a paren) in s.
def callees(s: str) -> [str] {
    let r: [str] = [];
    let i = 0;
    while (i < s.length) {
        if (is_alpha_(s[i]) && (i == 0 || !is_word(s[i - 1]))) {
            let w = ident_at(s, i);
            let j = i + w.length;
            while (j < s.length && is_space(s[j])) { j += 1; };
            if (j < s.length && s[j] == 40) { r += w; };
            i += w.length;
        } else {
            i += 1;
        };
    };
    r
};

def coverage_report(path: str, ok: [bool]) -> str {
    let graph: {str => [str]} = {};
    foreach (f in functions(path, false)) {
        let calls: [str] = [];
        foreach (l in f.body) { calls += callees(l); };
        graph[f.name] = calls;
    };
    let roots: [str] = [];
    foreach (l in yt.lines(yt.read(yc.ROOT + "/test/math/ulp_table.txt"))) {
        let t = l.trim();
        if (t != "" && !t.starts_with("#")) {
            let w = yt.words(t)[0];
            if (w in graph && !has(roots, w)) { roots += w; };
        };
    };
    foreach (d in ["test/y", "test/std"]) {
        foreach (f in yt.tree(yc.ROOT + "/" + d, ".y")) {
            let body = yt.read(f);
            let i = body.index_of("math.");
            while (i >= 0) {
                if (i == 0 || !is_word(body[i - 1])) {
                    let w = ident_at(body, i + 5);
                    let j = i + 5 + w.length;
                    while (j < body.length && is_space(body[j])) { j += 1; };
                    if (w != "" && j < body.length && body[j] == 40 && w in graph && !has(roots, w)) { roots += w; };
                };
                i = body.index_of("math.", i + 5);
            };
        };
    };
    let seen: {str => bool} = {};
    let stack = roots;
    while (stack.length > 0) {
        let n = stack[stack.length - 1];
        stack = stack[0:stack.length - 1];
        if (!(n in seen)) {
            seen[n] = true;
            foreach (c in graph[n]!) {
                if (c in graph && !(c in seen)) { stack += c; };
            };
        };
    };
    let out: [str] = [];
    let gaps = 0;
    let unknown: [str] = [];
    foreach (n in keys(graph)) {
        if (!(n in seen)) {
            gaps += 1;
            if (has(KNOWN_GAPS, n)) { out += "  known   " + n; } else { unknown += n; };
        };
    };
    foreach (n in unknown) { out += "  NEW     " + n.pad_right(16) + " not reachable from any ulp-table case or fixture call"; };
    out += "  " + tostring(graph.length) + " defs, " + tostring(seen.length) + " reachable from " + tostring(roots.length) + " roots, "
        + tostring(gaps) + " gap(s): " + tostring(gaps - unknown.length) + " known, " + tostring(unknown.length) + " new";
    if (unknown.length > 0) {
        out += "  A new gap is a function with no gate: an oracle reached only by a comparison (say so in";
        out += "  KNOWN_GAPS) or one that needs a fixture. Do not add it to KNOWN_GAPS to make this go away.";
    };
    ok[0] = unknown.length == 0;
    join(out, "\n")
};

// ── math-unroll: the generated kernels against what the generator writes ──
//
// poly_split walks two arrays, and an array read costs twelve instructions --
// 68% of the loop -- so the eight kernels a program reaches are unrolled into
// literal Horner chains, generated from the module's own arrays. A chain edited
// out of step with its arrays still answers within an ulp, so the WHOLE block,
// its banner's caller list included, must be byte-identical to what this
// writes. t328_split_unrolled.y asks both forms 32024 questions, to the bit.

let WANTED = [["exp_k", "exp_kl", "exp", "expm1, exp2_corr, exp_half"],
              ["log_k", "log_kl", "log", "log1p, log2_dd"],
              ["sinh_k", "sinh_kl", "sinh", "sinh_small"],
              ["tanh_k", "tanh_kl", "tanh", "tanh_small"],
              ["atan_k", "atan_kl", "atan", "atan_kernel"],
              ["asin_k", "asin_kl", "asin", "asin_half"],
              ["sin_k", "sin_kl", "sin", "sin_cos_k (via tan)"],
              ["cos_k", "cos_kl", "cos", "sin_cos_k (via tan)"]];

def read_array(src: str, name: str) -> [str] {
    let head = "let " + name + ": [float] = [";
    let i = if (src.starts_with(head)) { 0 } else { src.index_of("\n" + head) + 1 };
    if (i <= 0 && !src.starts_with(head)) { return []; };
    let a = i + head.length;
    let b = src.index_of("];", a);
    let vals: [str] = [];
    foreach (v in src[a:b].split(",")) {
        if (v.trim() != "") { vals += v.trim(); };
    };
    vals
};

def emit(name: str, fname: str, hi: [str], lo: [str]) -> str {
    let n = hi.length;
    let out = ["// " + name + "'s kernel, UNROLLED. Generated by test/math/gen_split_unroll.py",
               "// from the arrays in this file; do not retype it. See that script for why, and",
               "// t328_split_unrolled.y for the gate that says the two forms agree to the bit.",
               "//",
               "// The order is the loop's, exactly: p starts at the highest coefficient and",
               "// works down, which is Horner's rule and the only order that gives the split",
               "// evaluation its accuracy. Same operations, same sequence, no array.",
               "def poly_" + fname + "(w: float) -> float {",
               "    let p = " + hi[n - 1] + ";",
               "    let q = " + lo[n - 1] + ";"];
    let i = n - 2;
    while (i >= 0) {
        out += "    p = p * w + " + hi[i] + ";";
        let neg_ = lo[i].starts_with("-");
        out += "    q = q * w " + (if (neg_) { "- " + strip_chars(lo[i], "-") } else { "+ " + lo[i] }) + ";";
        i -= 1;
    };
    out += "    p + q";
    out += "};";
    join(out, "\n")
};

// The banner-plus-def block for one kernel: from "// ARR -- used by " to the
// "\n};" closing "def poly_FN(".
def block(src: str, arr: str, fname: str) -> str {
    let at = src.index_of("// " + arr + " -- used by ");
    while (at >= 0) {
        let d = src.index_of("\ndef poly_" + fname + "(", at);
        if (d >= 0) {
            let e = src.index_of("\n};", d + 1);
            if (e >= 0) { return src[at:e + 3]; };
        };
        at = src.index_of("// " + arr + " -- used by ", at + 1);
    };
    ""
};

def unroll_report(path: str, ok: [bool]) -> str {
    let src = yt.read(path);
    let bad: [str] = [];
    foreach (w in WANTED) {
        let hi = read_array(src, w[0]);
        let lo = read_array(src, w[1]);
        if (hi.length == 0 || hi.length != lo.length) {
            bad += w[0] + " (arrays: " + tostring(hi.length) + " hi, " + tostring(lo.length) + " lo)";
        } else {
            let mine = "// " + w[0] + " -- used by " + w[3] + ".\n" + emit(w[0], w[2], hi, lo);
            if (block(src, w[0], w[2]) != mine) { bad += "poly_" + w[2]; };
        };
    };
    ok[0] = bad.length == 0;
    if (ok[0]) { "  math.y matches the generator for all " + tostring(WANTED.length) + " kernels" }
    else { "math.y has drifted from the generator: " + join(bad, ", ") + "\n  regenerate the chains (ytest math-unroll --write)" }
};

/** The chains this writes, for a regeneration: every block, in order. */
def unroll_text(path: str) -> str {
    let src = yt.read(path);
    let chunks: [str] = [];
    foreach (w in WANTED) {
        chunks += "// " + w[0] + " -- used by " + w[3] + ".\n" + emit(w[0], w[2], read_array(src, w[0]), read_array(src, w[1])) + "\n";
    };
    join(chunks, "\n")
};

def math_y() -> str { yc.ROOT + "/src/y/std/math.y" };

def run_one(f: ([bool]) -> str) -> long {
    let ok = [false];
    print(f(ok));
    if (ok[0]) { 0 } else { 1 }
};

def main(what: str, av: [str]) -> long {
    let path = if (av.length > 0 && !av[0].starts_with("--")) { av[0] } else { math_y() };
    let st = av.length > 0 && av[av.length - 1] == "--selftest";
    if (what == "repeats") { return run_one(if (st) { repeats_selftest } else { (ok: [bool]) => repeats_report(path, ok) }); };
    if (what == "thresholds") { return run_one(if (st) { thresholds_selftest } else { (ok: [bool]) => thresholds_report(path, ok) }); };
    if (what == "coverage") { return run_one((ok: [bool]) => coverage_report(path, ok)); };
    if (what == "unroll") {
        if (av.length > 0 && av[av.length - 1] == "--write") {
            puts(unroll_text(math_y()));
            return 0;
        };
        return run_one((ok: [bool]) => unroll_report(path, ok));
    };
    1
};

export { main, repeats_report, repeats_selftest, thresholds_report, thresholds_selftest, coverage_report, unroll_report,
    math_y };
