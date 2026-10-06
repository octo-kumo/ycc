// sink.y -- the deterministic text output path.
//
// Everything this example prints with --no-tty goes through here: one fixed
// [byte; CAP] buffer, one write(2) when it fills or when asked, no `str`, no
// formatting library, no heap.  The reason is the same as everywhere else in
// this campaign -- the heap is an arena and nothing is ever freed
// (ORCHESTRATOR.md 2.7), so a `str` built per frame is a leak, and --soak
// measures heap_used() across whole solves.
//
// WHY NOT print() AND f-strings.  `print()` is println: it appends a newline
// to every argument, so a 24-cell row printed a character at a time would come
// out as 24 one-character LINES (measured, and it is the reason maze's sink
// exists).  puts() would be correct but allocates a string per call.  A buffer
// of bytes plus an integer formatter is the only way to write a frame of text
// without touching the heap.
//
// The digit scratch is module level for the sharp edge of that rule: an ARRAY
// LITERAL is evaluated onto the heap every time the expression runs, so a
// literal written inside out_num() would leak 192 bytes per call.

import tiles;
import wfc;

const CAP: long = 262144;        // 256 KiB: enough for every --frames dump at once
let ob: [byte; 262144] = [0; 262144];
let on: long = 0;
let written: long = 0;

let NBUF: [long; 24] = [48; 24];
let NMAXV: long = 999999999999999;     // 15 nines: past every count here

// sink_byte(b) -- append one byte, spilling first if the buffer is full.  A
// spill mid-line is harmless: stdout is a byte stream and nothing here is
// position-addressed.
def sink_byte(b: long) -> void {
    if (on >= CAP) { sink_flush() };
    ob[on] = b & 255;
    on = on + 1
};

def sink_str(t: str) -> void {
    let n = len(t);
    let i = 0;
    while (i < n) {
        sink_byte(byte_at(t, i));
        i = i + 1
    }
};

def sink_nl() -> void { sink_byte(10) };

// digits(v) -> long -- how many decimal digits v has, at least 1.  Written
// without a table so it cannot be wrong about 0 or about a value wider than any
// table would be.
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

// sink_num(v) -- a non-negative decimal, any width.  Values past NMAXV are
// CLAMPED rather than truncated: a truncated count reads as a real one, and a
// clamped one at least says "this is at least 999999999999999".
def sink_num(v: long) -> void {
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
        sink_byte(NBUF[i]);
        i = i + 1
    }
};

// sink_int(v) -- a SIGNED decimal.  sink_num deliberately clamps a negative to
// zero, because every count in this example is a count; but `--seed=-1` is a
// legal command line and printing it as 0 would be a lie about what the program
// did, so the one field that can be negative gets its own formatter.
def sink_int(v: long) -> void {
    if (v < 0) {
        sink_byte(45);
        sink_num(0 - v)
    } else {
        sink_num(v)
    }
};

// sink_pad(v, w) -- right-align a number in w columns, so the columns line up.
def sink_pad(v: long, w: long) -> void {
    let n = if (v < 0) { 0 } else { v };
    let d = digits(n);
    let k = d;
    while (k < w) {
        sink_byte(32);
        k = k + 1
    };
    sink_num(n)
};

// sink_hex16(v) -- sixteen hex digits of a signed long, most significant first.
// The shifts are `>>>` (logical) so a negative FNV state prints its two's
// complement nibbles instead of a wall of f's.  A 64-bit shift count is a trap
// at run time (ORCHESTRATOR.md 2.10), so the loop never asks for one: it walks
// down from 15 by one.
def sink_hex16(v: long) -> void {
    let i = 15;
    while (i >= 0) {
        let d = (v >>> (i * 4)) & 15;
        if (d < 10) { sink_byte(48 + d) } else { sink_byte(87 + d) };
        i = i - 1
    }
};

// sink_q30(v, dp) -- a Q30 fixed-point value with `dp` decimal places.
//
// There is no float->long conversion in Y at all (ORCHESTRATOR.md 2.4a), so a
// fraction is printed by integer arithmetic: the fraction bits are scaled by
// 10^dp and shifted back down.  10^3 * 2^30 is about 1.07e12, which fits a long
// with room to spare, so no wide multiply is needed.  The shifts are `>>>` on
// purpose: a negative entropy would otherwise print as a huge unsigned number.
def sink_q30(v: long, dp: long) -> void {
    let neg = 0;
    let n = v;
    if (n < 0) { neg = 1; n = 0 - n };
    let scale = 1;
    let d = 0;
    while (d < dp) {
        scale = scale * 10;
        d = d + 1
    };
    if (neg == 1) { sink_byte(45) };
    sink_num(n >>> 30);
    sink_byte(46);
    let frac = (n & 1073741823) * scale;
    // Round to nearest so 0.9999 does not print as 0.9999 with dp = 3.
    let whole = (frac + 536870912) / 1073741824;
    if (whole >= scale) {
        // The rounding carried: print 1.000 rather than 10.000.
        sink_num(1 + (n >>> 30));
        sink_byte(46);
        sink_pad(0, dp)
    } else {
        sink_pad(whole, dp)
    }
};

// sink_flush() -> void -- the one write(2).  fd 1, no buffer, the bytes we hold.
def sink_flush() -> void {
    if (on > 0) {
        syscall(1, 1, &ob[0], on);
        written = written + on;
        on = 0
    }
};

// ───────────────────────────────────────────────────────────────────────────
// the grid painter
//
// One character per cell, ASCII only -- no escape sequences, no colour, which
// is what belongs in a diff and what EXPECTED holds.  The characters are the
// tile's socket pattern in a mnemonic alphabet:
//
//   .  no socket        |  N+S            -  E+W
//   L  N+E (└)          7  E+S (┌)        J  S+W (┐)        F  W+N (┘)
//   +  three sockets    *  four sockets
//
// The tui painter draws the same sixteen tiles as real box-drawing
// codepoints (└ ┌ ┐ ┘ │ ─), so the terminal picture and this text are the same
// picture; the ASCII is a lossy but total stand-in, and tiles.ASC / tiles.GLY
// are the only place the two encodings exist.

// paint() -> void -- the whole grid as text.
//
// A cell with more than one tile still in its mask -- one the search has not
// reached -- is drawn as '?', so a frame is honest about what is known.  The
// two are distinguishable because a FINISHED grid has no '?' at all, which
// check.y asserts, and because a collapsed tile is always drawn from its
// singleton mask.
def paint() -> void {
    let y = 0;
    while (y < wfc.GH) {
        let x = 0;
        while (x < wfc.GW) {
            let i = y * wfc.GW + x;
            let m = wfc.MASK[i];
            if (wfc.CNT[i] == 1) {
                sink_byte(tiles.ASC[wfc.first_bit(m)]);
            } else {
                sink_byte(open_char(wfc.HENT[i]))
            };
            x = x + 1
        };
        sink_nl();
        y = y + 1
    }
};

// open_char(h) -> long -- the character for a cell the search has not reached.
//
// Four characters, none of which any tile uses, bucketed by the cell's Shannon
// entropy: the closer a cell is to being forced, the nearer the character is to
// a colon.  That makes the propagation FRONT visible in a text dump -- a frame of
// all-identical characters says nothing, and a frame where the constrained cells
// stand out in a ring shows the algorithm working.  It also puts the possibility
// sets into the frame digest, so a digest that moves without the picture moving
// is still a change worth seeing.
//
// The characters are picked from what the sixteen tiles do NOT use: the tile
// alphabet is . | - L 7 J F + *, so : = ~ # are free.
def open_char(h: long) -> long {
    // h is Q30; the buckets are 1, 2 and 3 bits, so compare against those
    // shifted up -- integer constants, no fixed-point division anywhere.
    if (h < 1073741824) { return 58 };         // < 1 bit: ':'
    if (h < 2147483648) { return 61 };         // < 2 bits: '='
    if (h < 3221225472) { return 126 };        // < 3 bits: '~'
    35                                           // 3 bits or more: '#'
};

// paint_hash() -> long -- FNV-1a over exactly the bytes paint() would emit, so
// the digest in a frame header is the digest OF THE PICTURE and can be compared
// by eye against a diff of the grid below it.  A digest of something else is
// the classic way a golden file stops meaning anything.
def paint_hash() -> long {
    let h = 0 - 3750763034362895579;          // FNV offset basis, as a signed long
    let y = 0;
    while (y < wfc.GH) {
        let x = 0;
        while (x < wfc.GW) {
            let i = y * wfc.GW + x;
            let c = open_char(wfc.HENT[i]);
            if (wfc.CNT[i] == 1) { c = tiles.ASC[wfc.first_bit(wfc.MASK[i])] };
            h = h ^ c;
            h = h * 1099511628211;
            x = x + 1
        };
        h = h ^ 10;
        h = h * 1099511628211;
        y = y + 1
    };
    h
};

export { CAP, sink_byte, sink_str, sink_nl, sink_num, sink_int,
         sink_pad, sink_hex16, sink_q30, sink_flush,
         digits, paint, open_char, paint_hash };