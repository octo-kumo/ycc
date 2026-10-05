// textout.y -- the deterministic sink behind --no-tty.
//
// Everything the program prints on the --no-tty path goes through this file,
// because that path's whole job is to produce the same bytes every run: one
// fixed output buffer, one write(2) when it fills or when asked, no `str` and
// no formatting library, so nothing depends on how a string happens to grow.
//
// WHY NOT puts() AND f-strings.  Both would be correct and both would be a
// per-call allocation on the frame loop, and the acceptance gate for this
// example is heap_used() unchanged across 300 frames (ORCHESTRATOR.md 2.7).
// A buffer of longs plus fb.utf8_byte is the only way to write a frame of
// Unicode glyphs without touching the heap.
//
// ZERO ALLOCATION, LIKE EVERY FRAME PATH.  `ob` is a module-level fixed
// [byte; OB_CAP] and nothing here builds a string, a record or an array.  The
// digest is FNV-1a over the surface's cells, the same function fb.capture_*
// uses, so the per-frame line in the output is a checksum of what was actually
// drawn rather than a claim about it.

import fb;

const OB_CAP: long = 65536;
const FNV_SEED: long = -3750763034362895579;   // 14695981039346656037, signed
const FNV_PRIME: long = 1099511628211;

let ob: [byte; 65536] = [0; 65536];
let on: long = 0;
let written: long = 0;              // bytes handed to write(2) so far

def out_reset() -> void {
    on = 0
};

def out_len() -> long { on };

// out_byte -- append one byte, spilling first if the buffer is full.  A spill
// mid-frame is harmless: stdout is a byte stream and nothing here is
// position-addressed.
def out_byte(b: long) -> void {
    if (on >= OB_CAP) { out_flush(); };
    ob[on] = b & 255;
    on = on + 1
};

def out_str(t: str) -> void {
    let n = len(t);
    let i = 0;
    while (i < n) {
        out_byte(byte_at(t, i));
        i = i + 1;
    }
};

// NBUF -- digit scratch, module level because an ARRAY LITERAL allocates every
// time the expression runs (72 bytes, measured) and this runs on the frame
// path.  24 digits is far more than any number here can reach; a long holds 19.
let NBUF: [long; 24] = [48; 24];
let NMAXV: long = 999999999999999;    // 15 nines: past every count here

// digits(v) -> long -- how many decimal digits v has, at least 1.  Written
// without a table so it cannot be wrong about 0 or about a value wider than
// the table.
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

// out_num -- a non-negative decimal, any width.  Values past NMAXV are CLAMPED
// rather than truncated: a truncated count reads as a real one, and a clamped
// one at least says ">= 999999999999999".
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

// out_pad -- right-align a number in `w` columns, for the digest table.
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

// out_hex16 -- sixteen hex digits of a signed long, most significant first.
// The shifts are UNSIGNED so a negative FNV state prints its two's complement
// nibbles instead of a wall of f's.
def out_hex16(v: long) -> void {
    let i = 15;
    while (i >= 0) {
        let d = (v >>> (i * 4)) & 15;
        if (d < 10) { out_byte(48 + d); } else { out_byte(87 + d); };
        i = i - 1;
    }
}

// out_glyph -- one cell's codepoint as UTF-8.
def out_glyph(cp: long) -> void {
    let c = cp;
    if (c < 0) { c = 32 };
    if (c > 1114111) { c = 65533 };
    let n = fb.utf8_len(c);
    let i = 0;
    while (i < n) {
        out_byte(fb.utf8_byte(c, i));
        i = i + 1;
    }
};

def out_flush() -> void {
    if (on > 0) {
        syscall(1, 1, &ob[0], on);
        written = written + on;
        on = 0;
    }
};

// grid_digest(s) -> long -- FNV-1a over every cell's codepoint AND its
// foreground colour, so a frame that changed colour but not shape is a
// different digest.  This is what the per-frame line in the deterministic
// output reports, and it is why that line is evidence rather than decoration.
def grid_digest(s: fb.Surface) -> long {
    let h: long = FNV_SEED;
    let n = s.rows * s.cols;
    let i = 0;
    while (i < n) {
        h = (h ^ s.ch[i]) * FNV_PRIME;
        h = (h ^ s.fg[i]) * FNV_PRIME;
        i = i + 1;
    };
    h
};

// grid_text(s) -- the surface as plain lines: one row per line, one glyph per
// cell, no escape sequences at all.  This is what the golden frames and the
// tail of the --no-tty output are, and it is why the deterministic output is
// readable in a diff and not just comparable.
def grid_text(s: fb.Surface) -> void {
    let r = 0;
    while (r < s.rows) {
        let c = 0;
        while (c < s.cols) {
            out_glyph(s.ch[r * s.cols + c]);
            c = c + 1;
        };
        out_byte(10);
        r = r + 1;
    }
};

export { OB_CAP, out_reset, out_len, out_byte, out_str, out_num, out_pad,
          digits,
          out_hex16, out_glyph, out_flush, grid_digest, grid_text };