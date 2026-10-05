// json.y -- a hand-rolled JSON reader that works in place over bytes.
//
// Y ships no JSON module (ORCHESTRATOR.md 2.4c) and no cast syntax, so
// this parses bytes: the caller hands over the buffer it already has and
// gets offsets back. Nothing here allocates -- no string is built, no
// array made, no record created -- because a parse is a walk over bytes
// that are already in place. That is what lets the client poll in steady
// state without growing the heap, and it is why this module has no
// `str` parameter anywhere except the key and the comparison string.
//
//   import json;
//
//   let end = json.validate(buf, 0, len(buf));
//   if (end < 0) { eputs("bad JSON at " + tostring(json.at) + ": " + json.err + "\n"); };
//   let p = json.get(buf, 0, len(buf), "served");
//   let n = json.int_at(buf, p, len(buf));    // the value; json.ok says if
//
// validate() is the whole-document check: it is what turns "the server
// emitted JSON" into "the server emitted JSON I can read", and a
// malformed document gets a position and a reason rather than a wrong
// number. `json.err` holds the reason and `json.at` the byte offset; both
// are left alone on success, so check `end < 0` rather than `json.err`.
//
// ── the buffer convention ────────────────────────────────────────────
//
// Every function takes the document as `b: [byte; 65536]`, which is the
// size of httpc's response buffer (`cbuf`). Both files say so at the top.
// The point of the exact fixed size is that the type system then refuses
// to hand this module a buffer it has not checked: a mismatch is a
// compile error, not a silent misparse at run time.

const MAXDEPTH = 24;

// ── results of the last call ───────────────────────────────────────────
let err = "";            // "" when the last call was happy
let at = 0;              // byte offset the complaint is about
let val = 0;             // int_at's value
let ok = false;          // int_at / str_eq say yes or no

let depth = 0;

// ── small scanners ─────────────────────────────────────────────────────

def is_digit(c: long) -> bool {
    c >= 48 && c <= 57
};

def is_ws(c: long) -> bool {
    c == 32 || c == 9 || c == 10 || c == 13
};

def bad(why: str, where: long) -> long {
    err = why;
    at = where;
    -1
};

// skip whitespace, staying inside [p, end)
def ws(b: [byte; 65536], p: long, end: long) -> long {
    let i = p;
    while (i < end && is_ws(b[i])) { i = i + 1; };
    i
};

def hexd(c: long) -> long {
    if (c >= 48 && c <= 57) { c - 48 } else {
        if (c >= 97 && c <= 102) { c - 87 } else {
            if (c >= 65 && c <= 70) { c - 55 } else { -1 }
        }
    }
};

// ── values ─────────────────────────────────────────────────────────────

// one string: the opening quote, its bytes (escapes allowed), the closing
// quote. Returns the offset just past it, or -1.
def str_v(b: [byte; 65536], p: long, end: long) -> long {
    let i = p;
    if (i >= end || b[i] != 34) { return bad("expected a string", i) };
    i = i + 1;
    let closed = false;
    while (i < end && !closed) {
        let c = b[i];
        if (c == 34) {
            i = i + 1;
            closed = true;
        } else if (c == 92) {
            // a backslash escape: \ " / b f n r t uXXXX
            let e = i + 1;
            if (e >= end) { return bad("string ends inside an escape", i) };
            let k = b[e];
            if (k == 117) {
                if (e + 4 >= end) { return bad("short \\u escape", i) };
                let h = 0;
                let d = 0;
                while (d < 4) {
                    let v = hexd(b[e + 1 + d]);
                    if (v < 0) { return bad("bad hex in \\u escape", e + 1 + d) };
                    h = h * 16 + v;
                    d = d + 1;
                };
                i = e + 5;
            } else if (k == 34 || k == 92 || k == 47 || k == 98 || k == 102 || k == 110 || k == 114 || k == 116) {
                i = e + 1;
            } else {
                return bad("unknown escape", e);
            }
        } else if (c < 32) {
            return bad("raw control byte in a string", i);
        } else {
            i = i + 1;
        };
    };
    if (!closed) { bad("string never closed", p) } else { i }
};

// one number, JSON grammar: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
def num_v(b: [byte; 65536], p: long, end: long) -> long {
    let i = p;
    let good = true;
    if (i < end && b[i] == 45) { i = i + 1; };
    if (i < end && b[i] == 48) {
        i = i + 1;
    } else if (i < end && b[i] >= 49 && b[i] <= 57) {
        while (i < end && is_digit(b[i])) { i = i + 1; };
    } else {
        good = false;
    };
    if (good && i < end && b[i] == 46) {
        i = i + 1;
        let n = 0;
        while (i < end && is_digit(b[i])) { i = i + 1; n = n + 1; };
        if (n == 0) { good = false; };
    };
    if (good && i < end && (b[i] == 101 || b[i] == 69)) {
        i = i + 1;
        if (i < end && (b[i] == 43 || b[i] == 45)) { i = i + 1; };
        let n = 0;
        while (i < end && is_digit(b[i])) { i = i + 1; n = n + 1; };
        if (n == 0) { good = false; };
    };
    if (good) { i } else { bad("expected a number", p) }
};

// one of true / false / null
def lit(b: [byte; 65536], p: long, end: long, s: str) -> long {
    let n = len(s);
    if (p + n > end) { return bad("truncated literal", p) };
    let i = 0;
    let same = true;
    while (i < n) {
        if (b[p + i] != s[i]) { same = false; };
        i = i + 1;
    };
    if (same) { p + n } else { bad("expected " + s, p) }
};

def arr_v(b: [byte; 65536], p: long, end: long) -> long {
    let i = p + 1;
    i = ws(b, i, end);
    if (i < end && b[i] == 93) { return i + 1; };
    let go = true;
    while (go) {
        i = value(b, i, end);
        if (i < 0) { go = false; } else {
            i = ws(b, i, end);
            if (i >= end) {
                bad("array never closed", p);
                go = false;
            } else if (b[i] == 93) {
                i = i + 1;
                go = false;
            } else if (b[i] == 44) {
                i = ws(b, i + 1, end);
            } else {
                bad("expected , or ] in an array", i);
                go = false;
            }
        };
    };
    if (err != "") { -1 } else { i }
};

def obj_v(b: [byte; 65536], p: long, end: long) -> long {
    let i = p + 1;
    i = ws(b, i, end);
    if (i < end && b[i] == 125) { return i + 1; };
    let go = true;
    while (go) {
        i = str_v(b, i, end);
        if (i < 0) { go = false; } else {
            i = ws(b, i, end);
            if (i >= end || b[i] != 58) {
                bad("expected : after a key", i);
                go = false;
            } else {
                i = ws(b, i + 1, end);
                i = value(b, i, end);
                if (i < 0) {
                    go = false;
                } else {
                    i = ws(b, i, end);
                    if (i >= end) {
                        bad("object never closed", p);
                        go = false;
                    } else if (b[i] == 125) {
                        i = i + 1;
                        go = false;
                    } else if (b[i] == 44) {
                        i = ws(b, i + 1, end);
                    } else {
                        bad("expected , or } in an object", i);
                        go = false;
                    }
                };
            }
        };
    };
    if (err != "") { -1 } else { i }
};

// one value of any kind, with the nesting depth bounded so a hostile
// document cannot drive this into a stack overflow -- which in an arena
// with no unwinding would be a crash, not a diagnostic.
def value(b: [byte; 65536], p: long, end: long) -> long {
    let i = ws(b, p, end);
    if (depth >= MAXDEPTH) { return bad("nested too deeply", i) };
    if (i >= end) { return bad("value expected", i) };
    let c = b[i];
    depth = depth + 1;
    let out = -1;
    if (c == 123) {
        out = obj_v(b, i, end);
    } else if (c == 91) {
        out = arr_v(b, i, end);
    } else if (c == 34) {
        out = str_v(b, i, end);
    } else if (c == 116) {
        out = lit(b, i, end, "true");
    } else if (c == 102) {
        out = lit(b, i, end, "false");
    } else if (c == 110) {
        out = lit(b, i, end, "null");
    } else {
        out = num_v(b, i, end);
    };
    depth = depth - 1;
    out
};

// ── the public face ───────────────────────────────────────────────────

// validate(b, 0, n) -> the offset just past the document (so == n when
// the bytes are exactly one JSON value), or -1 with json.err / json.at.
def validate(b: [byte; 65536], p: long, end: long) -> long {
    err = "";
    depth = 0;
    let out = value(b, p, end);
    if (out < 0) {
        -1
    } else {
        let tail = ws(b, out, end);
        if (tail != end) { bad("trailing bytes after the value", tail) } else { out }
    }
};

// the offset of the value a key holds in the object at p, or -1. `key`
// is compared byte for byte, so use it for the plain keys a server emits
// (every key this example sends is plain).
def get(b: [byte; 65536], p: long, end: long, key: str) -> long {
    let want = len(key);
    let i = ws(b, p, end);
    if (i >= end || b[i] != 123) { bad("not an object", i); return -1; };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 125) { return -1; };
    let found = -1;
    let go = true;
    while (go && found < 0) {
        let k0 = i;
        let k1 = str_v(b, i, end);
        if (k1 < 0) {
            go = false;
        } else {
            let same = k1 - k0 - 2 == want;
            if (same) {
                let c = 0;
                while (c < want) {
                    if (b[k0 + 1 + c] != key[c]) { same = false; };
                    c = c + 1;
                };
            };
            let j = ws(b, k1, end);
            if (j >= end || b[j] != 58) {
                bad("expected : after a key", j);
                go = false;
            } else {
                let v = ws(b, j + 1, end);
                if (same) {
                    found = v;
                } else {
                    let after = value(b, v, end);
                    if (after < 0) {
                        go = false;
                    } else {
                        let k = ws(b, after, end);
                        if (k < end && b[k] == 44) { i = ws(b, k + 1, end); } else { i = k; };
                        if (i >= end) { bad("object never closed", p); go = false; };
                    }
                }
            };
        };
    };
    found
};

// the integer at p. The value lands in json.val and json.ok; a number
// with a fraction or an exponent is refused rather than truncated, so a
// caller can never quietly read 3 for 3.5.
def int_at(b: [byte; 65536], p: long, end: long) -> long {
    err = "";
    ok = false;
    val = 0;
    let i = p;
    if (i >= end) { bad("number expected", i); return 0; };
    let neg = false;
    if (b[i] == 45) { neg = true; i = i + 1; };
    let digits = 0;
    let over = 0;
    while (i < end && is_digit(b[i])) {
        if (val < 1000000000000) { val = val * 10 + (b[i] - 48); } else { over = 1; };
        i = i + 1;
        digits = digits + 1;
    };
    if (digits == 0) { bad("no digits in the number", p); return 0; };
    if (over > 0) { bad("integer too large", p); return 0; };
    let tail = i;
    if (tail < end && (b[tail] == 46 || b[tail] == 101 || b[tail] == 69)) {
        bad("not an integer", tail);
        return 0;
    };
    val = if (neg) { 0 - val } else { val };
    ok = true;
    val
};

// how many elements the array at p holds. -1 if it is not an array.
def alen(b: [byte; 65536], p: long, end: long) -> long {
    let i = ws(b, p, end);
    if (i >= end || b[i] != 91) { bad("not an array", i); return -1; };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 93) { return 0; };
    let n = 0;
    let go = true;
    while (go) {
        i = value(b, i, end);
        if (i < 0) { go = false; } else {
            n = n + 1;
            i = ws(b, i, end);
            if (i >= end) { bad("array never closed", p); go = false; }
            else if (b[i] == 93) { go = false; }
            else if (b[i] == 44) { i = ws(b, i + 1, end); }
            else { bad("expected , or ] in an array", i); go = false; }
        };
    };
    if (err != "") { -1 } else { n }
};

// the offset of element i of the array at p, or -1.
def elem(b: [byte; 65536], p: long, end: long, want: long) -> long {
    let i = ws(b, p, end);
    if (i >= end || b[i] != 91) { bad("not an array", i); return -1; };
    i = ws(b, i + 1, end);
    let n = 0;
    let found = -1;
    let go = true;
    while (go) {
        if (n == want) { found = i; go = false; } else {
            i = value(b, i, end);
            if (i < 0) { go = false; } else {
                n = n + 1;
                i = ws(b, i, end);
                if (i >= end) { bad("array never closed", p); go = false; }
                else if (b[i] == 93) { go = false; }
                else if (b[i] == 44) { i = ws(b, i + 1, end); }
                else { bad("expected , or ] in an array", i); go = false; }
            }
        };
    };
    found
};

// is the string at p exactly s? `s` must carry no escapes; used for the
// short fixed strings this example checks (a content type, an error word).
def seq(b: [byte; 65536], p: long, end: long, s: str) -> bool {
    err = "";
    ok = false;
    let want = len(s);
    let i = p;
    if (i >= end || b[i] != 34) { bad("not a string", i); return false; };
    let same = i + 1 + want < end;
    if (same) {
        let c = 0;
        while (c < want) {
            if (b[i + 1 + c] != s[c]) { same = false; };
            c = c + 1;
        };
    };
    if (same && b[i + 1 + want] != 34) { same = false; };
    if (!same) { bad("not that string", i); false } else { ok = true; true }
};

export { MAXDEPTH, err, at, val, ok, validate, get, int_at, alen, elem, seq };