// std/str.y — the helpers behind the string methods (`s.pad_left(8)`).
//
// types.y str_method maps each method of a str to a builtin (`s.split(",")`
// is split(s, ",")) or to one of the defs here, which the emitter calls by
// label like any runtime helper (the y_ prefix, see std/rt.y). native.y
// embeds this file and splices it in front of a program that mentions one
// of str_names() -- the method names these defs serve -- so other programs
// neither carry it nor pay to parse it.
//
// Rules on top of rt.y's:
//   - NO STRING LITERALS. A literal's bytes go in .rodata whether or not
//     its def survives tree shaking (prune_bodies drops code, not data),
//     and the splice is a textual match: a program with a variable named
//     `count` gets this file too. Without literals that costs compile time
//     and nothing in the binary. An empty string is s[0:0].
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

def y_str_starts_with(s: str, p: str) -> bool { y_str_at(s, p, 0) };

def y_str_ends_with(s: str, p: str) -> bool { y_str_at(s, p, len(s) - len(p)) };

// An empty t is in every string (index_of never matches one).
def y_str_contains(s: str, t: str) -> bool { len(t) == 0 || index_of(s, t) >= 0 };

// Non-overlapping matches, left to right; an empty t counts 0.
def y_str_count(s: str, t: str) -> long {
    let m = len(t);
    let n = len(s);
    let c = 0;
    let i = 0;
    if (m > 0) {
        while (i + m <= n) {
            if (y_str_at(s, t, i)) { c = c + 1; i = i + m; 0; } else { i = i + 1; 0; };
        };
        0
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
    let i = 0;
    if (m > 0) {
        while (i + m <= n) {
            if (y_str_at(s, pat, i)) {
                parts += s[start:i];
                parts += rep;
                i = i + m;
                start = i;
                0
            } else { i = i + 1; 0; };
        };
        0
    };
    if (start == 0) {
        s
    } else {
        parts += s[start:n];
        join(parts, s[0:0])
    }
};

// ASCII letters only; every other byte is kept.
def y_str_upper(s: str) -> str { y_str_case(s, 97, 122, 0 - 32) };

def y_str_lower(s: str) -> str { y_str_case(s, 65, 90, 32) };

// The bytes in [lo, hi] moved by d.
def y_str_case(s: str, lo: long, hi: long, d: long) -> str {
    let b = bytes(s);
    let n = len(b);
    let i = 0;
    while (i < n) {
        let c = b[i];
        if (c >= lo && c <= hi) { b[i] = c + d; 0; };
        i = i + 1;
    };
    from_bytes(b)
};

// n copies of s back to back (empty for n <= 0).
def y_str_repeat(s: str, n: long) -> str {
    let parts: [str] = [];
    let i = 0;
    while (i < n) {
        parts += s;
        i = i + 1;
    };
    join(parts, s[0:0])
};

// `fill` repeated and cut to exactly k bytes (k > 0, fill not empty).
def y_str_fill(fill: str, k: long) -> str {
    let f = len(fill);
    y_str_repeat(fill, (k + f - 1) / f)[0:k]
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
            0
        };
        i = i + 1;
    };
    if (start < n) { out += y_str_line(s, start, n); 0; };
    out
};

// s[a:b] less one trailing CR.
def y_str_line(s: str, a: long, b: long) -> str {
    if (b > a && byte_at(s, b - 1) == 13) { s[a:b - 1] } else { s[a:b] }
};
