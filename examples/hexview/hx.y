// hx.y -- hexview's byte model: a file held as [byte], and the od-compatible
// row text the inspector prints.
//
// WHAT IT IS
// One module-level array, `DATA`, is the open file.  Every reader in the
// program -- the interactive cursor, the gutter, the histogram, the dump, the
// self-test -- goes through `hx.byte_at`, so there is exactly one definition of
// "what byte is at offset o" and one place where an out-of-range offset becomes
// an error code instead of a trap.
//
//   let ok = hx.open_path("data/sample.bin");    // whole file into DATA
//   if (!ok) { eputs("hexview: " + hx.err + "\n"); exit(1) };
//   let n = hx.row(0, 16);                       // one formatted row
//   write(1, &hx.LINE[0], n);                    // ... straight out
//
// THE REPRESENTATION, AND WHY (ORCHESTRATOR.md §2.10; SUGGESTIONS.md #12,
// #9)
//
// Everything here is a **variable-length [byte]**, never a fixed [byte; N].
// That is a decision, and it is the opposite of the one a fixed-size page
// buffer suggests:
//
//   * A hex editor's whole job is arbitrary sizes.  A `[byte; 4096]` page
//     buffer silently caps the file at 4096 bytes; the honest shapes are "read
//     the whole file" and "seek per page", and this tool does the first.
//   * `fs.read_bytes` answers `[byte]?`, and every getter in `struct` takes a
//     `[byte]`.  A fixed array would have to be copied into a `[byte]` before
//     anything could read it -- one more copy of the entire file.
//   * `[byte; N]` does not widen to `[byte]` (#12), so a fixed buffer would
//     force the row formatter to be written once per size.  As a `[byte]` the
//     file needs no size parameter anywhere, so there is exactly **one** fixed
//     array in this program -- `LINE`, the formatted-row scratch -- and exactly
//     one helper that names it.  The cost of #12 is paid once instead of twice.
//   * Scalar store into a `[byte]` element -- `DATA[i] = v` -- works, and costs
//     **zero** bytes, so an edit needs no `struct` writer at all.  #9's real
//     content is that `struct` has readers with no in-place setter; the
//     element-store route around it is free.  `hx.set` uses it, and the
//     self-test measures the zero.
//
// NO TRAP, EVER.  `byte_at` answers -1 past the end and `set` answers a
// negative error code; nothing in this file indexes without asking.  The dump
// of a zero-length file is the offset line and nothing else, which is what
// `od -A d -t x1z` prints for one too.
//
// THE ROW FORMAT IS GNU OD'S, BYTE FOR BYTE
// `hx.row` reproduces `od -A d -t x1z -v` -- the one format this program
// claims to be interchangeable with, and the oracle `--check` compares against
// (a different program, in C, decades apart).  Per row:
//
//   <offset, %0Nd><' '><byte 0 as 2 lowercase hex digits><' '>...
//   ...padded with spaces to 3*W...  '>' <gutter> '<'
//
// and one final line, the file's length as a bare offset.  N is 7, which is
// od's fixed width and is why every prefix is 58 columns at W=16.

import fs;

// ─────────────────────────────────────────────── the one fixed array ───

// The formatted-row scratch.  LINECAP covers the widest row this program
// prints: offset(7) + hex field (3 * 32) + two delimiters + gutter(32) = 137,
// and 256 leaves room for an offset field that grows past seven digits.
const LINECAP = 256;
let LINE: [byte; 256] = [0; 256];
let LINEN: long = 0;                       // how much of LINE is live

// ───────────────────────────────────────────────────────── the buffer ───

// The open file.  `DATA` is a [byte], so this is a *reference* assignment: a
// caller that keeps a handle on the array it handed in sees every edit.
let DATA: [byte] = [0; 0];
let SIZE: long = 0;                        // bytes in DATA
let DIRTY: long = 0;                       // 1 once a byte has been edited
let ERRS: str = "";                        // the last diagnostic

// The ceiling.  32 MiB in a 3.5 GiB cap, and it keeps the od offset field at
// seven digits (see the row format above), which is what the cross-check
// compares.
const CAP = 33554432;

// Error codes from `set`, so a caller can name the failure.  Zero is success.
const E_OK = 0;
const E_NEG = -1;                           // negative offset
const E_PAST = -2;                          // offset >= size
const E_RANGE = -3;                         // value outside 0..255

// The printable-ASCII gutter placeholder.  A dot, which is what od, hexdump and
// every hex editor since 1973 use, and which is unambiguous inside a dump.
const DOT = 46;

// `glyph` is THE gutter property, in one place: byte v renders as itself when
// 32 <= v <= 126, and as a dot otherwise.  Note the low bound is 32, not 33 --
// 0x20 is a space and must come out as a space.  Getting that one wrong is the
// classic hex-viewer bug and it is invisible in a golden whose sample has no
// spaces, which is why --check walks all 256 values instead.
def glyph(v: long) -> long {
    if (v >= 32 && v <= 126) { return v; };
    DOT
};

// One hex digit, 0..15 -> its ASCII code point.  '0'..'9' are 48..57 and
// 'a'..'f' are 97..102, so the two halves differ by 39 (48 + 39 = 87, and
// 87 + 10 = 97).
def hexdig(n: long) -> long {
    if (n < 10) { return 48 + n; };
    87 + n
};

// One hex *character* -> its value, or -1.  A checked inverse of hexdig.
def hexdig_of(c: long) -> long {
    if (c >= 48 && c <= 57) { return c - 48; };
    if (c >= 97 && c <= 102) { return c - 87; };
    if (c >= 65 && c <= 70) { return c - 55; };
    0 - 1
};

// A checked two-digit hex parse, both cases accepted, -1 for anything else.
// `tonum` is decimal-only and answers 0 for text it does not understand
// (SUGGESTIONS.md #4), which for a byte value would be silent corruption: a
// typo in --edit would write 0x00 and look like it worked.  So the parse here
// is a value or -1, never a guess.
def hexval(s: str) -> long {
    // EXACTLY two digits, so `--edit 0=ffff` is refused rather than silently
    // becoming 0xff.  A prefix-accepting parse here is a silent truncation.
    if (len(s) != 2) { return 0 - 1; };
    let hi = hexdig_of(s[0]);
    if (hi < 0) { return 0 - 1; };
    let lo = hexdig_of(s[1]);
    if (lo < 0) { return 0 - 1; };
    hi * 16 + lo
};

// A checked decimal parse, -1 for anything else -- the same reason as hexval,
// and because `--offset 99999999999999999999` must be a message, not a wrap.
def decval(s: str) -> long {
    if (len(s) < 1 || len(s) > 18) { return 0 - 1; };
    let i = 0;
    let v = 0;
    while (i < len(s)) {
        let c = s[i];
        if (c < 48 || c > 57) { return 0 - 1; };
        v = v * 10 + (c - 48);
        i = i + 1;
    };
    v
};

// ──────────────────────────────────────────────────────── the byte at ───

// The byte at `off`, or -1 when `off` is outside the file.  This is the only
// way anything reads a byte; the -1 is a value, never a trap.
def byte_at(off: long) -> long {
    if (off < 0 || off >= SIZE) { return 0 - 1; };
    DATA[off]
};

// The first offset at or after `from` holding `want`, or -1.  A hex editor's
// "find this byte" -- a linear scan, because there is no map in the language.
def find_byte(want: long, from: long) -> long {
    let i = from;
    while (i < SIZE) {
        if (DATA[i] == want) { return i; };
        i = i + 1;
    };
    0 - 1
};

// The first offset at or after `from` whose `n` bytes are `pat`, or -1.  The
// ASCII search: `pat` is a str, so `n` is its byte length.
def find_text(pat: str, from: long) -> long {
    let n = len(pat);
    if (n < 1 || n > SIZE) { return 0 - 1; };
    let i = from;
    while (i + n <= SIZE) {
        let j = 0;
        let same = 1;
        while (j < n) {
            if (DATA[i + j] != pat[j]) { same = 0; };
            j = j + 1;
        };
        if (same == 1) { return i; };
        i = i + 1;
    };
    0 - 1
};

// ─────────────────────────────────────────────────────────────── edits ───

// Store `v` at `off`.  Four negative reasons it did not happen, all of them
// reachable from a keypress at the end of a file, all of them values.
//
// The store itself is `DATA[off] = v`, one element assignment on a [byte].
// SUGGESTIONS.md #9 asks for `struct.put_u32le(b, off, v)` because `struct`
// has no in-place setter -- but for a single byte the element store already
// costs zero bytes (measured by --check), so no writer is wanted here.
def set(off: long, v: long) -> long {
    if (off < 0) { return E_NEG; };
    if (off >= SIZE) { return E_PAST; };
    if (v < 0 || v > 255) { return E_RANGE; };
    DATA[off] = v;
    DIRTY = 1;
    E_OK
};

// A human-readable name for a `set` error code, so the caller never has to
// invent one.
def set_errname(e: long) -> str {
    if (e == E_NEG) { return "offset before the start of the file"; };
    if (e == E_PAST) { return "offset past the end of the file"; };
    if (e == E_RANGE) { return "byte value outside 0..255"; };
    "no error"
};

// ──────────────────────────────────────────────────────────── opening ───

// Take ownership of an array the caller already has -- `fs.read_bytes` or
// `bytes(embed)`.  Y arrays are references, so DATA and the caller's handle are
// one array afterwards, and an edit through hx is visible in the caller's copy.
def adopt(b: [byte]) -> long {
    DATA = b;
    SIZE = len(b);
    DIRTY = 0;
    ERRS = "";
    SIZE
};

// Open a path whole.  Three things are refused with a message and never a
// trap: a path that is not there, a path that is not a regular file (a
// directory opens fine and then fails on read, so it is caught first), and a
// file over the ceiling.
def open_path(path: str) -> bool {
    ERRS = "";
    if (len(path) < 1) { ERRS = "no file name"; return false; };
    if (!fs.exists(path)) { ERRS = "no such file: " + path; return false; };
    if (!fs.is_file(path)) { ERRS = "not a regular file: " + path; return false; };
    let sz = fs.file_size(path);
    if (sz == none) { ERRS = "cannot stat: " + path; return false; };
    let n = sz!;
    if (n > CAP) {
        ERRS = "file is larger than the " + CAP + "-byte ceiling: " + path;
        return false
    };
    let r = fs.read_bytes(path);
    if (r == none) { ERRS = "cannot read: " + path; return false; };
    adopt(r!);
    true
};

// Write the buffer back.  A hex editor holds the whole file, so this is a
// whole-file write, not a seek-and-punch: the atomicity of a temp file plus a
// rename would need a second copy of the file, and `fs.write_bytes` answers
// whether the bytes actually landed, which is what --check re-reads.
def save(path: str) -> bool {
    if (!fs.write_bytes(path, DATA, -1)) {
        ERRS = "cannot write: " + path;
        return false
    };
    DIRTY = 0;
    true
};

// ───────────────────────────────────────────────────── the formatted row ───
//
// `row` writes one row of the od-compatible dump into the module-level LINE and
// returns its length.  It is the ONE function in this program whose signature
// names a fixed-size array -- and it does not even take one: the buffer is
// module-level, so #12's "one helper per buffer size" is paid exactly once.
//
// W is the row width in bytes.  The hex field is padded to 3*W so the '>' lands
// in the same column on a short last row, which is what od does and what makes
// the two dumps diffable.
def row(off: long, w: long) -> long {
    LINEN = 0;
    if (w < 1) { return 0; };
    // od pads the hex field to 3*W + 2 columns between the offset and the '>',
    // counted from the separator space -- measured at W = 4, 8, 16 and 32.  (It
    // is one more than the digits need; that one extra column is the whole
    // reason a hand-written dumper does not line up with od.)
    let hexw = w * 3 + 2;
    // The offset, %07d, growing if the file is large enough to need more.
    let odig = digits(SIZE);
    let ndig = 7;
    if (odig > ndig) { ndig = odig; };
    put_off(off, ndig);
    putb(32);                               // od's one space before the first byte
    let n = 1;                              // ... which is the first hexw column
    let i = 0;
    while (i < w && off + i < SIZE) {
        if (i > 0) { putb(32); n = n + 1; };
        let v = DATA[off + i];
        putb(hexdig(v / 16));
        putb(hexdig(v % 16));
        n = n + 2;
        i = i + 1;
    };
    while (n < hexw) { putb(32); n = n + 1; };
    putb(62);                                // '>'
    let k = 0;
    while (k < w && off + k < SIZE) {
        putb(glyph(DATA[off + k]));
        k = k + 1;
    };
    putb(60);                                // '<'
    LINEN
};

// How many rows a dump of [from, SIZE) at width `w` occupies, capped at
// `nrows` (0 or negative means no cap).  A pure function of the request, so the
// summary printed BEFORE the dump can state the row count and `dump` can be
// required to produce exactly this many -- which is what --check asserts.
def plan_rows(from: long, w: long, nrows: long) -> long {
    if (w < 1) { return 0; };
    let avail = 0;
    if (from < SIZE) { avail = SIZE - from; };
    let n = (avail + w - 1) / w;
    if (nrows > 0 && nrows < n) { n = nrows; };
    n
};

// The trailing line: the file's length as a bare offset, always, even for a
// zero-length file.  That is od's last line and it is the one a reader forgets.
def end_line() -> long {
    LINEN = 0;
    let odig = digits(SIZE);
    let ndig = 7;
    if (odig > ndig) { ndig = odig; };
    put_off(SIZE, ndig);
    LINEN
};

// ────────────────────────────── the two byte-writers LINE is built from ───
//
// Both take no buffer: they append to LINE.  LINECAP is the only size in this
// program's type signatures that is a count of bytes, and it appears here
// nowhere at all.

def putb(v: long) -> void {
    if (LINEN < LINECAP) { LINE[LINEN] = v; LINEN = LINEN + 1; }
};

def putstr(s: str) -> void {
    let i = 0;
    while (i < len(s)) {
        putb(s[i]);
        i = i + 1;
    }
};

// An offset, zero-padded to `ndig` digits.  Digits go out backwards through a
// module-level scratch, because a [byte; 24] on the stack per call is an
// allocation and this is called once per row.
let DIG: [byte; 24] = [0; 24];

def digits(v: long) -> long {
    if (v < 0) { return 1; };
    if (v == 0) { return 1; };
    let k = 0;
    let x = v;
    while (x > 0) { k = k + 1; x = x / 10; };
    k
};

def put_off(v: long, ndig: long) -> void {
    let k = digits(v);
    let i = 0;
    while (i < k && i < 24) {
        DIG[i] = 48 + (v % 10);
        v = v / 10;
        i = i + 1;
    };
    while (i < ndig) {
        putb(48);
        i = i + 1;
    };
    let j = k;
    if (j > 24) { j = 24; };
    while (j > 0) {
        j = j - 1;
        putb(DIG[j]);
    }
};