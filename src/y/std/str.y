// std/str.y — the helpers behind the string methods (`s.pad_left(8)`) and
// behind f-string format specs (`f"{x:>8.2f}"`, the y_fmt_* defs).
//
// types.y str_method maps each method of a str to a builtin (`s.split(",")`
// is split(s, ",")) or to one of the defs here, which the emitter calls by
// label like any runtime helper (the y_ prefix, see std/rt.y). native.y
// embeds this file and splices it in front of a program that mentions one
// of str_names() -- the method names these defs serve -- or has an
// f-string field with a spec, so other programs neither carry it nor pay
// to parse it.
//
// Rules on top of rt.y's:
//   - NO STRING LITERALS. A literal's bytes go in .rodata whether or not
//     its def survives tree shaking (prune_bodies drops code, not data),
//     and the splice is a textual match: a program with a variable named
//     `count` gets this file too. Without literals that costs compile time
//     and nothing in the binary. An empty string is s[0:0].
//   - NO RECORD VALUES, for the same reason: a record type's descriptor
//     goes in .rodata too (y_fmt_exact/y_fmt_places are two defs, not
//     one returning { d, f }).
//   - widths, counts and positions are in BYTES, like len() and slicing.
//   - whitespace is what trim() strips: space, tab, newline, CR.

def y_str_ws(c: long) -> bool {
    c == 32 || c == 9 || c == 10 || c == 13
};

def y_str_trim_start(s: str) -> str {
    let n = len(s);
    let i = 0;
    while (i < n && y_str_ws(byte_at(s, i))) { i = i + 1; };
    if (i == 0) { s } else { s[i:n] }
};

def y_str_trim_end(s: str) -> str {
    let n = len(s);
    let j = n;
    while (j > 0 && y_str_ws(byte_at(s, j - 1))) { j = j - 1; };
    if (j == n) { s } else { s[0:j] }
};

// p occurs in s at byte offset `at`.
def y_str_at(s: str, p: str, at: long) -> bool {
    let m = len(p);
    if (at < 0 || at + m > len(s)) {
        false
    } else {
        let j = 0;
        while (j < m && byte_at(s, at + j) == byte_at(p, j)) { j = j + 1; };
        j == m
    }
};

// KMP's failure table for p: fail[i] is the length of the longest proper
// prefix of p that is also a suffix of p[0:i]. Built once per search and
// reused, which is the whole point: it turns "does p match here" from m
// comparisons into one, so a scan costs the haystack and not the haystack
// times the needle.
def y_str_fail(p: str) -> [long] {
    let m = len(p);
    let f: [long] = [];
    let i = 0;
    while (i < m) { f += 0; i = i + 1; };
    // f[0] is 0 from the fill; each f[j] is assigned, never appended
    let k = 0;
    let j = 1;
    while (j < m) {
        if (byte_at(p, k) == byte_at(p, j)) {
            f[j] = k + 1;
            k = k + 1;
            j = j + 1;
        } else if (k > 0) {
            k = f[k - 1];
        } else {
            j = j + 1;
        };
    };
    f
};

// The first match of p in s at or after `from`, or -1. `f` is p's failure
// table (the caller's: count and replace build it once and scan many times).
// A short remainder is walked window by window, which beats the table when
// there is barely a window to read.
def y_str_scan(s: str, p: str, f: [long], from: long) -> long {
    let n = len(s);
    let m = len(p);
    let at = -1;
    if (m > 0 && from < n) {
        if (n - from < m + m) {
            let i = from;
            while (i + m <= n && at < 0) {
                if (y_str_at(s, p, i)) { at = i; };
                i = i + 1;
            };
        } else {
            let k = 0;
            let i = from;
            while (i < n && at < 0) {
                let c = byte_at(s, i);
                while (k > 0 && c != byte_at(p, k)) { k = f[k - 1]; };
                if (c == byte_at(p, k)) { k = k + 1; };
                if (k == m) { at = i + 1 - m; };
                i = i + 1;
            };
        };
    };
    at
};

// last_index_of: the last match of p in s, -1 when absent; an empty needle
// never matches, and overlaps count. One pass over the haystack with the
// match length carried along, keeping the last hit -- the scan resumes where
// it left off rather than starting over, so overlaps cost nothing.
// (index_of, split and trim are assembly: arch_x64.y y_str_index,
// y_str_split, y_str_trim -- this one lives here, next to the scan it is
// built on, and native.y reaches it by label.)
def y_str_lastidx(s: str, p: str, from: long) -> long {
    let n = len(s);
    let m = len(p);
    let found = -1;
    if (m > 0 && m <= n) {
        // `from` past the last place a match can begin (which is what the
        // two-argument caller passes: LONG_MAX) means the whole string, so
        // the one-argument method is exactly the old scan.
        let lim = from;
        if (lim > n - m) { lim = n - m; };
        let f = y_str_fail(p);
        let k = 0;
        let i = 0;
        let stop = lim + m;
        while (i < stop) {
            let c = byte_at(s, i);
            while (k > 0 && c != byte_at(p, k)) { k = f[k - 1]; };
            if (c == byte_at(p, k)) { k = k + 1; };
            if (k == m) { found = i + 1 - m; k = f[m - 1]; };
            i = i + 1;
        };
    };
    found
};

def y_str_starts_with(s: str, p: str) -> bool { y_str_at(s, p, 0) };

def y_str_ends_with(s: str, p: str) -> bool { y_str_at(s, p, len(s) - len(p)) };

// An empty t is in every string (index_of never matches one).
def y_str_contains(s: str, t: str) -> bool { len(t) == 0 || index_of(s, t) >= 0 };

// Non-overlapping matches, left to right; an empty t counts 0.
def y_str_count(s: str, t: str) -> long {
    let m = len(t);
    let n = len(s);
    let c = 0;
    if (m > 0 && m <= n) {
        // one failure table for the whole haystack (see y_str_scan): the
        // matches are non-overlapping, as before, but a miss costs one
        // comparison instead of comparing the needle again
        let f = y_str_fail(t);
        let i = 0;
        while (i + m <= n) {
            let at: long = y_str_scan(s, t, f, i);
            if (at < 0) { i = n; } else { c = c + 1; i = at + m; };
        };
    };
    c
};

// Every non-overlapping `pat`, left to right, becomes `rep`; an empty pat
// leaves s as it is.
def y_str_replace(s: str, pat: str, rep: str) -> str {
    let m = len(pat);
    let n = len(s);
    let parts: [str] = [];
    let start = 0;
    if (m > 0) {
        let f = y_str_fail(pat);          // as in y_str_count
        let i = 0;
        while (i + m <= n) {
            let at: long = y_str_scan(s, pat, f, i);
            if (at < 0) {
                i = n;
            } else {
                parts += s[start:at];
                parts += rep;
                i = at + m;
                start = i;
            };
        };
    };
    if (start == 0) {
        s
    } else {
        parts += s[start:n];
        join(parts, s[0:0])
    }
};

// ASCII letters only; every other byte is kept.
def y_str_upper(s: str) -> str { y_str_case(s, 97, 122, -32) };

def y_str_lower(s: str) -> str { y_str_case(s, 65, 90, 32) };

// The bytes in [lo, hi] moved by d.
def y_str_case(s: str, lo: long, hi: long, d: long) -> str {
    let b = bytes(s);
    let n = len(b);
    let i = 0;
    while (i < n) {
        let c = b[i];
        if (c >= lo && c <= hi) { b[i] = c + d; };
        i = i + 1;
    };
    from_bytes(b)
};

// n copies of s back to back (empty for n <= 0).
// prelude.s: a zeroed [byte] of n bytes, and a front-to-back copy that
// repeats what it has just written when its source is closer than its length.
ndef y_bytes_zero(n: long) -> [byte] = "y_bytes_zero";
ndef y_copy_fwd(dst: *byte, src: *byte, n: long) -> long = "y_copy_fwd";

// n copies of s: one copy of its bytes, then one forward copy over the rest
// of the buffer from its start, which repeats them. A count whose bytes do not
// fit a long is out of memory, like any other request that large.
def y_str_repeat(s: str, n: long) -> str {
    let m = len(s);
    if (n <= 0 || m == 0) { return s[0:0]; };
    let total = n * m;
    if (total / m != n) { total = -1; };
    let out = y_bytes_zero(total);
    let b = bytes(s);
    y_copy_fwd(out.ptr, b.ptr, m);
    y_copy_fwd(out.ptr + m, out.ptr, total - m);
    from_bytes(out)
};

// `fill` repeated and cut to exactly k bytes (k > 0, fill not empty).
//
// The count is a division and a remainder, not `(k + f - 1) / f`: that sum
// overflows for a width near 2^63 and comes out negative, y_str_repeat
// answers "" for a negative count, and the padding silently vanished --
// "7".pad_left(9223372036854775807, "abc") gave "7", where the same width
// with a one-byte fill (no overflow) tried to allocate and trapped with "out
// of memory". Now both ask for the same number of bytes and trap alike, which
// is the honest answer for a width of 2^63.
def y_str_fill(fill: str, k: long) -> str {
    let f = len(fill);
    let n = k / f;
    if (k % f > 0) { n = n + 1; };
    y_str_repeat(fill, n)[0:k]
};

// Pad to `width` bytes with `fill`, repeated and cut where it overruns.
// A string already that wide, or an empty fill, comes back as it is.
def y_str_pad_left(s: str, width: long, fill: str) -> str {
    let k = width - len(s);
    if (k <= 0 || len(fill) == 0) { s } else { y_str_fill(fill, k) + s }
};

def y_str_pad_right(s: str, width: long, fill: str) -> str {
    let k = width - len(s);
    if (k <= 0 || len(fill) == 0) { s } else { s + y_str_fill(fill, k) }
};

// The odd byte of padding goes on the right.
def y_str_center(s: str, width: long, fill: str) -> str {
    let k = width - len(s);
    if (k <= 0 || len(fill) == 0) {
        s
    } else {
        let l = k / 2;
        let r = y_str_fill(fill, k - l);
        if (l == 0) { s + r } else { y_str_fill(fill, l) + s + r }
    }
};

// Cut at each newline (byte 10). A CR right before it goes too (CRLF
// text), and a final newline does not start one more, empty, line.
def y_str_lines(s: str) -> [str] {
    let out: [str] = [];
    let n = len(s);
    let start = 0;
    let i = 0;
    while (i < n) {
        if (byte_at(s, i) == 10) {
            out += y_str_line(s, start, i);
            start = i + 1;
        };
        i = i + 1;
    };
    if (start < n) { out += y_str_line(s, start, n); };
    out
};

// s[a:b] less one trailing CR.
def y_str_line(s: str, a: long, b: long) -> str {
    if (b > a && byte_at(s, b - 1) == 13) { s[a:b - 1] } else { s[a:b] }
};

// ── format specs: f"{x:>8.2f}" ───────────────────────────────────────────
// native.y gen_fmt calls these for an f-string field with a spec, which it
// read at compile time (types.y fmt_spec) and packed into `code` with its
// defaults resolved (native.y fmt_code):
//   code % 256          the type: s d x X o b c f F e E %
//   code / 256 % 256    the fill byte
//   code / 65536 % 256  the alignment: < > ^ or = (fill after the sign)
//   code / 16777216     sign + 4 * alt + 8 * grouping: sign 0 (`-` only),
//                       1 (`+`) or 2 (a space), alt the `#` flag,
//                       grouping 0, 1 (`,`) or 2 (`_`)
// A width or precision < 0 is none.

// pre (a sign, a 0x) and body, padded to `width`.
def y_fmt_pad(pre: str, body: str, code: long, width: long) -> str {
    let k = width - len(pre) - len(body);
    if (k <= 0) {
        pre + body
    } else {
        let f = chr(code / 256 % 256);
        let a = code / 65536 % 256;
        if (a == 60) { pre + body + y_str_repeat(f, k) }
        else if (a == 94) { y_str_repeat(f, k / 2) + pre + body + y_str_repeat(f, k - k / 2) }
        else if (a == 61) { pre + y_str_repeat(f, k) + body }
        else { y_str_repeat(f, k) + pre + body }
    }
};

// s, cut to `prec` bytes.
def y_fmt_s(s: str, code: long, width: long, prec: long) -> str {
    if (prec >= 0 && prec < len(s)) {
        y_fmt_pad(s[0:0], s[0:prec], code, width)
    } else {
        y_fmt_pad(s[0:0], s, code, width)
    }
};

// What goes in front of a number: `-` when it is negative, otherwise what
// the spec asks for -- nothing (e, an empty string), `+` or a space.
def y_fmt_sign(neg: bool, code: long, e: str) -> str {
    let sg = code / 16777216 % 4;
    if (neg) { chr(45) } else if (sg == 1) { chr(43) } else if (sg == 2) { chr(32) } else { e }
};

// d x X o b c.
def y_fmt_i(v: long, code: long, width: long) -> str {
    let ty = code % 256;
    let e = chr(48)[0:0];
    if (ty == 99) {
        y_fmt_pad(e, chr(v), code, width)
    } else {
        let base = 10;
        if (ty == 120 || ty == 88) { base = 16; } else if (ty == 111) { base = 8; } else if (ty == 98) { base = 2; }
        let pre = y_fmt_sign(v < 0, code, e);
        let g = 3;
        if (base != 10) {
            // `#`: 0x 0X 0o 0b
            if (code / 16777216 / 4 % 2 == 1) { pre = pre + chr(48) + chr(ty); }
            g = 4;
        }
        y_fmt_num(pre, y_fmt_digits(v, base, ty == 88), e, code, width, g)
    }
};

// The digits of |v| in base 2, 8, 10 or 16 (`up`: A-F). Taken on the
// negative side, where every long has a twin (the most negative one has
// none on the other).
def y_fmt_digits(v: long, base: long, up: bool) -> str {
    let q = v;
    if (q > 0) { q = 0 - q; }
    let a = 87;
    if (up) { a = 55; }
    let out: [str] = [];
    let go = true;
    while (go) {
        let r = 0 - q % base;
        if (r < 10) { out *= chr(48 + r); } else { out *= chr(a + r); };
        q = q / base;
        go = q != 0;
    };
    join(out, chr(48)[0:0])
};

// pre (a sign, a 0x) + the integer digits d, in groups of g when the spec
// asks, + rest (a fraction, an exponent, a `%`), padded. Zero padding
// (fill 0, alignment =) goes into the digits, so the separators run
// through it as Python's do: f"{1234:010,}" is 00,001,234.
def y_fmt_num(pre: str, d: str, rest: str, code: long, width: long, g: long) -> str {
    let gr = code / 16777216 / 8;
    if (gr == 0) {
        y_fmt_pad(pre, d + rest, code, width)
    } else {
        let sep = chr(44);
        if (gr == 2) { sep = chr(95); }
        let ds = d;
        let out = y_fmt_group(ds, sep, g);
        if (code / 256 % 65536 == 15664) {
            // fill 48 + 256 * alignment 61
            while (len(pre) + len(out) + len(rest) < width) {
                ds = chr(48) + ds;
                out = y_fmt_group(ds, sep, g);
            };
        }
        y_fmt_pad(pre, out + rest, code, width)
    }
};

// d with sep between groups of g digits, counted from the right.
def y_fmt_group(d: str, sep: str, g: long) -> str {
    let n = len(d);
    if (n <= g) {
        d
    } else {
        let parts: [str] = [];
        let i = n % g;
        if (i > 0) { parts += d[0:i]; }
        while (i < n) {
            parts += d[i:i + g];
            i = i + g;
        };
        join(parts, sep)
    }
};

// f F e E and % (multiplied by 100 already) from the float's IEEE-754
// bits, which the emitter passes as a long. The digits are exact -- the
// binary value written out in decimal -- and rounded half to even, so a
// float prints as Python prints it: f"{0.125:.2f}" is 0.12, f"{0.1:.20f}"
// 0.10000000000000000555.
def y_fmt_f(bits: long, code: long, width: long, prec: long) -> str {
    let ty = code % 256;
    let alt = code / 16777216 / 4 % 2 == 1;
    let e = chr(48)[0:0];
    let pct = e;
    if (ty == 37) { pct = chr(37); }
    let neg = bits < 0;
    let b = bits;
    if (neg) { b = bits + 9223372036854775807 + 1; }
    let ex = b / 4503599627370496;
    let m = b % 4503599627370496;
    if (ex == 2047) {
        // inf and nan: no digits to group or zero-fill, and a nan no `-`
        if (m != 0) { neg = false; }
        y_fmt_pad(y_fmt_sign(neg, code, e), y_fmt_word(m == 0, ty == 70 || ty == 69) + pct, code, width)
    } else {
        if (ex == 0) { ex = 1; } else { m = m + 4503599627370496; };
        let d = y_fmt_exact(m, ex - 1075);
        let f = y_fmt_places(m, ex - 1075);
        if (ty == 101 || ty == 69) {
            y_fmt_sci(y_fmt_sign(neg, code, e), d, f, code, width, prec, alt, ty == 69)
        } else {
            y_fmt_fixed(y_fmt_sign(neg, code, e), d, f, code, width, prec, alt, pct)
        }
    }
};

// inf or nan, in capitals for F and E.
def y_fmt_word(inf: bool, up: bool) -> str {
    let d = 0;
    if (up) { d = 32; }
    if (inf) { chr(105 - d) + chr(110 - d) + chr(102 - d) } else { chr(110 - d) + chr(97 - d) + chr(110 - d) }
};

// m * 2^e (0 <= m < 2^53) in decimal: the value is d / 10^f, f =
// y_fmt_places(m, e), and d has no leading zeros (it is "0" for zero).
// (Two functions, not one returning a record: a record type's descriptor
// would stay in every binary that splices this file.)
def y_fmt_exact(m: long, e: long) -> str {
    let mm = m;
    let ee = e;
    while (ee < 0 && mm > 0 && mm % 2 == 0) {
        mm = mm / 2;
        ee = ee + 1;
    };
    let limbs: [long] = [mm % 1000000000, mm / 1000000000];
    if (mm == 0) {
    } else if (ee >= 0) {
        let k = ee;
        while (k >= 30) {
            y_fmt_mul(limbs, 1073741824);
            k = k - 30;
        };
        y_fmt_mul(limbs, y_fmt_pow(2, k));
    } else {
        let k = 0 - ee;
        while (k >= 13) {
            y_fmt_mul(limbs, 1220703125);
            k = k - 13;
        };
        y_fmt_mul(limbs, y_fmt_pow(5, k));
    };
    y_fmt_limbs(limbs)
};

// The decimal places of m * 2^e: one per binary place left once the
// trailing zero bits are gone.
def y_fmt_places(m: long, e: long) -> long {
    let mm = m;
    let ee = e;
    while (ee < 0 && mm > 0 && mm % 2 == 0) {
        mm = mm / 2;
        ee = ee + 1;
    };
    if (mm > 0 && ee < 0) { 0 - ee } else { 0 }
};

def y_fmt_pow(b: long, k: long) -> long {
    let p = 1;
    let i = 0;
    while (i < k) {
        p = p * b;
        i = i + 1;
    };
    p
};

// limbs *= k (k < 2^31): base 10^9, the least significant limb first.
def y_fmt_mul(limbs: [long], k: long) -> long {
    let c = 0;
    let i = 0;
    let n = len(limbs);
    while (i < n) {
        let t = limbs[i] * k + c;
        limbs[i] = t % 1000000000;
        c = t / 1000000000;
        i = i + 1;
    };
    while (c > 0) {
        limbs += c % 1000000000;
        c = c / 1000000000;
    };
    0
};

def y_fmt_limbs(limbs: [long]) -> str {
    let top = len(limbs) - 1;
    while (top > 0 && limbs[top] == 0) { top = top - 1; };
    let parts: [str] = [];
    parts += tostring(limbs[top]);
    let i = top - 1;
    while (i >= 0) {
        parts += y_str_pad_left(tostring(limbs[i]), 9, chr(48));
        i = i - 1;
    };
    join(parts, chr(48)[0:0])
};

// The first `keep` (>= 1) digits of d, rounded half to even by the rest;
// one digit longer when the rounding carries out of the front (99.7 ->
// 100), and zeros added when d is shorter.
def y_fmt_round(d: str, keep: long) -> str {
    let n = len(d);
    if (keep >= n) {
        d + y_str_repeat(chr(48), keep - n)
    } else {
        let nx = byte_at(d, keep);
        let up = nx > 53;
        if (nx == 53) {
            let j = keep + 1;
            while (j < n && byte_at(d, j) == 48) { j = j + 1; };
            up = j < n || byte_at(d, keep - 1) % 2 == 1;
        }
        if (up) {
            let b = bytes(d[0:keep]);
            let i = keep - 1;
            while (i >= 0 && b[i] == 57) {
                b[i] = 48;
                i = i - 1;
            };
            if (i >= 0) {
                b[i] = b[i] + 1;
                from_bytes(b)
            } else {
                chr(49) + from_bytes(b)
            }
        } else {
            d[0:keep]
        }
    }
};

// f and %: prec digits after the point (pct is the `%` or nothing).
def y_fmt_fixed(sign: str, d: str, f: long, code: long, width: long, prec: long, alt: bool, pct: str) -> str {
    let dd = d;
    if (len(dd) <= f) { dd = y_str_repeat(chr(48), f + 1 - len(dd)) + dd; }
    let r = y_fmt_round(dd, len(dd) - f + prec);
    let ip = len(r) - prec;
    let rest = pct;
    if (prec > 0 || alt) { rest = chr(46) + r[ip:len(r)] + pct; }
    y_fmt_num(sign, r[0:ip], rest, code, width, 3)
};

// e and E: a digit, the point and prec more, then the exponent -- signed,
// two digits at least.
def y_fmt_sci(sign: str, d: str, f: long, code: long, width: long, prec: long, alt: bool, up: bool) -> str {
    let x = 0;
    let r = y_str_repeat(chr(48), prec + 1);
    if (len(d) > 1 || byte_at(d, 0) != 48) {
        x = len(d) - f - 1;
        r = y_fmt_round(d, prec + 1);
        if (len(r) > prec + 1) { r = r[0:prec + 1]; x = x + 1; }
    }
    let ex = chr(101);
    if (up) { ex = chr(69); }
    if (x < 0) { ex = ex + chr(45); x = 0 - x; } else { ex = ex + chr(43); };
    if (x < 10) { ex = ex + chr(48); }
    ex = ex + tostring(x);
    let rest = ex;
    if (prec > 0 || alt) { rest = chr(46) + r[1:len(r)] + ex; }
    y_fmt_num(sign, r[0:1], rest, code, width, 3)
};
