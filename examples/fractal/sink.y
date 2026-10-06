import tui;
// sink.y -- the deterministic output path behind --no-tty.
//
// Everything the program prints on the headless path goes through this file,
// because that path's whole job is to produce the same bytes every run.  One
// fixed module-level byte buffer, one write(2) when it fills or when asked, no
// `str` and no formatting library, so nothing depends on how a string happens
// to grow.  That is not a preference: the Y heap is an arena and nothing is ever
// freed (ORCHESTRATOR.md 2.7), so an f-string or a tostring() on the frame path
// would allocate every frame -- which is the whole thing the renderer is trying
// to avoid.


const OB_CAP: long = 65536;
const FNV_SEED: long = -3750763034362895579;   // 14695981039346656037, signed
const FNV_PRIME: long = 1099511628211;

let OB: [byte; 65536] = [0; 65536];
let ON: long = 0;
let WRITTEN: long = 0;

def out_reset() -> void {
    ON = 0
};

def out_len() -> long { ON };

def out_byte(b: long) -> void {
    if (ON >= OB_CAP) { out_flush(); };
    OB[ON] = b & 255;
    ON = ON + 1
};

def out_str(t: str) -> void {
    let n = len(t);
    let i = 0;
    while (i < n) {
        out_byte(byte_at(t, i));
        i = i + 1;
    }
};

// NBUF -- digit scratch at module level, because an ARRAY LITERAL is evaluated
// onto the heap every time the expression runs (72 bytes, measured) and this
// runs on the frame path.  24 digits is far more than any number here reaches;
// a long holds 19.
let NBUF: [long; 24] = [48; 24];
let NMAXV: long = 999999999999999;        // 15 nines: past every count here

// digits(v) -- how many decimal digits v has, at least 1.  Written without a
// table so it cannot be wrong about 0 or about a value wider than the table.
def digits(v: long) -> long {
    let n = if (v < 0) { 0 } else { v };
    let d = 1;
    let t = n;
    while (t >= 10 && d < 24) {
        t = t / 10;
        d = d + 1;
    };
    d
};

// out_num(v) -- a non-negative decimal of any width.  Values past NMAXV are
// CLAMPED rather than truncated: a truncated count reads as a real one, and a
// clamped one at least says ">= 999999999999999".
def out_num(v: long) -> void {
    let n = if (v < 0) { 0 } else { if (v > NMAXV) { NMAXV } else { v } };
    let d = digits(n);
    let q = n;
    let k = d;
    while (k > 0) {
        NBUF[k - 1] = 48 + q % 10;
        q = q / 10;
        k = k - 1;
    };
    let i = 0;
    while (i < d) {
        out_byte(NBUF[i]);
        i = i + 1;
    }
};

// out_pad(v, w) -- right-aligned in w columns, for the digest table.
def out_pad(v: long, w: long) -> void {
    let n = if (v < 0) { 0 } else { v };
    let d = digits(n);
    let k = d;
    while (k < w) {
        out_byte(32);
        k = k + 1;
    };
    out_num(n)
};

// out_hex16(v) -- sixteen hex digits of a signed long, most significant first.
// The shifts are UNSIGNED, so a negative FNV state prints its two's complement
// nibbles instead of a wall of f's.
def out_hex16(v: long) -> void {
    let i = 15;
    while (i >= 0) {
        let d = (v >>> (i * 4)) & 15;
        if (d < 10) { out_byte(48 + d); } else { out_byte(87 + d); };
        i = i - 1;
    }
};

def out_glyph(cp: long) -> void {
    let c = cp;
    if (c < 0) { c = 32; };
    if (c > 1114111) { c = 65533; };
    let n = tui.utf8_len(c);
    let i = 0;
    while (i < n) {
        out_byte(tui.utf8_byte(c, i));
        i = i + 1;
    }
};

def out_flush() -> void {
    if (ON > 0) {
        syscall(1, 1, &OB[0], ON);
        WRITTEN = WRITTEN + ON;
        ON = 0;
    }
};

def out_written() -> long { WRITTEN };

// grid_digest(s) -- FNV-1a over every cell's codepoint AND both of its
// colours, so a frame that changed colour but not shape is a different digest.
// This is what the per-frame line in the deterministic output reports, which is
// why that line is evidence rather than decoration.  All three channels matter
// here in a way they do not in most examples: the half-block glyph carries the
// lower half's colour in the cell BACKGROUND, so a lighting change can be a
// background-only change.
// out_capture(fd, n) -- copy fb's first n CAPTURED bytes into a file, in 4096
// byte chunks.  This is how --ansi gets the frame out: the headless path
// otherwise throws the byte stream away.  It copies rather than pointing at
// fb's buffer because fb exposes the capture one byte at a time
// (tui.capture_byte), and a write(2) per byte would turn a 24 KiB frame into
// 24000 syscalls; a 4 KiB staging buffer makes it eight.
let CHUNK: [byte; 4096] = [0; 4096];

def out_capture(fd: long, n: long) -> void {
    let at = 0;
    while (at < n) {
        let take = n - at;
        if (take > 4096) { take = 4096; };
        let i = 0;
        while (i < take) {
            CHUNK[i] = tui.capture_byte(at + i);
            i = i + 1;
        };
        syscall(1, fd, &CHUNK[0], take);
        at = at + take;
    }
};

def grid_digest(s: tui.Surface) -> long {
    let h: long = FNV_SEED;
    let n = s.rows * s.cols;
    let i = 0;
    while (i < n) {
        h = (h ^ s.ch[i]) * FNV_PRIME;
        h = (h ^ s.fg[i]) * FNV_PRIME;
        h = (h ^ s.bg[i]) * FNV_PRIME;
        i = i + 1;
    };
    h
};

// grid_text(s) -- the surface as plain lines: one row per line, one glyph per
// cell, no escape sequences at all.  This is what the golden frames and the
// tail of the --no-tty output are, and it is why the deterministic output is
// readable in a diff and not merely comparable.
//
// Each glyph goes through tui.utf8_byte into the module-level byte buffer, one
// write(2) at the end.  That is not a stylistic choice, it is the third way
// round a hole the language has:
//
//   * the natural `line = line + RAMP[i]` SEGFAULTS -- see examples/BUGS.md,
//     "str + byte segfaults";
//   * the filing's suggested workaround `chr(cp)` does not work for a glyph
//     outside ASCII: chr() is documented in src/y/std/rt.y as the inverse of
//     ord(), and ord() is "the code of the first BYTE", so chr(0x2588) is a
//     one-byte string holding 0x88 -- the low byte of the codepoint, not the
//     character.  Every glyph a renderer wants (the block elements U+2580 and
//     U+2584, U+2588, the braille block from U+2800) is outside ASCII;
//   * and a growable str is a bad idea anyway on an arena heap.
//
// So the buffer it is.  Filed as a suggestion: Y has no way to make a `str` from
// a Unicode codepoint at all.
def grid_text(s: tui.Surface) -> void {
    let r = 0;
    while (r < s.rows) {
        let c = 0;
        while (c < s.cols) {
            out_glyph(s.ch[r * s.cols + c]);
            c = c + 1;
        };
        out_byte(10);
        r = r + 1;
    };
    out_flush()
};

// out_capture(fd, n) -- copy fb's first n CAPTURED bytes into a file, in 4096
// byte chunks.  This is how --ansi gets the frame out: the headless path
// otherwise throws the byte stream away.  It copies rather than pointing at
// fb's buffer because fb exposes the capture one byte at a time
// (tui.capture_byte), and a write(2) per byte would turn a 24 KiB frame into
// 24000 syscalls; a 4 KiB staging buffer makes it eight.
let CHUNK: [byte; 4096] = [0; 4096];

def out_capture(fd: long, n: long) -> void {
    let at = 0;
    while (at < n) {
        let take = n - at;
        if (take > 4096) { take = 4096; };
        let i = 0;
        while (i < take) {
            CHUNK[i] = tui.capture_byte(at + i);
            i = i + 1;
        };
        syscall(1, fd, &CHUNK[0], take);
        at = at + take;
    }
};

export { OB_CAP, out_reset, out_len, out_byte, out_str, out_num, out_pad,
          digits, out_hex16, out_glyph, out_flush, out_written, out_capture,
          out_capture, grid_digest, grid_text };
