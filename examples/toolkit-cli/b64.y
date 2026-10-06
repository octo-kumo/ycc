// b64.y -- RFC 4648 section 4 base64, written from scratch.
//
// Y has NO base64 encoder anywhere in the tree (ORCHESTRATOR.md 2.14):
// `x509.b64_decode` exists and nothing encodes. So both directions live
// here. `x509.b64_decode` is still the cross-check -- selftest.y feeds
// this module's encoder to it and demands the same bytes back, which
// makes the two independent implementations agree.
//
// ── three language facts this file works around ──────────────────────────
//
// WORKAROUND 1 (compiler bug, examples/BUGS.md): `s[i]` on a `str` is a
// BYTE and `str + byte` SEGFAULTS. So no `ALPHA[group]` may be typed as a
// char; the alphabet is a `[str]` array instead, indexed by the 6-bit
// group, which is well typed and needs no byte-to-str coercion.
//
// WORKAROUND 2 (language gap): there is no cast syntax at all, so
// `byte` values are produced at an ANNOTATED SITE and nowhere else.
// Every byte this module appends goes through put_byte().
//
// WORKAROUND 3 (no `break`/`continue`, ORCHESTRATOR.md 2.9): both loops
// are written with the positive-condition form and a guard flag.

let ALPHA: [str] = [
    "A", "B", "C", "D", "E", "F", "G", "H",
    "I", "J", "K", "L", "M", "N", "O", "P",
    "Q", "R", "S", "T", "U", "V", "W", "X",
    "Y", "Z", "a", "b", "c", "d", "e", "f",
    "g", "h", "i", "j", "k", "l", "m", "n",
    "o", "p", "q", "r", "s", "t", "u", "v",
    "w", "x", "y", "z", "0", "1", "2", "3",
    "4", "5", "6", "7", "8", "9", "+", "/"
];

// POW2[n] for n in 0..7 -- 2**n without a power operator (there is none).
let POW2: [long] = [1, 2, 4, 8, 16, 32, 64, 128];

// b_value(c: byte) -> long -- the 6-bit value of an alphabet character,
// -1 for anything else (including '=' and whitespace).
def b_value(c: byte) -> long {
    let v = 0 - 1;
    if (c >= 65 && c <= 90) {
        v = c - 65;
    } else if (c >= 97 && c <= 122) {
        v = c - 97 + 26;
    } else if (c >= 48 && c <= 57) {
        v = c - 48 + 52;
    } else if (c == 43) {
        v = 62;
    } else if (c == 47) {
        v = 63;
    };
    v
};

// b_ws(c: byte) -> bool -- the whitespace RFC 4648 section 3.2 says may
// be ignored in the encoded form.
def b_ws(c: byte) -> bool {
    c == 32 || c == 9 || c == 10 || c == 13 || c == 11 || c == 12
};

// put_byte(out: [byte], v: long) -- append one byte. The only place a
// long becomes a byte; see WORKAROUND 2.
def put_byte(out: [byte], v: long) {
    let b: byte = v;
    out += b
};

// ── encoding ──────────────────────────────────────────────────────────────

// encode(b: [byte], wrap: long) -> str
//   wrap 0  one unbroken line (the default, so it composes in a pipe)
//   wrap N  break after N characters; N is clamped to 1..76, the widest
//           multiple of 4 that keeps every line under 76 columns
// A trailing "\n" is always added when there is output, so the result is
// a well-formed text line whether or not wrapping is on.
def encode(b: [byte], wrap: long) -> str {
    let w = wrap;
    if (w < 0) { w = 0; };
    if (w > 76) { w = 76; };
    if (w > 0 && w % 4 != 0) { w = w - (w % 4); };
    if (w > 0 && w < 4) { w = 4; };
    let out = "";
    let n = len(b);
    let i = 0;
    let col = 0;
    let go = true;
    while (go) {
        // One quantum: up to three input bytes.
        let have = 0;
        let g0 = 0;
        let g1 = 0;
        let g2 = 0;
        while (have < 3 && i < n) {
            let v = b[i];
            if (have == 0) { g0 = v; } else if (have == 1) { g1 = v; } else { g2 = v; };
            have = have + 1;
            i = i + 1;
        };
        if (have == 0) {
            go = false;
        } else {
            // The three bytes packed big-endian; the missing ones are 0,
            // which is exactly what the padding bits are.
            let e = g0 * 65536 + g1 * 256 + g2;
            out += ALPHA[e / 262144];
            out += ALPHA[(e / 4096) % 64];
            if (have >= 2) { out += ALPHA[(e / 64) % 64]; } else { out += "="; };
            if (have >= 3) { out += ALPHA[e % 64]; } else { out += "="; };
            col = col + 4;
            if (w > 0 && col >= w) {
                out += "\n";
                col = 0;
            };
        }
    };
    if (col > 0) { out += "\n"; };
    out
};

// ── decoding ──────────────────────────────────────────────────────────────

// The error the last decode() call failed with, "" when it succeeded.
// Module level because decode() cannot return both its bytes and its
// diagnosis.
let dec_err = "";

// decode(s: str, lenient: bool) -> [byte]
//
// Strict by default, which is what a CLI wants: a character outside the
// alphabet (other than whitespace) is an error, not something to skip.
// `lenient` turns those into skipped characters, which is what
// `x509.b64_decode` always does. Either way the padding is checked: '='
// may only appear in the last group and only as "=" or "==", and the
// number of alphabet characters must be a multiple of 4.
//
// Bits are accumulated into a 24-bit window and drained a whole byte at a
// time, which handles the 2-character and 3-character tails with the same
// code path as the full ones; the 2, 4 or 6 bits left over at the end are
// the padding and are discarded.
def decode(s: str, lenient: bool) -> [byte] {
    dec_err = "";
    let out: [byte] = [];
    let n = len(s);
    let acc = 0;
    let nbits = 0;
    let pad = 0;
    let pad_at = 0;
    let bad = 0 - 1;
    let nalpha = 0;
    let i = 0;
    // NOTE: `go` starts as `i < n`, not `true` -- byte_at is bounds
    // checked and an empty string has no byte 0. Every scan loop in this
    // example is written this way.
    let go = n > 0;
    while (go) {
        let c = byte_at(s, i);
        let v = b_value(c);
        if (v >= 0) {
            if (pad > 0 && bad < 0) {
                bad = i;
                dec_err = "a base64 character follows the '=' padding at offset " + tostring(i)
            };
            nalpha = nalpha + 1;
            acc = acc * 64 + v;
            nbits = nbits + 6;
            let more = true;
            while (nbits >= 8 && more) {
                nbits = nbits - 8;
                put_byte(out, (acc / POW2[nbits]) % 256);
                more = nbits > 0;
            };
            acc = acc % POW2[nbits];
        } else if (c == 61) {
            pad = pad + 1;
            pad_at = i;
            if (pad > 2 && bad < 0) {
                bad = i;
                dec_err = "more than two '=' padding characters (first at offset " + tostring(pad_at) + ")"
            };
        } else if (b_ws(c)) {
            0
        } else if (bad < 0) {
            if (lenient) {
                0
            } else {
                bad = i;
                dec_err = t_byte(c) + " is not in the base64 alphabet (at offset " + tostring(i) + ")"
            };
        };
        i = i + 1;
        go = i < n;
    };
    // Padding validity. The only states RFC 4648 allows are
    // (alphabet chars % 4, '=' count) = (0,0), (3,1) or (2,2) -- the
    // '='s are part of the final quantum, so they count toward the
    // multiple of 4. Everything else is rejected by name.
    if (bad < 0 && pad == 0 && nalpha % 4 == 1) {
        bad = n;
        dec_err = "a lone base64 character carries no whole byte";
    };
    if (bad < 0 && pad == 0 && nalpha % 4 != 0) {
        bad = n;
        dec_err = tostring(nalpha) + " base64 characters is not a multiple of 4";
    };
    if (bad < 0 && pad == 1 && nalpha % 4 != 3) {
        bad = n;
        dec_err = "'=' padding does not close a group of 4";
    };
    if (bad < 0 && pad == 2 && nalpha % 4 != 2) {
        bad = n;
        dec_err = "'=' padding does not close a group of 4";
    };
    // A REJECTED decode returns nothing. Returning the bytes it managed to
    // accumulate before the error would let a caller that forgets to read
    // dec_err get a plausible wrong answer, which is worse than an empty
    // one -- and the self-test asserts the empty one.
    let r: [byte] = [];
    if (bad < 0) { r = out; };
    r
};

// t_byte(c: long) -> str -- a byte rendered for a diagnostic: printable
// characters as themselves, everything else as 0xNN. `tostring` on a byte
// would print a number, and the point is to show the offending character.
// The parameter is `long` and not `byte` so the JSON module can reuse this
// for the code points it reads out of a string.
def t_byte(c: long) -> str {
    let s = "";
    if (c >= 33 && c <= 126 && c != 92) {
        s += "'" + chr(c) + "'";
    } else {
        let h = "";
        let d = c / 16;
        let e = c % 16;
        if (d < 10) { h += chr(48 + d); } else { h += chr(87 + d); };
        if (e < 10) { h += chr(48 + e); } else { h += chr(87 + e); };
        s += "0x" + h
    };
    s
};

export { encode, decode, b_value, b_ws, t_byte, dec_err, ALPHA };