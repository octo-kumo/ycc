// std/utf8.y -- the UTF-8 encoding of a codepoint, as a `str`.
// `import utf8;` and call through the namespace: `utf8.chr(0x2588)`.
//
// `chr` (the builtin) is the inverse of `ord`, and `ord` reads a BYTE, so
// `chr(9608)` is faithfully one byte (0x88) and is not the block U+2588 it
// looks like. That is not a bug in `chr` -- regex.y and str.y's number
// formatting depend on it staying byte-exact -- it is a gap in the set of
// tools, and every renderer in the examples campaign filled it by hand with a
// byte buffer and its own encoder (`fb.utf8_byte` writes into the caller's
// array, so a frame of text could not be built as a `str` at all). This is
// the sibling that builds the string.

// The UTF-8 bytes of `cp`, as a str: one to four, by the width table, and the
// empty string for a value that cannot be encoded (negative, or past U+10FFFF). A
// surrogate is encoded rather than rejected: a caller that has a codepoint has
// already decided what it means, and the same three-or-four cases cost less
// than a validation rule nobody asked for.
def chr(cp: long) -> str {
    if (cp < 0) {
        ""
    } else if (cp < 128) {
        let b: [byte; 1] = [0; 1];
        b[0] = cp;
        from_bytes(b)
    } else if (cp < 2048) {
        let b: [byte; 2] = [0; 2];
        b[0] = 192 + cp / 64;
        b[1] = 128 + cp % 64;
        from_bytes(b)
    } else if (cp < 65536) {
        let b: [byte; 3] = [0; 3];
        b[0] = 224 + cp / 4096;
        b[1] = 128 + (cp / 64) % 64;
        b[2] = 128 + cp % 64;
        from_bytes(b)
    } else if (cp < 1114112) {
        let b: [byte; 4] = [0; 4];
        b[0] = 240 + cp / 262144;
        b[1] = 128 + (cp / 4096) % 64;
        b[2] = 128 + (cp / 64) % 64;
        b[3] = 128 + cp % 64;
        from_bytes(b)
    } else {
        ""
    }
};

// How many bytes `chr(cp)` is: 0 for a value it cannot encode. Written out
// rather than measured so a caller can size a buffer without building the
// string.
def len_of(cp: long) -> long {
    if (cp < 0) { 0 }
    else if (cp < 128) { 1 }
    else if (cp < 2048) { 2 }
    else if (cp < 65536) { 3 }
    else if (cp < 1114112) { 4 }
    else { 0 }
};

// The codepoints of `s`, decoding the UTF-8: an invalid byte becomes U+FFFD
// and is consumed one byte at a time, so a caller gets one codepoint per
// position and never a trap (the same rule `strings`/`sed` use).
def codes(s: str) -> [long] {
    let out: [long] = [];
    let n = len(s);
    let i = 0;
    while (i < n) {
        let b0 = byte_at(s, i);
        if (b0 < 128) {
            out += b0;
            i = i + 1;
        } else if (b0 < 224) {
            if (i + 1 < n && byte_at(s, i + 1) >= 128 && byte_at(s, i + 1) < 192) {
                out += (b0 - 192) * 64 + (byte_at(s, i + 1) - 128);
                i = i + 2;
            } else { out += 65533; i = i + 1; };
        } else if (b0 < 240) {
            if (i + 2 < n && byte_at(s, i + 1) >= 128 && byte_at(s, i + 1) < 192
                && byte_at(s, i + 2) >= 128 && byte_at(s, i + 2) < 192) {
                out += (b0 - 224) * 4096 + (byte_at(s, i + 1) - 128) * 64 + (byte_at(s, i + 2) - 128);
                i = i + 3;
            } else { out += 65533; i = i + 1; };
        } else if (b0 < 248) {
            if (i + 3 < n && byte_at(s, i + 1) >= 128 && byte_at(s, i + 1) < 192
                && byte_at(s, i + 2) >= 128 && byte_at(s, i + 2) < 192
                && byte_at(s, i + 3) >= 128 && byte_at(s, i + 3) < 192) {
                out += (b0 - 240) * 262144 + (byte_at(s, i + 1) - 128) * 4096
                + (byte_at(s, i + 2) - 128) * 64 + (byte_at(s, i + 3) - 128);
                i = i + 4;
            } else { out += 65533; i = i + 1; };
        } else {
            out += 65533;
            i = i + 1;
        };
    };
    out
};

// ── a string builder ────────────────────────────────────────────────────
// A render loop builds its frame one glyph at a time. `s += chr(n)` allocates a
// string per glyph and `s += n` is a type error (a `str` takes a `str`), so the
// loop wanted a byte buffer and its own encoder. A Builder is that buffer: the
// pushes append in place (amortized O(1), nothing allocated per glyph) and
// `build` makes the one `str` at the end.
type Builder = { buf: [byte] };

def builder() -> Builder {
    let b: [byte] = [];
    { buf: b }
};

// Appends the low eight bits of `n` as one byte.
def push_byte(sb: Builder, n: long) -> long {
    sb.buf += n & 255;
    0
};

// Appends the UTF-8 of `cp` (chr's width table); a value that cannot be
// encoded appends nothing.
def push_cp(sb: Builder, cp: long) -> long {
    if (cp < 0) {
    } else if (cp < 128) {
        sb.buf += cp;
    } else if (cp < 2048) {
        sb.buf += 192 + cp / 64;
        sb.buf += 128 + cp % 64;
    } else if (cp < 65536) {
        sb.buf += 224 + cp / 4096;
        sb.buf += 128 + (cp / 64) % 64;
        sb.buf += 128 + cp % 64;
    } else if (cp < 1114112) {
        sb.buf += 240 + cp / 262144;
        sb.buf += 128 + (cp / 4096) % 64;
        sb.buf += 128 + (cp / 64) % 64;
        sb.buf += 128 + cp % 64;
    };
    0
};

// Appends the bytes of `s`.
def push_str(sb: Builder, s: str) -> long {
    let n = len(s);
    let i = 0;
    while (i < n) {
        sb.buf += byte_at(s, i);
        i = i + 1;
    };
    0
};

// Appends `n` in decimal, as `tostring(n)` writes it, without making a string.
// The digits are taken from the negative side so that the most negative long,
// which has no positive twin, comes out right.
def push_long(sb: Builder, n: long) -> long {
    let v = n;
    if (n < 0) { sb.buf += 45; } else { v = 0 - n; };
    let start = len(sb.buf);
    let go = true;
    while (go) {
        sb.buf += 48 - v % 10;
        v = v / 10;
        go = v != 0;
    };
    let lo = start;
    let hi = len(sb.buf) - 1;
    while (lo < hi) {
        let t = sb.buf[lo];
        sb.buf[lo] = sb.buf[hi];
        sb.buf[hi] = t;
        lo = lo + 1;
        hi = hi - 1;
    };
    0
};

// The bytes pushed so far, as a str. The builder keeps its contents, so a
// frame can be built, read and extended.
def build(sb: Builder) -> str {
    from_bytes(sb.buf)
};

// Forgets the contents: the next push starts an empty string.
def reset(sb: Builder) -> long {
    let b: [byte] = [];
    sb.buf = b;
    0
};
