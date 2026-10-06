import tui;
// sink.y -- the deterministic output path behind --no-tty, and the text form of
// a frame.
//
// Everything the program prints on the headless path goes through this file,
// because that path's whole job is to produce the same bytes every run.  One
// fixed module-level byte buffer, one write(2) when it fills or when asked, no
// formatting library and no f-string, so nothing here depends on how a string
// happens to grow.  That is not a preference: the Y heap is an arena and
// nothing is ever freed (ORCHESTRATOR.md 2.7), so a tostring() on the frame
// path would allocate every frame, and a `str +=` in a value-used position
// would allocate it O(n^2) (examples/BUGS.md, the heading about a value-used
// append being quadratic).
//
// This is deliberately NOT a copy of fractal's sink.y: it is the same idea with
// a different interface.  Here the numbers are formatted into module-level
// digit scratch and the frame digest is over the cells rather than the byte
// stream, so a text dump and a colour dump have separate checksums.


const OB_CAP: long = 65536;
const FNV_SEED: long = 0 - 3750763034362895579;   // 14695981039346656037
const FNV_PRIME: long = 1099511628211;

let OB: [byte; 65536] = [0; 65536];
let ON: long = 0;
let WRITTEN: long = 0;

def out_byte(b: long) -> void {
    if (ON >= OB_CAP) { out_flush(); };
    OB[ON] = b & 255;
    ON = ON + 1
};

def out_str(t: str) -> void {
    let n = len(t);
    let i = 0;
    while (i < n) {
        OB[ON] = t[i];
        ON = ON + 1;
        if (ON >= OB_CAP) { out_flush(); };
        i = i + 1;
    }
};

// NBUF -- the digit scratch, at module level, because an ARRAY LITERAL is
// evaluated onto the heap every time the expression runs (72 bytes for
// [long; 12], measured) and this runs on the frame path.  24 digits is far
// more than any number here reaches; a long holds 19.
let NBUF: [long; 24] = [48; 24];
let NMAXV: long = 999999999999999;

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

// out_pad(v, w) -- right-aligned in w columns.
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
// nibbles instead of a wall of f's; and v is provably either a byte or a
// mask here, so `>>>` is what it wants.
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

// grid_digest(s) -- FNV-1a 64 over every cell's codepoint AND both of its
// colours.  Both colour channels matter here in a way they do not in most
// examples: the half-block glyph carries the lower half's colour in the cell
// BACKGROUND, so a lighting change can be a background-only change and a
// digest over codepoints alone would call that frame unchanged.
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
// cell, no escape sequences at all.  This is what the golden frames are, and it
// is why the deterministic output is readable in a diff and not merely
// comparable.
//
// Each glyph goes through tui.utf8_byte into the module-level byte buffer and
// leaves through one write(2).  That is the only route to a non-ASCII glyph in
// this language: `line = line + chr(cp)` segfaults (str + byte, examples/
// BUGS.md), and chr() is byte-wide anyway -- chr(9608) is a ONE-byte string
// holding 0x88, because ord() is documented as "the code of the first BYTE".
// Every glyph a renderer wants (the block elements, the braille block from
// U+2800) is outside ASCII.  Filed as SUGGESTIONS: Y has no way to build a
// `str` from a codepoint at all.
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

// out_capture(fd, n) -- copy fb's first n CAPTURED bytes into a file, in 4 KiB
// chunks.  fb exposes the capture one byte at a time, so a write(2) per byte
// would turn a 30 KiB frame into 30000 syscalls; the staging buffer makes it
// eight.  This is how --ansi gets the truecolour frame out.
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

export { OB_CAP, out_byte, out_str, out_num, out_pad, out_hex16, out_glyph,
          out_flush, out_written, grid_digest, grid_text, out_capture, digits };