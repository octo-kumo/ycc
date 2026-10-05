// jsonval.y -- a JSON value, a strict parser, a deterministic emitter, a
// structural comparison and a dotted-path query.
//
// ── why this file exists ─────────────────────────────────────────────────
//
// There is NO JSON module in Y (ORCHESTRATOR.md 2.4c / 2.14): no parser,
// no emitter, nothing. JSON *literal* syntax is on the compiler's own
// roadmap (TODO.md section 3), so this is expected work rather than a
// workaround and nothing here is filed as a bug. What the file buys is a
// document model that keeps two things JSON cares about and a hash map
// would throw away:
//
//   * object KEY ORDER as written, not sorted -- `fields` is an ordered
//     array of pairs, not a map. Sorting is available but opt-in
//     (--sort-keys), so the default output is byte-stable.
//   * NUMBER TEXT verbatim. `s` holds the token exactly as it was read,
//     so 1.0 stays 1.0, 1e2 stays 1e2, and parse -> emit -> parse is
//     exactly the identity. Normalising would lose information the input
//     carried.
//
// ── the value ─────────────────────────────────────────────────────────────
//
// One flat record with a tag, not a tagged union: `kind` says which of
// the other fields is live (0 null, 1 bool, 2 num, 3 str, 4 array,
// 5 object). A union of six records would want `match` and a cast at
// every read, and the C twin's value model has no tagged variants worth
// copying. A flat record costs a little memory per node and nothing in
// clarity.
//
//   kind  b      n     s                items          fields
//   0     -      0     ""               -              -
//   1     value  0     ""               -              -
//   2     -      int   the number text  -              -
//   3     -      0     the text         -              -
//   4     -      0     ""               the elements   -
//   5     -      0     ""               -              the pairs
//
// `n` is the integer value of a kind-2 node when the token is a plain
// integer of at most 18 digits, and 0 otherwise -- so a caller that wants
// to count or index can, and a caller that wants exactness uses `s`.
//
// ── linear scans, everywhere ──────────────────────────────────────────────
//
// There is no hash map, no lookup by name in O(1) and no `sort` in Y: a
// `{str => long}` is a linear scan (ORCHESTRATOR.md 2.8). So j_get is
// O(fields) and --sort-keys is a selection sort. A JSON object with many
// keys therefore costs a linear scan per lookup, which is right for a
// document and wrong for a 100 000-key index. The README says so too.

import b64;

type JField = { k: str, v: JVal };
type JVal = { kind: long, b: bool, n: long, s: str, items: [JVal], fields: [JField] };

// One shared empty array for the two fields a scalar node never uses, so
// a scalar node costs one allocation rather than three. The invariant
// this buys: nothing ever appends to `items` unless kind is 4, nor to
// `fields` unless the kind is 5.
let EMPTY_J: [JVal] = [];
let EMPTY_F: [JField] = [];

// The nesting bound. Y recursion is cheap (20 000 frames verified), but a
// bound is still what keeps `[[[[[...` from turning a 4 MB input into a
// stack overflow, and the diagnostic names the bound so it is not a
// mystery to whoever hits it.
const MAX_DEPTH = 200;

// ── constructors ──────────────────────────────────────────────────────────

def j_null() -> JVal { { kind: 0, b: false, n: 0, s: "", items: EMPTY_J, fields: EMPTY_F } };
def j_bool(v: bool) -> JVal { { kind: 1, b: v, n: 0, s: "", items: EMPTY_J, fields: EMPTY_F } };
def j_num(raw: str, n: long) -> JVal { { kind: 2, b: false, n: n, s: raw, items: EMPTY_J, fields: EMPTY_F } };
def j_str(v: str) -> JVal { { kind: 3, b: false, n: 0, s: v, items: EMPTY_J, fields: EMPTY_F } };
def j_arr() -> JVal { { kind: 4, b: false, n: 0, s: "", items: [], fields: EMPTY_F } };
def j_obj() -> JVal { { kind: 5, b: false, n: 0, s: "", items: EMPTY_J, fields: [] } };

// j_int(v: long) -- a number node for an integer Y value.
def j_int(v: long) -> JVal { j_num(tostring(v), v) };

// num_isint(v: JVal) -> bool -- is a kind-2 node a plain integer?
def num_isint(v: JVal) -> bool {
    v.s.index_of(".") < 0 && v.s.index_of("e") < 0 && v.s.index_of("E") < 0
};

// ── diagnostics ───────────────────────────────────────────────────────────

// p_desc(c: long) -> str -- a code point for an error message: printable
// characters quoted, everything else 0xNN. Reuses b64's t_byte so the two
// modules cannot drift apart in how they render a byte.
def p_desc(c: long) -> str { b64.t_byte(c) };

// p_q(c: long) -> str -- the same, but preferring \" for the quote so a
// message about a bad string reads well.
def p_q(c: long) -> str {
    // A quote and a single quote both need words, not quoting: "\'" and
    // '\'' read as noise in a diagnostic.
    if (c == 34) { "a double quote" }
    else if (c == 39) { "a single quote" }
    else { b64.t_byte(c) }
};

// HEXD is an ARRAY of one-character strings, not a string. Indexing a
// `str` yields a byte (and `str + byte` segfaults -- the filed bug), so a
// digit lookup table has to be `[str]` to be usable at all. This is the
// only shape that works, and b64.y does the same with its alphabet.
let HEXD: [str] = ["0", "1", "2", "3", "4", "5", "6", "7",
                   "8", "9", "a", "b", "c", "d", "e", "f"];

// hex4(c: long) -> str -- the last two hex digits, so a diagnostic can
// name the exact \u form to write instead of the code point.
def hex4(c: long) -> str {
    let s = "";
    s += HEXD[(c / 16) % 16];
    s += HEXD[c % 16];
    s
};

// p_quote(s: str) -> str -- a string inside a diagnostic, cut short so a
// 4000-character key cannot make a 4000-character message.
def p_quote(s: str) -> str {
    let cut = s;
    if (len(cut) > 40) { cut = cut[0:40] + "..."; };
    "\"" + cut + "\""
};

// ── the parser's state ────────────────────────────────────────────────────
//
// Module level, so the recursive-descent functions can return just a
// value and report failure through p_err -- the shape a language with no
// exceptions wants: check p_err once, at the top.

let p_s = "";
let p_i = 0;
let p_line = 1;
let p_col = 1;
let p_err = "";
let p_depth = 0;
// read_u4() has no out-parameter to fill (Y has none), so it parks the
// value it read here and the caller reads it back.
let u4_val = 0;

// fail(msg: str) -- record the FIRST error, with its line and column.
// Keeping the first is what makes a diagnostic point at the actual
// mistake rather than at one of its consequences.
def fail(msg: str) {
    if (p_err == "") {
        p_err = "line " + tostring(p_line) + " column " + tostring(p_col) + ": " + msg
    }
};

// errv(msg: str) -> JVal -- fail(), and hand back a placeholder for a
// caller that needs a value on the error path.
def errv(msg: str) -> JVal { fail(msg); j_null() };

// bump() -- consume one byte, tracking line and column. Every advance in
// the parser goes through here, so a diagnostic's line/column is exact
// without a second pass.
def bump() {
    if (p_i < len(p_s)) {
        if (byte_at(p_s, p_i) == 10) { p_line = p_line + 1; p_col = 1; } else { p_col = p_col + 1; };
        p_i = p_i + 1
    }
};

// ws() -- skip the four characters JSON allows between tokens. Written as
// a positive-condition loop because Y has no `continue` (2.9); the guard
// flag IS the continue here.
def ws() {
    let go = true;
    while (go) {
        let c = peek();
        if (c == 32 || c == 9 || c == 10 || c == 13) { bump(); } else { go = false; };
    }
};


// peek() -> long -- the byte at the cursor, or -1 at end of input.
def peek() -> long {
    let c = 0 - 1;
    if (p_i < len(p_s)) { c = byte_at(p_s, p_i); };
    c
};

// at(c: long) -> bool -- is the next byte this? (JSON is ASCII-only.)
def at(c: long) -> bool { peek() == c };

def is_digit(c: long) -> bool { c >= 48 && c <= 57 };
def is_hex(c: long) -> bool {
    (c >= 48 && c <= 57) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70)
};
def hexval(c: long) -> long {
    let v = 0;
    if (c >= 48 && c <= 57) { v = c - 48; } else if (c >= 97 && c <= 102) { v = c - 87; } else { v = c - 55; };
    v
};

// all_digits(s: str) -> bool -- a local integer check, so this module
// depends on b64 and nothing else (no args, no toolkit).
def all_digits(s: str) -> bool {
    let ok = len(s) > 0;
    let i = 0;
    while (i < len(s) && ok) { if (!is_digit(byte_at(s, i))) { ok = false; }; i = i + 1; };
    ok
};

// put_utf8(buf: [byte], cp: long) -- append one code point as UTF-8.
def put_utf8(buf: [byte], cp: long) {
    let b0: byte = 0;
    let b1: byte = 0;
    let b2: byte = 0;
    let b3: byte = 0;
    if (cp < 128) {
        b0 = cp;
        buf += b0;
    } else if (cp < 2048) {
        b0 = 192 + (cp / 64);
        b1 = 128 + (cp % 64);
        buf += b0;
        buf += b1;
    } else if (cp < 65536) {
        b0 = 224 + (cp / 4096);
        b1 = 128 + ((cp / 64) % 64);
        b2 = 128 + (cp % 64);
        buf += b0;
        buf += b1;
        buf += b2;
    } else {
        b0 = 240 + (cp / 262144);
        b1 = 128 + ((cp / 4096) % 64);
        b2 = 128 + ((cp / 64) % 64);
        b3 = 128 + (cp % 64);
        buf += b0;
        buf += b1;
        buf += b2;
        buf += b3
    }
};

// putb(buf: [byte], v: long) -- append ONE byte. The only long -> byte
// conversion in the file; Y has no cast syntax, so the annotated binding
// is the whole mechanism.
def putb(buf: [byte], v: long) {
    let b: byte = v;
    buf += b
};

// put_u4(buf: [byte], cp: long) -- \uXXXX, for a control character with
// no short name and for a code point that did not fit two bytes.
def put_u4(buf: [byte], cp: long) {
    let b: byte = 92;
    let u: byte = 117;
    let d0: byte = ord(HEXD[(cp / 4096) % 16]);
    let d1: byte = ord(HEXD[(cp / 256) % 16]);
    let d2: byte = ord(HEXD[(cp / 16) % 16]);
    let d3: byte = ord(HEXD[cp % 16]);
    buf += b;
    buf += u;
    buf += d0;
    buf += d1;
    buf += d2;
    buf += d3
};

// p_string() -> str -- a quoted string, returned DECODED. Reports p_err
// if the quotes are not closed, if a control character appears raw, or
// if an escape is not one JSON knows.
//
// The result is built in a [byte] and converted once with from_bytes,
// rather than appending `chr(c)` per character: one allocation and one
// copy instead of one string per character.
def p_string() -> str {
    bump();                     // the opening quote
    let buf: [byte] = [];
    let go = true;
    // The `&& p_err == ""` is load-bearing: every error arm below bails
    // out of the scanner by setting p_err, and without it a failure that
    // does not advance the cursor would spin for ever.
    while (go && p_err == "") {
        let c = peek();
        if (c < 0) {
            fail("unterminated string: no closing quote");
            go = false;
        } else if (c == 34) {
            bump();
            go = false;
        } else if (c == 92) {
            bump();             // the backslash
            let e = peek();
            if (e == 34) { putb(buf, 34); bump(); }
            else if (e == 92) { putb(buf, 92); bump(); }
            else if (e == 47) { putb(buf, 47); bump(); }
            else if (e == 98) { putb(buf, 8); bump(); }
            else if (e == 102) { putb(buf, 12); bump(); }
            else if (e == 110) { putb(buf, 10); bump(); }
            else if (e == 114) { putb(buf, 13); bump(); }
            else if (e == 116) { putb(buf, 9); bump(); }
            else if (e == 117) {
                bump();
                // read_u4 has no out-parameter to fill (Y has none), so it
                // parks the value in u4_val -- the module-state idiom the
                // rest of this file uses too.
                let ok = read_u4();
                let cp = u4_val;
                if (!ok) {
                    fail("\\u needs four hex digits");
                } else if (cp >= 55296 && cp <= 56319) {
                    // A high surrogate. The low half has to follow as \u,
                    // and the two together are one 4-byte code point.
                    let low = 0 - 1;
                    let ok2 = false;
                    if (at(92)) {
                        bump();
                        if (at(117)) {
                            bump();
                            ok2 = read_u4();
                            low = u4_val;
                            if (ok2 && (low < 56320 || low > 57343)) {
                                fail("a high surrogate must be followed by a low one");
                                ok2 = false;
                            };
                        } else {
                            fail("a high surrogate must be followed by \\u")
                        };
                    } else {
                        fail("a high surrogate must be followed by \\u")
                    };
                    if (ok2) { put_utf8(buf, 65536 + (cp - 55296) * 1024 + (low - 56320)) };
                } else if (cp >= 56320 && cp <= 57343) {
                    fail("a low surrogate must follow a high one in \\u");
                } else {
                    put_utf8(buf, cp)
                };
            } else if (e < 0) {
                fail("unterminated string: a backslash at end of input");
            } else {
                fail("unknown escape \\" + p_q(e))
            };
        } else if (c < 32) {
            fail("a raw control character " + p_desc(c) + " must be written \\u00" + hex4(c));
        } else {
            // >= 128 is UTF-8 and is already correct, so it passes through
            // byte by byte -- which is also why no decoding is attempted.
            let b: byte = c;
            buf += b;
            bump()
        };
    };
    from_bytes(buf)
};

// read_u4() -- read four hex digits from the cursor into u4_val. Returns
// false (and consumes what it could) if they are not all hex digits.
def read_u4() -> bool {
    let cp = 0;
    let ok = true;
    let k = 0;
    while (k < 4 && ok) {
        let h = peek();
        if (h < 0) { ok = false; } else if (!is_hex(h)) { ok = false; } else { cp = cp * 16 + hexval(h); bump(); };
        k = k + 1;
    };
    u4_val = cp;
    ok
};

// p_number() -> JVal -- a number, validated against the JSON grammar and
// not C's: -? (0 | [1-9][0-9]*) (.[0-9]+)? ([eE][+-]?[0-9]+)?
// The token text is kept verbatim, which is what makes
// parse -> emit -> parse the identity for 1.0, 1e2 and -0.
def p_number() -> JVal {
    let r = j_num("0", 0);
    let start = p_i;
    if (at(45)) { bump(); };
    if (!is_digit(peek())) {
        r = errv("a number needs a digit, found " + p_q(peek()));
    } else if (peek() == 48) {
        bump();
        // A leading zero may not be followed by more digits.
        if (is_digit(peek())) { r = errv("a leading '0' cannot be followed by digits"); }
    } else {
        let go = true;
        while (go) { if (is_digit(peek())) { bump(); } else { go = false; }; }
    };
    if (p_err == "" && at(46)) {
        bump();
        if (!is_digit(peek())) {
            r = errv("a '.' must be followed by at least one digit");
        } else {
            let go = true;
            while (go) { if (is_digit(peek())) { bump(); } else { go = false; }; }
        };
    };
    if (p_err == "" && (at(101) || at(69))) {
        bump();
        if (at(43) || at(45)) { bump(); };
        if (!is_digit(peek())) {
            r = errv("an exponent needs at least one digit");
        } else {
            let go = true;
            while (go) { if (is_digit(peek())) { bump(); } else { go = false; }; }
        };
    };
    if (p_err == "") {
        let raw = p_s[start:p_i];
        // The integer value, when the token is a plain integer that fits in
        // 18 digits. Anything else -- a fraction, an exponent, a huge
        // literal -- leaves n at 0 and the text in s, which is exact.
        let iv = 0;
        if (raw.index_of(".") < 0 && raw.index_of("e") < 0 && raw.index_of("E") < 0 &&
            len(raw) <= 18) {
            iv = tolong(raw)
        };
        r = j_num(raw, iv)
    };
    r
};

// p_word() -> JVal -- true, false or null, spelled out.
def p_word() -> JVal {
    let r = j_null();
    let c = peek();
    if (c == 116) {
        if (p_s[p_i:p_i + 4] == "true") {
            let k = 0;
            while (k < 4) { bump(); k = k + 1; };
            r = j_bool(true)
        } else { r = errv("expected 'true', 'false' or 'null'"); }
    } else if (c == 102) {
        if (p_s[p_i:p_i + 5] == "false") {
            let k = 0;
            while (k < 5) { bump(); k = k + 1; };
            r = j_bool(false)
        } else { r = errv("expected 'true', 'false' or 'null'"); }
    } else {
        if (p_s[p_i:p_i + 4] == "null") {
            let k = 0;
            while (k < 4) { bump(); k = k + 1; };
            r = j_null()
        } else { r = errv("expected 'true', 'false' or 'null'"); }
    };
    r
};

def p_array() -> JVal {
    p_depth = p_depth + 1;
    let out = j_arr();
    let go = false;
    if (p_depth > MAX_DEPTH) {
        fail("nested deeper than " + tostring(MAX_DEPTH) + " levels");
    } else {
        bump();                 // '['
        ws();
        if (at(93)) {
            bump();             // the empty array: ']' is ours to eat
        } else { go = true; };
        while (go) {
            let v = p_value();
            if (p_err != "") {
                go = false;
            } else {
                out.items += v;
                ws();
                let d = peek();
                if (d == 44) {
                    bump();
                    ws();
                    if (at(93)) {
                        fail("a trailing ',' before ']'");
                        go = false;
                    };
                } else if (d == 93) {
                    bump();
                    go = false;
                } else if (d < 0) {
                    fail("unexpected end of input; expected ',' or ']'");
                    go = false;
                } else {
                    fail("unexpected " + p_q(d) + " after a value; expected ',' or ']'");
                    go = false;
                }
            };
        };
        p_depth = p_depth - 1
    };
    out
};

def p_object() -> JVal {
    p_depth = p_depth + 1;
    let out = j_obj();
    let go = false;
    if (p_depth > MAX_DEPTH) {
        fail("nested deeper than " + tostring(MAX_DEPTH) + " levels");
    } else {
        bump();                 // '{'
        ws();
        if (at(125)) {
            bump();             // the empty object: '}' is ours to eat
        } else { go = true; };
        while (go) {
            let k0 = peek();
            if (k0 != 34) {
                if (k0 == 125) {
                    fail("a trailing ',' before '}'");
                } else if (k0 < 0) {
                    fail("unexpected end of input; expected a quoted key");
                } else {
                    fail("a key must be a quoted string, found " + p_q(k0));
                };
                go = false;
            } else {
                let key = p_string();
                if (p_err != "") {
                    go = false;
                } else {
                    ws();
                    let d = peek();
                    if (d != 58) {
                        if (d < 0) {
                            fail("unexpected end of input; expected ':' after the key " + p_quote(key));
                        } else {
                            fail("expected ':' after the key " + p_quote(key) + ", found " + p_q(d));
                        };
                        go = false;
                    } else {
                        bump();
                        let v = p_value();
                        if (p_err != "") {
                            go = false;
                        } else {
                            out.fields += { k: key, v: v };
                            ws();
                            let e = peek();
                            if (e == 44) {
                                bump();
                                ws();
                                if (at(125)) {
                                    fail("a trailing ',' before '}'");
                                    go = false;
                                };
                            } else if (e == 125) {
                                bump();
                                go = false;
                            } else if (e < 0) {
                                fail("unexpected end of input; expected ',' or '}'");
                                go = false;
                            } else {
                                fail("unexpected " + p_q(e) + " after a value; expected ',' or '}'");
                                go = false;
                            }
                        };
                    };
                };
            };
        };
        p_depth = p_depth - 1
    };
    out
};

// p_value() -> JVal -- one JSON value.
def p_value() -> JVal {
    ws();
    let r = j_null();
    if (p_err == "") {
        let c = peek();
        if (c < 0) {
            fail("unexpected end of input where a value was expected");
        } else if (c == 123) {
            r = p_object();
        } else if (c == 91) {
            r = p_array();
        } else if (c == 34) {
            r = j_str(p_string());
        } else if (c == 116 || c == 102 || c == 110) {
            r = p_word();
        } else if (c == 45 || is_digit(c)) {
            r = p_number();
        } else {
            fail("unexpected " + p_q(c) + " where a value was expected");
        };
    };
    r
};

// parse(s: str) -> JVal -- a whole document. On success p_err is "" and
// the returned value is the root; on failure p_err says what and where
// and the returned value is a placeholder the caller must not use.
def parse(s: str) -> JVal {
    p_s = s;
    p_i = 0;
    p_line = 1;
    p_col = 1;
    p_err = "";
    p_depth = 0;
    let v = p_value();
    if (p_err == "") {
        ws();
        let c = peek();
        if (c >= 0) {
            fail("unexpected " + p_q(c) + " after the top-level value")
        };
    };
    v
};

// parse_err() -> str -- the diagnosis from the last parse(); "" on
// success.
def parse_err() -> str { p_err };

// parse_ok(s: str) -> JVal? -- parse, or none when the document is bad.
def parse_ok(s: str) -> JVal? {
    let v = parse(s);
    if (p_err == "") { some(v) } else { none }
};

// ── the emitter ───────────────────────────────────────────────────────────
//
// State is module level so the recursion can append to one buffer. `+=` on
// a `str` that owns its buffer is amortised O(1) (NATIVE.md, "Owned
// strings"), so emitting a document is one linear pass.

// em_out is a [byte], NOT a str. See the WORKAROUND note above render().
let em_out: [byte] = [];
let em_pretty = true;
let em_indent = 2;
let em_sort = false;

// esc_str(s: str) -> str -- a JSON string literal, quotes included.
//
// chr(c) returns exactly one byte for 0..255 (verified), so the raw
// bytes pass through with one += each. Bytes >= 128 are already UTF-8 and
// need nothing done to them.
def esc_str(s: str) -> str {
    let out = "\"";
    let i = 0;
    let n = len(s);
    let go = i < n;
    while (go) {
        let c = byte_at(s, i);
        if (c == 34) { out += "\\\""; }
        else if (c == 92) { out += "\\\\"; }
        else if (c == 8) { out += "\\b"; }
        else if (c == 9) { out += "\\t"; }
        else if (c == 10) { out += "\\n"; }
        else if (c == 12) { out += "\\f"; }
        else if (c == 13) { out += "\\r"; }
        else if (c < 32 || c == 127) { out += "\\u00" + hex4(c); }
        else { out += chr(c); };
        i = i + 1;
        go = i < n;
    };
    out += "\""
};

// sort_fields(fs: [JField]) -> [JField] -- selection sort by key. There is
// no `sort` in Y; this is the shape std/fs.y uses for its own sort_names.
// It works on a COPY of the pointer array, so --sort-keys cannot reorder
// the caller's document. O(fields^2), which is fine at the scale a
// document has keys and is why --sort-keys is not the default.
def sort_fields(fs: [JField]) -> [JField] {
    let out: [JField] = [];
    let i = 0;
    while (i < len(fs)) { out += fs[i]; i = i + 1; };
    let a = 0;
    while (a < len(out)) {
        let best = a;
        let b = a + 1;
        while (b < len(out)) { if (out[b].k < out[best].k) { best = b; }; b = b + 1; };
        if (best != a) { let t = out[a]; out[a] = out[best]; out[best] = t; };
        a = a + 1;
    };
    out
};

// ind(depth: long) -> str -- `depth` levels of indentation.
def ind(depth: long) -> str {
    let s = "";
    let k = 0;
    let n = depth * em_indent;
    while (k < n) { s += " "; k = k + 1; };
    s
};

// em_put(t: str) -- append t's bytes to the output buffer, one byte at a
// time. A [byte] `+=` grows by doubling, which is amortised O(1) with no
// ownership flag involved, so this is linear however many em_put calls the
// loop makes.
def em_put(t: str) {
    let i = 0;
    let n = len(t);
    let go = i < n;
    while (go) {
        let b: byte = byte_at(t, i);
        em_out += b;
        i = i + 1;
        go = i < n;
    }
};

// leaf_text(v: JVal) -> str -- a node with no children as its JSON text.
// An EMPTY container counts: the walk below sends it here rather than
// pushing it on the stack, so its text has to be "[]" / "{}" and not the
// empty string its unused `s` field holds.
def leaf_text(v: JVal) -> str {
    if (v.kind == 0) { "null" }
    else if (v.kind == 1) { v.b ? "true" : "false" }
    else if (v.kind == 2) { v.s }
    else if (v.kind == 3) { esc_str(v.s) }
    else if (v.kind == 4) { "[]" }
    else { "{}" }
};

// ── WORKAROUND, and it is a filed bug ─────────────────────────────────────
//
// This emitter is ITERATIVE, with an explicit stack of open containers,
// and it is that on purpose.
//
// `s += t` on a `str` is documented as amortised O(1) (NATIVE.md, "Owned
// strings"), and it measures that way -- 1.6 MB of appends cost 4.2 MB of
// heap -- but ONLY while no nested append to the same variable happens.
// The ownership flag the fast path is built on is cleared by every READ of
// the variable, and a nested append necessarily reads it, so the moment a
// second function (or a recursive call) appends to the accumulator the
// fast path is gone for good and every later append copies the whole
// buffer. Building a string that way is quadratic in memory.
//
// A recursive pretty-printer is exactly that shape: emit_at appends, calls
// itself, then appends again. On the pinned compiler a 130 KB JSON
// document took 2.7 GB of heap that way and died on the 3.5 GiB cap; this
// version of the same emitter walks the tree with a stack of
// (container, next-child index, depth) and never leaves the one function,
// so every append stays adjacent and the whole emit is linear.
//
// Filed as "str += stops growing in place once a nested append touches the
// same variable" -- see examples/BUGS.md. Do not "simplify" this back into
// recursion without re-reading that entry: the output would be identical
// and the memory would not be.

let em_sv: [JVal] = [];     // the open container
let em_si: [long] = [];     // its next child's index
let em_sd: [long] = [];     // its depth

def render(v: JVal, pretty: bool, indent: long, sorted: bool) -> str {
    em_out = [];
    em_pretty = pretty;
    em_indent = indent;
    em_sort = sorted;
    em_sv = [];
    em_si = [];
    em_sd = [];
    let seeded = false;
    let go = true;
    while (go) {
        if (!seeded) {
            // The root: a container opens itself and joins the stack, and a
            // scalar -- or an EMPTY container -- is just written.
            seeded = true;
            if (v.kind == 4 && len(v.items) > 0) {
                em_put("[");
                em_sv += v;
                em_si += 0;
                em_sd += 0;
            } else if (v.kind == 5 && len(v.fields) > 0) {
                em_put("{");
                push_object(v, 0);
            } else {
                em_put(leaf_text(v))
            }
        } else if (len(em_si) == 0) {
            go = false;
        } else {
            let top = len(em_si) - 1;
            let cont = em_sv[top];
            let i = em_si[top];
            let d = em_sd[top];
            let obj = cont.kind == 5;
            let n = len(cont.fields);
            if (!obj) { n = len(cont.items); };
            if (i < n) {
                em_si[top] = i + 1;
                if (i > 0) { em_put(","); };
                if (em_pretty) {
                    em_put("\n");
                    em_put(ind(d + 1));
                };
                // An object's `items` is the shared EMPTY_J, so it must not
                // be indexed at all: read the FIELD, not the element.
                let ch = j_null();
                if (obj) {
                    let fld = cont.fields[i];
                    ch = fld.v;
                    if (em_pretty) {
                        em_put(esc_str(fld.k) + ": ");
                    } else {
                        em_put(esc_str(fld.k) + ":")
                    }
                } else {
                    ch = cont.items[i]
                };
                if (ch.kind == 4 && len(ch.items) > 0) {
                    em_put("[");
                    em_sv += ch;
                    em_si += 0;
                    em_sd += d + 1;
                } else if (ch.kind == 5 && len(ch.fields) > 0) {
                    em_put("{");
                    push_object(ch, d + 1);
                } else {
                    em_put(leaf_text(ch))
                }
            } else {
                // This container is finished: close it and pop.
                let tail = "]";
                if (cont.kind == 5) { tail = "}"; };
                if (em_pretty) { em_put("\n"); em_put(ind(d)); };
                em_put(tail);
                em_sv = em_sv[0:top];
                em_si = em_si[0:top];
                em_sd = em_sd[0:top]
            }
        }
    };
    from_bytes(em_out)
};

// push_object(v: JVal, d: long) -> void -- open an object and put it on
// the stack. With --sort-keys the object that gets walked is a NEW record
// holding the sorted fields, because records are REFERENCES in Y: `let
// src = v; src.fields = ...` would reorder the caller's document, and
// --sort-keys must not change anything except the output bytes.
def push_object(v: JVal, d: long) -> void {
    let src = v;
    if (em_sort) {
        src = { kind: 5, b: false, n: 0, s: "", items: EMPTY_J, fields: sort_fields(v.fields) }
    };
    em_sv += src;
    em_si += 0;
    em_sd += d
};

// ── structural comparison ─────────────────────────────────────────────────
//
// same(a, b) is the property the self-test leans on: two parses of one
// document are the SAME VALUE, not the same bytes. Numbers compare on
// their token text, which is stricter than comparing values and is the
// right strictness here because the parser preserves the text.

def same(a: JVal, b: JVal) -> bool {
    let r = false;
    if (a.kind != b.kind) {
        r = false;
    } else if (a.kind == 0) {
        r = true;
    } else if (a.kind == 1) {
        r = a.b == b.b;
    } else if (a.kind == 2 || a.kind == 3) {
        r = a.s == b.s;
    } else if (a.kind == 4) {
        r = len(a.items) == len(b.items);
        let i = 0;
        while (r && i < len(a.items)) {
            if (!same(a.items[i], b.items[i])) { r = false; };
            i = i + 1;
        };
    } else {
        r = len(a.fields) == len(b.fields);
        let i = 0;
        while (r && i < len(a.fields)) {
            if (a.fields[i].k != b.fields[i].k || !same(a.fields[i].v, b.fields[i].v)) { r = false; };
            i = i + 1;
        };
    };
    r
};

// same_unordered(a, b) -- like same(), but object KEYS may come in any
// order. `same` is deliberately order sensitive, because preserving key
// order is one of the two things this model exists to do; this is the
// comparison for the one operation that deliberately reorders (--sort-keys).
def same_unordered(a: JVal, b: JVal) -> bool {
    let r = false;
    if (a.kind != b.kind) {
        r = false;
    } else if (a.kind == 0 || (a.kind >= 1 && a.kind <= 3)) {
        r = same(a, b);
    } else if (a.kind == 4) {
        r = len(a.items) == len(b.items);
        let i = 0;
        while (r && i < len(a.items)) {
            if (!same_unordered(a.items[i], b.items[i])) { r = false; };
            i = i + 1;
        };
    } else {
        r = len(a.fields) == len(b.fields);
        let i = 0;
        while (r && i < len(a.fields)) {
            // A linear scan per key: j_get is O(fields), so this is
            // O(fields^2) over an object. There is no map in Y to make it
            // cheaper, and at document scale that does not matter.
            let f = j_get(b, a.fields[i].k);
            if (!is_some(f) || !same_unordered(a.fields[i].v, unwrap(f))) { r = false; };
            i = i + 1;
        };
    };
    r
};

// node_count(v: JVal) -> long -- nodes in a document, for --stats.
def node_count(v: JVal) -> long {
    let c = 1;
    if (v.kind == 4) {
        let i = 0;
        while (i < len(v.items)) { c = c + node_count(v.items[i]); i = i + 1; };
    } else if (v.kind == 5) {
        let i = 0;
        while (i < len(v.fields)) { c = c + node_count(v.fields[i].v); i = i + 1; };
    };
    c
};

// max_depth(v: JVal) -> long -- how many levels of array or object nest
// BELOW v, so a scalar is 0 and {"a": [1]} is 1.
def max_depth(v: JVal) -> long {
    let d = 0;
    if (v.kind == 4) {
        let i = 0;
        while (i < len(v.items)) {
            let k = max_depth(v.items[i]);
            if (k > d) { d = k; };
            i = i + 1;
        };
        d = d + 1;
    } else if (v.kind == 5) {
        let i = 0;
        while (i < len(v.fields)) {
            let k = max_depth(v.fields[i].v);
            if (k > d) { d = k; };
            i = i + 1;
        };
        d = d + 1;
    };
    d
};

// ── lookup and query ──────────────────────────────────────────────────────
//
// Both are a LINEAR SCAN of the field list. There is no hash map in Y
// (ORCHESTRATOR.md 2.8), so a lookup into an object with k keys costs O(k)
// and nothing here pretends otherwise.

def j_get(o: JVal, key: str) -> JVal? {
    let r: JVal? = none;
    if (o.kind == 5) {
        let i = 0;
        let go = true;
        while (i < len(o.fields) && go) {
            if (o.fields[i].k == key) { r = some(o.fields[i].v); go = false; };
            i = i + 1;
        };
    };
    r
};

// q_err -- the diagnosis from the last lookup() call.
let q_err = "";

def fail_q(msg: str) { q_err = msg; };

// lookup(root: JVal, path: str) -> JVal?
//
// The path is dot-separated, with `[n]` suffixes: `a.b[2].c`. An empty path
// is the document itself. Anything that does not resolve is `none` with
// q_err set, so the caller can tell "absent" from "broken" and print a
// message that says which.
def lookup(root: JVal, path: str) -> JVal? {
    q_err = "";
    let cur = root;
    let todo = path;
    let go = todo != "";
    while (go) {
        // A segment is `name` followed by zero or more `[n]` suffixes.
        // The NAME resolves against the current value first, then the
        // indices apply to what it named -- so `a.b[2]` is b, then [2],
        // and not "index a, the object, with 2".
        let seg = todo;
        let rest = "";
        let dot = todo.index_of(".");
        if (dot >= 0) {
            seg = todo[0:dot];
            rest = todo[dot + 1:len(todo)];
        };
        let name = seg;
        let idxs = "";
        let br = seg.index_of("[");
        if (br >= 0) {
            name = seg[0:br];
            idxs = seg[br:len(seg)];
        };
        if (q_err == "" && name != "") {
            if (cur.kind != 5) {
                fail_q("cannot read the key " + p_quote(name) + " out of " + kind_name(cur.kind));
            } else {
                let f = j_get(cur, name);
                if (is_some(f)) { cur = unwrap(f); } else { fail_q("no key " + p_quote(name) + " here"); };
            };
        };
        let ip = idxs;
        while (q_err == "" && ip != "") {
            let rb = ip.index_of("]");
            if (rb < 1) {
                fail_q("'" + ip + "' has a '[' with no ']'");
            } else {
                let inner = ip[1:rb];
                if (!all_digits(inner)) {
                    fail_q("'" + inner + "' is not an index");
                } else {
                    let idx = tolong(inner);
                    if (cur.kind != 4) {
                        fail_q("cannot index " + kind_name(cur.kind) + " with [" + tostring(idx) + "]");
                    } else if (idx >= len(cur.items)) {
                        fail_q("index " + tostring(idx) + " is out of range for a length of " +
                               tostring(len(cur.items)));
                    } else {
                        cur = cur.items[idx];
                        ip = ip[rb + 1:len(ip)]
                    };
                };
            };
        };
        todo = rest;
        go = q_err == "" && todo != "";
    };
    if (q_err == "") { some(cur) } else { none }
};

// kind_name(k: long) -> str -- how a value is named in a diagnostic.
def kind_name(k: long) -> str {
    let s = "a value";
    if (k == 0) { s = "null"; }
    else if (k == 1) { s = "a boolean"; }
    else if (k == 2) { s = "a number"; }
    else if (k == 3) { s = "a string"; }
    else if (k == 4) { s = "an array"; }
    else if (k == 5) { s = "an object"; };
    s
};

// scalar_text(v: JVal) -> str -- a leaf as plain text, for --op=text.
def scalar_text(v: JVal) -> str {
    let s = "";
    if (v.kind == 0) { s = "null"; }
    else if (v.kind == 1) { s = v.b ? "true" : "false"; }
    else if (v.kind == 2 || v.kind == 3) { s = v.s; }
    else if (v.kind == 4) { s = "an array of " + tostring(len(v.items)) + " items"; }
    else { s = "an object of " + tostring(len(v.fields)) + " keys"; };
    s
};

export { JField, JVal, MAX_DEPTH, HEXD, putb, same_unordered, leaf_text, EMPTY_J, EMPTY_F, j_null, j_bool, j_num, j_str, j_arr, j_obj, j_int, num_isint, parse, parse_ok, parse_err, p_desc, p_q, hex4, p_quote, esc_str, sort_fields, render, same, node_count, max_depth, j_get, lookup, q_err, kind_name, scalar_text, put_utf8 };