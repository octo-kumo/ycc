// json.y -- a hand-rolled JSON reader that works in place over bytes.
//
//   import json;
//
//   if (!json.doc(body, len(body))) { eputs("bad JSON: " + json.err + "\n") };
//   let at = json.member(body, 0, len(body), "qty");
//   let qty = json.int_at(body, at, len(body));    // json.iok says if
//
// Y ships no JSON module and no cast syntax (ORCHESTRATOR.md 2.4c), and
// the arena never frees, so this parses bytes and hands back **offsets**:
// nothing here allocates, not a string, not an array, not a record. That
// is what lets the client read a response, print it and throw it away
// without the heap growing, and it is why every function but `text_is`
// takes `str` only for a key to compare against.
//
// The buffer convention is the point of the exact fixed size: every
// function takes `b: [byte; 65536]`, which is the size of the client's
// response buffer and of the server's request buffer, so the compiler
// refuses to hand this module a buffer nobody checked.
//
// ── the shape of it ───────────────────────────────────────────────────
//
// A *value* is scanned by `value`, which returns the offset just past it
// or -1 with `err`/`errpos` naming the byte that stopped it. Everything
// else is a walk using that one primitive:
//
//   doc()      the whole document is one value, then only whitespace
//   member()   the value a key holds in an object
//   nth_member()/nmembers()   the object's keys, in order, for a walk
//   elem()/nelems()           the array's elements, in order
//   int_at()   an integer, refusing 3.5 rather than truncating to 3
//   text_into() a string, escapes decoded into a caller's fixed buffer
//
// `err` is cleared by `doc` and set on failure, so check the return value
// rather than the flag.

const CAP = 65536;            // the fixed size every buffer here shares
const MAXDEPTH = 32;          // a hostile document cannot blow the stack

// ── the last call's complaint ──────────────────────────────────────────
let err = "";                 // "" when happy
let errpos = 0;               // the byte offset it is about
let ival = 0;                 // int_at's value
let iok = false;              // int_at / text_is say yes or no

def fail(why: str, at: long) -> long {
    err = why;
    errpos = at;
    0 - 1
};

def is_digit(c: long) -> bool { c >= 48 && c <= 57 };
def is_ws(c: long) -> bool { c == 32 || c == 9 || c == 10 || c == 13 };

def hexval(c: long) -> long {
    if (c >= 48 && c <= 57) { c - 48 } else {
        if (c >= 97 && c <= 102) { c - 102 + 10 } else {
            if (c >= 65 && c <= 70) { c - 65 + 10 } else { 0 - 1 }
        }
    }
};

// skip whitespace inside [p, end)
def ws(b: [byte; 65536], p: long, end: long) -> long {
    let i = p;
    while (i < end && is_ws(b[i])) { i = i + 1; };
    i
};

// ── the scalars ────────────────────────────────────────────────────────

// A string starting at the quote at p: its bytes with escapes checked,
// its closing quote. Returns the offset just past it, or -1.
def scan_str(b: [byte; 65536], p: long, end: long) -> long {
    if (p >= end || b[p] != 34) { return fail("expected a string", p) };
    let i = p + 1;
    let done = false;
    while (i < end && !done) {
        let c = b[i];
        if (c == 34) {
            i = i + 1;
            done = true;
        } else if (c == 92) {
            // \\ \" \/ \b \f \n \r \t and \uXXXX -- nothing else
            if (i + 1 >= end) { return fail("string ends inside an escape", i) };
            let k = b[i + 1];
            if (k == 117) {
                if (i + 5 >= end) { return fail("short \\u escape", i) };
                let d = 0;
                while (d < 4) {
                    if (hexval(b[i + 2 + d]) < 0) { return fail("bad hex in \\u escape", i + 2 + d) };
                    d = d + 1;
                };
                i = i + 6;
            } else if (k == 34 || k == 92 || k == 47 || k == 98 || k == 102 ||
                       k == 110 || k == 114 || k == 116) {
                i = i + 2;
            } else {
                return fail("unknown escape", i + 1);
            }
        } else if (c < 32) {
            return fail("raw control byte in a string", i);
        } else {
            i = i + 1;
        };
    };
    if (!done) { fail("string never closed", p) } else { i }
};

// A number in JSON grammar: -? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?
def scan_num(b: [byte; 65536], p: long, end: long) -> long {
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
    if (good) { i } else { fail("expected a number", p) }
};

def scan_lit(b: [byte; 65536], p: long, end: long, s: str) -> long {
    let n = len(s);
    if (p + n > end) { return fail("truncated literal", p) };
    let i = 0;
    let same = true;
    while (i < n) {
        if (b[p + i] != s[i]) { same = false; };
        i = i + 1;
    };
    if (same) { p + n } else { fail("expected " + s, p) }
};

// One value of any kind. `depth` is passed down rather than kept in a
// module variable so a caller cannot forget to reset it.
def value(b: [byte; 65536], p: long, end: long, depth: long) -> long {
    let i = ws(b, p, end);
    if (depth > MAXDEPTH) { return fail("nested too deeply", i) };
    if (i >= end) { return fail("a value was expected", i) };
    let c = b[i];
    if (c == 123) {
        // { "k": v , ... }
        let j = ws(b, i + 1, end);
        if (j < end && b[j] == 125) { return j + 1; };
        let go = true;
        while (go) {
            j = scan_str(b, ws(b, j, end), end);
            if (j < 0) { go = false; } else {
                j = ws(b, j, end);
                if (j >= end || b[j] != 58) {
                    fail("expected : after a key", j);
                    go = false;
                } else {
                    j = value(b, j + 1, end, depth + 1);
                    if (j < 0) {
                        go = false;
                    } else {
                        j = ws(b, j, end);
                        if (j >= end) {
                            fail("object never closed", i);
                            go = false;
                        } else if (b[j] == 125) {
                            j = j + 1;
                            go = false;
                        } else if (b[j] == 44) {
                            // a trailing comma lands here: ws skips the
                            // space, then a } where a key belongs
                            j = ws(b, j + 1, end);
                            if (j < end && b[j] == 125) {
                                fail("trailing comma in an object", j);
                                go = false;
                            } else {
                                j = ws(b, j, end);
                                if (j < end && b[j] != 34) {
                                    fail("a key must be a quoted string", j);
                                    go = false;
                                };
                            }
                        } else {
                            fail("expected , or } in an object", j);
                            go = false;
                        }
                    }
                }
            }
        };
        if (err != "") { 0 - 1 } else { j }
    } else if (c == 91) {
        // [ v , ... ]
        let j = ws(b, i + 1, end);
        if (j < end && b[j] == 93) { return j + 1; };
        let go = true;
        while (go) {
            j = value(b, j, end, depth + 1);
            if (j < 0) {
                go = false;
            } else {
                j = ws(b, j, end);
                if (j >= end) {
                    fail("array never closed", i);
                    go = false;
                } else if (b[j] == 93) {
                    j = j + 1;
                    go = false;
                } else if (b[j] == 44) {
                    j = ws(b, j + 1, end);
                    if (j < end && b[j] == 93) {
                        fail("trailing comma in an array", j);
                        go = false;
                    }
                } else {
                    fail("expected , or ] in an array", j);
                    go = false;
                }
            }
        };
        if (err != "") { 0 - 1 } else { j }
    } else if (c == 34) {
        scan_str(b, i, end)
    } else if (c == 116) {
        scan_lit(b, i, end, "true")
    } else if (c == 102) {
        scan_lit(b, i, end, "false")
    } else if (c == 110) {
        scan_lit(b, i, end, "null")
    } else {
        scan_num(b, i, end)
    }
};

// ── the document ───────────────────────────────────────────────────────

// The whole of b[at:end] is exactly one JSON value and nothing else.
// `at` exists because the HTTP server parses the body where it actually
// landed inside one big read buffer -- rbuf[0:head_end] is the head and
// the body starts at body_at -- while a client parsing its own reply sees
// the document at offset 0. doc() below is the at==0 case.
def doc_at(b: [byte; 65536], at: long, end: long) -> bool {
    err = "";
    errpos = at;
    if (end <= at) {
        err = "the body is empty";
        errpos = at;
        return false;
    };
    let p = ws(b, at, end);
    if (p >= end) {
        err = "the body is only whitespace";
        errpos = p;
        return false;
    };
    let after = value(b, p, end, 0);
    if (after < 0) { return false; };
    let tail = ws(b, after, end);
    if (tail != end) {
        err = "trailing bytes after the value";
        errpos = tail;
        return false;
    };
    true
};

// The whole of b[0:len] is exactly one JSON value and nothing else.
// false sets err/errpos -- an empty body is malformed, not an empty
// document, which is what makes a 204 distinguishable from a bad reply.
def doc(b: [byte; 65536], len0: long) -> bool { doc_at(b, 0, len0) };

// ── objects ────────────────────────────────────────────────────────────

// The value `key` holds in the object at p, or -1 when the object has no
// such key (an absent key is not a parse error, so it leaves err as it
// found it -- which is why the err is cleared here, at entry, rather than
// left over from whatever the caller did before).
def member(b: [byte; 65536], p: long, end: long, key: str) -> long {
    err = "";
    let want = len(key);
    let i = ws(b, p, end);
    if (i >= end || b[i] != 123) { return fail("not an object", i) };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 125) { return 0 - 1; };
    let found = 0 - 1;
    let go = true;
    while (go && found < 0) {
        let k0 = i;
        let k1 = scan_str(b, i, end);
        if (k1 < 0) {
            go = false;
        } else {
            let same = k1 - k0 - 2 == want;
            if (same) {
                let c = 0;
                while (c < want) {
                    // a key this module compares is always a plain one, so
                    // the raw bytes between the quotes are the name
                    if (b[k0 + 1 + c] != key[c]) { same = false; };
                    c = c + 1;
                }
            };
            let colon = ws(b, k1, end);
            if (colon >= end || b[colon] != 58) {
                fail("expected : after a key", colon);
                go = false;
            } else {
                let v = ws(b, colon + 1, end);
                if (same) {
                    found = v;
                } else {
                    let after = value(b, v, end, 1);
                    if (after < 0) {
                        go = false;
                    } else {
                        let k = ws(b, after, end);
                        if (k < end && b[k] == 44) { i = ws(b, k + 1, end); } else { i = k; };
                        if (i >= end) { fail("object never closed", p); go = false; };
                    }
                }
            }
        }
    };
    found
};

// How many keys the object at p holds; -1 if it is not an object.
def nmembers(b: [byte; 65536], p: long, end: long) -> long {
    // every entry point clears err first. Without this a stale message from
    // an *earlier* call poisons the `if (err != "") { -1 }` at the bottom,
    // and a parse that succeeded reports -1 -- which is how "[7,8,9] holds
    // three elements" came out -1 right after a call that had legitimately
    // failed on a fraction.
    err = "";
    let i = ws(b, p, end);
    if (i >= end || b[i] != 123) { return fail("not an object", i) };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 125) { return 0; };
    let n = 0;
    let go = true;
    while (go) {
        let k1 = scan_str(b, i, end);
        if (k1 < 0) { go = false; } else {
            let colon = ws(b, k1, end);
            if (colon >= end || b[colon] != 58) { fail("expected : after a key", colon); go = false; } else {
                i = value(b, colon + 1, end, 1);
                if (i < 0) {
                    go = false;
                } else {
                    n = n + 1;
                    i = ws(b, i, end);
                    if (i >= end) { fail("object never closed", p); go = false; }
                    else if (b[i] == 125) { go = false; }
                    else if (b[i] == 44) { i = ws(b, i + 1, end); }
                    else { fail("expected , or } in an object", i); go = false; }
                }
            }
        }
    };
    if (err != "") { 0 - 1 } else { n }
};

// The `want`-th key's value, with the key's bytes copied into `key` (a
// caller's fixed buffer, so this allocates nothing) -- or -1 when the
// object has no `want`-th member. This is the walk a round-trip check
// needs: every key the server sent, one at a time, in order.
def nth_member(b: [byte; 65536], p: long, end: long, want: long, key: [byte; 64]) -> long {
    err = "";
    let i = ws(b, p, end);
    if (i >= end || b[i] != 123) { return fail("not an object", i) };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 125) { return 0 - 1; };
    let n = 0;
    let found = 0 - 1;
    let go = true;
    while (go && found < 0) {
        let k0 = i;
        let k1 = scan_str(b, i, end);
        if (k1 < 0) {
            go = false;
        } else {
            let klen = k1 - k0 - 2;
            if (klen >= 64) { fail("a key longer than 63 bytes", k0); go = false; } else {
                let c = 0;
                while (c < klen) {
                    key[c] = b[k0 + 1 + c];
                    c = c + 1;
                };
                key[klen] = 0;
                let colon = ws(b, k1, end);
                if (colon >= end || b[colon] != 58) { fail("expected : after a key", colon); go = false; } else {
                    let v = ws(b, colon + 1, end);
                    if (n == want) {
                        found = v;
                    } else {
                        // n counts the members already stepped over. It has
                        // to advance here: left at 0, the walk compares the
                        // same first member against every `want` and so
                        // returns -1 for anything past member 0.
                        n = n + 1;
                        let after = value(b, v, end, 1);
                        if (after < 0) {
                            go = false;
                        } else {
                            let k = ws(b, after, end);
                            if (k < end && b[k] == 44) { i = ws(b, k + 1, end); } else { i = k; };
                            if (i >= end) { fail("object never closed", p); go = false; };
                        }
                    }
                }
            }
        }
    };
    found
};

// ── arrays ─────────────────────────────────────────────────────────────

// How many elements the array at p holds; -1 if it is not an array.
def nelems(b: [byte; 65536], p: long, end: long) -> long {
    err = "";               // see nmembers: a stale err must not answer here
    let i = ws(b, p, end);
    if (i >= end || b[i] != 91) { return fail("not an array", i) };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 93) { return 0; };
    let n = 0;
    let go = true;
    while (go) {
        i = value(b, i, end, 1);
        if (i < 0) {
            go = false;
        } else {
            n = n + 1;
            i = ws(b, i, end);
            if (i >= end) { fail("array never closed", p); go = false; }
            else if (b[i] == 93) { go = false; }
            else if (b[i] == 44) { i = ws(b, i + 1, end); }
            else { fail("expected , or ] in an array", i); go = false; }
        }
    };
    if (err != "") { 0 - 1 } else { n }
};

// The value of element `want` of the array at p, or -1.
def elem(b: [byte; 65536], p: long, end: long, want: long) -> long {
    err = "";               // see nmembers: a stale err must not answer here
    let i = ws(b, p, end);
    if (i >= end || b[i] != 91) { return fail("not an array", i) };
    i = ws(b, i + 1, end);
    if (i < end && b[i] == 93) { return 0 - 1; };
    let n = 0;
    let found = 0 - 1;
    let go = true;
    while (go && found < 0) {
        if (n == want) {
            found = ws(b, i, end);
        } else {
            let after = value(b, i, end, 1);
            if (after < 0) {
                go = false;
            } else {
                n = n + 1;
                let k = ws(b, after, end);
                if (k >= end) { fail("array never closed", p); go = false; } else {
                    if (b[k] == 93) { go = false; } else { i = k + 1; };
                }
            }
        }
    };
    found
};

// ── values out ─────────────────────────────────────────────────────────

// The integer at p: the value lands in ival, iok says whether it was
// one. A number with a fraction or an exponent is refused rather than
// truncated, so a caller can never quietly read 3 for 3.5.
def int_at(b: [byte; 65536], p: long, end: long) -> long {
    err = "";
    iok = false;
    ival = 0;
    let i = p;
    if (i >= end) { fail("a number was expected", i); return 0; };
    let neg = false;
    if (b[i] == 45) { neg = true; i = i + 1; };
    let digits = 0;
    let over = false;
    while (i < end && is_digit(b[i])) {
        if (ival < 1000000000000) { ival = ival * 10 + (b[i] - 48); } else { over = true; };
        i = i + 1;
        digits = digits + 1;
    };
    if (digits == 0) { fail("no digits in the number", p); return 0; };
    if (over) { fail("integer too large", p); return 0; };
    if (i < end && (b[i] == 46 || b[i] == 101 || b[i] == 69)) {
        fail("not an integer", i);
        return 0;
    };
    // the byte after the digits must end the value: a number is a value,
    // not the front of one, so 12abc is malformed rather than 12
    if (i < end && !(b[i] == 93 || b[i] == 125 || b[i] == 44 || is_ws(b[i]))) {
        fail("junk after the number", i);
        return 0;
    };
    ival = if (neg) { 0 - ival } else { ival };
    iok = true;
    ival
};

// The string at p, escapes decoded, into `out`: how many bytes it wrote,
// or -1. A \uXXXX becomes UTF-8; a surrogate half is refused rather than
// written as a replacement, so a round-trip check cannot pass on a value
// the server never sent.
def text_into(b: [byte; 65536], p: long, end: long, out: [byte; 256]) -> long {
    err = "";
    let i = p;
    if (i >= end || b[i] != 34) { return fail("expected a string", i) };
    i = i + 1;
    let n = 0;
    let done = false;
    while (i < end && !done) {
        let c = b[i];
        if (n >= 256) { return fail("string longer than 255 bytes", p) };
        if (c == 34) {
            done = true;
        } else if (c == 92) {
            if (i + 1 >= end) { return fail("string ends inside an escape", i) };
            let k = b[i + 1];
            i = i + 2;
            if (k == 110) { out[n] = 10; n = n + 1; }
            else if (k == 116) { out[n] = 9; n = n + 1; }
            else if (k == 114) { out[n] = 13; n = n + 1; }
            else if (k == 98) { out[n] = 8; n = n + 1; }
            else if (k == 102) { out[n] = 12; n = n + 1; }
            else if (k == 34 || k == 92 || k == 47) { out[n] = k; n = n + 1; }
            else if (k == 117) {
                if (i + 3 >= end) { return fail("short \\u escape", i - 2) };
                let cp = 0;
                let d = 0;
                while (d < 4) {
                    let h = hexval(b[i + d]);
                    if (h < 0) { return fail("bad hex in \\u escape", i + d) };
                    cp = cp * 16 + h;
                    d = d + 1;
                };
                i = i + 4;
                if (cp >= 55296 && cp <= 57343) { return fail("a surrogate half is not a character", i - 6) };
                if (cp < 128) {
                    out[n] = cp; n = n + 1;
                } else if (cp < 2048) {
                    out[n] = 192 + (cp / 64); n = n + 1;
                    out[n] = 128 + (cp % 64); n = n + 1;
                } else {
                    out[n] = 224 + (cp / 4096); n = n + 1;
                    out[n] = 128 + ((cp / 64) % 64); n = n + 1;
                    out[n] = 128 + (cp % 64); n = n + 1;
                }
            } else {
                return fail("unknown escape", i - 1);
            }
        } else {
            out[n] = c;
            n = n + 1;
            i = i + 1;
        }
    };
    if (!done) { fail("string never closed", p); 0 - 1 } else { n }
};

// Is the string at p exactly `s`? `s` carries no escapes -- it is one of
// the short fixed words this client compares (a type, an error name).
def text_is(b: [byte; 65536], p: long, end: long, s: str) -> bool {
    err = "";
    let want = len(s);
    let i = p;
    if (i >= end || b[i] != 34) { fail("expected a string", i); return false; };
    let same = i + 1 + want < end && b[i + 1 + want] == 34;
    if (same) {
        let c = 0;
        while (c < want) {
            if (b[i + 1 + c] != s[c]) { same = false; };
            c = c + 1;
        }
    };
    same
};

// Is the value at p the JSON literal true or false? 1, 0, or -1 when it is
// not a boolean at all (err says why, iok is false). This exists because
// text_is() above only matches a *quoted* word, so a real JSON boolean --
// the one a REST body is supposed to carry -- would have to be written
// "done":"true", which is a string, not a boolean.
def bool_at(b: [byte; 65536], p: long, end: long) -> long {
    err = "";
    iok = false;
    let i = ws(b, p, end);
    if (scan_lit(b, i, end, "true") >= 0) {
        iok = true;
        1
    } else if (scan_lit(b, i, end, "false") >= 0) {
        iok = true;
        0
    } else {
        fail("expected true or false", i);
        0 - 1
    }
};

export {
    CAP, MAXDEPTH, err, errpos, ival, iok,
    fail, is_digit, is_ws, hexval, ws, value, doc, doc_at,
    member, nmembers, nth_member, nelems, elem, int_at, text_into, text_is,
    bool_at
};
