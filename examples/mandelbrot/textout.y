// textout.y -- the deterministic sink behind --no-tty.
//
// Everything on the --no-tty path that is not a raw cell byte goes through
// this file, because that path's whole job is to produce the same bytes every
// run: ONE fixed output buffer, ONE write(2) when it fills or when it is
// asked, no `str` and no formatting library, so nothing about the output can
// depend on how a string happened to grow or where a map happened to order
// its keys.
//
// WHY NOT puts() AND f-strings.  Both would be correct and both would be a
// per-call allocation on the frame loop, and the acceptance gate for this
// example is that heap_used() does not move across the render.  A buffer of
// bytes plus an integer formatter is the way to write a header and a table of
// digests without touching the heap at all.
//
// ZERO ALLOCATION, LIKE EVERY OTHER FRAME PATH.  `ob` is a module-level
// [byte; 65536] and nothing here builds a string, a record or an array -- the
// digit scratch is a module-level array for the same reason OBUF is, and the
// reason is that an array literal is evaluated onto the heap every
// time the expression runs, so a literal written inside a formatter here would
// leak once per number printed.
//
// out_flush() is the only syscall in the file, and it is write(2) on fd 1
// with an explicit length -- `syscall(1, 1, s, 0)` writes nothing and fails
// silently, so the count is always passed.

const OB_CAP: long = 65536;
const FNV_SEED: long = -3750763034362895579;   // 14695981039346656037, signed

let ob: [byte; 65536] = [0; 65536];
let on: long = 0;
let written: long = 0;              // bytes handed to write(2) so far

// 24 digits: a signed 64-bit long has 19, so this can never overflow, and it
// is big enough that out_num needs no error case.
let NBUF: [long; 24] = [48; 24];

// Values past this are CLAMPED rather than wrapped: a truncated count reads as
// a real one, and a clamped one at least says ">= 999999999999999".
const NMAXV: long = 999999999999999;

def out_reset() -> void {
    on = 0
};

def out_len() -> long { on };
def out_written() -> long { written };

def out_flush() -> void {
    if (on > 0) {
        syscall(1, 1, &ob[0], on);
        written = written + on;
        on = 0
    }
};

// out_byte(b) -- append one byte, spilling first if the buffer is full.  A
// spill mid-line is harmless: stdout is a byte stream and nothing here is
// position-addressed.
def out_byte(b: long) -> void {
    if (on >= OB_CAP) { out_flush(); };
    ob[on] = b & 255;
    on = on + 1
};

// out_str(t) -- a string's bytes verbatim.
def out_str(t: str) -> void {
    let n = len(t);
    let i: long = 0;
    while (i < n) {
        out_byte(byte_at(t, i));
        i = i + 1;
    }
};

// digits(v) -> long -- how many decimal digits v has, at least 1.  Written
// without a table, so it cannot be wrong about 0.
def digits(v: long) -> long {
    let n = if (v < 0) { 0 } else { v };
    let d: long = 1;
    let t = n;
    while (t >= 10 && d < 24) {
        t = t / 10;
        d = d + 1;
    };
    d
};

// out_num(v) -- a non-negative decimal, any width.
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
    let i: long = 0;
    while (i < d) {
        out_byte(NBUF[i]);
        i = i + 1;
    }
};

// out_pad(v, w) -- a non-negative decimal right-aligned in w columns, so the
// columns of the per-frame table line up in a diff.
def out_pad(v: long, w: long) -> void {
    let n = if (v < 0) { 0 } else { if (v > NMAXV) { NMAXV } else { v } };
    let d = digits(n);
    let k = d;
    while (k < w) {
        out_byte(32);
        k = k + 1;
    };
    out_num(n)
};

// out_hex16(v) -- sixteen hex digits of a signed long, most significant first.
// The shift is UNSIGNED, so a negative FNV state prints its two's complement
// nibbles instead of a wall of f's.
def out_hex16(v: long) -> void {
    let i: long = 15;
    while (i >= 0) {
        let d = (v >>> (i * 4)) & 15;
        if (d < 10) { out_byte(48 + d); } else { out_byte(87 + d); };
        i = i - 1;
    }
};

// out_fixed6(v) -- a Q30 value as a signed decimal with exactly six decimals,
// the precision fx.to_str prints, so the per-frame table's span column reads
// like any other coordinate this project prints.
//
// The fraction is ONE multiply and ONE divide: (frac*10^6 + 2^29)/2^30.  The
// half-step is what makes it ROUNDED rather than truncated: a span of
// 1.7999999... would otherwise print as "1.799999", which reads as a bug in a
// program that has none.  frac < 2^30 so the product is under 1.1e15 --
// nowhere near a long's limit -- and there is no float and no rounding mode
// anywhere in it.
def out_fixed6(v: long) -> void {
    let neg = v < 0;
    let a = if (neg) { 0 - v } else { v };
    if (neg) { out_byte(45); };
    out_num(a >> 30);
    out_byte(46);                          // '.'
    let micro = ((a & 1073741823) * 1000000 + 536870912) / 1073741824;
    let u = micro;
    let i: long = 6;
    while (i > 0) {
        NBUF[i - 1] = 48 + u % 10;
        u = u / 10;
        i = i - 1;
    };
    let k: long = 0;
    while (k < 6) {
        out_byte(NBUF[k]);
        k = k + 1;
    }
};

export {
    OB_CAP, out_reset, out_len, out_written, out_byte, out_str, out_num,
    out_pad, out_hex16, out_fixed6, digits, out_flush
};