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
// the sibling that builds the string (SUGGESTIONS.md 11).

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
