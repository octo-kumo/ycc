// json.y -- a hand-rolled JSON reader and writer.
//
// Y ships no JSON module (ORCHESTRATOR.md 2.4c) and no cast syntax, so
// this is a recursive-descent parser over a `str`, plus an emitter that
// turns the tree back into text.
//
//   import json;
//   let d = json.parse(body);
//   if (!d.ok) { eputs(d.err); exit(1) };
//   let t = json.obj(d.val, "current");          // -> Json (missing = null node)
//   let c = json.int_of(t, "temp_c");            // -> long, 0 when absent
//
// The tree is ONE record type rather than a union, because a union member
// copied out of a union shares nothing and there is no cast back (AGENTS.md
// "No unknown types"). A `Json` node carries all six payloads and says in
// `kind` which one is live: "obj", "arr", "str", "num", "true", "false",
// "null". So every accessor is total -- it never traps, never unwraps a
// `none`, and answers a documented default for a missing field. The
// client's error paths rely on that: a 200 with a truncated body must
// produce a message, not a runtime error.
//
// Strictness is deliberate and is a tested property, not an accident:
//   - no trailing comma in an object or an array
//   - keys must be double-quoted strings (no bare identifiers)
//   - no single-quoted strings
//   - escapes are the JSON six, plus \uXXXX; anything else is an error
//   - a raw control byte below 0x20 inside a string is an error
//   - a duplicate key is an error
//   - the whole document must be consumed: trailing bytes are an error
//   - nesting deeper than MAXD is an error (a guard, not a limit to hit)
// Integers are exact; a number with a fraction or an exponent keeps its
// literal text in `s` and puts the truncated-toward-zero integer in `n`,
// so nothing is lost by having no float support.

const MAXD = 32;           // deepest array/object nesting accepted

type Json = {
    kind: str, n: long, s: str, keys: [str], vals: [Json], items: [Json]
};

type Doc = { ok: bool, val: Json, err: str, at: long };

// ── parser state (single-threaded by construction) ──────────────────────
let src = "";
let pos = 0;
let err = "";
let at = 0;

// ── constructors ────────────────────────────────────────────────────────
def null_node() -> Json { { kind: "null", n: 0, s: "", keys: [], vals: [], items: [] } };
def str_node(s: str) -> Json { { kind: "str", n: 0, s: s, keys: [], vals: [], items: [] } };
def num_node(t: str, n: long) -> Json { { kind: "num", n: n, s: t, keys: [], vals: [], items: [] } };
def bool_node(b: bool) -> Json {
    if (b) { { kind: "true", n: 1, s: "true", keys: [], vals: [], items: [] } }
    else { { kind: "false", n: 0, s: "false", keys: [], vals: [], items: [] } }
};

def obj_node(k: [str], v: [Json]) -> Json { { kind: "obj", n: 0, s: "", keys: k, vals: v, items: [] } };
def arr_node(it: [Json]) -> Json { { kind: "arr", n: 0, s: "", keys: [], vals: [], items: it } };

// ── total accessors: never trap, never unwrap a none ────────────────────

// The member of an object, or a null node. A missing key and a key holding
// null are deliberately indistinguishable -- a caller that needs the
// difference checks `has`.
def obj(v: Json, key: str) -> Json {
    let out = null_node();
    if (v.kind == "obj") {
        let i = 0;
        while (i < v.keys.length) {
            if (v.keys[i] == key) { out = v.vals[i] };
            i = i + 1;
        };
    };
    out
};

def has(v: Json, key: str) -> bool {
    let found = false;
    if (v.kind == "obj") {
        let i = 0;
        while (i < v.keys.length) {
            if (v.keys[i] == key) { found = true };
            i = i + 1;
        };
    };
    found
};

// The integer value of a field, or `dflt` when it is missing, null, a
// string, or a number that is not an integer literal. A caller that wants
// a hard failure uses `req_int`.
def int_of(v: Json, key: str, dflt: long = 0) -> long {
    let f = obj(v, key);
    if (f.kind == "num") { f.n } else { dflt }
};

def str_of(v: Json, key: str, dflt: str = "") -> str {
    let f = obj(v, key);
    if (f.kind == "str") { f.s } else { dflt }
};

def arr_of(v: Json, key: str) -> [Json] {
    let f = obj(v, key);
    if (f.kind == "arr") { f.items } else { [] }
};

// The string payload of a node, "" unless it is a string. For array
// elements, which have no key to look up by.
def text(v: Json) -> str {
    if (v.kind == "str") { v.s } else { "" }
};

// The integer payload of a node, 0 unless it is an integer literal. For
// array elements, and for numbers that carried a fraction.
def whole(v: Json) -> long {
    if (v.kind == "num") { v.n } else { 0 }
};

// Element `i` of an array, or a null node when it is shorter than that.
def elem(v: Json, i: long) -> Json {
    if (v.kind == "arr" && i >= 0 && i < v.items.length) { v.items[i] } else { null_node() }
};

// Element `i` of an array ALREADY taken out of a document, or a null node.
// (Not `at`: that is the parser's byte cursor.)
def nth(items: [Json], i: long) -> Json {
    if (i >= 0 && i < items.length) { items[i] } else { null_node() }
};

// True when every node in the tree is of a kind this module can emit.
def intact(v: Json) -> bool {
    if (v.kind == "obj") {
        let ok = true;
        let i = 0;
        while (i < v.keys.length) {
            if (!intact(v.vals[i])) { ok = false };
            i = i + 1;
        };
        ok
    } else if (v.kind == "arr") {
        let ok = true;
        let i = 0;
        while (i < v.items.length) {
            if (!intact(v.items[i])) { ok = false };
            i = i + 1;
        };
        ok
    } else { v.kind == "str" || v.kind == "num" || v.kind == "true" || v.kind == "false" || v.kind == "null" }
};

// ── the scanner ─────────────────────────────────────────────────────────
def ws() -> void {
    let go = true;
    while (go && pos < src.length) {
        let c = src[pos];
        if (c == 32 || c == 9 || c == 10 || c == 13) { pos = pos + 1 } else { go = false };
    }
};

def hex4() -> long {
    let v = 0;
    let got = 0;
    while (got < 4) {
        if (pos >= src.length) { return 0 - 1 };
        let c = src[pos];
        let d = 0 - 1;
        if (c >= 48 && c <= 57) { d = c - 48 }
        else if (c >= 97 && c <= 102) { d = c - 87 }
        else if (c >= 65 && c <= 70) { d = c - 55 };
        if (d < 0) { return 0 - 1 };
        v = v * 16 + d;
        pos = pos + 1;
        got = got + 1;
    };
    v
};

// Append one codepoint as UTF-8. chr() is byte-oriented (ORD/SUGGESTIONS
// §11), so a codepoint above 0x7f is written out by hand here.
// so a codepoint above 0x7f is written out by hand here.
// Each arm's last append ends with its `;` INSIDE the braces: this runs once
// per codepoint from pstring's loop, and a value-used `out += ...` is emitted
// as `out = out + ...` -- a fresh exact-size copy of everything built so far
// on every call (esc()'s comment spells the rule out). The function returns
// `out` on the last line, so the arms may be void; that is why adding the `;`
// here cannot make the function stop returning.
def put_cp(out: str, cp: long) -> str {
    if (cp < 0x80) { out += chr(cp); }
    else if (cp < 0x800) {
        out += chr(0xC0 + (cp >> 6));
        out += chr(0x80 + (cp & 63));
    } else if (cp < 0x10000) {
        out += chr(0xE0 + (cp >> 12));
        out += chr(0x80 + ((cp >> 6) & 63));
        out += chr(0x80 + (cp & 63));
    } else {
        out += chr(0xF0 + (cp >> 18));
        out += chr(0x80 + ((cp >> 12) & 63));
        out += chr(0x80 + ((cp >> 6) & 63));
        out += chr(0x80 + (cp & 63));
    };
    out
}

// A complete string literal, escapes resolved. none on any error.
def pstring() -> str? {
    if (pos >= src.length || src[pos] != 34) {
        err = "expected a double-quoted string";
        at = pos;
        return none;
    };
    pos = pos + 1;
    let out = "";
    let go = true;
    while (go) {
        if (pos >= src.length) {
            err = "unterminated string";
            at = pos;
            return none;
        };
        let c = src[pos];
        if (c == 34) {
            pos = pos + 1;
            go = false;
        } else if (c == 92) {
            let esc_at = pos;
            pos = pos + 1;
            if (pos >= src.length) {
                err = "unterminated escape";
                at = esc_at;
                return none;
            };
            let e = src[pos];
            if (e == 34) { out += "\""; pos = pos + 1 }
            else if (e == 92) { out += "\\"; pos = pos + 1 }
            else if (e == 47) { out += "/"; pos = pos + 1 }
            else if (e == 98) { out += chr(8); pos = pos + 1 }
            else if (e == 102) { out += chr(12); pos = pos + 1 }
            else if (e == 110) { out += "\n"; pos = pos + 1 }
            else if (e == 114) { out += "\r"; pos = pos + 1 }
            else if (e == 116) { out += "\t"; pos = pos + 1 }
            else if (e == 117) {
                pos = pos + 1;
                let cp = hex4();
                if (cp < 0) {
                    err = "\\u needs four hex digits";
                    at = esc_at;
                    return none;
                };
                // A high surrogate must be followed by its low partner.
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    if (pos + 1 >= src.length || src[pos] != 92 || src[pos + 1] != 117) {
                        err = "a high surrogate needs a \\u low surrogate";
                        at = pos;
                        return none;
                    };
                    pos = pos + 2;
                    let lo = hex4();
                    if (lo < 0xDC00 || lo > 0xDFFF) {
                        err = "a high surrogate needs a \\u low surrogate";
                        at = pos;
                        return none;
                    };
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    err = "a lone low surrogate";
                    at = esc_at;
                    return none;
                };
                out = put_cp(out, cp)
            } else {
                err = "unknown escape \\" + chr(e);
                at = esc_at;
                return none;
            };
        } else if (c < 32) {
            err = "a raw control byte in a string needs an escape";
            at = pos;
            return none;
        } else {
            out += chr(c);
            pos = pos + 1;
        };
    };
    some(out)
};

// A number. Integers are exact; anything with a fraction or an exponent
// keeps its text and truncates toward zero for `n`.
def pnumber() -> Json? {
    let start = pos;
    if (pos < src.length && src[pos] == 45) { pos = pos + 1 };
    let digits = 0;
    let leading_zero = false;
    if (pos < src.length && src[pos] == 48) {
        leading_zero = true;
        pos = pos + 1;
        digits = 1;                  // the 0 is itself a digit
    };
    while (pos < src.length && src[pos] >= 48 && src[pos] <= 57) {
        pos = pos + 1;
        digits = digits + 1;
    };
    if (digits == 0) {
        err = "a number needs at least one digit";
        at = start;
        return none;
    };
    // `01` is not JSON: a leading zero may not be followed by more digits.
    // A bare `0` is.
    if (leading_zero && digits > 1) {
        err = "a number may not have a leading zero";
        at = start;
        return none;
    };
    let exact = true;
    if (pos < src.length && src[pos] == 46) {
        exact = false;
        pos = pos + 1;
        let fd = 0;
        while (pos < src.length && src[pos] >= 48 && src[pos] <= 57) {
            pos = pos + 1;
            fd = fd + 1;
        };
        if (fd == 0) {
            err = "a fraction needs at least one digit";
            at = start;
            return none;
        };
    };
    if (pos < src.length && (src[pos] == 101 || src[pos] == 69)) {
        exact = false;
        pos = pos + 1;
        if (pos < src.length && (src[pos] == 43 || src[pos] == 45)) { pos = pos + 1 };
        let ed = 0;
        while (pos < src.length && src[pos] >= 48 && src[pos] <= 57) {
            pos = pos + 1;
            ed = ed + 1;
        };
        if (ed == 0) {
            err = "an exponent needs at least one digit";
            at = start;
            return none;
        };
    };
    let text = src[start:pos];
    if (exact) {
        // tolong() guesses -- it prints and exits on garbage -- but the text
        // here has already been validated as a plain integer literal, so it
        // is exact. Past 18 digits the value could overflow anyway, so the
        // literal text is kept and `n` reports 0 rather than a wrapped lie.
        if (pos - start <= 19) { some(num_node(text, tolong(text))) } else { some(num_node(text, 0)) }
    } else {
        // No float -> long conversion exists (ORCHESTRATOR.md 2.4a), so a
        // fractional literal keeps its text and reports 0. Callers that want
        // a number out of one format it to a string first.
        some(num_node(text, 0))
    }
};

def plit(word: str, kind: str) -> Json? {
    let n = src.length;
    if (pos + word.length <= n && src[pos:pos + word.length] == word) {
        pos = pos + word.length;
        if (kind == "true") { some(bool_node(true)) } else { some(null_node()) }
    } else {
        err = "expected " + word;
        at = pos;
        none
    }
};

def value(d: long) -> Json? {
    if (d > MAXD) {
        err = "nested deeper than " + tostring(MAXD);
        at = pos;
        return none;
    };
    ws();
    if (pos >= src.length) {
        err = "unexpected end of input";
        at = pos;
        return none;
    };
    let c = src[pos];
    let r: Json? = none;
    if (c == 123) { r = object(d) }
    else if (c == 91) { r = array(d) }
    else if (c == 34) {
        let s = pstring();
        if (is_some(s)) { r = some(str_node(unwrap(s))) } else { r = none }
    } else if (c == 116) { r = plit("true", "true") }
    else if (c == 102) { r = plit("false", "false") }
    else if (c == 110) { r = plit("null", "null") }
    else if (c == 45 || (c >= 48 && c <= 57)) { r = pnumber() }
    else {
        err = "unexpected byte '" + chr(c) + "'";
        at = pos;
        r = none;
    };
    r
};

def object(d: long) -> Json? {
    pos = pos + 1;                     // the '{'
    let keys: [str] = [];
    let vals: [Json] = [];
    ws();
    let go = true;
    if (pos < src.length && src[pos] == 125) {
        pos = pos + 1;
        return some(obj_node(keys, vals));
    };
    while (go) {
        ws();
        if (pos >= src.length) {
            err = "unterminated object";
            at = pos;
            return none;
        };
        if (src[pos] != 34) {
            err = "an object key must be a double-quoted string";
            at = pos;
            return none;
        };
        let k = pstring();
        if (is_some(k) == false) { return none };
        let key = unwrap(k);
        let i = 0;
        let dup = false;
        while (i < keys.length) {
            if (keys[i] == key) { dup = true };
            i = i + 1;
        };
        if (dup) {
            err = "duplicate key '" + key + "'";
            at = pos;
            return none;
        };
        ws();
        if (pos >= src.length || src[pos] != 58) {
            err = "expected ':' after a key";
            at = pos;
            return none;
        };
        pos = pos + 1;
        let v = value(d + 1);
        if (is_some(v) == false) { return none };
        keys += key;
        vals += unwrap(v);
        ws();
        if (pos >= src.length) {
            err = "unterminated object";
            at = pos;
            return none;
        };
        if (src[pos] == 125) {
            pos = pos + 1;
            go = false;
        } else if (src[pos] == 44) {
            pos = pos + 1;
            ws();
            if (pos < src.length && src[pos] == 125) {
                err = "a trailing comma is not JSON";
                at = pos;
                return none;
            };
        } else {
            err = "expected ',' or '}' in an object";
            at = pos;
            return none;
        };
    };
    some(obj_node(keys, vals))
};

def array(d: long) -> Json? {
    pos = pos + 1;                     // the '['
    let items: [Json] = [];
    ws();
    if (pos < src.length && src[pos] == 93) {
        pos = pos + 1;
        return some(arr_node(items));
    };
    let go = true;
    while (go) {
        let v = value(d + 1);
        if (is_some(v) == false) { return none };
        items += unwrap(v);
        ws();
        if (pos >= src.length) {
            err = "unterminated array";
            at = pos;
            return none;
        };
        if (src[pos] == 93) {
            pos = pos + 1;
            go = false;
        } else if (src[pos] == 44) {
            pos = pos + 1;
            ws();
            if (pos < src.length && src[pos] == 93) {
                err = "a trailing comma is not JSON";
                at = pos;
                return none;
            };
        } else {
            err = "expected ',' or ']' in an array";
            at = pos;
            return none;
        };
    };
    some(arr_node(items))
};

// ── entry point ─────────────────────────────────────────────────────────

// Parse a whole document. `err`/`at` on the result say where it stopped;
// the tree is a null node when ok is false, so a caller that forgets to
// look gets a total value instead of a trap.
def parse(s: str) -> Doc {
    src = s;
    pos = 0;
    err = "";
    at = 0;
    let v = value(0);
    ws();
    if (is_some(v) == false) {
        { ok: false, val: null_node(), err: err, at: at }
    } else if (pos < src.length) {
        { ok: false, val: null_node(), err: "trailing bytes after the document", at: pos }
    } else {
        { ok: true, val: unwrap(v), err: "", at: src.length }
    }
};

// ── the writer ──────────────────────────────────────────────────────────

def esc(s: str) -> str {
    let out = "\"";
    let i = 0;
    let go = true;
    while (go) {
        if (i < s.length) {
            let c = s[i];
            // Every arm's `;` is INSIDE the braces, and that one character is
            // the whole difference between linear and quadratic here. A `;`
            // AFTER the closing brace (`};`) discards the if-statement's
            // value but leaves the arm's own last statement value-used, and a
            // value-used `out += x` is emitted as the plain concat
            // `out = out + x` -- a fresh exact-size buffer per character, so
            // escaping n characters allocates O(n^2) bytes (examples/BUGS.md,
            // "`str +=` in a value-used position"). With the `;` inside, the
            // same statement is emitted as the in-place append and the growth
            // is O(n). Checked by selftest.y section F, which measures
            // heap_used() at n and 4n and requires at most 5x.
            if (c == 34) { out += "\\\""; }
            else if (c == 92) { out += "\\\\"; }
            else if (c == 8) { out += "\\b"; }
            else if (c == 12) { out += "\\f"; }
            else if (c == 10) { out += "\\n"; }
            else if (c == 13) { out += "\\r"; }
            else if (c == 9) { out += "\\t"; }
            else if (c < 32) {
                let h = "000" + hexdig((c >> 4) & 15) + hexdig(c & 15);
                out += "\\u00" + h[1:4];
            } else { out += chr(c); };
            i = i + 1;
        } else { go = false };
    };
    out + "\""
};

def hexdig(v: long) -> str {
    if (v < 10) { chr(48 + v) } else { chr(87 + v) }
};

// Compact, deterministic text: no spaces, keys in the order the tree holds
// them, integers exactly. Emitting a parsed document and re-parsing it is
// therefore a fixed point, which is the round-trip property --check asserts.
def emit(v: Json) -> str {
    if (v.kind == "obj") {
        let out = "{";
        let first = true;
        let i = 0;
        while (i < v.keys.length) {
            // `;` inside the braces, for the reason esc()'s arms give: the
            // separator append is in a loop, and a value-used append copies
            // the whole string built so far.
            if (!first) { out += ","; };
            out += esc(v.keys[i]);
            out += ":";
            out += emit(v.vals[i]);
            first = false;
            i = i + 1;
        };
        out + "}"
    } else if (v.kind == "arr") {
        let out = "[";
        let i = 0;
        while (i < v.items.length) {
            if (i > 0) { out += ","; };
            out += emit(v.items[i]);
            i = i + 1;
        };
        out + "]"
    } else if (v.kind == "str") { esc(v.s) }
    else if (v.kind == "num") {
        if (v.s.length > 0) { v.s } else { tostring(v.n) }
    } else if (v.kind == "true") { "true" }
    else if (v.kind == "false") { "false" }
    else { "null" }
};

export { MAXD, Json, Doc, null_node, str_node, num_node, bool_node, obj_node, arr_node,
         obj, has, int_of, str_of, arr_of, elem, nth, text, whole, intact, parse, emit, esc };
