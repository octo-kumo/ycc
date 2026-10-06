import tui;
// sink.y -- the deterministic output path for turtle.y.
//
// Everything this program prints goes through here: the headless frame table,
// the dumped frames, the property check's report, and the interactive HUD.  One
// fixed module-level byte buffer, one write(2) when it fills or when asked, no
// `str` and no formatting library -- so nothing about the output depends on how
// a string happened to grow.  That is not a preference: the Y heap is an arena
// and nothing is ever freed (ORCHESTRATOR.md 2.7), so an f-string or a
// tostring() on the frame path would allocate every frame, which is the whole
// thing a renderer is trying to avoid.
//
// print() is deliberately NOT used on the frame path, for two reasons.  It
// appends a newline to every value, so it cannot build one line out of parts;
// and `x + y` on a str is the exact-size copy (y_str_cat), which is the
// quadratic position the campaign's audit counts.  out_* here append in place.


const OB_CAP: long = 65536;
const FNV_SEED: long = -3750763034362895579;   // 14695981039346656037, signed
const FNV_PRIME: long = 1099511628211;

let OB: [byte; 65536] = [0; 65536];
let ON: long = 0;
let WRITTEN: long = 0;

def out_reset() -> void { ON = 0 };

def out_len() -> long { ON };

def out_mark() -> long { ON };

// out_trunc(m) -- throw away everything written since mark m.  The HUD uses it
// to build a line into the shared buffer, blit it into the surface cell by cell
// and then put the buffer back, instead of allocating a str for tui.text.
def out_trunc(m: long) -> void { ON = m };

def out_byte(b: long) -> void {
    if (ON >= OB_CAP) { out_flush() };
    OB[ON] = b & 255;
    ON = ON + 1
};

// ob_at(i) -- byte i of the buffer, for the HUD blit.  -1 out of range.
def ob_at(i: long) -> long {
    if (i < 0 || i >= ON) { return 0 - 1 };
    OB[i]
};

def out_str(t: str) -> void {
    let n = len(t);
    let i = 0;
    while (i < n) {
        out_byte(byte_at(t, i));
        i = i + 1
    }
};

// NBUF -- digit scratch at module level, because an ARRAY LITERAL is evaluated
// onto the heap every time the expression runs (64 bytes, measured) and this
// runs on the frame path.  24 digits is far more than any number here reaches;
// a long holds 19.
let NBUF: [long; 24] = [48; 24];
const NMAXV: long = 999999999999999;        // 15 nines: past every count here

// digits(v) -- how many decimal digits v has, at least 1.  Written without a
// table so it cannot be wrong about 0 or about a value wider than the table.
def digits(v: long) -> long {
    let n = if (v < 0) { 0 } else { v };
    let d = 1;
    let t = n;
    while (t >= 10 && d < 24) {
        t = t / 10;
        d = d + 1
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
        k = k - 1
    };
    let i = 0;
    while (i < d) {
        out_byte(NBUF[i]);
        i = i + 1
    }
};

// out_pad(v, w) -- right-aligned in w columns, for the digest table.
def out_pad(v: long, w: long) -> void {
    let n = if (v < 0) { 0 } else { v };
    let d = digits(n);
    let k = d;
    while (k < w) {
        out_byte(32);
        k = k + 1
    };
    out_num(n)
};

// out_spaces(to) -- pad out to column `to`, for the check's report table.  A
// monospaced report is the only kind that can be read in a diff.
// The target is an ABSOLUTE buffer position, so a caller mid-line passes
// mark + column: the buffer is never reset between lines and a relative pad
// would do nothing after the first one.
def out_spaces(to: long) -> void {
    while (ON < to) { out_byte(32) }
};

// out_snum2(v) -- a signed decimal, for the check's coordinates and the opcode
// dump's negative counts.
def out_snum2(v: long) -> void {
    if (v < 0) { out_byte(45); out_num(0 - v) } else { out_num(v) }
};

// out_hex16(v) -- sixteen hex digits of a signed long, most significant first.
// The shifts are UNSIGNED, so a negative FNV state prints its two's complement
// nibbles instead of a wall of f's.
def out_hex16(v: long) -> void {
    let i = 15;
    while (i >= 0) {
        let d = (v >>> (i * 4)) & 15;
        if (d < 10) { out_byte(48 + d); } else { out_byte(87 + d) };
        i = i - 1
    }
};

// out_glyph(cp) -- a codepoint as UTF-8, for the text dump of a frame.
def out_glyph(cp: long) -> void {
    let c = cp;
    if (c < 0) { c = 32 };
    if (c > 1114111) { c = 65533 };
    let n = tui.utf8_len(c);
    let i = 0;
    while (i < n) {
        out_byte(tui.utf8_byte(c, i));
        i = i + 1
    }
};

def out_flush() -> void {
    if (ON > 0) {
        syscall(1, 1, &OB[0], ON);
        WRITTEN = WRITTEN + ON;
        ON = 0
    }
};

def out_written() -> long { WRITTEN };

// out_capture(fd, n) -- copy fb's first n CAPTURED bytes into a file, in 4096
// byte chunks.  A write(2) per byte would turn a 24 KiB frame into 24000
// syscalls; a 4 KiB staging buffer makes it eight.
let CHUNK: [byte; 4096] = [0; 4096];

def out_capture(fd: long, n: long) -> void {
    let at = 0;
    while (at < n) {
        let take = n - at;
        if (take > 4096) { take = 4096 };
        let i = 0;
        while (i < take) {
            CHUNK[i] = tui.capture_byte(at + i);
            i = i + 1
        };
        syscall(1, fd, &CHUNK[0], take);
        at = at + take
    }
};

// grid_digest(s) -- FNV-1a over every cell's codepoint AND both of its colours,
// so a frame that changed colour but not shape is a different digest.  This is
// the per-frame line in the deterministic output, which is why that line is
// evidence rather than decoration.
def grid_digest(s: tui.Surface) -> long {
    let h: long = FNV_SEED;
    let n = s.rows * s.cols;
    let i = 0;
    while (i < n) {
        h = (h ^ s.ch[i]) * FNV_PRIME;
        h = (h ^ s.fg[i]) * FNV_PRIME;
        h = (h ^ s.bg[i]) * FNV_PRIME;
        i = i + 1
    };
    h
};

// grid_text(s) -- the surface as plain lines: one row per line, one glyph per
// cell, no escape sequences.  This is what the golden frames and the tail of
// the --no-tty output are, so the deterministic output is readable in a diff
// and not merely comparable.
//
// Each glyph goes through tui.utf8_byte into the module-level byte buffer and
// out through one write(2), because there is no other route to a non-ASCII
// character in this language (examples/BUGS.md, "str + byte segfaults", and the
// suggestion filed there: chr() cannot make a glyph outside ASCII).
def grid_text(s: tui.Surface) -> void {
    let r = 0;
    while (r < s.rows) {
        let c = 0;
        while (c < s.cols) {
            out_glyph(s.ch[r * s.cols + c]);
            c = c + 1
        };
        out_byte(10);
        r = r + 1
    }
};

export { OB_CAP, out_reset, out_len, out_mark, out_trunc, ob_at, out_byte,
          out_str, out_num, out_pad, out_spaces, out_snum2, digits, out_hex16, out_glyph, out_flush,
          out_written, out_capture, grid_digest, grid_text };