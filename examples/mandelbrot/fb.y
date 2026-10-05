// fb.y -- an ANSI terminal framebuffer for Y.
//
// Vendored, not imported across folders (ORCHESTRATOR.md section 4).  Every
// visual example in examples/ keeps its own copy of this file; this one is the
// canonical, tested revision.
//
// WHAT IT IS
// A Surface is a grid of terminal cells: a Unicode codepoint plus a 24-bit
// foreground and a 24-bit background, drawn with primitives and then written
// to a file descriptor as an ANSI byte stream.  Two flush modes: `flush`
// redraws everything, `flush_diff` redraws only what changed since the last
// flush.  An example draws, calls flush_diff, and is on screen in one frame:
//
//   let s = fb.new(40, 100);
//   while (running) {
//       fb.fill_rect(s, 0, 0, 40, 100, 32, fb.DEFAULT, fb.rgb(8, 8, 16));
//       fb.put(s, 20, 50, ord("X"), fb.rgb(255, 200, 0), fb.DEFAULT);
//       fb.flush_diff(s);
//   }
//
// COLOUR
// A colour is one `long` packing 0xRRGGBB (bits 16..23 red, 8..15 green,
// 0..7 blue).  Channels are 0..255 ints and are NOT auto-clamped by the
// arithmetic, so build them with `rgb`, which clamps.  `fb.DEFAULT` (-1) means
// "whatever the terminal already uses": it emits SGR 39 / 49 instead of a
// truecolor triple, which is both shorter and lets a caller's palette follow
// the user's own terminal colours.
//
// There is no float->long conversion in Y (ORCHESTRATOR.md section 2.4a), so
// nothing here takes a float and nothing converts one.  Do colour arithmetic
// in `long` and clamp with `clamp255`.
//
// CELL STORE -- the surface layout
//   type Surface = { rows, cols, ch, fg, bg, sh, sf, sb }
//   ch  [long; 32768]   codepoint per cell; -1 = SKIP (see text())
//   fg  [long; 32768]   0xRRGGBB, or -1 for the terminal default
//   bg  [long; 32768]   0xRRGGBB, or -1 for the terminal default
//   sh/sf/sb [long; 32768]  the same three arrays as of the last flush:
//                       the shadow, which is the retained front buffer
// Maximum size is 128 rows x 256 cols = 32768 cells, allocated whole at
// `new()`.  A cell costs 6 longs across the two buffers, so a full-size
// Surface is 1.5 MiB.  Fixed `[T; N]` arrays were chosen over growable
// arrays because `+=` on a fixed array is a type error and because a growable
// array would reallocate; the grid never changes shape without `resize`.
//
// Separate arrays rather than one packed `long` per cell: a packed cell would
// need 69 bits for ch+fg+bg, and dropping a channel to make it fit would cost
// truecolor.  The three compares per cell in the diff are free next to the
// SGR and UTF-8 work in the same loop.  `key_at(s, row, col)` returns the
// packed (fg<<24|bg) change key for callers who want one compare instead of
// two.
//
// PER-FRAME ALLOCATION: none, and that is the point of the module.
// The Y heap is an arena and nothing is ever freed (ORCHESTRATOR.md 2.7), so
// anything allocated per frame is a leak.  Every buffer here is a top-level
// `let` or comes from `new()`:
//   * `new()`      allocates 6 x 32768 longs, ONCE per surface.  A surface
//                  that lives for the program's life costs 1.5 MiB in total.
//   * `resize()`   allocates NOTHING.  The arrays are always at MAX_CELLS, so
//                  resizing is a field write plus a full shadow reset.  Call
//                  it on SIGWINCH or at start-up; it is safe to call in a
//                  frame loop, though it forces a full redraw.
//   * flush, flush_diff, put, text, hline, vline, rect, fill_rect, blit
//                  write into existing arrays and into one fixed 4 KiB output
//                  buffer.  They allocate nothing.
//   * `emit_codepoint`, `emit_str`, `capture_str` are the exceptions and are
//     labelled as such.  `capture_str` builds a `str` and is for tests and
//     debugging only.
//
// DOUBLE BUFFERING
// There is one grid and one shadow; no swap.  The shadow holds what the
// terminal is known to be showing, which is exactly the state a front buffer
// would hold, and `flush_diff` copies front->shadow as it emits.  So a
// caller draws into the grid and flushes; the shadow plays the front buffer's
// role for free.  A true swap would need a third array and buy nothing here,
// because each row is written with one write(2) preceded by an absolute CUP,
// so a row is never shown half-updated.
//
// If an example wants a static background layer it keeps its own Surface and
// `blit`s it every frame -- the same discipline, without per-frame allocation
// in either layer.
//
// DIFFING
// `flush_diff` compares each cell against its shadow and, per row, emits one
// CUP plus only the maximal runs of changed cells.  An unchanged row costs
// zero bytes and zero syscalls.  Worst case (every cell changed, every cell a
// different colour) is 36 bytes of SGR plus 4 of UTF-8 per cell plus a CUP,
// so about 41 bytes/cell -- 1.3 MiB for a full 256x128 screen, which is what
// `flush` costs anyway and only happens on a frame that changes everything.
// The common case (a few hundred changed cells) is a few kilobytes, which at
// 30 fps is a few hundred KiB/s of pipe traffic -- nothing, but it is why
// `flush` exists at all and `flush_diff` is the one to call per frame.
//
// GLYPH RAMPS
// `shade*` map a value to a glyph by COVERAGE, not by brightness, so the
// picture reads the same on a light and a dark terminal: a ramp that went
// dark-to-light would invert.  Four modes:
//   shade_ascii    10 levels, printable ASCII only, no font requirement
//   shade_blocks    5 levels, U+2591..U+2593 shade blocks + full block
//                   (the default; true coverage, needs a font with them)
//   shade_half      4 levels, upper/lower half block: vertical 2x
//   shade_braille  16 levels, one cell as 2x4 braille dots (U+2800+mask),
//                   the practical high-resolution mode
// All four are monotonic non-decreasing in v by construction: they all index
// through `ramp_index`, which is.  There is deliberately no 2x2 "quadrant"
// ramp: Unicode has no UPPER-RIGHT-only quadrant glyph (U+2596..U+259F cover
// every 2x2 combination except that one), so it cannot be done without a
// substitute some fonts draw differently.  Braille is the answer.
//
// braille() takes 8 coverage values, row-major (2 wide, 4 tall) and sets a
// dot for each at or above the threshold.  A terminal cell is 2x4 dots, so
// braille is 2x horizontal and 4x vertical resolution against `shade_blocks`
// -- at the cost of 3-byte codepoints (against 1-2 for the block ramps) and
// a font that has U+2800.  A donut on a 100x40 grid is 200x160 braille dots.
//
// WIDE CHARACTERS
// `width_of(cp)` reports how many columns a codepoint takes: 0 for combining
// marks and controls, 2 for East Asian wide and emoji, 1 otherwise.
// `text()` advances by that width and writes a SKIP cell (ch = -1) after a
// double-width glyph, which the emitters skip, so the terminal's own advance
// lines up with the grid.  Box drawing and block elements are all width 1, so
// a roguelike's walls need no special care.
//
// EXPORTS
//   Surface, MAX_ROWS, MAX_COLS, MAX_CELLS, DEFAULT, SKIP, REPLACEMENT, space
//   new, resize, clear, fill, put, put_skip, get, key_at, text, hline, vline,
//   rect, fill_rect, blit, width_of
//   flush, flush_diff, begin_frame, end_frame, frame_bytes, row_bytes,
//   row_count, set_fd, fd, spill
//   rgb, r_of, g_of, b_of, clamp255, lerp_rgb, grey
//   utf8_len, utf8_byte, emit_codepoint, emit_str
//   shade, shade_ascii, shade_blocks, shade_half, shade_braille, shade_len,
//   ramp_index, braille_mask, braille_cp, braille_dot, braille, braille_put,
//   ascii_ramp, block_ramp, half_ramp
//   capture_on, capture_off, capture_reset, capture_len, capture_byte,
//   capture_checksum, capture_str
//
// NOT IN HERE, ON PURPOSE
// No terminal size query, no raw mode, no key decoding: that is term.y.  No
// frame pacing or fps meter: that is time.y.  This module does exactly one
// thing and touches exactly one syscall (write, 2).

// ----------------------------------------------------------------- size ----
// Array sizes have to be integer literals (the parser takes no expression in
// a type position), so the numbers are spelled out in the type positions below
// and these constants carry the same values for the reader.
let MAX_ROWS = 128;
let MAX_COLS = 256;
let MAX_CELLS = 32768;   // MAX_ROWS * MAX_COLS
let OBUF_CAP = 4096;     // the flush output buffer; a spill mid-row is fine,
                         // because a CUP is absolute and the SGR state is
                         // tracked per frame, not per write
let CAP_CAP = 262144;    // the self-test's capture buffer

let DEFAULT = -1;        // "terminal default colour" (SGR 39 / 49)
let SKIP = -1;           // this cell is covered by the glyph to its left
let REPLACEMENT = 65533; // U+FFFD, for malformed UTF-8 input
let space = 32;         // ' ', what a cleared surface is filled with

type Surface = {
    rows: long,
    cols: long,
    ch: [long; 32768],
    fg: [long; 32768],
    bg: [long; 32768],
    sh: [long; 32768],
    sf: [long; 32768],
    sb: [long; 32768]
};

// --------------------------------------------------------------- colour ----

def rgb(r: long, g: long, b: long) -> long {
    (clamp255(r) << 16) | (clamp255(g) << 8) | clamp255(b)
};

def r_of(c: long) -> long {
    if (c < 0) { return 0; };
    (c >> 16) & 255
};

def g_of(c: long) -> long {
    if (c < 0) { return 0; };
    (c >> 8) & 255
};

def b_of(c: long) -> long {
    if (c < 0) { return 0; };
    c & 255
};

def clamp255(v: long) -> long {
    if (v < 0) { return 0; };
    if (v > 255) { return 255; };
    v
};

def grey(v: long) -> long {
    let q = clamp255(v);
    (q << 16) | (q << 8) | q
};

def lerp_rgb(a: long, b: long, t: long) -> long {
    // t is 0..255: 0 gives a, 255 gives b.
    let u = clamp255(t);
    rgb(r_of(a) + ((r_of(b) - r_of(a)) * u + 127) / 255,
        g_of(a) + ((g_of(b) - g_of(a)) * u + 127) / 255,
        b_of(a) + ((b_of(b) - b_of(a)) * u + 127) / 255)
};

// ---------------------------------------------------------------- utf-8 ----

def utf8_len(cp: long) -> long {
    if (cp < 0) { return 1; };
    if (cp < 128) { return 1; };
    if (cp < 2048) { return 2; };
    if (cp < 65536) { return 3; };
    4
};

def utf8_byte(cp: long, i: long) -> long {
    // The i'th byte (0-based) of cp's UTF-8 encoding.  An i outside 0..3
    // gives '?' rather than trapping, so a caller can ask past the end safely.
    let c = cp;
    if (c < 0) { return 63; };
    if (i < 0 || i > 3) { return 63; };
    if (c > 1114111) { c = 1114111; };
    if (c < 128) {
        if (i == 0) { return c; };
        return 63;
    };
    if (c < 2048) {
        if (i == 0) { return 192 | (c >> 6); };
        if (i == 1) { return 128 | (c & 63); };
        return 63;
    };
    if (c < 65536) {
        if (i == 0) { return 224 | (c >> 12); };
        if (i == 1) { return 128 | ((c >> 6) & 63); };
        if (i == 2) { return 128 | (c & 63); };
        return 63;
    };
    if (i == 0) { return 240 | (c >> 18); };
    if (i == 1) { return 128 | ((c >> 12) & 63); };
    if (i == 2) { return 128 | ((c >> 6) & 63); };
    128 | (c & 63)
};

// --------------------------------------------------------------- output ----

let obuf: [byte; 4096] = [0; 4096];   // the one fixed output buffer
let olen = 0;
let ofd = 1;
let frame_n = 0;                      // bytes emitted by the current flush
let rbytes = 0;                       // bytes of the last row that emitted
let rrows = 0;                        // rows that emitted in the last flush
let cur_fg = -2;                      // -2 = nothing emitted yet this frame
let cur_bg = -2;

let cap: [byte; 262144] = [0; 262144];
let capn = 0;
let capon = 0;

def fd() -> long {
    ofd
};

def set_fd(d: long) {
    // Anything write(2) takes.  Default 1.  The self-test captures instead of
    // writing, so it never has to redirect the descriptor.
    ofd = d;
};

def spill() {
    // Push whatever is buffered.  Called automatically when the buffer fills
    // (mid-row is fine) and at the end of every flush.
    if (olen > 0) {
        syscall(1, ofd, &obuf[0], olen);
        olen = 0;
    };
};

def emit_byte(b: long) -> long {
    if (olen >= OBUF_CAP) { spill(); };
    obuf[olen] = b;
    olen = olen + 1;
    if (capon != 0 && capn < CAP_CAP) {
        cap[capn] = b;
        capn = capn + 1;
    };
    frame_n = frame_n + 1;
    b
};

def emit_num(v: long) {
    // Decimal, no leading zeros.  Used for both the CUP operands (1-based row,
    // 1-based col) and the 0..255 SGR channels.
    //
    // Find the highest place first, then emit EVERY place down to units. The
    // place is found rather than guarded per-digit on purpose: a per-digit
    // guard like `if (q >= 10) { emit tens; q = q % 10 }` skips any place whose
    // digit is 0 once a more significant digit has been emitted, because the
    // remainder is then smaller than the place. That silently emitted 205 as
    // "25" -- a wrong COLOUR on the terminal, not a wrong digit count -- and
    // 101 as "11", so every SGR channel with an interior zero was wrong. Two
    // digits and 250 happened to come out right, which is what made it look
    // like a rounding problem instead of a bug.
    let q = v;
    if (q < 0) { q = 0 };
    let place = 1;
    while (place <= q / 10) { place = place * 10 };
    while (place > 0) {
        emit_byte(48 + (q / place) % 10);
        q = q % place;
        place = place / 10;
    }
};

def emit_cup(r: long, c: long) {
    // ESC [ r ; c H, 1-based.  One CUP per changed run of cells.
    emit_byte(27);
    emit_byte(91);
    emit_num(r);
    emit_byte(59);
    emit_num(c);
    emit_byte(72);
};

def emit_sgr(fg: long, bg: long) {
    // ESC [ 0 ; fg ; bg m, assembled byte by byte.  A -1 channel emits 39 / 49
    // and skips the truecolor triple entirely.  36 bytes at worst.
    emit_byte(27);
    emit_byte(91);
    emit_byte(48);   // '0'
    emit_byte(59);   // ';'
    if (fg < 0) {
        emit_byte(51);   // '3'
        emit_byte(57);   // '9'
    } else {
        emit_byte(51); emit_byte(56); emit_byte(59); emit_byte(50); emit_byte(59);
        emit_num((fg >> 16) & 255);
        emit_byte(59);
        emit_num((fg >> 8) & 255);
        emit_byte(59);
        emit_num(fg & 255);
    };
    emit_byte(59);
    if (bg < 0) {
        emit_byte(52);   // '4'
        emit_byte(57);   // '9'
    } else {
        emit_byte(52); emit_byte(56); emit_byte(59); emit_byte(50); emit_byte(59);
        emit_num((bg >> 16) & 255);
        emit_byte(59);
        emit_num((bg >> 8) & 255);
        emit_byte(59);
        emit_num(bg & 255);
    };
    emit_byte(109);  // 'm'
};

def emit_codepoint(cp: long) -> long {
    // UTF-8 encode cp into the output buffer; returns the byte count.  To
    // encode into an array of your own instead, use utf8_len + utf8_byte.
    let n = 0;
    for i in 0..4 {
        if (i < utf8_len(cp)) {
            emit_byte(utf8_byte(cp, i));
            n = n + 1;
        };
    };
    n
};

def emit_str(t: str) -> long {
    // Writes t's bytes verbatim -- for a caller that has pre-built a string of
    // escape sequences.  Allocates nothing beyond what t already is.
    let n = len(t);
    for i in 0..n {
        emit_byte(byte_at(t, i));
    };
    n
};

// -------------------------------------------------------------- capture ----
// Everything the module emits can also be copied into a fixed capture buffer,
// byte for byte, as it is emitted.  That is how the self-test gets at the raw
// stream without redirecting the descriptor, and it costs one compare and one
// store per byte while capture_on() is in force.

def capture_on() {
    capn = 0;
    capon = 1;
};

def capture_off() {
    capon = 0;
};

def capture_reset() {
    capn = 0;
};

def capture_len() -> long {
    capn
};

def capture_byte(i: long) -> long {
    if (i < 0 || i >= capn) { return -1; };
    cap[i]
};

def capture_checksum() -> long {
    // FNV-1a 64 over everything captured: cheap, and it fails loudly if a
    // single byte of a frame changed.  `long` multiply wraps, so the FNV
    // prime's high bits fold in as intended.
    let h: long = -3750763034362895579;   // 14695981039346656037, signed
    let i = 0;
    while (i < capn) {
        h = (h ^ cap[i]) * 1099511628211;
        i = i + 1;
    };
    h
};

def capture_str(from: long, to: long) -> str {
    // A lossless printable rendering of the captured bytes: 0x20..0x7e
    // verbatim, `"` and `\` escaped, everything else as \xNN.  ALLOCATES (it
    // builds a str) -- for tests and debugging only, never a frame path.
    let lo = from;
    let hi = to;
    if (lo < 0) { lo = 0; };
    if (lo > capn) { lo = capn; };
    if (hi > capn) { hi = capn; };
    if (hi < lo) { hi = lo; };
    let s = "";
    let i = lo;
    while (i < hi) {
        let b = cap[i];
        if (b == 92) {
            s += "\\\\";
        } else if (b == 34) {
            s += "\\\"";
        } else if (b >= 32 && b < 127) {
            s += chr(b);
        } else {
            s += "\\x";
            let hi2 = b / 16;
            let lo2 = b - hi2 * 16;
            s += chr(48 + hi2);
            s += chr(87 + lo2);   // 'W' is 48+39 and 'a' is 87+10
        };
        i = i + 1;
    };
    s
};

// ----------------------------------------------------------------- ramp ----

let ascii_ramp: [long; 10] = [32, 46, 58, 45, 61, 43, 42, 35, 37, 64];
// light -> dark, which is coverage order: ' ', U+2591, U+2592, U+2593, U+2588
let block_ramp: [long; 5] = [32, 9617, 9618, 9619, 9608];
// ' ', upper half, lower half, full
let half_ramp: [long; 4] = [32, 9600, 9604, 9608];

def ramp_index(v: long, n: long, levels: long) -> long {
    // The one place a value becomes a ramp position, and the reason every
    // ramp in this module is monotonic: v <= 0 gives the emptiest glyph,
    // v >= n the fullest, and in between it is (v * levels) / n, which is
    // non-decreasing in v for every n >= 0.
    if (levels <= 1) { return 0; };
    if (n <= 0) { return levels - 1; };
    if (v <= 0) { return 0; };
    if (v >= n) { return levels - 1; };
    let i = (v * levels) / n;
    if (i < 0) { return 0; };
    if (i > levels - 1) { return levels - 1; };
    i
};

def shade_ascii(v: long, n: long) -> long {
    ascii_ramp[ramp_index(v, n, 10)]
};

def shade_blocks(v: long, n: long) -> long {
    block_ramp[ramp_index(v, n, 5)]
};

def shade_half(v: long, n: long) -> long {
    half_ramp[ramp_index(v, n, 4)]
};

def shade(v: long, n: long) -> long {
    // The default ramp: block shades, because coverage is what the eye reads
    // and it is the one that survives a light terminal.
    block_ramp[ramp_index(v, n, 5)]
};

def shade_len(mode: long) -> long {
    // 0 ascii, 1 blocks (the default), 2 half, 3 braille
    if (mode == 0) { return 10; };
    if (mode == 2) { return 4; };
    if (mode == 3) { return 16; };
    5
};

def braille_dot(px: long, py: long) -> long {
    // The U+2800 mask bits for the dot at (px, py), px in 0..1, py in 0..3 --
    // OR these together and add 0x2800 for a codepoint.  Braille numbers its
    // dots down the left column and then down the right, which is why x
    // contributes 2 and y contributes (y/2)*4 + (y&1) to the bit INDEX:
    //   (0,0)->0x01 (0,1)->0x02 (1,0)->0x04 (1,1)->0x08
    //   (0,2)->0x10 (0,3)->0x20 (1,2)->0x40 (1,3)->0x80
    // Note this is the mask value, already shifted, not the bit number.
    1 << (px * 2 + (py >> 1) * 4 + (py & 1))
};

def braille_mask(level: long) -> long {
    // The first `level` of the 8 dots, in reading order (row-major over the
    // 2-wide by 4-tall cell).  The result is a proper progressive fill: every
    // step adds dots and removes none, and level 8 is 0xff.
    if (level <= 0) { return 0; };
    let n = level;
    if (n > 8) { n = 8; };
    let m = 0;
    for i in 0..8 {
        if (i < n) { m = m | braille_dot(i % 2, i / 2); };
    };
    m
};

def braille_cp(mask: long) -> long {
    10240 + (mask & 255)
};

def shade_braille(v: long, n: long) -> long {
    braille_cp(braille_mask(ramp_index(v, n, 16)))
};

def braille(vs: [long], thresh: long) -> long {
    // 8 coverage values, row-major over a 2-wide by 4-tall cell; a dot is set
    // for each value at or above thresh.  A short array is padded with zeros
    // (below any non-negative thresh) and extra values are ignored, so a
    // caller cannot trap here.  Pure: returns a codepoint, draws nothing.
    let m = 0;
    for i in 0..8 {
        if (i < len(vs)) {
            if (vs[i] >= thresh) { m = m | braille_dot(i % 2, i / 2); };
        };
    };
    braille_cp(m)
};

def braille_put(s: Surface, row: long, col: long, vs: [long], thresh: long, fg: long, bg: long) -> long {
    put(s, row, col, braille(vs, thresh), fg, bg)
};

// ---------------------------------------------------------------- width ----

def width_of(cp: long) -> long {
    // Columns a codepoint occupies: 0 do not advance (combining marks and
    // controls), 2 for East Asian wide and emoji, 1 otherwise.  The ranges
    // are the East Asian Wide/Fullwidth set plus the common emoji planes; a
    // codepoint outside every range is width 1, which is right for Latin,
    // Greek, Cyrillic, box drawing and block elements.
    if (cp < 32) { return 0; };
    if (cp >= 768 && cp <= 879) { return 0; };        // combining diacritics
    if (cp >= 6832 && cp <= 6911) { return 0; };      // combining extended
    if (cp >= 8203 && cp <= 8207) { return 0; };      // ZWSP .. RLM
    if (cp >= 8288 && cp <= 8292) { return 0; };      // word joiner etc
    if (cp >= 65024 && cp <= 65039) { return 0; };    // variation selectors
    if (cp == 65279) { return 0; };                   // BOM / ZWNBSP
    if (cp >= 917760 && cp <= 917999) { return 0; };  // variation select sup
    if (cp >= 4352 && cp <= 4447) { return 2; };      // Hangul Jamo
    if (cp >= 11904 && cp <= 12350) { return 2; };    // CJK radicals .. U+303E
    if (cp >= 12353 && cp <= 13311) { return 2; };    // kana .. CJK compat
    if (cp >= 13312 && cp <= 19903) { return 2; };    // CJK extension A
    if (cp >= 19968 && cp <= 40959) { return 2; };    // CJK unified
    if (cp >= 40960 && cp <= 42191) { return 2; };    // Yi
    if (cp >= 44032 && cp <= 55203) { return 2; };    // Hangul syllables
    if (cp >= 63744 && cp <= 64255) { return 2; };    // CJK compat ideographs
    if (cp >= 65072 && cp <= 65135) { return 2; };    // vertical forms
    if (cp >= 65280 && cp <= 65376) { return 2; };    // fullwidth forms
    if (cp >= 65504 && cp <= 65510) { return 2; };    // fullwidth signs
    if (cp >= 127744 && cp <= 128591) { return 2; };  // emoji
    if (cp >= 129280 && cp <= 129535) { return 2; };  // supplemental emoji
    if (cp >= 131072 && cp <= 262141) { return 2; };  // CJK extension B+
    1
};

// -------------------------------------------------------------- surface ----

def clamp_dim(v: long, hi: long) -> long {
    if (v < 1) { return 1; };
    if (v > hi) { return hi; };
    v
};

def new(rows: long, cols: long) -> Surface {
    // THE ONLY ALLOCATION a program should make, and it makes it once per
    // surface: 6 x 32768 longs = 1.5 MiB, never more, whatever size is asked
    // for.  All six arrays start at -1, which is SKIP with DEFAULT colours --
    // a state no draw can produce, because put() writes a real codepoint or a
    // SKIP whose fg and bg match its neighbour's.  So the first flush_diff
    // sees every cell as changed and emits the whole screen.  A full surface
    // of 128x256 leaves the cells above the size requested untouched; they
    // are outside rows*cols and never flushed.
    let a: [long; 32768] = [0; 32768];
    let b: [long; 32768] = [0; 32768];
    let c: [long; 32768] = [0; 32768];
    let d: [long; 32768] = [0; 32768];
    let e: [long; 32768] = [0; 32768];
    let f: [long; 32768] = [0; 32768];
    for i in 0..32768 {
        a[i] = -1; b[i] = -1; c[i] = -1;
        d[i] = -1; e[i] = -1; f[i] = -1;
    };
    let s: Surface = { rows: clamp_dim(rows, MAX_ROWS),
                       cols: clamp_dim(cols, MAX_COLS),
                       ch: a, fg: b, bg: c, sh: d, sf: e, sb: f };
    s
};

def resize(s: Surface, rows: long, cols: long) -> Surface {
    // Allocation-free: the store is always at MAX_CELLS, so a resize is two
    // field writes plus a shadow reset that forces the next flush_diff to
    // repaint the whole screen (the terminal's idea of the old geometry is
    // gone).  Returns the same surface, so `let s2 = resize(s, 50, 100);` and
    // `s = resize(s, 50, 100);` both work -- but prefer the first, because it
    // keeps the record in one place.  Safe to call every frame if the caller
    // really does resize every frame; it just repaints everything.
    s.rows = clamp_dim(rows, MAX_ROWS);
    s.cols = clamp_dim(cols, MAX_COLS);
    for i in 0..32768 {
        s.sh[i] = -1;
        s.sf[i] = -1;
        s.sb[i] = -1;
    };
    s
};

def clear(s: Surface, bg: long) -> long {
    // Space on `bg`, foreground left to the terminal.
    let n = fill(s, space, DEFAULT, bg);
    n
};

def fill(s: Surface, cp: long, fg: long, bg: long) -> long {
    let n = s.rows * s.cols;
    for i in 0..n {
        put_at(s, i, cp, fg, bg);
    };
    n
};

// The index-taking core.  put() checks the bounds; this does not, so every
// caller must pass 0 <= i < rows * cols.
def put_at(s: Surface, i: long, cp: long, fg: long, bg: long) -> long {
    let c = cp;
    if (c > 1114111) { c = REPLACEMENT; };
    if (c < 0) { c = SKIP; };
    s.ch[i] = c;
    s.fg[i] = fg;
    s.bg[i] = bg;
    1
};

def put(s: Surface, row: long, col: long, cp: long, fg: long, bg: long) -> long {
    // Bounds-safe: an out-of-range row or col is IGNORED, not clamped and not
    // an error, because clipping a scanline is the normal case for the drawing
    // examples and a silently clamped line is a bug that shows up as a wrong
    // picture rather than as a message.  Returns 1 if the cell was written.
    if (row < 0 || row >= s.rows || col < 0 || col >= s.cols) { return 0; };
    put_at(s, row * s.cols + col, cp, fg, bg)
};

def put_skip(s: Surface, row: long, col: long, fg: long, bg: long) -> long {
    // Mark a cell as covered by the glyph on its left.  Only needed by a caller
    // drawing wide characters by hand; text() does it for you.
    put(s, row, col, SKIP, fg, bg)
};

def get(s: Surface, row: long, col: long) -> long {
    // The codepoint at (row, col), or -1 if out of range.
    if (row < 0 || row >= s.rows || col < 0 || col >= s.cols) { return -1; };
    s.ch[row * s.cols + col]
};

def key_at(s: Surface, row: long, col: long) -> long {
    // (fg << 24) | bg for the cell -- one compare instead of two when a
    // caller is tracking changes itself.  -1 out of range.
    if (row < 0 || row >= s.rows || col < 0 || col >= s.cols) { return -1; };
    let i = row * s.cols + col;
    (s.fg[i] << 24) | s.bg[i]
};

def text(s: Surface, row: long, col: long, t: str, fg: long, bg: long) -> long {
    // Draws t starting at (row, col), decoding UTF-8 in place from the
    // caller's bytes -- no allocation, and no intermediate copy.  One codepoint
    // per cell, except a double-width codepoint takes two cells: the second
    // gets a SKIP, which the emitters skip, so the terminal's own advance
    // stays aligned with the grid.  A newline (LF or CR) moves to the next row
    // at the original column.  A tab is drawn as a single tab codepoint.
    //
    // Malformed UTF-8 (a stray continuation byte, a lead byte with no
    // continuation, a 5-byte lead) consumes the offending byte and draws
    // U+FFFD.  It never traps: every byte read is guarded by the length.
    let c0 = col;
    let r = row;
    let c = col;
    let i = 0;
    let n = len(t);
    let drawn = 0;
    let go = 1;
    while (go == 1 && i < n) {
        let b0 = byte_at(t, i);
        let cp = REPLACEMENT;
        let adv = 1;
        if (b0 < 128) { cp = b0; adv = 1; }
        else if (b0 < 192) { cp = REPLACEMENT; adv = 1; }
        else if (b0 < 224) { cp = b0 & 31; adv = 2; }
        else if (b0 < 240) { cp = b0 & 15; adv = 3; }
        else if (b0 < 248) { cp = b0 & 7; adv = 4; }
        else { cp = REPLACEMENT; adv = 1; };
        if (adv > 1) {
            let bad = 0;
            for k in 1..adv {
                if (i + k >= n) { bad = 1; } else {
                    let bc = byte_at(t, i + k);
                    if (bc < 128 || bc >= 192) { bad = 1; };
                };
            };
            if (bad != 0) {
                cp = REPLACEMENT;
            } else {
                for k in 1..adv {
                    cp = (cp << 6) | (byte_at(t, i + k) & 63);
                };
            };
        };
        if (cp == 10 || cp == 13) {
            r = r + 1;
            c = c0;
        } else {
            let w = width_of(cp);
            if (w > 0) {
                put(s, r, c, cp, fg, bg);
                if (w > 1) { put(s, r, c + 1, SKIP, fg, bg); };
                c = c + w;
                drawn = drawn + 1;
            };
        };
        i = i + adv;
    };
    drawn
};

def hline(s: Surface, row: long, col: long, n: long, cp: long, fg: long, bg: long) -> long {
    // n cells from (row, col) to the right, clipped at the surface edge.  A
    // negative n draws nothing.
    let k = 0;
    while (k < n) {
        put(s, row, col + k, cp, fg, bg);
        k = k + 1;
    };
    n
};

def vline(s: Surface, row: long, col: long, n: long, cp: long, fg: long, bg: long) -> long {
    // n cells DOWN from (row, col).  Same anchor order as hline, so the two
    // read alike: the first two arguments are always the start point.
    let k = 0;
    while (k < n) {
        put(s, row + k, col, cp, fg, bg);
        k = k + 1;
    };
    n
};

def rect(s: Surface, row: long, col: long, h: long, w: long, cp: long, fg: long, bg: long) -> long {
    // Outline, h rows by w cols, anchored at (row, col).  Clipped.  h < 2 or
    // w < 2 degenerates to the lines that fit, which is what a caller wants
    // when a window is one cell tall.
    hline(s, row, col, w, cp, fg, bg);
    if (h > 1) {
        hline(s, row + h - 1, col, w, cp, fg, bg);
    };
    vline(s, row, col, h, cp, fg, bg);
    if (w > 1) {
        vline(s, row, col + w - 1, h, cp, fg, bg);
    };
    1
};

def fill_rect(s: Surface, row: long, col: long, h: long, w: long, cp: long, fg: long, bg: long) -> long {
    let r = 0;
    while (r < h) {
        hline(s, row + r, col, w, cp, fg, bg);
        r = r + 1;
    };
    1
};

def blit(dst: Surface, src: Surface, srow: long, scol: long, drow: long, dcol: long, h: long, w: long) -> long {
    // Copies an h x w window of src onto dst, both clipped to their own
    // surfaces.  How an example composes a static background layer: keep a
    // second Surface, draw it once, blit it every frame.  Copies ch/fg/bg
    // only -- the shadow stays dst's, because it is the terminal's state and
    // flush_diff maintains it.
    let moved = 0;
    let r = 0;
    while (r < h) {
        let c = 0;
        while (c < w) {
            let si = srow + r;
            let sj = scol + c;
            if (si >= 0 && si < src.rows && sj >= 0 && sj < src.cols) {
                let di = drow + r;
                let dj = dcol + c;
                if (di >= 0 && di < dst.rows && dj >= 0 && dj < dst.cols) {
                    let a = si * src.cols + sj;
                    let b = di * dst.cols + dj;
                    dst.ch[b] = src.ch[a];
                    dst.fg[b] = src.fg[a];
                    dst.bg[b] = src.bg[a];
                    moved = moved + 1;
                };
            };
            c = c + 1;
        };
        r = r + 1;
    };
    moved
};

// ----------------------------------------------------------------- flush ----

def frame_bytes() -> long {
    // Total bytes the last flush emitted.
    frame_n
};

def row_bytes() -> long {
    // Bytes the last flushed row emitted (0 for a row that changed nothing).
    rbytes
};

def row_count() -> long {
    // How many rows emitted anything in the last flush.  This is the number
    // an example wants after a frame: on a settled screen it is 0.
    rrows
};

def begin_frame() {
    // Resets the byte accounting and the SGR state tracker.  flush and
    // flush_diff call it themselves; call it directly only when a frame
    // interleaves its own emit_str/emit_codepoint output with a flush.
    spill();
    frame_n = 0;
    rbytes = 0;
    rrows = 0;
    cur_fg = -2;
    cur_bg = -2;
};

def cell_same(s: Surface, i: long) -> bool {
    s.ch[i] == s.sh[i] && s.fg[i] == s.sf[i] && s.bg[i] == s.sb[i]
};

def cell_commit(s: Surface, i: long) {
    s.sh[i] = s.ch[i];
    s.sf[i] = s.fg[i];
    s.sb[i] = s.bg[i];
};

def emit_cell(s: Surface, i: long) {
    let cp = s.ch[i];
    // A SKIP cell emits nothing and, crucially, does NOT move the SGR
    // tracker: the terminal never received that colour, so the next real cell
    // still has to emit an SGR for itself.
    if (cp < 0) { return; };
    let f = s.fg[i];
    let b = s.bg[i];
    if (f != cur_fg || b != cur_bg) {
        cur_fg = f;
        cur_bg = b;
        emit_sgr(f, b);
    };
    emit_codepoint(cp);
};

def flush(s: Surface) -> long {
    // Repaints every row in full, whatever the shadow says, and brings the
    // shadow up to date.  Use it once after a resize or a clear-the-line, and
    // use flush_diff everywhere else: this costs one CUP and one cell per
    // column per row even when nothing changed.
    begin_frame();
    for r in 0..s.rows {
        let rs = frame_n;
        let base = r * s.cols;
        emit_cup(r + 1, 1);
        for c in 0..s.cols {
            emit_cell(s, base + c);
            cell_commit(s, base + c);
        };
        let used = frame_n - rs;
        if (used > 0) {
            rbytes = used;
            rrows = rrows + 1;
        };
    };
    spill();
    frame_n
};

def flush_diff(s: Surface) -> long {
    // Emits only what changed.  Per row it finds the maximal runs of changed
    // cells and writes one CUP plus each run, so an unchanged row costs
    // nothing at all and a row with one changed cell costs one CUP and one
    // cell.  Returns the frame's byte count.  After it returns, the surface's
    // shadow is the terminal's state, so the next call diffs against it.
    begin_frame();
    for r in 0..s.rows {
        let rs = frame_n;
        let base = r * s.cols;
        let c = 0;
        let go = 1;
        while (go == 1) {
            while (c < s.cols && cell_same(s, base + c)) { c = c + 1; };
            if (c >= s.cols) {
                go = 0;
            } else {
                let r0 = c;
                let run = 1;
                while (run == 1 && c < s.cols) {
                    if (cell_same(s, base + c)) { run = 0; } else { c = c + 1; };
                };
                let r1 = c;
                emit_cup(r + 1, r0 + 1);
                for k in r0..r1 {
                    emit_cell(s, base + k);
                    cell_commit(s, base + k);
                };
            };
        };
        let used = frame_n - rs;
        if (used > 0) {
            rbytes = used;
            rrows = rrows + 1;
        };
    };
    spill();
    frame_n
};

def end_frame(s: Surface) -> long {
    // flush_diff under the name a frame loop wants.  Exactly the same call:
    // begin_frame(); draw; end_frame(s).  The separate begin_frame() entry is
    // only needed when the caller emits its own bytes into the stream between
    // flushes.
    flush_diff(s)
};

export { Surface, MAX_ROWS, MAX_COLS, MAX_CELLS, DEFAULT, SKIP, REPLACEMENT, space,
          new, resize, clear, fill, put, put_skip, get, key_at, text, hline, vline,
          rect, fill_rect, blit, width_of,
          flush, flush_diff, begin_frame, end_frame, frame_bytes, row_bytes,
          row_count, set_fd, fd, spill,
          rgb, r_of, g_of, b_of, clamp255, lerp_rgb, grey,
          utf8_len, utf8_byte, emit_codepoint, emit_str,
          shade, shade_ascii, shade_blocks, shade_half, shade_braille, shade_len,
          ramp_index, braille_mask, braille_cp, braille_dot, braille, braille_put,
          ascii_ramp, block_ramp, half_ramp,
          capture_on, capture_off, capture_reset, capture_len, capture_byte,
          capture_checksum, capture_str };
