// sink.y -- the deterministic text output path.
//
// Everything this example prints with --no-tty goes through here: one fixed
// [byte; CAP] buffer, one write(2) when it fills or when asked, no `str`, no
// formatting library, no heap.  The reason is the same as everywhere else in
// this campaign -- the heap is an arena and nothing is ever freed
// (ORCHESTRATOR.md 2.7), so a `str` built per frame is a leak, and this
// example's gate measures heap_used() across 10 000 solver steps.
//
// WHY NOT puts() AND f-strings.  Both would be correct.  Both are also a heap
// allocation per call, and a 23-line maze frame printed with puts() one line at
// a time is 23 allocations per frame for the life of the process.  A buffer of
// bytes plus an integer formatter is the only way to write a frame of text
// without touching the heap.
//
// The digit scratch is module level for the sharp edge of that rule: an ARRAY
// LITERAL is evaluated onto the heap every time the expression runs, so a
// literal written inside out_num() would leak 192 bytes per call.

import grid;

const CAP = 262144;        // 256 KiB: enough for every --ascii dump at once
let ob: [byte; 262144] = [0; 262144];
let on: long = 0;
let written: long = 0;

let NBUF: [long; 24] = [48; 24];
let NMAXV: long = 999999999999999;     // 15 nines: past every count here

def sink_reset() -> void { on = 0 };

def sink_len() -> long { on };

// sink_byte(b) -- append one byte, spilling first if the buffer is full.  A
// spill mid-line is harmless: stdout is a byte stream and nothing here is
// position-addressed.
def sink_byte(b: long) -> void {
    if (on >= CAP) { sink_flush(); };
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

// sink_pad(v, w) -- right-align a number in w columns, so the columns in the
// comparison table line up.
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

// sink_padl(v, w) -- left-align, for a name column.
def sink_padl(t: str, w: long) -> void {
    sink_str(t);
    let k = len(t);
    while (k < w) {
        sink_byte(32);
        k = k + 1
    }
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
        if (d < 10) { sink_byte(48 + d); } else { sink_byte(87 + d); };
        i = i - 1
    }
};

def sink_flush() -> void {
    if (on > 0) {
        syscall(1, 1, &ob[0], on);
        written = written + on;
        on = 0
    }
};

// ─────────────────────────────────────────────────────────────────────────
// the ASCII painter
//
// One kind per character, ASCII only.  Walls '#' and floors ' ' is the shape
// every maze has been drawn with for forty years; the overlays are '.', '*',
// '@', 'S', 'G'.  Everything here is a literal CHARACTER in the source, so
// there is no byte-indexed table anywhere -- which is also how the `str + byte`
// bug filed in BUGS.md is dodged: nothing in this file ever concatenates a
// byte into a string.
def ascii_of(k: long) -> long {
    let c = 32;
    if (k == grid.K_WALL) { c = 35; }
    else if (k == grid.K_FLOOR) { c = 32; }
    else if (k == grid.K_SEEN) { c = 46; }
    else if (k == grid.K_PATH) { c = 42; }
    else if (k == grid.K_ME) { c = 64; }
    else if (k == grid.K_START) { c = 83; }
    else if (k == grid.K_GOAL) { c = 71; };
    c
};

// sink_maze() -- the whole render buffer as text: one line per row, and a
// trailing newline after the last one so the next section starts on its own
// line.  No escape sequences, no colour: this is what EXPECTED holds and what
// belongs in a diff.
def sink_maze() -> void {
    let y = 0;
    while (y < grid.RH) {
        let x = 0;
        while (x < grid.RW) {
            sink_byte(ascii_of(grid.rk[y * grid.RW + x]));
            x = x + 1
        };
        sink_nl();
        y = y + 1
    }
};

export { CAP, sink_reset, sink_len, sink_byte, sink_str, sink_nl, sink_num, sink_int,
         sink_pad, sink_padl, sink_hex16, sink_flush,
         digits, ascii_of, sink_maze };