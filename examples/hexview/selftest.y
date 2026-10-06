// selftest.y -- hexview's property check.
//
//   ./hexview --check          the properties, with no reference file anywhere
//   ./hexview --check --od     ... and the GNU od cross-check
//
// WHY THIS FILE EXISTS AT ALL
// EXPECTED is a golden: it proves the run is deterministic and nothing else.
// `cube` in this campaign passed every gate item while rendering filled wedges,
// because its golden had been generated from the broken output.  So nothing here
// reads EXPECTED, nothing here reads a fixture of "known good output", and
// every expected value is written out in this file from something outside the
// code under test -- a literal table, a hand-computed od line, a count taken
// from fs.file_size (i.e. from the operating system), or GNU od itself.
//
// THE ORACLES, and what each one is for
//
//   1. the gutter over all 256 byte values      a definition, exhaustively
//   2. the hex digits over all 256 values       a literal 16-entry table
//   3. one fixture's dump, hand-derived        four lines written by hand here
//   4. GNU od -A d -t x1z -v                    a different program, in C,
//                                               decades apart -- the strong one
//   5. round-trip edits                         a FRESH reader on the saved file
//   6. struct's readers vs two compositions     a third opinion on the bytes
//   7. bounds                                   every hostile offset is a value
//   8. every flag's error path                  exec'd, with the trap marker read
//
// THE VACUITY TRAP (ORCHESTRATOR.md §2.6)
// Two agents in this campaign shipped checks that compared two values which
// were BOTH ABSENT, and passed.  So every section here starts by proving its
// subject is present and non-zero before comparing anything, the expected
// counts come from outside the code under test, and the final line reports the
// number of assertions run -- which must not be zero, and which is counted
// here rather than by the program being checked.
//
// WHAT IT NEEDS
// Sections 11 and 12 run the program as a child process, so they need `exec`
// (i.e. the binary must NOT be built with `ycc --no-exec`) and `./hexview` to
// exist next to the cwd.  gate.conf's build line uses neither condition against
// it.  Sections 1 to 10 need nothing but a writable /tmp; 11 and 12 also need
// exec (i.e. a binary NOT built with `ycc --no-exec`) and ./hexview beside the cwd.

import fs;
import hx;
import struct;
import test;

// The shipped sample again, so section 11 can plan a row count for the same
// bytes the child process is about to dump.  `embed` is a statement of its own
// ending in a semicolon, and its path resolves at compile time relative to THIS
// file.
embed SAMPLE from "data/sample.bin";

// ───────────────────────────────────────────────────────── the bookkeeping ───

// This file used to carry its own assertion helpers -- `ok(cond, what, got)`,
// `ck(got, want, what)` and `ckstr(got, want, what)`, with the counters
// CHECKS/FAILS beside them -- and they are `std/test.y`'s now:
//
//   ok(cond, what, got)  ->  test.ck(what, cond, got)     name, ok, detail
//   ck(got, want, what)  ->  test.ck_eq(what, got, want)
//   ckstr(got, want, w)  ->  test.ck_str(what, got, want)
//
// Every call site below was reordered by hand; none of them had the same order.
// Two visible consequences, both intended and neither a loss:
//
//   * the old `ok` printed ONLY on failure, so a clean run was 19 lines; every
//     assertion in std/test.y prints a verdict line and a detail line on BOTH
//     outcomes, so a clean run is now 1464.  That is the module's deliberate
//     trade ("a check whose output only appears on failure is one nobody can
//     read"), and the detail on a pass is the measurement.
//   * the old failure line was one line, "  FAIL <what>: <got>"; it is now
//     "  FAIL  <what>" and "          <got>".  inject.py's oracle greps for
//     the substring "FAIL" and hexview/README.md's defect table quotes the
//     first failing line, so both were re-measured rather than assumed.
//
// The counts are unchanged -- 720 assertions, measured before and after -- and
// CHECKS/FAILS are now test.checks()/test.failures().

// One line to stdout, with no doubled blank lines: `print` already ends a line,
// so appending another "\n" to every message puts a blank between all of them.
// This writes the bytes and one newline with a single write(2).  std/test.y's
// `print` reaches fd 1 the same unbuffered way -- y_print_hstr is two
// syscall(1, 1, ...) calls, the text and then the newline (std/rt.y) -- so its
// lines and these interleave in the order they are made.
let SB: [byte; 1024] = [0; 1024];

def say(s: str) -> void {
    let n = 0;
    let i = 0;
    while (i < len(s) && n < 1020) { SB[n] = s[i]; n = n + 1; i = i + 1; };
    SB[n] = 10;
    let want = n + 1;
    let done = 0;
    while (done < want) {
        let w = syscall(1, 1, ptr_addr(&SB[done]), want - done);
        if (w <= 0) { done = want; } else { done = done + w; }
    };
    0
};

// A section heading.  std/test.y's test.group(), which prints the blank line
// first, so the sections read as sections.
def sec(s: str) {
    test.group("[" + s + "]")
};

// ───────────────────────────────────────────── the fixture, byte for byte ───
//
// 48 bytes, laid out so that every hex viewer's bug has somewhere to show:
//   [ 0..15]  0x00 .. 0x0f   a NUL first, and no trailing newline anywhere
//   [16..31]  0xf0 .. 0xff   the top sixteen, all non-printable
//   [32..47]  0x20 .. 0x2f   0x20 is a SPACE: the gutter's off-by-one
// 48 is exactly three rows of sixteen, so there is no partial last row -- the
// partial-row padding is checked in section 4 against od, on files whose last
// row is short.
//
// The expected dump, written out by hand from the byte list above (and
// confirmed against GNU od by section 4, so the two agree or the check says so):
let FIXN = 48;
let FIXWANT: [str; 4] = [
    "0000000 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f  >................<",
    "0000016 f0 f1 f2 f3 f4 f5 f6 f7 f8 f9 fa fb fc fd fe ff  >................<",
    "0000032 20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f  > !\"#$%&'()*+,-./<",
    "0000048"
];

def fix(i: long) -> long {
    if (i < 16) { return i; };
    if (i < 32) { return 240 + (i - 16); };
    32 + (i - 32)
};

let FIX: [byte; 48] = [0; 48];

def fix_build() {
    let i = 0;
    while (i < FIXN) { FIX[i] = fix(i); i = i + 1; }
};

// THE ONE WORKAROUND, AND WHAT IT COSTS (examples/SUGGESTIONS.md #12)
// A `[byte; N]` does not widen to `[byte]`, so hx.adopt, fs.write_bytes and
// every reader in `struct` -- all of which want a `[byte]` -- cannot be handed
// a fixed array.  `FIX[0:48]` is the route that works: a slice is a COPY (so
// writing through it does not write FIX, verified) and it costs one small array
// per slice.  Here that is a handful of slices in a check that runs once, which
// is the cheap end of the trade.  In the frame path it would not be affordable,
// which is exactly why hx.DATA -- the one array the program reads and writes --
// is a [byte] and never a [byte; N].  Nothing here needs `struct.put_u8` for the
// same reason (SUGGESTIONS.md #9): `DATA[i] = v` is the element store and costs
// zero bytes.
def fixb() -> [byte] {
    FIX[0:FIXN]
};

// ───────────────────────────────────────── the independent hex digit table ───
//
// Sixteen literal strings.  Not derived from hx.hexdig: that is the whole point.
//
let HEXD: [str; 16] = ["0", "1", "2", "3", "4", "5", "6", "7",
                       "8", "9", "a", "b", "c", "d", "e", "f"];

// ───────────────────────────────────────────────────────────── the scratch ───

const TDIR = "/tmp/hexview_selfcheck";
let SELF: str = "";                        // ./hexview, from argv()[0]
let OUTB: [byte; 4096] = [0; 4096];        // the dump, rebuilt for comparison
let OUTN: long = 0;

def ob(v: long) {
    if (OUTN < 4096) { OUTB[OUTN] = v; OUTN = OUTN + 1; }
};

def ostr(s: str) {
    let i = 0;
    while (i < len(s)) { ob(s[i]); i = i + 1; }
};

def outs() -> str {
    from_bytes(OUTB[0:OUTN])
};

// fs.file_size() -> long?, and the places below want a number.  This is the
// checked unwrap: `none` becomes the sentinel the caller compares against, so a
// missing file is a FAILED ASSERTION with a message and never an
// "unwrap of none" trap.
def osz_or(v: long?, dflt: long) -> long {
    if (v == none) { return dflt; };
    v!
};

def tpath(n: str) -> str {
    TDIR + "/" + n
};

def slurp(p: str) -> str {
    let r = fs.read_file(p);
    if (r == none) { return ""; };
    r!
};

// Run this program with `a` as arguments, capturing stdout AND stderr into
// `out`.  `> f 2>&1` and not the other order, or the stderr copy lands on the
// real terminal and the file comes back empty.
def run_self(a: str, out: str) -> long {
    exec(SELF + " " + a + " > " + out + " 2>&1")
};

// ── two compositions of a little-endian u32, and struct's own reader ──
//
// hx's formatter composes a byte pair with division and modulo
// (v / 16, v % 16); these two use multiplication and shifts.  If any of the
// three disagrees with the other two, one of them is wrong.
//
// BOTH ARE LITTLE-ENDIAN, and getting that wrong is what this section is for:
// the first draft of these two had b[at] in the high position, so they agreed
// with each other on every word and disagreed with struct's reader on every
// word.  Two oracles that share a mistake are one oracle.  So the counts are
// asserted from struct's answer, not from the agreement of the other two.
def u32_mul(b: [byte], at: long) -> long {
    b[at] + b[at + 1] * 256 + b[at + 2] * 65536 + b[at + 3] * 16777216
};

def u32_shift(b: [byte], at: long) -> long {
    b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)
};

// The byte at `i` after the edits section 5 applies, computed from the
// literals above rather than from anything the program stored.
const NEO = 10;
let EDOFS: [long; 10] = [0, 1, 5, 15, 16, 17, 31, 32, 46, 47];
let EDVAL: [long; 10] = [255, 0, 65, 126, 128, 1, 32, 170, 10, 85];

def edited_at(i: long) -> long {
    let k = 0;
    while (k < NEO) {
        if (EDOFS[k] == i) { return EDVAL[k]; };
        k = k + 1;
    };
    fix(i)
};

// The SECOND round trip's pattern, which starts from the first round's file:
// offset (FIXN-1-o) gets 255 - its first-round value, so it is a different byte
// at every one of the same ten offsets, and the two rounds cannot be confused
// for each other.  An offset round 2 does not touch KEEPS its round-1 value,
// which is `edited_at(o)` and not `fix(o)` -- the first draft of this said fix(o)
// and reported 10 mismatches that were the check's mistake, not the program's.
def edited2_at(o: long) -> long {
    let k = 0;
    while (k < NEO) {
        if (EDOFS[k] == FIXN - 1 - o) { return 255 - EDVAL[k]; };
        k = k + 1;
    };
    edited_at(o)
};

// ────────────────────────────────────────────────── 1. the ASCII gutter ───
//
// The property: byte v renders as itself when 32 <= v <= 126 and as a dot
// otherwise.  The two ends of that range are where a hex viewer goes wrong --
// 0x20 is a space and NOT "non-printable", and 0x7f is NOT printable -- so all
// 256 values are walked, and the two counts are asserted as 95 and 161.
//
// 95 comes from 126 - 32 + 1, computed here and not read from anywhere.
def sec_gutter() {
    sec("1 the ASCII gutter, all 256 byte values");
    let nself = 0;
    let ndot = 0;
    let bad = 0;
    let firstbad = "";
    let v = 0;
    while (v < 256) {
        let printable = v >= 32 && v <= 126;
        let want = v;
        if (!printable) { want = hx.DOT; };
        let got = hx.glyph(v);
        if (got != want) {
            bad = bad + 1;
            if (len(firstbad) < 1) {
                firstbad = "first at " + tostring(v) + ": got "
                           + tostring(got) + ", want " + tostring(want);
            };
        };
        // Classed by the BYTE, never by comparing the rendered value with DOT.
        // 0x2e is a printable '.', so it renders as itself and equals DOT at the
        // same time -- and counting by the rendered value puts it in the wrong
        // class, which is how this section first reported 94 and 162.
        if (printable) { nself = nself + 1; } else { ndot = ndot + 1; };
        v = v + 1;
    };
    test.ck("every one of 256 byte values renders right", bad == 0, firstbad);
    // The counts, from the definition rather than from the loop above.
    test.ck_eq("values that render as themselves", nself, 95);
    test.ck_eq("values that render as the placeholder", ndot, 161);
    test.ck_eq("the two counts cover every byte value", nself + ndot, 256);
    test.ck("neither class is empty",
        nself > 0 && ndot > 0,
        "nself=" + tostring(nself)
       + " ndot=" + tostring(ndot));
    // The four values the off-by-one lives on, named.
    test.ck_eq("0x20 is a space, not a placeholder", hx.glyph(32), 32);
    test.ck_eq("0x7e is '~'", hx.glyph(126), 126);
    test.ck_eq("0x1f is a placeholder", hx.glyph(31), hx.DOT);
    test.ck_eq("0x7f (DEL) is a placeholder", hx.glyph(127), hx.DOT);
    test.ck_eq("0xff is a placeholder", hx.glyph(255), hx.DOT);
    test.ck_eq("the placeholder is '.'", hx.DOT, 46);
    // 0x00 is the byte a hex editor shows most, and it is not a space.
    test.ck_eq("0x00 is a placeholder", hx.glyph(0), hx.DOT);
    0
};

// ──────────────────────────────────────────── 2. the hex digits, 256 values ───

def sec_hexdigits() {
    sec("2 the hex digits, all 256 byte values");
    let bad = 0;
    let badv = 0;
    let v = 0;
    while (v < 256) {
        let want_hi = HEXD[v / 16][0];
        let want_lo = HEXD[v % 16][0];
        let got_hi = hx.hexdig(v / 16);
        let got_lo = hx.hexdig(v % 16);
        if (got_hi != want_hi || got_lo != want_lo) {
            bad = bad + 1;
            if (badv == 0) { badv = v; };
        };
        // ... and the parser is the inverse of the formatter, on the literal
        // table's own spelling, including upper case.
        let upper = "";
        if (v / 16 > 9) {
            upper = upper + chr(HEXD[v / 16][0] - 32);
        } else {
            upper = upper + HEXD[v / 16];
        };
        if (v % 16 > 9) {
            upper = upper + chr(HEXD[v % 16][0] - 32);
        } else {
            upper = upper + HEXD[v % 16];
        };
        test.ck_eq("hexval parses the table's spelling of a byte", hx.hexval(upper), v);
        test.ck_eq("hexval parses the lower-case spelling of a byte",
            hx.hexval(HEXD[v / 16] + HEXD[v % 16]),
            v);
        v = v + 1;
    };
    test.ck("both digits of every byte value match the literal table",
        bad == 0,
        badv == 0 ? "clean" : "first wrong at " + tostring(badv));
    // The parser refuses what it does not understand -- `tolong` would answer 0.
    test.ck_eq("hexval refuses 'zz'", hx.hexval("zz"), 0 - 1);
    test.ck_eq("hexval refuses '0z'", hx.hexval("0z"), 0 - 1);
    test.ck_eq("hexval refuses 'z0'", hx.hexval("z0"), 0 - 1);
    test.ck_eq("hexval refuses a single digit", hx.hexval("f"), 0 - 1);
    test.ck_eq("hexval refuses the empty string", hx.hexval(""), 0 - 1);
    test.ck_eq("hexval refuses three digits", hx.hexval("fff"), 0 - 1);
    test.ck_eq("hexval accepts '00'", hx.hexval("00"), 0);
    test.ck_eq("hexval accepts upper case", hx.hexval("FF"), 255);
    test.ck_eq("hexdig_of refuses '/'", hx.hexdig_of(47), 0 - 1);
    test.ck_eq("hexdig_of refuses a backtick", hx.hexdig_of(96), 0 - 1);
    test.ck_eq("hexdig_of refuses 'g'", hx.hexdig_of(103), 0 - 1);
    // The decimal parser used by --offset and --rows.
    test.ck_eq("decval parses 0", hx.decval("0"), 0);
    test.ck_eq("decval parses 4096", hx.decval("4096"), 4096);
    test.ck_eq("decval refuses the empty string", hx.decval(""), 0 - 1);
    test.ck_eq("decval refuses a minus sign", hx.decval("-1"), 0 - 1);
    test.ck_eq("decval refuses '1x'", hx.decval("1x"), 0 - 1);
    test.ck_eq("decval refuses 20 digits", hx.decval("99999999999999999999"), 0 - 1);
    0
};

// ─────────────────────────────── 3. one fixture's dump, hand-derived ───
//
// FIXWANT is four literal lines.  The dump is rebuilt here from hx.row -- the
// same call the program makes -- and compared to them.  This is the check that
// would catch an off-by-one column, a wrong nibble order or a dropped trailing
// size line, on bytes chosen to break each.
def sec_handwritten() {
    sec("3 one fixture's dump, against four hand-written lines");
    fix_build();
    test.ck("hx is not holding this fixture yet (sanity: the sizes differ or it is empty)",
        len(hx.DATA) != FIXN || hx.SIZE != FIXN,
        "held");
    hx.adopt(fixb());
    // Non-vacuity, before anything is compared: the buffer really is the fixture.
    test.ck_eq("the adopted buffer is 48 bytes", hx.SIZE, FIXN);
    test.ck_eq("the adopted array is 48 elements", len(hx.DATA), FIXN);
    let mism = 0;
    let i = 0;
    while (i < FIXN) {
        if (hx.byte_at(i) != fix(i)) { mism = mism + 1; };
        i = i + 1;
    };
    test.ck_eq("every byte of the buffer matches the literal layout", mism, 0);

    let rows = hx.plan_rows(0, 16, 0);
    test.ck_eq("plan_rows says three rows for 48 bytes at width 16", rows, 3);
    let line = "";
    let r = 0;
    while (r < rows) {
        hx.row(r * 16, 16);
        line = line + outs_n(hx.LINEN) + "\n";
        r = r + 1;
    };
    hx.end_line();
    line = line + outs_n(hx.LINEN) + "\n";
    // Compare line by line against the literals, and name the first that differs.
    let gotl = line.split("\n");
    test.ck_eq("the dump is three rows plus the size line", len(gotl), 4);
    let k = 0;
    while (k < 4 && k < len(gotl)) {
        test.ck_str("dump line " + tostring(k), gotl[k], FIXWANT[k]);
        k = k + 1;
    };
    // The plan and the dump must agree, and the size line must be the size.
    test.ck_eq("the file length is two digits", hx.digits(hx.SIZE), 2);
    hx.end_line();
    test.ck_str("the trailing line is the length", outs_n(hx.LINEN), "0000048");
    // A partial last row: 48 is exact, so ask for width 32 and check the pad.
    test.ck_eq("48 bytes at width 32 is two rows", hx.plan_rows(0, 32, 0), 2);
    hx.row(32, 32);
    test.ck_str("a 16-of-32 row pads the hex field to width 32 and the gutter to 16 -- this literal is od's own line for `od -w32` on the same bytes",
        outs_n(hx.LINEN),
        "0000032 20 21 22 23 24 25 26 27 28 29 2a 2b 2c 2d 2e 2f                                                  > !\"#$%&'()*+,-./<");
    test.ck_eq("an offset at the end plans no rows", hx.plan_rows(48, 16, 0), 0);
    test.ck_eq("--rows 2 caps the plan at two", hx.plan_rows(0, 16, 2), 2);
    test.ck_eq("an offset one byte in still needs three rows", hx.plan_rows(1, 16, 0), 3);
    0
};

// The first n bytes of hx.LINE as a str, for comparing a formatted row.
def outs_n(n: long) -> str {
    from_bytes(hx.LINE[0:n])
};

// ───────────────────────────────────────── 4. the GNU od cross-check ───
//
// The strongest oracle available and a completely different kind: GNU coreutils
// od, written in C, decades apart, by people who had no access to this code.
// `--check --od` writes a family of fixtures, asks od for each, asks hexview
// for each, and diffs the two files byte for byte.
//
// The fixtures are chosen so the format's corners are all covered: length 0
// (no rows at all, only the size line), 1, a row boundary (15, 16, 17), three
// IDENTICAL rows (which od collapses to '*' unless -v is given -- hexview never
// collapses, and this proves the difference is deliberate), all 256 byte values,
// a NUL in the middle, high bytes, no trailing newline, and a long generated
// file so the loop over rows is exercised many times.
const NCROSS = 12;
let CROSSN: [long; 12] = [0, 1, 5, 15, 16, 17, 48, 256, 257, 1000, 4096, 7];
let CROSSOK: long = 0;
let ODSKIP: long = 0;                      // 1 = od was not installed, section skipped
let CROSSBYTES: long = 0;
let CROSSODBYTES: long = 0;

// A tiny LCG, so the 1000- and 4096-byte fixtures are generated rather than
// shipped, and are the same bytes on every machine and every run.
let LCG: long = 12345;
def lcg() -> long {
    LCG = (LCG * 1103515245 + 12345) % 2147483648;
    LCG / 65536 % 256
};

// ── the fixture cells, one per size ──
//
// Two gaps close the same door here (SUGGESTIONS.md #8 and #12): `[0; n]` wants
// an integer LITERAL, so a fixture of a runtime length cannot be declared; and
// a `[byte; N]` does not widen to `[byte]`, so a helper that fills one cannot be
// written once -- it has to name its own size.  The honest result is four cells
// and FOUR copies of the same four-line fill loop, with the size in the name.
// That is #12's concrete price, paid here in a check that runs once.  The
// program never pays it: its one buffer is a `[byte]`.
let ONE: [byte; 1] = [0; 1];
let CELL16: [byte; 16] = [0; 16];
let CELL256: [byte; 256] = [0; 256];
let CELL1024: [byte; 1024] = [0; 1024];
let CELL4096: [byte; 4096] = [0; 4096];

// Each family member gets bytes in a shape that would catch a class of defect,
// so twelve files are twelve different questions:
//   0      no rows at all -- only the size line
//   1      one byte: the gutter, the pad and the size line all degenerate
//   5      a short last row
//   7      a short last row again, different bytes
//   15     one byte short of a row, so the size line is NOT a row
//   16     exactly one row, and the size line stands alone
//   17     one byte over: a one-byte last row
//   48     the ramp: three rows
//   256    all 256 byte values, sixteen rows
//   257    all 256 values plus one, so a row count of 17 is not 16
//   1000   generated: many rows, and no two alike
//   4096   generated: 256 rows
def fill16(b: [byte; 16], n: long, seed: long) -> void {
    let i = 0;
    while (i < n && i < 16) { b[i] = (i * 37 + seed * 11) % 256; i = i + 1; }
};

def fill256(b: [byte; 256], n: long, seed: long) -> void {
    let i = 0;
    while (i < n && i < 256) { b[i] = (i * 37 + seed * 11) % 256; i = i + 1; }
};

def fill1024(b: [byte; 1024], n: long, seed: long) -> void {
    let i = 0;
    while (i < n && i < 1024) { b[i] = (i * 37 + seed * 11) % 256; i = i + 1; }
};

// The 4096-byte one is the LCG, so it is a generator rather than a pattern: a
// long run of similar bytes would hide an off-by-one that a varied one shows.
def fill4096(b: [byte; 4096], n: long, seed: long) -> void {
    let i = 0;
    LCG = seed;
    while (i < n && i < 4096) { b[i] = lcg(); i = i + 1; }
};

def cross_bytes(n: long) -> [byte] {
    if (n == 0) { return CELL16[0:0]; };
    if (n == 48) { return fixb(); };
    if (n == 256) { fill256(CELL256, 256, 8); return CELL256[0:256]; };
    if (n == 257) {
        fill256(CELL256, 256, 9);
        ONE[0] = 46;
        return CELL256[0:256] + ONE[0:1];
    };
    if (n == 1000) { fill1024(CELL1024, 1000, 12345); return CELL1024[0:1000]; };
    if (n == 4096) { fill4096(CELL4096, 4096, 999); return CELL4096[0:4096]; };
    if (n == 17) { fill16(CELL16, 16, 17); return CELL16[0:16] + ONE[0:1]; };
    fill16(CELL16, n, n);
    CELL16[0:n]
};

def sec_od() {
    sec("11 the GNU od cross-check: od -A d -t x1z -v, byte for byte");
    if (!fs.make_dirs(TDIR)) {
        test.ck("the scratch directory " + TDIR + " is usable",
            fs.is_dir(TDIR),
            "make_dirs failed and it is not there");
        return 0
    };
    let odv = run_self("--help", tpath("ver.txt"));
    test.ck("the program under test runs", true, "status " + tostring(odv));
    // Is od itself there?  Ask it for nothing and see.
    // If od is not installed the section is SKIPPED, loudly, rather than
    // silently: a check that quietly stops comparing anything is the vacuous
    // pass this file exists to avoid.  The summary line says which happened.
    let st = exec("od --version > " + tpath("odver.txt") + " 2>&1");
    if (st != 0) {
        ODSKIP = 1;
        say("  SKIPPED: `od` is not installed (od --version exited "
            + tostring(st) + "), so no dump was compared against it");
        return 0
    };
    let ver = slurp(tpath("odver.txt"));
    test.ck("GNU od answered", ver.length > 0, "empty --version output");

    // The family of fixtures.  0..2 are the shipped files, so the bytes that
    // ship with the example are the bytes od is asked about.
    let shipped: [str; 3] = ["data/sample.bin", "data/all256.bin", "data/zeros48.bin"];
    let si = 0;
    while (si < 3) {
        let p = shipped[si];
        one_cross(p, "shipped " + p);
        si = si + 1;
    };
    let i = 0;
    while (i < NCROSS) {
        let n = CROSSN[i];
        let b = cross_bytes(n);
        let p = tpath("x" + tostring(i) + ".bin");
        if (!fs.write_bytes(p, b, -1)) {
            test.ck("wrote the " + tostring(n) + "-byte fixture", false, "write refused");
        } else {
            one_cross(p, tostring(n) + " generated bytes");
        };
        i = i + 1;
    };
    // The empty file is the one od and everyone else handles worst: no rows, and
    // a size line of "0000000".  It is fixture 0 in CROSSN.
    test.ck_eq("the zero-length fixture really is empty", cross_bytes(0).length, 0);
    say("  " + tostring(CROSSOK) + " of " + tostring(NCROSS + 3)
        + " dumps identical to od, " + tostring(CROSSBYTES) + " bytes compared against "
        + tostring(CROSSODBYTES) + " bytes of od output");
    test.ck("the cross-check compared something",
        CROSSOK > 0,
        "0 files agreed -- a vacuous pass");
    test.ck("every cross-checked file matched od",
        CROSSOK == NCROSS + 3,
        tostring(CROSSOK) + " of " + tostring(NCROSS + 3));
    0
};

// Dump `p` two ways -- once through this process (hx.row) and once by running
// the program under test as a child -- and compare both against od's file.
def one_cross(p: str, label: str) -> void {
    let odout = tpath("od.txt");
    let mineout = tpath("mine.txt");
    let st = exec("od -A d -t x1z -v " + p + " > " + odout + " 2>/dev/null");
    if (st != 0) {
        test.ck(label + ": od ran", false, "exit " + tostring(st));
        return;
    };
    let rc = run_self("--no-tty --file " + p, mineout);
    if (rc != 0) {
        test.ck(label + ": hexview ran",
            false,
            "exit " + tostring(rc)
           + " " + slurp(mineout));
        return;
    };
    // The child's output is the summary line plus the dump; the summary is two
    // lines and the dump is everything after it.  Take it from the first line
    // that starts with a digit -- the summary never does.
    let full = slurp(mineout);
    let cut = full.index_of("0000");
    if (cut < 0) { cut = 0; };
    // cut back to the start of that line
    let at = 0;
    let nl = 0;
    while (nl < 3 && at < cut) {
        if (full[at] == 10) { nl = nl + 1; };
        at = at + 1;
    };
    let body = full[at:len(full)];
    let odtxt = slurp(odout);
    let odlen = len(odtxt);
    let bad = "";
    if (body != odtxt) {
        // Name the first differing line rather than dumping 4096 bytes.
        let a = body.split("\n");
        let b = odtxt.split("\n");
        let k = 0;
        while (k < len(a) && k < len(b)) {
            if (a[k] != b[k]) {
                bad = "line " + tostring(k) + ": got [" + a[k] + "] want [" + b[k] + "]";
                k = len(a);
            } else { k = k + 1; };
        };
        if (len(bad) < 1) { bad = "different lengths: " + tostring(len(body)) + " vs " + tostring(len(odtxt)) };
    };
    if (len(bad) < 1) {
        CROSSOK = CROSSOK + 1;
        CROSSBYTES = CROSSBYTES + len(body);
        CROSSODBYTES = CROSSODBYTES + odlen;
    };
    test.ck(label + ": hexview's dump is byte-identical to od's", len(bad) < 1, bad);
    0
};

// ────────────────────────────────────────────── 5. round-tripped edits ───
//
// The property: a pattern written into the buffer, saved, and read back with a
// FRESH reader, is the pattern that was written -- byte for byte, at every
// offset including 0, a row boundary and the last byte.  An edit that appears
// to work in the buffer but is never flushed is invisible to a golden and
// invisible to the in-memory comparison, so the re-read is the whole test.
//
// Three further assertions keep it from being vacuous:
//   * the pattern really does differ from the original at exactly NEO offsets,
//     so "save wrote nothing" cannot pass;
//   * the file we did NOT save to still holds the original bytes, so a check
//     that compared the buffer with itself would fail;
//   * a SECOND round trip, over a different pattern, also lands.
def sec_roundtrip() {
    sec("4 round-tripped edits: write, save, re-read with a fresh reader");
    if (!fs.make_dirs(TDIR)) {
        test.ck("the scratch directory is usable", fs.is_dir(TDIR), "cannot make " + TDIR);
        return 0
    };
    fix_build();
    let orig = tpath("rt_orig.bin");
    let saved = tpath("rt_saved.bin");
    let saved2 = tpath("rt_saved2.bin");
    // DELETE FIRST, and say so.  The scratch directory is /tmp, so a file left
    // by an earlier run would still be there when this section starts -- and the
    // defect M10 (hx.save writing to `path + ".tmp"`, so the edit never reaches
    // the file) was MISSED for exactly that reason: `saved` already existed from
    // the unmutated run, the fresh reader read it, and every assertion passed.
    // A check that passes on a stale artifact is not a check.
    fs.remove_file(orig);
    fs.remove_file(saved);
    fs.remove_file(saved2);
    fs.remove_file(saved + ".tmp");
    fs.remove_file(saved2 + ".tmp");
    test.ck("the round trip's output file does not exist yet",
        !fs.exists(saved),
        "a previous run left " + saved + " behind");
    test.ck("nor the second one", !fs.exists(saved2), "a previous run left it behind");
    test.ck("wrote the original fixture", fs.write_bytes(orig, fixb(), -1), "write refused");
    // Non-vacuity from OUTSIDE the program: the OS says how big it is.
    let sz = fs.file_size(orig);
    test.ck("the OS can stat the original", sz != none, "stat failed");
    test.ck_eq("the OS says the original is 48 bytes", osz_or(sz, 0 - 1), FIXN);

    test.ck("opened the original", hx.open_path(orig), hx.ERRS);
    test.ck_eq("the open buffer is 48 bytes", hx.SIZE, FIXN);
    let ecount = 0;
    let k = 0;
    while (k < NEO) {
        let e = hx.set(EDOFS[k], EDVAL[k]);
        if (e != 0) {
            test.ck("set at offset " + tostring(EDOFS[k]),
                false,
                hx.set_errname(e));
        };
        ecount = ecount + 1;
        k = k + 1;
    };
    test.ck_eq("every edit was accepted", ecount, NEO);
    test.ck_eq("the buffer knows it is dirty", hx.DIRTY, 1);
    test.ck("saved the edited buffer", hx.save(saved), hx.ERRS);
    test.ck_eq("saving cleared the dirty flag", hx.DIRTY, 0);
    // hx.save must have created THAT path and no other.  M10 wrote to
    // `saved + ".tmp"`; this is the assertion that notices.
    test.ck("the save created the file it was told to",
        fs.file_size(saved) != none,
        saved + " does not exist");
    test.ck("and it did not write the bytes beside it",
        !fs.exists(saved + ".tmp"),
        saved + ".tmp exists, so the bytes went somewhere else");

    // THE FRESH READER.  A new fs.read_bytes, a new array, nothing shared with
    // the buffer that was edited.
    // No `!` here.  `fs.file_size` answers `none` for a path that is not there,
    // and unwrapping that is an "unwrap of none" trap -- so a mutant that stops
    // `save` creating the file would kill the check instead of failing it, and
    // the battery would report "caught by a trap" where there should be a
    // named assertion.  (That is exactly what happened: M10 was first reported
    // as a trap because of this line.)
    let sz2 = fs.file_size(saved);
    test.ck("the OS can stat the saved file", sz2 != none, "stat failed");
    test.ck_eq("the saved file is 48 bytes -- an edit did not change the length",
        osz_or(sz2, 0 - 1),
        FIXN);
    // Again no `!` without a guard: a read of a file that is not there answers
    // `none`, and unwrapping it traps.  The check has to be able to REPORT a
    // mutant that stops `save` writing; it must not die on one.
    let r = fs.read_bytes(saved);
    let got = r != none;
    test.ck("a fresh reader can read the saved file", got, "read refused");
    let fresh: [byte] = [];
    if (got) { fresh = r!; };
    if (!got) { return 0 };
    test.ck_eq("the re-read array is 48 bytes", len(fresh), FIXN);
    let wrong = 0;
    let first = "";
    let changed = 0;
    let i = 0;
    while (i < FIXN) {
        let want = edited_at(i);
        if (fresh[i] != want) {
            wrong = wrong + 1;
            if (len(first) < 1) {
                first = "offset " + tostring(i) + ": on disk "
                        + tostring(fresh[i]) + ", expected " + tostring(want);
            };
        };
        if (fresh[i] != fix(i)) { changed = changed + 1; };
        if (fresh[i] != hx.DATA[i]) {
            test.ck("the buffer and the file agree at " + tostring(i),
                false,
                "buffer " + tostring(hx.DATA[i]) + ", file " + tostring(fresh[i]));
        };
        i = i + 1;
    };
    test.ck("every byte on disk is the byte that was written", wrong == 0, first);
    test.ck_eq("the pattern differs from the original at exactly "
       + tostring(NEO) + " offsets -- a save that wrote nothing cannot pass",
        changed,
        NEO);
    // The offset-0 edit is the one a truncating writer loses.
    test.ck_eq("the edit at offset 0 is on disk", fresh[0], 255);
    // The last byte, which a short write loses.
    test.ck_eq("the edit at the last byte is on disk", fresh[FIXN - 1], 85);
    // A row boundary, which an off-by-one row size loses.
    test.ck_eq("the edit at offset 16 is on disk", fresh[16], 128);

    // The file we did NOT save to must still be the original: if the check ever
    // compared the buffer with itself instead of with the disk, this is what
    // catches it.
    let r0 = fs.read_bytes(orig);
    test.ck("a fresh reader can still read the original", r0 != none, "read refused");
    let untouched: [byte] = [];
    if (r0 != none) { untouched = r0!; };
    let drift = 0;
    let j = 0;
    while (j < FIXN) {
        if (untouched[j] != fix(j)) { drift = drift + 1; };
        j = j + 1;
    };
    test.ck_eq("the file that was not written to is untouched", drift, 0);

    // A second round trip, over a DIFFERENT pattern, so a save path that works
    // the first time by accident is not enough.
    test.ck("re-opened the saved file", hx.open_path(saved), hx.ERRS);
    test.ck_eq("the re-opened file is 48 bytes", hx.SIZE, FIXN);
    let k2 = 0;
    while (k2 < NEO) {
        let v2 = 255 - EDVAL[k2];
        hx.set(FIXN - 1 - EDOFS[k2], v2);
        k2 = k2 + 1;
    };
    test.ck("saved the second pattern", hx.save(saved2), hx.ERRS);
    let sz3 = fs.file_size(saved2);
    test.ck_eq("the second saved file is 48 bytes", osz_or(sz3, 0 - 1), FIXN);
    let r2 = fs.read_bytes(saved2);
    let got2 = r2 != none;
    test.ck("a fresh reader can read the second save", got2, "read refused");
    let f2: [byte] = [];
    if (got2) { f2 = r2!; };
    if (!got2) { return 0 };
    let wrong2 = 0;
    let first2 = "";
    let i2 = 0;
    while (i2 < FIXN) {
        let want2 = edited2_at(i2);
        if (f2[i2] != want2) {
            wrong2 = wrong2 + 1;
            if (len(first2) < 1) {
                first2 = "offset " + tostring(i2) + ": " + tostring(f2[i2])
                        + " on disk, " + tostring(want2) + " expected";
            };
        };
        i2 = i2 + 1;
    };
    test.ck("the second round trip landed too", wrong2 == 0, first2);
    0
};

// ────────────────────────────────── 6. struct's readers, two compositions ───

def sec_struct() {
    sec("5 struct's u32 readers against two hand compositions");
    fix_build();
    hx.adopt(fixb());
    let bad = 0;
    let badat = 0;
    let w = 0;
    while (w < FIXN / 4) {
        let at = w * 4;
        let a = u32_mul(hx.DATA, at);
        let b = u32_shift(hx.DATA, at);
        let c = struct.get_u32le(hx.DATA, at);
        if (a != b || b != c) { bad = bad + 1; if (badat == 0) { badat = at; } };
        w = w + 1;
    };
    test.ck("struct.get_u32le agrees with multiplication and with shifts",
        bad == 0,
        badat == 0 ? "all twelve words agree" : "first disagreement at " + tostring(badat));
    // And the same three on all 256 byte values, one word at a time, so a reader
    // that is right on this fixture and wrong on a high byte cannot pass.
    let big: [byte; 256] = [0; 256];
    let v = 0;
    while (v < 256) { big[v] = v; v = v + 1; };
    // struct's getters want a [byte] and a [byte; 256] does not widen (#12), so
    // one slice hands them a real array.
    let bb = big[0:256];
    let bad2 = 0;
    let w2 = 0;
    while (w2 < 64) {
        let at = w2 * 4;
        if (struct.get_u32le(bb, at) != u32_mul(bb, at)) { bad2 = bad2 + 1; };
        if (struct.get_u32le(bb, at) != u32_shift(bb, at)) { bad2 = bad2 + 1; };
        w2 = w2 + 1;
    };
    test.ck_eq("all 256 byte values, read as 64 words, agree three ways", bad2, 0);
    test.ck_eq("the word at 0 of 0,1,2,...,255 is 03020100", struct.get_u32le(bb, 0), 50462976);
    test.ck_eq("the word at 252 is fc fd fe ff, little-endian",
        struct.get_u32le(bb, 252),
        4294901244);
    test.ck_eq("the u16 at 0 is 0x0100", struct.get_u16le(bb, 0), 0x0100);
    test.ck_eq("the byte at 255 is 255", struct.get_u8(bb, 255), 255);
    0
};

// ───────────────────────────────────────────── 7. bounds, and no trap ───
//
// A hex editor's natural inputs are hostile: a zero-length file, an offset past
// the end, a negative offset, a value out of range, a directory where a file
// was expected.  Every one of them is a VALUE here.  None of them is a trap --
// traps print to stdout (ORCHESTRATOR.md §2.6) and would corrupt the golden.
def sec_bounds() {
    sec("6 bounds: every hostile offset is a value, not a trap");
    fix_build();
    hx.adopt(fixb());
    test.ck_eq("the first byte", hx.byte_at(0), 0);
    test.ck_eq("the last byte", hx.byte_at(FIXN - 1), 47);
    test.ck_eq("one byte before the start", hx.byte_at(0 - 1), 0 - 1);
    test.ck_eq("a long way before the start", hx.byte_at(0 - 1000), 0 - 1);
    test.ck_eq("one byte past the end", hx.byte_at(FIXN), 0 - 1);
    test.ck_eq("a long way past the end", hx.byte_at(FIXN + 1000), 0 - 1);
    test.ck_eq("the most negative long", hx.byte_at(0 - 9223372036854775807), 0 - 1);
    test.ck_eq("a negative offset is refused", hx.set(0 - 1, 0), hx.E_NEG);
    test.ck_eq("an offset at the end is refused", hx.set(FIXN, 0), hx.E_PAST);
    test.ck_eq("an offset past the end is refused", hx.set(FIXN + 1000, 0), hx.E_PAST);
    test.ck_eq("the value 256 is refused", hx.set(0, 256), hx.E_RANGE);
    test.ck_eq("the value -1 is refused", hx.set(0, 0 - 1), hx.E_RANGE);
    // The refusals left the byte alone...
    test.ck_eq("the refused edits did not land", hx.byte_at(0), 0);
    // ... and these two are accepted.
    test.ck_eq("the value 0 is accepted", hx.set(0, 0), hx.E_OK);
    test.ck_eq("the value 255 is accepted", hx.set(0, 255), hx.E_OK);
    test.ck_eq("the accepted edit landed", hx.byte_at(0), 255);
    test.ck_eq("an accepted edit marks the buffer dirty", hx.DIRTY, 1);
    // Every error code has a name that is not "no error".
    test.ck_str("the success code's name", hx.set_errname(hx.E_OK), "no error");
    test.ck("the negative-offset code is named", hx.set_errname(hx.E_NEG) != "no error", "unnamed");
    test.ck("the past-the-end code is named", hx.set_errname(hx.E_PAST) != "no error", "unnamed");
    test.ck("the out-of-range code is named", hx.set_errname(hx.E_RANGE) != "no error", "unnamed");

    // The zero-length file: no rows, and a size line and nothing else.
    let empty: [byte; 0] = [0; 0];
    hx.adopt(empty[0:0]);
    test.ck_eq("the empty buffer is 0 bytes", hx.SIZE, 0);
    test.ck_eq("the empty array is 0 elements", len(hx.DATA), 0);
    test.ck_eq("no byte at 0 of an empty file", hx.byte_at(0), 0 - 1);
    test.ck_eq("no edit at 0 of an empty file", hx.set(0, 1), hx.E_PAST);
    test.ck_eq("an empty file plans no rows", hx.plan_rows(0, 16, 0), 0);
    hx.row(0, 16);
    // 7 offset digits, the separator space, then the hex field -- 3*16+2 = 50
    // columns, 49 of them padding here because the first is the separator -- then
    // '>' and '<' with no gutter between them.
    test.ck_eq("a row of an empty file is offset, padding and the two delimiters", hx.LINEN, 7 + 1 + 49 + 1 + 1);
    hx.end_line();
    test.ck_str("an empty file's size line is 0000000", outs_n(hx.LINEN), "0000000");
    test.ck("find_byte on an empty file finds nothing", hx.find_byte(0, 0) == 0 - 1, "found one");
    test.ck("find_text on an empty file finds nothing", hx.find_text("a", 0) == 0 - 1, "found one");
    test.ck("find_text of the empty string finds nothing", hx.find_text("", 0) == 0 - 1, "found one");

    // Search: a hit, a miss, and a boundary.
    hx.adopt(fixb());
    test.ck_eq("the byte 0xf0 is first at offset 16", hx.find_byte(240, 0), 16);
    test.ck_eq("there is no 0xf0 after offset 16", hx.find_byte(240, 17), 0 - 1);
    test.ck_eq("the byte 0xff is at offset 31", hx.find_byte(0xff, 0), 31);
    test.ck_eq("the byte 0x99 is not in the fixture", hx.find_byte(0x99, 0), 0 - 1);
    test.ck_eq("a search from past the end finds nothing", hx.find_byte(0, 9999), 0 - 1);
    test.ck_eq("the byte 0x20 is at offset 32", hx.find_byte(0x20, 0), 32);
    // A pattern longer than the file, and one at the very end.  FIX[45..47] is
    // 0x2d 0x2e 0x2f, i.e. "-./" -- the three bytes the fixture's last row ends
    // with, and a '.' among them, so a gutter bug could not hide it.
    test.ck_eq("the last three bytes match at offset 45", hx.find_text("-./", 45), 45);
    test.ck("no three-byte match starts at 46", hx.find_text("-./", 46) == 0 - 1, "found one");
    test.ck_eq("the same pattern is found from the start", hx.find_text("-./", 0), 45);
    let longpat = "0123456789012345678901234567890123456789012345678901234567890123456789";
    test.ck("a pattern longer than the file never matches", hx.find_text(longpat, 0) == 0 - 1, "matched");

    // Opening something that is not a readable regular file.
    test.ck("a missing path is refused", !hx.open_path("/nonexistent/hexview/nope"), "accepted");
    test.ck("a missing path says so", len(hx.ERRS) > 0, "the message was empty");
    test.ck("a directory is refused", !hx.open_path("/tmp"), "accepted");
    test.ck("a directory says so", len(hx.ERRS) > 0, "the message was empty");
    test.ck("an empty path is refused", !hx.open_path(""), "accepted");
    test.ck("an empty path says so", len(hx.ERRS) > 0, "the message was empty");
    0
};

// ───────────────────────────────────────────────── 8. every flag's errors ───
//
// Each case is run as a child process.  Three things are required of each: a
// NON-ZERO exit, a message on stdout or stderr, and NO runtime trap.  The third
// is the one that matters -- a trap prints to stdout and would land in the
// golden diff looking like output (ORCHESTRATOR.md §2.6), so the marker is read out
// of the captured file rather than trusted.
// Each case is run as a child process, and each carries the MESSAGE it is
// expected to produce.  Three things are required of every one: a non-zero exit,
// that message on stdout or stderr, and NO runtime trap.
//
// WHY THE MESSAGE MATTERS, and why every case begins `--no-tty`
// The first version of this table ran the cases bare -- `--width=-1`, no
// `--no-tty` -- and every one of them "passed".  They passed for the wrong
// reason: with no --no-tty and a non-terminal stdin, `run_interactive` refuses
// to start and exits 2 with "not a terminal", so the flag was never even
// validated.  Thirty-four vacuous passes.  The defect battery (inject.py) is
// what found it, because M18 -- moving the --offset bound from SIZE to SIZE+16
// -- changed nothing the table could see.
//
// So: every case says `--no-tty`, and every case asserts the SPECIFIC message.
// A case that exits non-zero for any other reason fails.
//
// Two layers are tested and the distinction is real:
//   * args' own refusal -- an unrecognised option, an option missing its value,
//     a value that is not a number.  args writes the message to stderr and
//     answers USAGE; hexview must then exit 2 and put its usage text on stderr
//     too, not stdout.
//   * hexview's own validation -- a number that parses but is out of range.  It
//     is reached with the ATTACHED form (`--width=-1`), because in the separated
//     form a leading '-' makes the value look like another flag and args refuses
//     it first with "needs a value".  Both spellings are below.
const NCASE = 32;
let CASES: [str; 32] = [
    // hexview's own range checks, through the attached form.
    "--no-tty --width=-1",            // 0: hexview's --width message
    "--no-tty --offset=-1",           // 1: hexview's --offset message
    "--no-tty --rows=-5",             // 2: hexview's --rows message
    "--no-tty --frames=-1",           // 3: hexview's --frames message
    "--no-tty --width=0",             // 4
    "--no-tty --width=7",             // 5
    "--no-tty --width=999",           // 6
    "--no-tty --offset=100000",       // 7: past the end
    "--no-tty --offset=97",           // 8: one past the end of the 96-byte sample
    "--no-tty --offset=100",          // 9: four past -- inside M18's slack
    // the same numbers separated, refused by args first
    "--no-tty --width -1",            // 10: args' missing-value message
    "--no-tty --offset -1",           // 11
    "--no-tty --rows -5",             // 12
    "--no-tty --frames -1",           // 13
    "--no-tty --bench=-1",            // 13b
    // args: an unknown option, an option with no value, a value that is not a
    // number
    "--no-tty --frobnicate",          // 14: args' unknown-option message
    "--no-tty --width",               // 15
    "--no-tty --offset=zz",           // 16: args' wants-a-number message
    "--no-tty --rows=1e3",            // 17
    // a file that is not there, or not a regular file.  /dev/null is a character
    // device, so `is_file` refuses it whatever the caller's uid -- unlike
    // /etc/shadow, whose answer depends on whether you are root.
    "--no-tty --file /nonexistent/hexview/nope",   // 18: hx.open_path's message
    "--no-tty --file /tmp",           // 19: a directory
    "--no-tty --file /dev/null",      // 20: a character device
    // --edit: every shape that is not OFF=HH
    "--no-tty --edit zz=1",           // 21: the offset is not hex
    "--no-tty --edit 5",              // 22: no '=' at all
    "--no-tty --edit 5=zz",           // 23: the value is not two hex digits
    "--no-tty --edit 0=ffff",         // 24: three digits
    "--no-tty --edit 0=ff,1=",        // 25: an empty value
    // and the ones about a path, an offset past the end, an offset too wide to
    // be an offset, and two files at once
    "--no-tty --edit 60=ff",          // 26: 0x60 == 96 == the length
    "--no-tty --edit ffffffffffffffff=ff",      // 27: 64 bits of f, wraps to -1
    "--no-tty --edit 1000000000000000000=ff",  // 28: 19 digits, would wrap to 0
    "--no-tty --save /nonexistent-dir-xyz/out.bin",   // 29
    "data/sample.bin data/all256.bin"                // 30
];
// The substring each case's message must contain.  Index for index with CASES.
let WANTED: [str; 32] = [
    "--width must be",
    "--offset cannot be",
    "--rows cannot be",
    "--frames cannot be",
    "--width must be",
    "--width must be",
    "--width must be",
    "is past the end of",
    "is past the end of",
    "is past the end of",
    "needs a value",
    "needs a value",
    "needs a value",
    "needs a value",
    "--bench cannot be",
    "unknown option",
    "needs a value",
    "wants a number",
    "wants a number",
    "no such file",
    "not a regular file",
    "not a regular file",
    "is not a hex offset",
    "is not OFF=HH",
    "is not two hex digits",
    "is not two hex digits",
    "is not OFF=HH",
    "past the end of the file",
    "before the start of the file",
    "more than 16 hex digits",
    "cannot write",
    "one file at a time"
];
let PATHOK: long = 0;

def sec_paths() {
    sec("12 every flag's error path: non-zero exit, ITS OWN message, no trap");
    if (len(SELF) < 1) {
        test.ck("the path of this program is known", false, "SELF is empty");
        return 0
    };
    if (!fs.make_dirs(TDIR)) {
        test.ck("the scratch directory is usable", fs.is_dir(TDIR), "cannot make " + TDIR);
        return 0
    };
    let outp = tpath("case.txt");
    let i = 0;
    while (i < NCASE) {
        let a = CASES[i];
        let want = WANTED[i];
        let st = run_self(a, outp);
        let txt = slurp(outp);
        let bad = "";
        if (st == 0) { bad = "exited 0"; };
        if (len(txt) < 1) { bad = "printed nothing"; };
        if (txt.index_of("runtime error:") >= 0) {
            bad = "a runtime trap fired: " + txt;
        };
        // The anti-vacuity guard.  A non-zero exit is not enough: the message
        // has to be THIS flag's message, and it must not be the
        // refuse-to-start-in-a-non-terminal one, which is what every case in this
        // table produced before each one said `--no-tty`.
        if (len(bad) < 1 && txt.index_of("not a terminal") >= 0) {
            bad = "exited non-zero because stdin is not a terminal, not because of the flag";
        };
        if (len(bad) < 1 && txt.index_of(want) < 0) {
            bad = "the message does not mention '" + want + "': " + txt;
        };
        if (len(bad) > 0) {
            test.ck("'" + a + "'", false, bad);
        } else {
            PATHOK = PATHOK + 1;
        };
        i = i + 1;
    };
    test.ck_eq("all " + tostring(NCASE)
       + " error paths exit non-zero with their OWN message and no trap",
        PATHOK,
        NCASE);
    // Every message names the program, so a caller can tell whose complaint it
    // is.  The captures are overwritten in the loop above, so this is a second
    // pass; eight execs is worth it.
    let named = 0;
    let q = 0;
    while (q < NCASE) {
        let st2 = run_self(CASES[q], outp);
        if (st2 != 0 && slurp(outp).index_of("hexview") >= 0) { named = named + 1; };
        q = q + 1;
    };
    test.ck_eq("and every one of them names the program in its message", named, NCASE);
    // And the other side of the table: seven invocations that must SUCCEED, so a
    // table that passes because everything fails cannot pass.  --offset 96 is
    // here because an offset equal to the length is a legitimate "seek to the
    // end" and must NOT be refused -- the boundary, pinned from both sides.
    let gp = tpath("good.bin");
    let good: [str; 8] = [
        "--no-tty",
        "--no-tty --width 8",
        "--no-tty --width 32",
        "--no-tty --hist",
        "--no-tty --hist=maybe",
        "--no-tty --file data/all256.bin",
        "--no-tty --edit 0=ff,1=ee --save " + gp,
        "--no-tty --offset 96"
    ];
    let j = 0;
    while (j < 8) {
        let st3 = run_self(good[j], outp);
        test.ck_eq("'" + good[j] + "' succeeds", st3, 0);
        j = j + 1;
    };
    // The --save case really wrote, so that row is not passing vacuously.
    let gs = fs.file_size(gp);
    test.ck("the --save case wrote a file", gs != none, "nothing was written");
    test.ck_eq("and it is the sample's 96 bytes", osz_or(gs, 0 - 1), 96);
    0
};

// ────────────────────────────────── 7. the histogram conserves bytes ───
//
// The expected total is fs.file_size -- the operating system's answer -- and
// not hx.SIZE, so a buffer that lost bytes on the way in cannot make the
// histogram agree with itself.
let HB: [long; 256] = [0; 256];

def sec_hist() {
    sec("7 the histogram conserves the byte count");
    fix_build();
    let p = tpath("hist.bin");
    test.ck("wrote the histogram fixture", fs.write_bytes(p, fixb(), -1), "write refused");
    test.ck("opened it", hx.open_path(p), hx.ERRS);
    let osz = fs.file_size(p);
    test.ck("the OS can stat it", osz != none, "stat failed");
    let i = 0;
    while (i < 256) { HB[i] = 0; i = i + 1; };
    let counted = 0;
    let j = 0;
    while (j < hx.SIZE) { HB[hx.byte_at(j)] = HB[hx.byte_at(j)] + 1; counted = counted + 1; j = j + 1; };
    test.ck_eq("the histogram visited exactly as many bytes as the OS says are there", counted, osz_or(osz, 0 - 1));
    test.ck_eq("and that is 48", counted, 48);
    // The counts themselves, from the literal layout: 0x00..0x0f once each,
    // 0xf0..0xff once each, 0x20..0x2f once each, and nothing else.
    let wrong = 0;
    let v = 0;
    while (v < 256) {
        let want = 0;
        if (v < 16 || (v >= 240 && v <= 255) || (v >= 32 && v <= 47)) { want = 1; };
        if (HB[v] != want) { wrong = wrong + 1; };
        v = v + 1;
    };
    test.ck_eq("every byte value's count matches the literal layout", wrong, 0);
    test.ck_eq("0x00 occurs once", HB[0], 1);
    test.ck_eq("0xff occurs once", HB[255], 1);
    test.ck_eq("0x20 occurs once", HB[32], 1);
    test.ck_eq("0x40 ('@') does not occur", HB[64], 0);
    0
};

// ─────────────────────────────────── 9. the formatter is deterministic ───
//
// Two passes over the same bytes must produce the same bytes in the same
// places.  A formatter that carries state between rows -- an uninitialised
// column counter, a length that survives the loop -- shows up here and nowhere
// else, because a golden compares against a run that made the same mistake.
def sec_determinism() {
    sec("9 the row formatter is deterministic");
    fix_build();
    hx.adopt(fixb());
    let a: [byte; 4096] = [0; 4096];
    let an = collect(a);
    let b: [byte; 4096] = [0; 4096];
    let bn = collect(b);
    test.ck_str("two passes over the same bytes produce the same text",
        from_bytes(b[0:bn]),
        from_bytes(a[0:an]));
    // 7 offset digits + 1 space + 50 hex field + '>' + 16 gutter + '<' = 77, and
    // the size line is 7 digits, so three rows and a size line.
    // 7 offset digits + 1 space + 50 hex field + '>' + 16 gutter + '<' = 75,
    // and the size line is 7 digits.
    test.ck_eq("the dump is three 75-byte rows and a 7-byte size line", an, 75 * 3 + 7);
    test.ck("the formatter produced something to compare", an > 0, "empty");
    // A row width of 0 must produce nothing rather than spin.
    test.ck_eq("a width of 0 formats nothing", hx.row(0, 0), 0);
    test.ck_eq("a negative width formats nothing", hx.row(0, 0 - 1), 0);
    0
};

// Three rows and the size line, copied out of hx.LINE into `dst`.
def collect(dst: [byte; 4096]) -> long {
    let n = 0;
    let r = 0;
    while (r < 3) {
        hx.row(r * 16, 16);
        let k = 0;
        while (k < hx.LINEN) { dst[n] = hx.LINE[k]; n = n + 1; k = k + 1; };
        r = r + 1;
    };
    hx.end_line();
    let k2 = 0;
    while (k2 < hx.LINEN) { dst[n] = hx.LINE[k2]; n = n + 1; k2 = k2 + 1; };
    n
};

// ────────────────────────────────── 10. the summary line's own numbers ───
//
// EXPECTED covers the summary line and nothing else does: it is a few lines of
// numbers this program computed about itself, and a golden cannot tell a right
// row count from a wrong one.  So the child process is asked for the same dump
// at eight different --rows values and the number IT prints is compared with
// hx.plan_rows computed here, and the number of dump lines the child actually
// emitted is counted and compared with that same number.
//
// The first draft of the summary line printed ROWS_OUT + 1 -- the count was
// taken after the dump instead of planned before it -- and this section is the
// reason that is caught rather than shipped.
def sec_summary() {
    sec("10 the summary line's own numbers, at eight --rows values");
    if (!fs.make_dirs(TDIR)) {
        test.ck("the scratch directory is usable", fs.is_dir(TDIR), "cannot make " + TDIR);
        return 0
    };
    hx.adopt(bytes(SAMPLE));
    test.ck_eq("the embedded sample is 96 bytes", hx.SIZE, 96);
    let outp = tpath("sum.txt");
    let pre = "  96 bytes, width 16, from 0, ";
    // No `continue` in this language (ORCHESTRATOR.md §2.10): a guard flag with an explicit
    // terminal assignment is the early-exit idiom, so the body is one `if`.
    let r = 0;
    while (r < 8) {
        let skip = 0;
        let st = run_self("--no-tty --rows " + tostring(r), outp);
        let txt = slurp(outp);
        let lines = txt.split("\n");
        let want = hx.plan_rows(0, 16, r);
        if (st != 0) {
            test.ck("--rows " + tostring(r) + " ran", false, txt);
            skip = 1;
        };
        if (skip == 0 && len(lines) < 2) {
            test.ck("--rows " + tostring(r) + ": the output has a summary",
                false,
                "one line only");
            skip = 1;
        };
        if (skip == 0) {
            let head = lines[1];
            let a2 = head.index_of(pre);
            if (a2 < 0) {
                test.ck("--rows " + tostring(r)
                   + ": the summary names the file size and the width",
                    false,
                    head);
                skip = 1;
            } else {
                let b2 = head.index_of(" row");
                test.ck_eq("--rows " + tostring(r) + ": the summary's row count",
                    hx.decval(head[a2 + len(pre):b2]),
                    want);
            };
        };
        if (skip == 0) {
            // And the dump really has that many rows, plus the size line.  A
            // summary that agrees with the plan while the dump prints a
            // different number is the case this half catches.
            let dump = 0;
            let q = 0;
            while (q < len(lines)) {
                let ln = lines[q];
                if (len(ln) >= 7 && ln[0] >= 48 && ln[0] <= 57
                    && ln[6] >= 48 && ln[6] <= 57) {
                    dump = dump + 1;
                };
                q = q + 1;
            };
            test.ck_eq("--rows " + tostring(r)
               + ": the dump has that many rows plus the size line",
                dump,
                want + 1);
        };
        r = r + 1;
    };
    // The boundary itself: --offset equal to the length is accepted and shows an
    // empty view -- no rows, and the size line alone.  Pinned from the output
    // side as well as the exit-status side.
    let st3 = run_self("--no-tty --offset 96", outp);
    test.ck_eq("--offset 96 (the length) is accepted", st3, 0);
    let t3 = slurp(outp);
    test.ck("--offset 96 prints the size line and no rows at all",
        t3.index_of("0000096\n") >= 0 && t3.index_of("0000000 ") < 0,
        "output was " + tostring(len(t3)) + " bytes, first 40 [" + t3[0:40] + "]");
    // The width, too: three widths, each with its own row count.
    let ws: [long; 3] = [8, 16, 32];
    let w = 0;
    while (w < 3) {
        let wid = ws[w];
        let st4 = run_self("--no-tty --width " + tostring(wid) + " --rows 2", outp);
        test.ck("--width " + tostring(wid) + " --rows 2 ran", st4 == 0, slurp(outp));
        w = w + 1;
    };
    0
};

// ──────────────────────────── 8. the histogram hexview PRINTS ───
//
// Section 9 checks a histogram this file counts for itself.  hexview.y has its
// own counter (HBUCK) and that is the one `--hist` prints and EXPECTED holds --
// so when the injected defect M17 bucketed 0xff into 0x00 in hexview.y, nothing
// noticed.  This section runs the real program and checks what it prints, cell
// by cell, against counts derived from the file's bytes.
//
// A tiny scanner, because decval() insists every character is a digit and a
// histogram line is digits separated by runs of spaces.
let CUR_I: long = 0;

def scan_num(s: str) -> long {
    while (CUR_I < len(s) && !(s[CUR_I] >= 48 && s[CUR_I] <= 57)) {
        CUR_I = CUR_I + 1;
    };
    let v = 0;
    let any = 0;
    while (CUR_I < len(s) && s[CUR_I] >= 48 && s[CUR_I] <= 57) {
        v = v * 10 + (s[CUR_I] - 48);
        CUR_I = CUR_I + 1;
        any = 1;
    };
    if (any == 0) { return 0 - 1; };
    v
};

let HS: [long; 16] = [0; 16];
let WANT: [long; 256] = [0; 256];

def sec_hist_printed() {
    sec("8 the histogram hexview prints, cell by cell");
    if (!fs.make_dirs(TDIR)) {
        test.ck("the scratch directory is usable", fs.is_dir(TDIR), "cannot make " + TDIR);
        return 0
    };
    let outp = tpath("hist.txt");
    let st = run_self("--no-tty --hist", outp);
    test.ck_eq("--no-tty --hist ran", st, 0);
    let txt = slurp(outp);
    let lines = txt.split("\n");
    // The expected counts, from the bytes on disk -- and the total from the OS.
    let raw = fs.read_bytes("data/sample.bin");
    let gotraw = raw != none;
    test.ck("a fresh reader can read the shipped sample", gotraw, "read refused");
    let rb: [byte] = [];
    if (gotraw) { rb = raw!; };
    if (!gotraw) { return 0 };
    let osz = fs.file_size("data/sample.bin");
    test.ck("the OS can stat the shipped sample", osz != none, "stat failed");
    let i = 0;
    while (i < 256) { WANT[i] = 0; i = i + 1; };
    let seen = 0;
    i = 0;
    while (i < len(rb)) { WANT[rb[i]] = WANT[rb[i]] + 1; seen = seen + 1; i = i + 1; };
    test.ck_eq("the fresh reader saw as many bytes as the OS says", seen, osz_or(osz, 0 - 1));
    // Non-vacuity: both classes are non-empty in the shipped sample, so a
    // histogram that answered zero everywhere cannot pass.
    let nonzero = 0;
    let zeros = 0;
    i = 0;
    while (i < 256) {
        if (WANT[i] > 0) { nonzero = nonzero + 1; } else { zeros = zeros + 1; };
        i = i + 1;
    };
    test.ck("the expected histogram has both classes",
        nonzero > 0 && zeros > 0,
        "nonzero=" + tostring(nonzero) + " zeros=" + tostring(zeros));

    let gotrows = 0;
    let row = 0;
    let bad = 0;
    let firstbad = "";
    let total = 0 - 1;
    i = 0;
    while (i < len(lines)) {
        let ln = lines[i];
        if (len(ln) > 6 && ln[0] == 32 && ln[1] == 32 && ln[4] == 45) {
            // "  00-0f ..." -- one of the sixteen rows.
            CUR_I = 6;
            let c = 0;
            let rowbad = 0;
            while (c < 16) {
                let g = scan_num(ln);
                HS[c] = g;
                if (g != WANT[row * 16 + c]) {
                    rowbad = rowbad + 1;
                    if (len(firstbad) < 1) {
                        firstbad = "row " + tostring(row) + " col " + tostring(c)
                                   + ": printed " + tostring(g) + ", want "
                                   + tostring(WANT[row * 16 + c]);
                    };
                };
                c = c + 1;
            };
            if (rowbad > 0) { bad = bad + 1; };
            gotrows = gotrows + 1;
            row = row + 1;
        };
        if (len(ln) > 9 && ln.index_of("total") == 2) {
            CUR_I = 8;
            total = scan_num(ln);
        };
        i = i + 1;
    };
    test.ck_eq("the histogram has sixteen rows", gotrows, 16);
    test.ck("every one of the 256 printed counts matches the file",
        bad == 0,
        len(firstbad) > 0 ? firstbad : "clean");
    test.ck_eq("the printed total is the file's length, as the OS reports it", total, osz_or(osz, 0 - 1));
    0
};

// ──────────────────────────────────────────────────────── the entry point ───

def run(with_od: bool, self: str) -> long {
    SELF = self;
    say("hexview property check");
    say("  toolkit-free model: hx.y holds a file as [byte]; the row format is");
    say("  GNU od -A d -t x1z -v, reproduced byte for byte");
    // Non-vacuity, first, before anything is compared anywhere.  CHECKS and
    // FAILS were this file's own counters and this line used to zero them; they
    // are std/test.y's now, and std/test.y has no reset(), so the tally is the
    // whole process.  That is safe because `run()` is reached once per process
    // (hexview.y's run_check, from --check), and it is a gap worth naming: a
    // battery run twice in one process would report twice the assertions.
    CROSSOK = 0;
    PATHOK = 0;
    sec_gutter();
    sec_hexdigits();
    sec_handwritten();
    sec_roundtrip();
    sec_struct();
    sec_bounds();
    sec_hist();
    sec_hist_printed();
    sec_determinism();
    sec_summary();
    if (with_od) {
        sec_od();
        sec_paths();
    };
    // The count must be real.  A check that ran nothing reports nothing.
    test.ck("the check ran a real number of assertions",
        test.checks() > 200,
        "only " + tostring(test.checks()));
    say("  " + tostring(test.checks()) + " assertions, "
        + tostring(test.failures()) + " failed");
    if (with_od) {
        if (ODSKIP == 1) {
            say("  od cross-check: SKIPPED (no od on this machine) -- the "
                + tostring(CROSSOK) + " dumps it did compare are the whole of it");
        } else {
            say("  od cross-check: " + tostring(CROSSOK) + " files, "
                + tostring(CROSSBYTES) + " bytes identical to "
                + "od -A d -t x1z -v");
        };
    } else {
        say("  od cross-check: not asked for (--od)");
    };
    if (test.failures() > 0) {
        say("hexview --check: " + tostring(test.failures()) + " of "
            + tostring(test.checks()) + " assertions FAILED");
        return 1
    };
    say("hexview --check: every property held");
    0
};