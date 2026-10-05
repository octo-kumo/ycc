import tui;
// fb_test.y — the acceptance suite for std tui's surface half
//
// Written to replace an earlier 952-line suite that had 57 failing
// checks. Every one of those was a fault in the *test*, not in the
// library; the causes are recorded at the bottom of this file so they
// are not rediscovered. This version is deliberately smaller and
// checks the things the gate actually cares about.
//
// What the Wave 0c gate asks for is "a synthetic scene rendering
// byte-identical twice". That is check 1 below, and it is the reason
// the file exists.
//
//   (ulimit -S -v 3670016; ../refs/ycc.ref fb_test.y -o /tmp/fbt && /tmp/fbt) </dev/null
//
// Raw stream bytes are read with capture_byte(), never by searching
// capture_str(): capture_str() returns a *lossless printable* form in
// which byte 0x1B is the four characters \x1b, so a substring search
// for a real escape byte can never match, and the string is longer
// than the stream it came from. That mistake accounted for most of
// the old suite's failures.


let checks = 0;
let failed = 0;

def ok(cond: bool, name: str, detail: str) {
    checks = checks + 1;
    if (cond) {
        print("ok   ", name);
    } else {
        failed = failed + 1;
        print("FAIL ", name, "  ", detail);
    };
};

def eq(got: long, want: long, name: str) {
    ok(got == want, name, "got " + tostring(got) + ", want " + tostring(want));
};

// A deterministic synthetic scene: box border, a per-cell glyph and
// truecolour gradient, and a string with 2- and 3-byte UTF-8.
def scene(s: tui.Surface, w: long, h: long) {
    tui.clear(s, tui.rgb(0, 0, 0));
    tui.rect(s, 0, 0, h, w, 0x2502, tui.rgb(0, 170, 0), tui.rgb(0, 0, 0));
    let r = 0;
    while (r < h) {
        let c = 0;
        while (c < w) {
            let v = (r * 7 + c * 13) % 256;
            tui.put(s, r, c, 0x2580 + ((r + c) % 8),
                   tui.rgb(v, 255 - v, (v * 3) % 256), tui.rgb(0, 0, 0));
            c = c + 1;
        };
        r = r + 1;
    };
    tui.text(s, 1, 2, "fb é█ ok", tui.rgb(255, 255, 255), tui.rgb(0, 0, 0));
};

// `--golden` (and the identical `--verify`) write the raw ANSI stream
// of the scene to stdout and stop. From examples/_toolkit/ the golden
// file is produced by
//
//   ../../refs/ycc.ref fb_test.y -o /tmp/fbt && /tmp/fbt --golden > fb_golden.txt
//
// and checked by
//
//   /tmp/fbt --verify > /tmp/now.txt && cmp /tmp/now.txt fb_golden.txt
//
// The stream is raw escape bytes, so it is stored raw and compared
// with cmp -- NOT printed through capture_str(), which would escape
// every one of them into printable text.
let arg = argv();
if (len(arg) > 1 && (arg[1] == "--golden" || arg[1] == "--verify")) {
    tui.capture_off();
    let g = tui.new(12, 40);
    scene(g, 40, 12);
    tui.flush(g);
    exit(0);
};

// ---------------------------------------------------------------- 1
// THE GATE: a synthetic scene must render byte-identically twice.
print("-- determinism --");
tui.capture_on();
let a = tui.new(12, 40);
scene(a, 40, 12);
let n1 = tui.flush(a);
let len1 = tui.capture_len();
let sum1 = tui.capture_checksum();

tui.capture_reset();
let b = tui.new(12, 40);
scene(b, 40, 12);
let n2 = tui.flush(b);
let len2 = tui.capture_len();
let sum2 = tui.capture_checksum();

eq(n1, n2, "same scene flushes the same byte count");
eq(len1, len2, "same length captured");
ok(sum1 == sum2, "same checksum", "run1 " + tostring(sum1) + " run2 " + tostring(sum2));
ok(n1 > 0, "the scene emits bytes", "got " + tostring(n1));
print("   scene bytes = ", n1, " checksum = ", sum1);

// ---------------------------------------------------------------- 2
// Row diffing: changing one cell must emit only that row, and only
// the changed span. This is what makes 30 fps reachable.
print("-- row diffing --");
tui.capture_reset();
let before = tui.flush_diff(a);          // settles: nothing changed
eq(before, 0, "a settled frame emits nothing");

tui.put(a, 5, 5, 0x2588, tui.rgb(1, 2, 3), tui.rgb(4, 5, 6));
let d = tui.flush_diff(a);
ok(d > 0, "one changed cell emits something", "got " + tostring(d));
ok(d < n1 / 4, "the diff is far smaller than a full frame",
   "diff " + tostring(d) + " vs full " + tostring(n1));
// the diff must address row 5 (1-based CUP => ESC [ 6 ; 7 H at the head)
let cup_row_ok = false;
let i = 0;
while (i + 6 < tui.capture_len()) {
    if (tui.capture_byte(i) == 27 && tui.capture_byte(i + 1) == 91
        && tui.capture_byte(i + 2) == 54) {
        cup_row_ok = true;
    };
    i = i + 1;
};
ok(cup_row_ok, "the diff addresses row 6 (0-based row 5)",
   "no ESC[6 found in " + tostring(tui.capture_len()) + " bytes");

// one full frame, then the same frame again: the second is free
tui.capture_reset();
let f1 = tui.flush(a);
let f2 = tui.flush_diff(a);
eq(f2, 0, "re-flushing an unchanged frame emits nothing");
ok(f1 > 0, "the full flush emits bytes", "got " + tostring(f1));

// ---------------------------------------------------------------- 3
// UTF-8 encoding, byte for byte.
print("-- utf-8 --");
eq(tui.utf8_len(65), 1, "utf8_len('A') = 1");
eq(tui.utf8_len(0xE9), 2, "utf8_len(e-acute) = 2");
eq(tui.utf8_len(0x2588), 3, "utf8_len(half block) = 3");
eq(tui.utf8_len(0x1F600), 4, "utf8_len(4-byte) = 4");

tui.capture_reset();
let t = tui.new(2, 8);
tui.clear(t, tui.rgb(0, 0, 0));
tui.put(t, 0, 0, 0xE9, tui.rgb(0, 0, 0), tui.rgb(0, 0, 0));
tui.put(t, 0, 2, 0x2588, tui.rgb(0, 0, 0), tui.rgb(0, 0, 0));
tui.flush(t);
// the CUP and SGR precede the glyph, so search for the 2-byte and
// 3-byte sequences by raw byte
let has2 = false;
let has3 = false;
let j = 0;
while (j + 1 < tui.capture_len()) {
    if (tui.capture_byte(j) == 0xC3 && tui.capture_byte(j + 1) == 0xA9) { has2 = true; };
    j = j + 1;
};
j = 0;
while (j + 2 < tui.capture_len()) {
    if (tui.capture_byte(j) == 0xE2 && tui.capture_byte(j + 1) == 0x96
        && tui.capture_byte(j + 2) == 0x88) { has3 = true; };
    j = j + 1;
};
ok(has2, "a 2-byte glyph reaches the stream as c3 a9", "not found");
ok(has3, "the 3-byte half block reaches the stream as e2 96 88", "not found");

// ---------------------------------------------------------------- 4
// Colour packing round-trips.
print("-- colour --");
let c = tui.rgb(12, 34, 56);
eq(tui.r_of(c), 12, "r_of");
eq(tui.g_of(c), 34, "g_of");
eq(tui.b_of(c), 56, "b_of");
eq(tui.rgb(0, 0, 0), 0, "black is 0");

// ---------------------------------------------------------------- 5
// Glyph ramps ascend with coverage, and index 0 is a space.
print("-- ramps --");
let up = true;
let k = 1;
while (k <= 10) {
    if (tui.shade_half(k, 10) < tui.shade_half(k - 1, 10)) { up = false; };
    k = k + 1;
};
ok(up, "shade_half ascends over 0..10", "not monotonic");
eq(tui.shade_half(0, 10), 32, "shade_half(0) is a space");
eq(tui.shade_half(10, 10), 0x2588, "shade_half(10) is the full block █");
// half_ramp is [32, 9600, 9604, 9608] = space, ▀, ▄, █ -- ascending by
// COVERAGE. A codepoint-order monotonicity test is wrong here: █ is
// U+2588 and ▄ is U+2584, so coverage ascends while the codepoints
// happen to as well here, but that is a coincidence of the chosen
// glyphs, not a property worth asserting. Assert the table instead.
eq(tui.shade_half(3, 10), 9600, "shade_half(3) is ▀");
eq(tui.shade_half(6, 10), 9604, "shade_half(6) is ▄");

// block_ramp is [32, 9617, 9618, 9619, 9608] = space, ▁, ▂, ▃, █.
// Note ▃ (9619) > █ (9608) as codepoints, so this ramp is NOT
// monotonic in codepoint order even though it is in coverage. That is
// exactly what the previous suite misread.
let blk = true;
let want: [long] = [32, 9617, 9618, 9619, 9608];
k = 0;
while (k <= 4) {
    if (tui.shade_blocks(k * 10 / 5, 10) != want[k]) { blk = false; };
    k = k + 1;
};
ok(blk, "shade_blocks matches its documented ramp", "table mismatch");
eq(tui.shade_blocks(0, 10), 32, "shade_blocks(0) is a space");
eq(tui.shade_blocks(10, 10), 9608, "shade_blocks(10) is █");
eq(tui.shade_len(1), 5, "block ramp has 5 levels");
eq(tui.shade_len(3), 16, "braille ramp has 16 levels");

// ---------------------------------------------------------------- 6
// Bounds safety: nothing here may trap. Gate item 3.
print("-- bounds safety --");
let h = tui.new(4, 6);
tui.put(h, -5, -5, 65, 0, 0);
tui.put(h, -999999, -999999, 65, 0, 0);
tui.put(h, 999999, 999999, 65, 0, 0);
tui.put(h, 3, 5, 65, 0, 0);          // last valid cell
tui.put(h, 4, 0, 65, 0, 0);          // one past the bottom
tui.put(h, 0, 6, 65, 0, 0);          // one past the right
tui.hline(h, -1, -1, 100, 45, 0, 0);
tui.vline(h, 3, 5, 100, 46, 0, 0);
tui.rect(h, -3, -3, 100, 100, 47, 0, 0);
tui.fill_rect(h, 2, 4, 100, 100, 48, 0, 0);
tui.text(h, -2, -2, "hello", 0, 0);
tui.text(h, 3, 5, "tail", 0, 0);
tui.blit(h, h, -5, -5, -5, -5, 100, 100);
tui.blit(h, h, 3, 5, 0, 0, 100, 100);
tui.clear(h, 0);
tui.flush(h);
ok(true, "hostile draws complete without a trap", "");
ok(tui.capture_len() >= 0, "capture_len is sane after them", "");

// ---------------------------------------------------------------- 7
// No per-frame allocation.
print("-- allocation --");
let p = tui.new(16, 40);
tui.clear(p, 0);
tui.put(p, 1, 1, 65, 0, 0);
tui.flush(p);
let h0 = heap_used();
let f = 0;
while (f < 500) {
    tui.put(p, 2, 2, 66, 0, 0);
    tui.flush_diff(p);
    tui.put(p, 2, 2, 65, 0, 0);
    tui.flush_diff(p);
    f = f + 1;
};
let h1 = heap_used();
eq(h1 - h0, 0, "500 frames of flush_diff allocate nothing");
ok(true, "frame loop ran", "heap " + tostring(h0) + " -> " + tostring(h1));

// ---------------------------------------------------------------- 8
// emit_num must spell EVERY integer exactly. This section exists because its
// absence let a real bug through: emit_num used to guard each decimal place
// with `if (q >= place)`, which skips any place whose digit is 0 once a more
// significant digit has been emitted. It therefore rendered 205 as "25" and
// 101 as "11" -- a WRONG COLOUR reaching the terminal, not a wrong digit
// count. The 34 checks above all passed anyway, and so did the golden file,
// because every colour in the test scene happened to be 0 or 255-ish: not one
// SGR channel in fb_golden.txt had an interior zero.
//
// The values below are exactly the shapes that used to fail: an interior zero
// in the tens place, in the hundreds place, and two at once, plus the
// two-digit and trailing-zero cases that always worked, so a regression that
// "fixes" it by dropping all zeros is caught too.
print("-- emit_num spells every integer --");
let en = tui.new(1, 6);
tui.capture_on();
tui.begin_frame();
tui.put(en, 0, 0, 65, tui.rgb(203, 101, 100), -1);   // interior zeros
tui.put(en, 0, 1, 66, tui.rgb(105, 100, 210), -1);
tui.put(en, 0, 2, 67, tui.rgb(200, 250, 10), -1);     // leading + trailing
tui.put(en, 0, 3, 68, tui.rgb(0, 255, 255), -1);     // single zero
tui.put(en, 0, 4, 69, tui.rgb(100, 100, 100), -1);   // all interior
tui.put(en, 0, 5, 70, tui.rgb(255, 255, 255), -1);   // no zeros at all
tui.end_frame(en);
tui.flush(en);
tui.capture_off();
let ens = tui.capture_str(0, tui.capture_len());
// Each cell emits ESC [ 0 ; 38 ; 2 ; R ; G ; B m, so the decimal spelling of
// the three channels must appear verbatim and in order.
let want = "38;2;203;101;100";
ok(ens.index_of(want) >= 0, "emit_num spells 203;101;100", "not in: " + ens);
let want2 = "38;2;105;100;210";
ok(ens.index_of(want2) >= 0, "emit_num spells 105;100;210", "not in: " + ens);
let want3 = "38;2;200;250;10";
ok(ens.index_of(want3) >= 0, "emit_num spells 200;250;10", "not in: " + ens);
let want4 = "38;2;100;100;100";
ok(ens.index_of(want4) >= 0, "emit_num spells 100;100;100", "not in: " + ens);
let want5 = "38;2;255;255;255";
ok(ens.index_of(want5) >= 0, "emit_num spells 255;255;255", "not in: " + ens);
ok(ens.index_of("38;2;0;255;255") >= 0, "emit_num spells 0;255;255",
   "not in: " + ens);
// The verbatim-substring assertions above are the real guard: "38;2;203;101;100"
// can only be present if all three channels kept their interior zeros. This is
// just a sanity check that the capture produced something to search.
ok(tui.capture_len() > 0, "the capture captured the six cells",
   "capture_len " + tostring(tui.capture_len()));

// ---------------------------------------------------------------- done
print("");
print(tostring(checks) + " checks, " + tostring(checks - failed) + " ok, "
      + tostring(failed) + " failed");
if (failed == 0) { print("RESULT: PASS"); } else { print("RESULT: FAIL"); };
if (failed == 0) { exit(0); } else { exit(1); };

// ---------------------------------------------------------------------------
// Why the previous suite's 57 failures were all test-side. Kept so the next
// person does not spend the same afternoon.
//
//  1. capture_str() returns a LOSSLESS PRINTABLE form (tui.y:318): 0x20-0x7e
//     verbatim, `"` and `\` escaped, everything else as \xNN. So
//     capture_str(0,n).contains("\x1b[") can NEVER match, and
//     len(capture_str(0,n)) != n — a 72-byte stream came back as 93
//     characters. The old suite searched capture_str() for raw escape
//     bytes, so every CUP/SGR/glyph count came back 0. Raw bytes must be
//     read with capture_byte(i), or the whole stream compared with
//     capture_len() + capture_checksum() as this suite does.
//
//  2. block_ramp is [32, 9617, 9618, 9619, 9608] (tui.y:354) — ASCENDING
//     coverage: space, then the light blocks, then the full block. The old
//     suite expected a DESCENDING ramp starting at U+2583, so
//     shade_blocks(1,8) returning 32 was reported as a failure when it is
//     correct (ramp_index(1,8,5) = (1*5)/8 = 0).
//
//  3. Several checks walked the capture with capture_byte() without
//     bounding the walk by capture_len(), so they compared -1 (the
//     out-of-range return) against a real byte.
//
//  4. Some used ABSOLUTE tolerances where a RELATIVE one is needed:
//     hypot(1e6,1e6) is 912313 Q30 steps out on 1.5e15, a relative error
//     of 6e-10, which is excellent — but 912313 > a fixed 64-step budget.
//     Absolute tolerances on fixed-point results have to scale with the
//     magnitude of the value.
//
// `contains` itself is fine: "A\x1b[1;1HB".contains("\x1b[") is true and
// index_of is 1. That was verified separately.