// json.y -- JSON for Y programs: parse, and print back.
//
// `import json;` and call through the namespace (`json.parse`, and the types
// are `json.Val`, `json.Num` and so on). Nothing here is LSP-specific; the
// language server in src/tools/lsp/ is one caller among others.
//
// THE VALUE TYPE. A JSON value is a `Val`: a number, a string, a bool, null,
// an array, or an object. An OBJECT is a plain map, `{ str => Val }`, not a
// wrapper -- so you index one directly, with no function call in the way:
//
//     let o = json.obj();
//     o["thing"] = json.num(1);
//     o["name"] = json.str("x");
//     json.stringify(o);
//
// A map's value type is pinned by its first entry (see e25_map_value_type.y),
// so an object must be built through `obj()` and never through a map literal;
// `{"a": 1, "b": "x"}` does not infer. `obj()` returns an empty map whose value
// type is already `Val`, so every assignment after it is checked against it.
//
// WHY THE WRAPPER EXISTS. Not for recursion any more: a type alias may reach
// itself through a map, an array or an option as well as through a record field
// (TODO.md item 1, landed), so `type Json = { str => Json }` is legal on its
// own. It is INDEXABILITY that keeps objects out of the union -- `o["thing"] = v`
// on a `Val` would need the object narrowed to its map member first, and a JSON
// object is addressed that way constantly. So `Val` keeps a record member
// holding a map, `JObj`, for an object *stored inside* another value, which
// costs one `jobj(map)`; a top-level object costs nothing, and `stringify` takes
// the bare map.
//
// NUMBERS ARE TEXT. A number holds its literal text, not a number, because Y
// has no string-to-float conversion at all: `tolong` returns a long and there is
// no `tofloat` anywhere. So `{"x": 1.5}` parses to a `Num` holding "1.5", which
// prints back byte for byte. `as_long` gives the integer part; `as_float` does
// not exist yet.
//
// See LSP.md §15 for the full design and its obligations.

// How deep a value may nest. The parser and the printer are both recursive, so
// a document nested a few thousand deep would run either off the stack; past
// this they fail cleanly instead.
const json_depth_max = 200;
const json_depth_error = "<json: too deep>";

// Every member needs its OWN shape. A record type is its set of fields, so
// `Num = { v: str }` and `Str = { v: str }` would be one type: `if let Str` would
// match a number, and the two arms would overwrite each other. Distinct field
// names are what makes `if let` able to tell the members apart -- there is no
// discriminant, no tag, and no `typeof` on a union.
type Num = { num: str };
type Str = { s: str };
type Bool = { b: bool };
type Null = { nil: long };
type Arr = { items: [Val] };
type JObj = { members: { str => Val } };
type Val = Num | Str | Bool | Null | Arr | JObj;

// ── constructors ────────────────────────────────────────────────────────
// Each builds the union member through an annotated `let`: the VOID law means
// the expected type does not reach into an `if`'s arms, so a union value can
// only be produced by a cast into a position that already declares one.

def obj() -> { str => Val } {
    let m: { str => Val } = {};
    m
}

def arr() -> [Val] {
    let a: [Val] = [];
    a
}

def jobj(o: { str => Val }) -> Val {
    let v: Val = { members: o };
    v
}

def jarr(a: [Val]) -> Val {
    let v: Val = { items: a };
    v
}

def num(n: long) -> Val {
    let v: Val = { num: tostring(n) };
    v
}

def numtext(t: str) -> Val {
    let v: Val = { num: t };
    v
}

def str(s: str) -> Val {
    let v: Val = { s: s };
    v
}

def boolean(b: bool) -> Val {
    let v: Val = { b: b };
    v
}

def nul() -> Val {
    let v: Val = { nil: 0 };
    v
}

// ── reading ─────────────────────────────────────────────────────────────

def keys_of(o: { str => Val }) -> [str] {
    keys(o)
}

// The value at `k`, or none. A map read is already an option, so this is the
// map's own `o[k]` with the type spelled out for a caller holding a `Val`.
def field(o: Val, k: str) -> Val? {
    let hit: Val? = none;
    // `j.members[k]`, read in place. This bound the map to a local first, on
    // the belief that a field of an `if let`-narrowed binding loses its type
    // (the oldest entry in BUGS.md). There is no such bug: the shape that
    // failed is the `[` of the NEXT line being read as an index of the `if`,
    // because expressions continue across newlines -- `;` after the block is
    // the whole fix (docs 03-grammar, "Statements are separated by `;`", and
    // test/y/native/e175_index_valueless_if.y, which names the shape). The
    // local was never needed; the type is there.
    if let JObj j = o { hit = j.members[k]; };
    hit
}

// Element `i` of an array, or none. An array read is total -- it does not box
// into an option the way a map read does -- so the bounds test is here and the
// value is boxed explicitly.
def index(a: Val, i: long) -> Val? {
    let hit: Val? = none;
    if let Arr x = a {
        let items = x.items;
        if (i >= 0 && i < len(items)) { hit = some(items[i]); };
    };
    hit
}

def as_str(v: Val) -> str? {
    let out: str? = none;
    if let Str t = v { out = some(t.s); };
    out
}

def as_long(v: Val) -> long? {
    let out: long? = none;
    // tolong answers long?: a JSON number with a fraction or an exponent is
    // none here rather than silently truncated, which is what as_long means.
    if let Num n = v { out = tolong(n.num); };
    out
}

def as_bool(v: Val) -> bool? {
    let out: bool? = none;
    if let Bool x = v { out = some(x.b); };
    out
}

def as_arr(v: Val) -> [Val]? {
    let out: [Val]? = none;
    if let Arr a = v { out = some(a.items); };
    out
}

// The object as a bare map, for indexing. none when `v` is not an object.
def as_obj(v: Val) -> { str => Val }? {
    let out: { str => Val }? = none;
    if let JObj o = v { out = some(o.members); };
    out
}

def is_null(v: Val) -> bool {
    let r = false;
    if let Null z = v { r = z.nil == 0; };
    r
}

// ── strings ─────────────────────────────────────────────────────────────

// Two lowercase hex digits of a byte value.
def hex2(c: long) -> str {
    let d = "0123456789abcdef";
    let s = "";
    s += chr(d[c / 16]);
    s += chr(d[c % 16]);
    s
}

// Append one codepoint to `b` as UTF-8. Y's `chr` emits a single byte, `v mod
// 256` (chr(256) is NUL, chr(8364) is 0xac), so the multi-byte forms have to be
// built here: 110xxxxx 10xxxxxx, 1110xxxx 10xxxxxx 10xxxxxx,
// 11110xxx 10xxxxxx 10xxxxxx 10xxxxxx.
def utf8_put(b: [byte], cp: long) -> [byte] {
    if (cp < 128) {
        b += bytes(chr(cp));
    } else if (cp < 2048) {
        b += bytes(chr(192 + (cp / 64)));
        b += bytes(chr(128 + (cp % 64)));
    } else if (cp < 65536) {
        b += bytes(chr(224 + (cp / 4096)));
        b += bytes(chr(128 + ((cp / 64) % 64)));
        b += bytes(chr(128 + (cp % 64)));
    } else {
        b += bytes(chr(240 + (cp / 262144)));
        b += bytes(chr(128 + ((cp / 4096) % 64)));
        b += bytes(chr(128 + ((cp / 64) % 64)));
        b += bytes(chr(128 + (cp % 64)));
    };
    b
}
// The body of a JSON string, without the quotes: " and \ escaped, the C0 range
// as \b \f \n \r \t or \u00XX, everything else passed through as UTF-8.
def escape(s: str) -> str {
    let out = "";
    let i = 0;
    let n = len(s);
    while (i < n) {
        let c = byte_at(s, i);
        if (c == 34) { out += "\\\""; }
        else if (c == 92) { out += "\\\\"; }
        else if (c == 8) { out += "\\b"; }
        else if (c == 9) { out += "\\t"; }
        else if (c == 10) { out += "\\n"; }
        else if (c == 12) { out += "\\f"; }
        else if (c == 13) { out += "\\r"; }
        else if (c < 32) { out += "\\u00" + hex2(c); }
        else { out += chr(c); };
        i = i + 1;
    };
    out
}

// ── printing ────────────────────────────────────────────────────────────

// Compact output: no space after a colon or a comma, which is what every JSON
// producer emits and what makes stringify(parse(s)) byte-identical to a
// canonically written s.
//
// A number prints as the text it was parsed from, so a float survives.
def stringify_val(v: Val, depth: long) -> str {
    let out = "null";
    if let Num n = v { out = n.num; }
    if let Str t = v { out = "\"" + escape(t.s) + "\""; }
    if let Bool x = v {
        if (x.b) { out = "true"; } else { out = "false"; };
    }
    if let Arr a = v {
        if (depth > json_depth_max) {
            out = json_depth_error;
        } else {
            let parts: [str] = [];
            let i = 0;
            let items = a.items;
            while (i < len(items)) {
                parts += stringify_val(items[i], depth + 1);
                i = i + 1;
            };
            out = "[" + ",".join(parts) + "]";
        }
    }
    if let JObj o = v { out = stringify_obj(o.members, depth); };
    out
}

def stringify(o: { str => Val }) -> str {
    stringify_obj(o, 0)
}

def stringify_obj(o: { str => Val }, depth: long) -> str {
    if (depth > json_depth_max) { return json_depth_error; }
    let parts: [str] = [];
    let i = 0;
    let ks = keys(o);
    while (i < len(ks)) {
        let k = ks[i];
        let got = o[k];
        if let some(v) = got {
            parts += "\"" + escape(k) + "\":" + stringify_val(v, depth + 1);
        };
        i = i + 1;
    };
    "{" + ",".join(parts) + "}"
}

export {
  Val, Num, Str, Bool, Null, Arr, JObj,
  obj, arr, jobj, jarr, num, numtext, str, boolean, nul,
  keys_of, field, index,
  as_str, as_long, as_bool, as_arr, as_obj, is_null,
  escape, utf8_put, hex2,
  stringify, stringify_val, stringify_obj,
  json_depth_max, json_depth_error
};

// ── parsing ─────────────────────────────────────────────────────────────
//
// A recursive-descent parser over a cursor. `P` is a record and records are
// references, so `p.i` advances in the caller's copy too -- that is what lets
// the descent be a set of small functions with no threading through returns.
//
// Every `p_*` returns `none` on failure and leaves the cursor wherever it
// stopped; the caller does not try to recover. `parse` reports none for the
// whole document, which is all a caller can act on.
//
// THE UNION TRAP, once, in one place: the VOID law means the expected type does
// not reach into an `if`'s arms, so no expression produces a union value. Every
// value here is therefore built by calling a constructor (`num`, `str`, ...) or
// through an annotated `let`, never by returning a record literal from two
// arms.

type P = { s: str, i: long };

// The value of one hex digit, or -1.
def hexval(c: long) -> long {
    let d = 0 - 1;
    if (c >= 48 && c <= 57) { d = c - 48; }
    if (c >= 97 && c <= 102) { d = c - 97 + 10; }
    if (c >= 65 && c <= 70) { d = c - 65 + 10; }
    d
}

// Skip JSON whitespace: space, tab, LF, CR. Nothing else counts.
def p_ws(p: P) -> long {
    let go = true;
    while (go) {
        if (p.i < len(p.s)) {
            let c = byte_at(p.s, p.i);
            if (c == 32 || c == 9 || c == 10 || c == 13) {
                p.i = p.i + 1;
            } else { go = false; }
        } else { go = false; }
    };
    p.i
}

def at(p: P) -> long {
    if (p.i < len(p.s)) { byte_at(p.s, p.i) } else { 0 - 1 }
}

def lit(p: P, t: str) -> bool {
    let n = len(t);
    if (p.i + n > len(p.s)) { return false; }
    let k = 0;
    while (k < n) {
        if (byte_at(p.s, p.i + k) != byte_at(t, k)) { return false; }
        k = k + 1;
    };
    p.i = p.i + n;
    true
}

// Four hex digits, or -1. Advances past them on success.
def p_hex4(p: P) -> long {
    let v = 0;
    let k = 0;
    let bad = false;
    while (k < 4) {
        if (p.i >= len(p.s)) {
            bad = true;
        } else {
            let d = hexval(byte_at(p.s, p.i));
            if (d < 0) { bad = true; } else { v = v * 16 + d; p.i = p.i + 1; }
        }
        k = k + 1;
    };
    if (bad) { 0 - 1 } else { v }
}

// One \uXXXX, with a surrogate pair folded into one codepoint, appended to
// `out` as UTF-8. Returns 0, or -1 for an escape that is not well formed -- a
// short one, a non-hex digit, or a surrogate with no partner. `out` grows in
// place (arrays are references and `+=` is in place), so the bytes written
// before a failure are simply abandoned with the rest of the string.
//
// utf8_put is what writes the codepoint, because `chr` cannot: it emits one
// byte, `v mod 256`.
def p_uescape(p: P, out: [byte]) -> long {
    let cp = p_hex4(p);
    if (cp < 0) { return 0 - 1; }
    if (cp >= 55296 && cp < 56320) {
        // a high surrogate: a \uDC00.. low surrogate must follow
        let paired = false;
        if (p.i + 1 < len(p.s) && byte_at(p.s, p.i) == 92 && byte_at(p.s, p.i + 1) == 117) {
            let save = p.i;
            p.i = p.i + 2;
            let lo = p_hex4(p);
            if (lo >= 56320 && lo < 57344) {
                cp = 65536 + (cp - 55296) * 1024 + (lo - 56320);
                paired = true;
            } else {
                p.i = save;
            }
        }
        if (!paired) { return 0 - 1; }
    } else if (cp >= 56320 && cp < 57344) {
        // a low surrogate with no high one before it
        return 0 - 1;
    }
    out = utf8_put(out, cp);
    0
}

// A string body, opening quote already consumed. Returns the decoded bytes.
def p_string(p: P) -> str? {
    let out: [byte] = [];
    let bad = false;
    let go = true;
    while (go) {
        if (p.i >= len(p.s)) {
            bad = true;
            go = false;
        } else {
            let c = byte_at(p.s, p.i);
            if (c == 34) {
                p.i = p.i + 1;
                go = false;
            } else if (c == 92) {
                p.i = p.i + 1;
                if (p.i >= len(p.s)) {
                    bad = true;
                    go = false;
                } else {
                    let e = byte_at(p.s, p.i);
                    p.i = p.i + 1;
                    if (e == 34) { out += bytes(chr(34)); }
                    else if (e == 92) { out += bytes(chr(92)); }
                    else if (e == 47) { out += bytes(chr(47)); }
                    else if (e == 98) { out += bytes(chr(8)); }
                    else if (e == 102) { out += bytes(chr(12)); }
                    else if (e == 110) { out += bytes(chr(10)); }
                    else if (e == 114) { out += bytes(chr(13)); }
                    else if (e == 116) { out += bytes(chr(9)); }
                    else if (e == 117) {
                        if (p_uescape(p, out) != 0) { bad = true; go = false; }
                    }
                    else { bad = true; go = false; }
                }
            } else if (c < 32) {
                // a raw control character is not allowed in a JSON string
                bad = true;
                go = false;
            } else {
                out += bytes(chr(c));
                p.i = p.i + 1;
            }
        }
    };
    let r: str? = none;
    if (!bad) { r = some(from_bytes(out)); };
    r
}

// A number's literal text, validated against JSON's grammar:
// -?(0|[1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
// A leading zero, a bare ".5" or a trailing "1." are all rejected.
def p_number(p: P) -> str? {
    let start = p.i;
    if (at(p) == 45) { p.i = p.i + 1; }
    if (at(p) == 48) {
        p.i = p.i + 1;
    } else {
        let d = 0 - 1;
        if (at(p) >= 0) { d = hexval(at(p)); }
        if (d < 1 || d > 9) { return none; }
        while (at(p) >= 48 && at(p) <= 57) { p.i = p.i + 1; }
    }
    if (at(p) == 46) {
        p.i = p.i + 1;
        if (!(at(p) >= 48 && at(p) <= 57)) { return none; }
        while (at(p) >= 48 && at(p) <= 57) { p.i = p.i + 1; }
    }
    if (at(p) == 101 || at(p) == 69) {
        p.i = p.i + 1;
        if (at(p) == 43 || at(p) == 45) { p.i = p.i + 1; }
        if (!(at(p) >= 48 && at(p) <= 57)) { return none; }
        while (at(p) >= 48 && at(p) <= 57) { p.i = p.i + 1; }
    }
    let r: str? = none;
    if (p.i > start) { r = some(p.s[start:p.i]); };
    r
}

// `[ ... ]`
def p_array(p: P, depth: long) -> Val? {
    let r: Val? = none;
    if (depth > json_depth_max) { return none; }
    p.i = p.i + 1;
    let items: [Val] = [];
    p_ws(p);
    if (at(p) == 93) {
        p.i = p.i + 1;
        r = some(jarr(items));
    } else {
        let bad = false;
        let go = true;
        while (go) {
            p_ws(p);
            let got = p_value(p, depth + 1);
            if (got == none) {
                bad = true;
                go = false;
            } else {
                items += got!;
                p_ws(p);
                if (at(p) == 44) {
                    p.i = p.i + 1;
                } else if (at(p) == 93) {
                    p.i = p.i + 1;
                    r = some(jarr(items));
                    go = false;
                } else {
                    bad = true;
                    go = false;
                }
            }
        }
        if (bad) { r = none; }
    }
    r
}

// `{ ... }`, built through `obj()` because a map literal would pin its value
// type to the first entry (see e25_map_value_type.y).
def p_object(p: P, depth: long) -> Val? {
    let r: Val? = none;
    if (depth > json_depth_max) { return none; }
    p.i = p.i + 1;
    let members = obj();
    p_ws(p);
    if (at(p) == 125) {
        p.i = p.i + 1;
        r = some(jobj(members));
    } else {
        let bad = false;
        let go = true;
        while (go) {
            p_ws(p);
            if (at(p) != 34) {
                bad = true;
                go = false;
            } else {
                p.i = p.i + 1;
                let k = p_string(p);
                if (k == none) {
                    bad = true;
                    go = false;
                } else {
                    p_ws(p);
                    if (at(p) != 58) {
                        bad = true;
                        go = false;
                    } else {
                        p.i = p.i + 1;
                        p_ws(p);
                        let v = p_value(p, depth + 1);
                        if (v == none) {
                            bad = true;
                            go = false;
                        } else {
                            members[k!] = v!;
                            p_ws(p);
                            if (at(p) == 44) {
                                p.i = p.i + 1;
                            } else if (at(p) == 125) {
                                p.i = p.i + 1;
                                r = some(jobj(members));
                                go = false;
                            } else {
                                bad = true;
                                go = false;
                            }
                        }
                    }
                }
            }
        }
        if (bad) { r = none; }
    }
    r
}

// Any JSON value.
def p_value(p: P, depth: long) -> Val? {
    let r: Val? = none;
    let c = at(p);
    if (c == 34) {
        p.i = p.i + 1;
        let s = p_string(p);
        if (s != none) { r = some(str(s!)); }
    }
    if (r == none && (c == 123 || c == 91)) {
        if (c == 123) { r = p_object(p, depth); } else { r = p_array(p, depth); }
    }
    if (r == none && c == 116 && lit(p, "true")) { r = some(boolean(true)); }
    if (r == none && c == 102 && lit(p, "false")) { r = some(boolean(false)); }
    if (r == none && c == 110 && lit(p, "null")) { r = some(nul()); }
    if (r == none && (c == 45 || (c >= 48 && c <= 57))) {
        let n = p_number(p);
        if (n != none) { r = some(numtext(n!)); }
    }
    r
}


// ── entry points ────────────────────────────────────────────────────────

// A whole document, as any value.
def parse_val(s: str) -> Val? {
    let r: Val? = none;
    let p = { s: s, i: 0 };
    p_ws(p);
    if (p.i >= len(s)) { return none; }
    let got = p_value(p, 0);
    if (got != none) {
        p_ws(p);
        if (p.i >= len(s)) { r = got; }
    };
    r
}

// A document that must be an object, returned as the bare map so it can be
// indexed directly -- the common case, and the one the LSP wants.
def parse(s: str) -> { str => Val }? {
    let r: { str => Val }? = none;
    let v = parse_val(s);
    if (v != none) {
        let got = as_obj(v!);
        if (got != none) { r = got; }
    };
    r
}

// As parse, but with the message and the byte offset of the failure. A program
// that wants to point at the problem in a document it did not author needs both.
def parse_err(s: str) -> { ok: bool, value: Val?, err: str, at: long } {
    let p = { s: s, i: 0 };
    p_ws(p);
    if (p.i >= len(s)) {
        return { ok: false, value: none, err: "empty document", at: p.i };
    }
    let got = p_value(p, 0);
    if (got == none) {
        return { ok: false, value: none, err: "unexpected " + p_show(s, p.i), at: p.i };
    }
    p_ws(p);
    if (p.i < len(s)) {
        return { ok: false, value: none, err: "trailing " + p_show(s, p.i), at: p.i };
    }
    { ok: true, value: got, err: "", at: p.i }
}

// A short description of the byte at `i`, for an error message.
def p_show(s: str, i: long) -> str {
    if (i >= len(s)) { return "end of input"; }
    let c = byte_at(s, i);
    if (c >= 32 && c < 127) { return "'" + chr(c) + "'"; }
    return "byte " + tostring(c)
}

export {
  P, hexval, at, lit,
  parse, parse_val, parse_err, p_show
};

//
// ── vkind ─────────────────────────────────────────────────────────────────
//
// Which union member is this?  1 num, 2 str, 3 bool, 4 null, 5 array,
// 6 object.  Internal.
//
// This exists because `else if let` DOES NOT PARSE in this language -- the
// parser wants a block after `else` and stops at the `if` -- so a chain of six
// union cases cannot be written the way it reads.  A discriminator turns each
// case into its own guarded statement, which does parse.
//
// It is written on top of as_long/as_str/as_bool/is_null/as_arr rather than on
// `if let Num x = v` directly, and that is not a style choice: matching a union
// member BINDS it, and five of the six bindings would be unused, which is a
// warning per case and this file has to compile with zero.  The accessors
// already do the matching and use their own bindings.
def vkind(v: Val) -> long {
    let k = 0;
    if (as_long(v) != none) {
        k = 1
    } else {
        if (as_str(v) != none) {
            k = 2
        } else {
            if (as_bool(v) != none) {
                k = 3
            } else {
                if (is_null(v)) {
                    k = 4
                } else {
                    if (as_arr(v) != none) {
                        k = 5
                    } else {
                        k = 6
                    }
                }
            }
        }
    };
    k
}

// fieldv(o, k) -> Val -- the member at `k`, or null when it is absent.
//
// `field` answers `Val?`, and an option of a UNION cannot be narrowed with a
// pattern (the compiler says so: "cannot match a record pattern against
// Val?").  `!` unwraps one, and unwrapping `none` TRAPS, so the presence test
// has to come first.  Callers should use the get_* functions below rather than
// this; it is here because `same` and `pretty_val` need a `Val` to recurse on.
def fieldv(o: Val, k: str) -> Val {
    let out = nul();
    if let JObj j = o {
        let hit = j.members[k];
        if (hit != none) { out = hit! };
    };
    out
}

// ── parse_bytes ──────────────────────────────────────────────────────────
//
// NOT ZERO-COPY, and it would be dishonest to call it that: the bytes become a
// `str` and go to parse_val, so the copy this function was added to avoid still
// happens.  What it removes is the CALLER's copy -- examples/httpsrv and
// examples/rest-client each wrote that loop themselves.
//
// The zero-copy form is a second parser walking the buffer, and both examples
// want it for the same reason: their document IS the socket's receive buffer.
// They go further and never build a DOM at all -- httpsrv wants one field and a
// length, rest-client one field and a comparison -- so an extractive parser is
// the real gap and `get_*` below is half of it.
def parse_bytes(b: [byte], len: long) -> Val? {
    let n = len;
    if (n > b.length) { n = b.length };
    let s = "";
    let i = 0;
    while (i < n) { s = s + chr(b[i]); i = i + 1 };
    parse_val(s)
}

// ── accessors with a default ─────────────────────────────────────────────
//
// field/as_long answer `none`, which forces every caller to unwrap or trap.
// examples/weather wrote int_of/str_of/arr_of because a config lookup wants a
// value, not a proof of absence: a missing key in a config file is not an
// error worth three lines at every call site.
def get_long(o: Val, key: str, dflt: long) -> long {
    let out = dflt;
    let f = field(o, key);
    if (f != none) {
        // A number that is not a whole one (a fraction, an exponent, junk)
        // leaves the caller's default: tolong answers none rather than
        // truncating, and this function's contract is a long, not an option.
        if let Num n = f! {
            let v = tolong(n.num);
            if (v != none) { out = v!; };
        };
    };
    out
}

def get_str(o: Val, key: str, dflt: str) -> str {
    let out = dflt;
    let f = field(o, key);
    if (f != none) {
        if let Str x = f! { out = x.s };
    };
    out
}

def get_arr(o: Val, key: str) -> [Val]? {
    let out: [Val]? = none;
    let f = field(o, key);
    if (f != none) {
        if let Arr a = f! { out = some(a.items) };
    };
    out
}

// ── structural comparison ────────────────────────────────────────────────
//
// A golden file needs to know whether two documents are the SAME document, and
// "the same text" is not that: member order is insignificant in JSON, so two
// printers that disagree about order emit different bytes for equal values.
// `pretty(..., true)` is the other half of that problem.
//
// Recursion is bounded the way the parser's is: a document a few thousand deep
// runs off the stack otherwise.
def same(a: Val, b: Val) -> bool {
    let ka = vkind(a);
    let eq = ka == vkind(b);
    if (eq && ka == 1) {
        if let Num x = a { if let Num y = b { eq = x.num == y.num } }
    };
    if (eq && ka == 2) {
        if let Str x = a { if let Str y = b { eq = x.s == y.s } }
    };
    if (eq && ka == 3) {
        if let Bool x = a { if let Bool y = b { eq = x.b == y.b } }
    };
    if (eq && ka == 4) {
        if let Null x = a { if let Null y = b { eq = x.nil == y.nil } }
    };
    if (eq && ka == 5) {
        if let Arr x = a {
            if let Arr y = b {
                eq = x.items.length == y.items.length;
                let i = 0;
                while (eq && i < x.items.length) {
                    eq = same(x.items[i], y.items[i]);
                    i = i + 1
                }
            }
        }
    };
    if (eq && ka == 6) {
        if let JObj x = a {
            if let JObj y = b {
                let kx = keys_of(x.members);
                let ky = keys_of(y.members);
                eq = kx.length == ky.length;
                let i = 0;
                while (eq && i < kx.length) {
                    eq = same(fieldv(a, kx[i]), fieldv(b, kx[i]));
                    i = i + 1
                }
            }
        }
    };
    eq
}

// ── size and depth ───────────────────────────────────────────────────────
def node_count(v: Val) -> long {
    let n = 1;
    let k = vkind(v);
    if (k == 5) {
        if let Arr a = v {
            let i = 0;
            while (i < a.items.length) {
                n = n + node_count(a.items[i]);
                i = i + 1
            }
        }
    };
    if (k == 6) {
        if let JObj o = v {
            let ks = keys_of(o.members);
            let i = 0;
            while (i < ks.length) {
                n = n + node_count(fieldv(v, ks[i]));
                i = i + 1
            }
        }
    };
    n
}

def max_depth(v: Val) -> long {
    let d = 1;
    let k = vkind(v);
    if (k == 5) {
        if let Arr a = v {
            let i = 0;
            let m = 0;
            while (i < a.items.length) {
                let c = max_depth(a.items[i]);
                if (c > m) { m = c };
                i = i + 1
            };
            d = m + 1
        }
    };
    if (k == 6) {
        if let JObj o = v {
            let ks = keys_of(o.members);
            let i = 0;
            let m = 0;
            while (i < ks.length) {
                let c = max_depth(fieldv(v, ks[i]));
                if (c > m) { m = c };
                i = i + 1
            };
            d = m + 1
        }
    };
    d
}

// ── canonical serialisation ──────────────────────────────────────────────
//
// pretty(v, indent, sorted): stringify with newlines and, when `sorted`, the
// members in a fixed order.  `sorted` is the point -- a golden file needs a
// canonical form, and JSON member order is not significant, so an unsorted
// printer's output depends on map iteration order.
//
// There is no sort in the language (SUGGESTIONS.md #17), so this is an
// insertion sort over the key list: O(n^2), which is right for the object
// sizes a config file or an API response actually has and wrong for a large
// one.  Each insertion rebuilds the list rather than splicing, because there is
// no insert-in-place and `+=` would copy the tail on every step.
def sort_keys(ks: [str]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < ks.length) {
        let k = ks[i];
        let j = out.length;
        while (j > 0 && out[j - 1] > k) { j = j - 1 };
        let nxt: [str] = [];
        let m = 0;
        while (m < j) { nxt += out[m]; m = m + 1 };
        nxt += k;
        m = j;
        while (m < out.length) { nxt += out[m]; m = m + 1 };
        out = nxt;
        i = i + 1
    };
    out
}

def indent_of(depth: long, width: long) -> str {
    let s = "";
    let i = 0;
    while (i < depth * width) { s = s + " "; i = i + 1 };
    s
}

def pretty_val(v: Val, depth: long, width: long, sorted: bool) -> str {
    let pad = indent_of(depth, width);
    let pad1 = indent_of(depth + 1, width);
    let out = "";
    let k = vkind(v);
    if (k == 1) {
        if let Num x = v { out = x.num }
    };
    if (k == 2) {
        if let Str x = v { out = "\"" + escape(x.s) + "\"" }
    };
    if (k == 3) {
        if let Bool x = v { out = if x.b { "true" } else { "false" } }
    };
    if (k == 4) {
        out = "null"
    };
    if (k == 5) {
        if let Arr a = v {
            if (a.items.length == 0) {
                out = "[]"
            } else {
                out = "[\n";
                let i = 0;
                while (i < a.items.length) {
                    out = out + pad1
                         + pretty_val(a.items[i], depth + 1, width, sorted);
                    if (i + 1 < a.items.length) { out = out + "," };
                    out = out + "\n";
                    i = i + 1
                };
                out = out + pad + "]"
            }
        }
    };
    if (k == 6) {
        if let JObj o = v {
            let ks = keys_of(o.members);
            if (sorted) { ks = sort_keys(ks) };
            if (ks.length == 0) {
                out = "{}"
            } else {
                out = "{\n";
                let i = 0;
                while (i < ks.length) {
                    out = out + pad1 + "\"" + escape(ks[i]) + "\": "
                         + pretty_val(fieldv(v, ks[i]), depth + 1, width, sorted);
                    if (i + 1 < ks.length) { out = out + "," };
                    out = out + "\n";
                    i = i + 1
                };
                out = out + pad + "}"
            }
        }
    };
    out
}

def pretty(v: Val, indent: long, sorted: bool) -> str {
    pretty_val(v, 0, indent, sorted)
}

export {
  parse_bytes, get_long, get_str, get_arr,
  same, node_count, max_depth,
  sort_keys, pretty, pretty_val
};
