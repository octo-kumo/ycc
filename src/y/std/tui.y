// tui -- a terminal user interface in one unit: the tty, the cell grid, the
// frame diff, the capture, and the pacer.
//
// WHY ONE MODULE.  Three vendored files became this: examples/_toolkit/term.y
// (53 functions, vendored into 19 folders), fb.y (64, into 16) and the
// Pacer/Fps half of time.y (11, into 19-20). The dependency between them is not
// optional -- fb.flush_diff is the per-row diff, term is the tty it diffs into,
// and a frame loop needs the pacer to call them at a rate -- so a program picks
// one import rather than three and cannot get the order wrong. Two more names
// were the same module: sink.y (5 folders) and textout.y (4) are the same
// helper under two names and NOT ONE of the nine copies is byte-identical to
// another; grid_digest and grid_text below are that helper, given one
// signature.
//
// WHAT IS AND IS NOT THE API.  The functions listed in the export block are the
// module's surface, and they are the 104 agreed with the campaign. The rest of
// this file -- emit_*, esc_*, sgr_*, set_cc, decode_esc, the capture readers --
// are INTERNAL and are kept because the public functions call them: deleting
// them does not compile, since there is no way to make a private helper in this
// language. They are reachable, and they are not a contract.
//
// THE CLOCK IS NOT HERE.  rt.y already has y_clock_us, y_time_us and y_sleep,
// and y_sleep_us is the sub-millisecond addition this change makes to it. Only
// the pacer and the fps meter were terminal-shaped, so only those moved -- and
// they call the runtime rather than carrying a clock: clock_us() is a builtin
// and nap_us() is rt's. The three functions this file used to vendor for
// that are gone, which is the point of not re-implementing them.
//
// `Size` and `Surface` are the two types; `Pacer` and `Fps` come from time.y.
//
// ONE LIMITATION, MEASURED, NOT FIXED HERE: a Surface holds SIX [long; 32768]
// arrays, so it is capped at 32768 cells -- a 128x256 screen. `new` allocates
// 1.5 MiB once per surface and never more, whatever size it is asked for, and
// cells above rows*cols are never flushed. A full-screen 320x240 surface does
// not fit, which is why examples/x11 carries its own byte buffer instead of
// using this. Widening it is an allocation-policy decision, not an API one, and
// it is out of scope for a merge.

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

type Size = { rows: long, cols: long };

// ---- ioctl requests and termios geometry (see the header) ---------------
let TCGETS = 0x5401;
let TCSETS = 0x5402;
let TIOCGWINSZ = 0x5413;

// c_lflag bits. LFLAG_RAW, 32859 (0x805b), is the mask raw_mode() clears:
// ISIG | ICANON | ECHO | ECHOE | ECHONL | IEXTEN. IEXTEN is 0x8000, not
// 0x10 -- 0x10 is ECHOE.
let ISIG = 1;
let ICANON = 2;
let ECHO = 8;
let ECHOE = 16;
let ECHONL = 64;
let IEXTEN = 32768;
let LFLAG_RAW = ISIG | ICANON | ECHO | ECHOE | ECHONL | IEXTEN;

// c_iflag bits raw_mode() clears, mask 1330 (0x532):
//   BRKINT 2    BREAK is not turned into SIGINT
//   ICRNL  256  CR is not translated to NL on input -- WITHOUT THIS, the
//               Enter key arrives as 10 and not 13, which is the classic
//               "my program cannot tell Enter from ^J" bug
//   INPCK  16   parity is not checked
//   ISTRIP 32   the 8th bit is not stripped, so Alt/meta keys survive
//   IXON    1024 Ctrl-S / Ctrl-Q are not flow control, so Ctrl-S cannot
//               appear to freeze the terminal
// c_oflag is deliberately LEFT ALONE: OPOST on means a plain "\n" still
// moves down a line, which a renderer that mixes CUP and newlines needs.
let BRKINT = 2;
let INPCK = 16;
let ISTRIP = 32;
let ICRNL = 256;
let IXON = 1024;
let IFLAG_RAW = BRKINT | INPCK | ISTRIP | ICRNL | IXON;

// Offsets inside struct termios. VTIME is 22, VMIN is 23.
let LFLAG_AT = 12;
let IFLAG_AT = 0;
let VTIME_AT = 22;
let VMIN_AT = 23;

// the VMIN/VTIME pair the terminal is believed to be in right now, or -1
// for "do not know" -- which is what stops every read_key() from paying for
// a redundant TCSETS.
let CUR_VT = -1;
let CUR_VM = -1;

// ---- the key table. See the header for the escape sequences. -----------
let KEY_NONE = -1;
let KEY_ESC = 4096;
let KEY_UNKNOWN = 4097;
let KEY_UP = 4098;
let KEY_DOWN = 4099;
let KEY_RIGHT = 4100;
let KEY_LEFT = 4101;
let KEY_HOME = 4102;
let KEY_END = 4103;
let KEY_PGUP = 4104;
let KEY_PGDN = 4105;
let KEY_INSERT = 4106;
let KEY_DELETE = 4107;
let KEY_F1 = 4108;
let KEY_F2 = 4109;
let KEY_F3 = 4110;
let KEY_F4 = 4111;
let KEY_F5 = 4112;
let KEY_F6 = 4113;
let KEY_F7 = 4114;
let KEY_F8 = 4115;
let KEY_F9 = 4116;
let KEY_F10 = 4117;
let KEY_F11 = 4118;
let KEY_F12 = 4119;

// ---- ESC_WAIT_MS: how long an unfinished escape sequence waits for its
// ---- continuation bytes, in milliseconds (rounded up to a decisecond).
let ESC_WAIT_MS = 500;

// ---- state ---------------------------------------------------------------
let IN_RAW = false;           // this module put the terminal in raw mode
let HAVE_SAVED = false;       // SAVED holds a real termios
let ARMED = false;            // a watchdog child is waiting to restore us

// NB: these three are growable [byte] rather than [byte; 64] on purpose --
// Y has no `*[T]` pointer type and a fixed array is not a `[byte]`, so a
// fixed buffer could not be passed to rd32/wr32/rd16 below or to any
// caller. They are still exactly 64 bytes and are never grown.
let TM: [byte] = [0; 64];       // termios scratch
let SAVED: [byte] = [0; 64];    // the termios to put back
let WS: [byte] = [0; 64];       // winsize scratch

// ---- the escape-sequence buffer (the only output buffer) ----------------
let ESC_BUF: [byte; 64] = [0; 64];
let ESC_LEN = 0;

// ---- scratch, at module scope on purpose -------------------------------
// A local `let ds: [byte; 20] = [0; 20];` ALLOCATES on every call: a Y
// array carries a {len, cap, data, front} header, so those 20 bytes cost a
// 64-byte heap block. In a per-frame loop that is 768 bytes a frame, and the
// heap is an arena, so it never comes back. Every scratch buffer this module
// uses is therefore a module-level fixed array and nothing here allocates,
// ever. term_test.y checks this with heap_used() around 2000 rounds.
let DEC_BUF: [byte; 20] = [0; 20];       // decimal digits of one put_num
let KEY_BUF: [byte; 1] = [0; 1];         // the one byte read_key reads
let PIPE_BUF: [byte; 8] = [0; 8];        // pipe(2)'s two out fds

// ---- input pushback, so a bad escape sequence never eats input ----------
let PB: [byte; 64] = [0; 64];
let PB_N = 0;

// ---- escape-sequence collection ------------------------------------------
let SQ: [byte; 16] = [0; 16];
let SQ_N = 0;

// ===========================================================================
// termios plumbing
// ===========================================================================

// le32 at offset `at` of a byte buffer
def rd32(b: [byte], at: long) -> long {
    b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)
};

// wr32 at offset `at`
def wr32(b: [byte], at: long, v: long) {
    b[at] = v & 255;
    b[at + 1] = (v >> 8) & 255;
    b[at + 2] = (v >> 16) & 255;
    b[at + 3] = (v >> 24) & 255;
};

// rd16 at offset `at` -- TIOCGWINSZ hands back four of these, row first
def rd16(b: [byte], at: long) -> long {
    b[at] | (b[at + 1] << 8)
};

// is_tty(fd) -- true when `fd` is a terminal that answers TCGETS. This is
// exactly what C's isatty() does, and it is the check every other function
// in this module makes before touching termios.
def is_tty(fd: long) -> bool {
    syscall(16, fd, TCGETS, &TM[0]) >= 0
};

// set_cc(vtime_ds, vmin) -- put the terminal into VMIN/VTIME, but only if it
// is not already there. Re-reads the live struct first, so a `stty` run in
// another shell is never clobbered from a stale copy. NOTE the order:
// VTIME is byte 22, VMIN is byte 23.
def set_cc(vtime_ds: long, vmin: long) {
    if (!IN_RAW) {
        return;
    };
    if (vtime_ds == CUR_VT && vmin == CUR_VM) {
        return;
    };
    if (syscall(16, 0, TCGETS, &TM[0]) < 0) {
        return;
    };
    TM[VTIME_AT] = vtime_ds & 255;
    TM[VMIN_AT] = vmin & 255;
    if (syscall(16, 0, TCSETS, &TM[0]) >= 0) {
        CUR_VT = vtime_ds;
        CUR_VM = vmin;
    };
};

// blocking read settings: one byte, no timer. This is what an interactive
// loop wants -- read_key() parks in the kernel until a key arrives. After
// raw_mode() this costs nothing at all, because the state is cached.
def blocking_mode() {
    set_cc(0, 1);
};

// timed read settings: return after vtime_ds deciseconds even with nothing
// typed. vmin 0 means "zero bytes is a legitimate answer".
def timeout_mode(vtime_ds: long) {
    set_cc(vtime_ds, 0);
};

// install the raw lflag/iflags into TM. VMIN/VTIME are already in TM.
def install_raw() -> bool {
    wr32(TM, LFLAG_AT, rd32(TM, LFLAG_AT) & ~LFLAG_RAW);
    wr32(TM, IFLAG_AT, rd32(TM, IFLAG_AT) & ~IFLAG_RAW);
    syscall(16, 0, TCSETS, &TM[0]) >= 0
};

// ---------------------------------------------------------------------------
// raw_mode() -- enter raw mode on fd 0 and remember how to get back.
// Returns false, and changes nothing at all, when fd 0 is not a terminal.
// That is the whole not-a-tty contract: check the return value, print a
// message, exit non-zero. Nothing here can trap.
// ---------------------------------------------------------------------------
def raw_mode() -> bool {
    if (syscall(16, 0, TCGETS, &TM[0]) < 0) {
        return false;
    };
    for i in 0..64 {
        SAVED[i] = TM[i];
    };
    HAVE_SAVED = true;
    TM[VTIME_AT] = 0;
    TM[VMIN_AT] = 1;
    if (!install_raw()) {
        // TCSETS refused: put back what we took and report failure rather
        // than leaving the caller believing it owns a raw terminal.
        for i in 0..64 {
            TM[i] = SAVED[i];
        };
        syscall(16, 0, TCSETS, &TM[0]);
        HAVE_SAVED = false;
        return false;
    };
    IN_RAW = true;
    CUR_VT = 0;
    CUR_VM = 1;
    true
};

// active() -- is this module currently holding the terminal in raw mode?
// A program that keeps its own exit paths can use it as a guard flag.
def active() -> bool {
    IN_RAW
};

// cooked_mode() -- alias for restore(), named for what it means to the
// kernel. Identical behaviour; both are safe when raw mode was never
// entered, and safe to call any number of times.
def cooked_mode() -> void {
    restore()
};

// restore() -- put the saved termios back. Idempotent, and a no-op when
// raw_mode() never succeeded. NEVER fails, NEVER traps, and does not exit.
def restore() -> void {
    if (HAVE_SAVED) {
        syscall(16, 0, TCSETS, &SAVED[0]);
        HAVE_SAVED = false;
    };
    if (IN_RAW) {
        IN_RAW = false;
    };
    if (ARMED) {
        // The watchdog child restores the same bytes when we die; make it
        // harmless to fire after an orderly exit.
        ARMED = false;
    };
    CUR_VT = -1;
    CUR_VM = -1;
};

// restore_exit(code) -- restore, then exit(code). This is the one call a
// program should make on every exit path: it cannot be forgotten half way,
// because there is nothing after it.
def restore_exit(code: long) {
    restore();
    exit(code)
};

// ---------------------------------------------------------------------------
// arm_watchdog() -- fork a child that restores the terminal when this process
// dies, however it dies. Call it right after raw_mode(), while the mode is
// still installed.
//
// This is the only thing that covers a crash, `kill -9`, or a SIGSEGV: Y
// has no signal handlers, so nothing in-process can run on those paths. The
// child costs one process and no memory (fork is copy-on-write) and it
// restores exactly the bytes an orderly restore would, so the two can never
// disagree.
//
// HOW THE CHILD KNOWS. Not with wait4(2) -- that waits for the caller's
// CHILDREN, and a child waiting on its parent correctly fails with ECHILD
// (-10); that mistake silently restores the terminal immediately, on every
// keypress, which looks like "the terminal keeps snapping back to cooked
// mode". It is a self-pipe, the standard idiom:
//   * the parent keeps the WRITE end of a pipe(2) open for its whole life;
//   * the child closes the write end and blocks in read(2) on the read end;
//   * when the parent dies -- exit, crash, SIGKILL, anything -- the kernel
//     closes its write end, the child's read returns 0, and the child
//     rewrites the saved termios.
// Zero syscalls in the parent, no polling, no /proc, no signals.
//
// THE CHILD MUST CALL setsid(2), AND THIS IS NOT OPTIONAL. A forked child
// is in the terminal's foreground process group, so the moment the parent
// dies the kernel sends it SIGHUP -- and with the default disposition that
// kills it before it can restore anything. The symptom is a watchdog that
// never fires and a terminal left in raw mode after a SIGKILL, which looks
// exactly like the watchdog not existing. setsid(2) puts the child in a new
// session with no controlling terminal, so it receives no terminal-generated
// signal at all. It still holds fd 0, and TCSETS on a pty slave does not
// need a controlling terminal.
//
// WHAT IT DOES NOT COVER: a signal that kills the child too, a machine
// crash, or a terminal that is not fd 0. It also cannot restore the alt
// screen or the cursor -- that state lives in the terminal emulator, and
// only a write to fd 1 can put it back, which by then is not ours. For the
// paths you CAN control use restore_all_exit(), and use the watchdog as the
// backstop.
//
// Returns true if a watchdog is now armed. False means no watchdog (raw mode
// not held, or already armed, or fork failed) -- nothing is lost, you just
// have no crash coverage.
// ---------------------------------------------------------------------------
def arm_watchdog() -> bool {
    if (!IN_RAW || !HAVE_SAVED || ARMED) {
        return false;
    };
    // pipe(2) writes TWO 32-bit ints, not two longs: read them with rd32 or
    // you get 0x400000003 instead of 3, and every later fd is nonsense.
    // Every syscall whose out-params are C `int` rather than `long` has this
    // shape.
    // pipe(2) writes TWO 32-bit ints, not two longs: read them 4 bytes at a time
    // or you get 0x400000003 for the first fd and a nonsense second one, and
    // close(wfd) then fails with EBADF so the child's read never sees EOF and
    // the watchdog silently never fires. rd32 cannot be used here because it
    // takes a [byte] and PIPE_BUF is a [byte; 8] -- Y has no `*[T]`.
    if (syscall(22, &PIPE_BUF[0], 0, 0, 0, 0, 0) != 0) {   // pipe(2)
        return false;
    };
    let rfd = PIPE_BUF[0] | (PIPE_BUF[1] << 8) | (PIPE_BUF[2] << 16) | (PIPE_BUF[3] << 24);
    let wfd = PIPE_BUF[4] | (PIPE_BUF[5] << 8) | (PIPE_BUF[6] << 16) | (PIPE_BUF[7] << 24);
    if (rfd < 0 || wfd < 0) {
        syscall(3, rfd);
        syscall(3, wfd);
        return false;
    };
    let pid = syscall(57, 0, 0, 0, 0, 0, 0);          // fork(2): 0 in the child
    if (pid < 0) {
        syscall(3, rfd);
        syscall(3, wfd);
        return false;
    };
    if (pid == 0) {
        // ---- child. Leave the terminal's process group FIRST, or the
        // kernel's SIGHUP on the parent's death kills us mid-restore.
        syscall(112, 0, 0, 0, 0, 0, 0);              // setsid(2)
        syscall(3, wfd);
        syscall(0, rfd, &KEY_BUF[0], 1);             // 0 == the parent is gone
        syscall(16, 0, TCSETS, &SAVED[0]);           // TCSETS, from our own fd 0
        // The alt screen and the cursor are emulator state; cooked mode is
        // all we can put back from here.
        syscall(3, rfd);
        syscall(3, 0);
        syscall(3, 1);
        syscall(3, 2);
        syscall(231, 0);                             // exit_group(0)
    };
    syscall(3, rfd);                                 // parent: drop the read end
    ARMED = true;
    true
};

// ---------------------------------------------------------------------------
// size() -- the window size, as {rows, cols}.
//
// TIOCGWINSZ fills WS with {ws_row, ws_col, ws_xpixel, ws_ypixel} as four
// 16-bit little-endian values, row first. Falls back to 24x80 when the
// ioctl fails or reports a zero -- which is what a pty from pty.fork()
// looks like if nobody set TIOCSWINSZ, and a zero row would otherwise
// divide by zero in the first frame a renderer computes.
// ---------------------------------------------------------------------------
def size() -> Size {
    let r = 0;
    let c = 0;
    if (syscall(16, 1, TIOCGWINSZ, &WS[0]) >= 0) {
        r = rd16(WS, 0);
        c = rd16(WS, 2);
    };
    if (r < 1) { r = 24; };
    if (c < 1) { c = 80; };
    if (r > 1000) { r = 1000; };
    if (c > 1000) { c = 1000; };
    { rows: r, cols: c }
};

// set_size(rows, cols) -- ask the emulator to resize the window. Used by
// the test harness; almost never by a program. Returns false on failure.
def set_size(rows: long, cols: long) -> bool {
    wr32(WS, 0, 0);
    wr32(WS, 4, 0);
    WS[0] = rows & 255;
    WS[1] = (rows >> 8) & 255;
    WS[2] = cols & 255;
    WS[3] = (cols >> 8) & 255;
    syscall(16, 1, 0x5414, &WS[0]) >= 0     // TIOCSWINSZ
};

// ===========================================================================
// reading bytes
// ===========================================================================

// pop the pushback stack, or -1 when it is empty
def pop_key() -> long {
    if (PB_N <= 0) {
        return -1;
    };
    PB_N = PB_N - 1;
    PB[PB_N]
};

// push_key(n) -- push n bytes of SQ back onto the pushback stack, in arrival
// order, so nothing is lost.
//
// Both ends are clamped, and the second clamp is a real fix rather than
// tidiness: SQ is 16 bytes and PB is 64, so `push_key(1000)` computed
// SQ[999] and trapped with "index out of bounds" -- on stdout, mid-frame. The
// test for this unit found it by pushing past the end on purpose.
def push_key(n: long) {
    let room = 64 - PB_N;
    let take = n;
    if (take > room) { take = room; };     // the pushback stack's own limit
    if (take > 16) { take = 16; };         // and SQ's, which is what it indexes
    let j = 0;
    while (j < take) {
        // SQ[n-1-j] first, so that popping gives SQ[0] first.  Indexed from the
        // end, so only SQ[0 .. take-1] is ever touched.
        PB[PB_N + j] = SQ[take - 1 - j];
        j = j + 1;
    };
    PB_N = PB_N + take;
};

// raw_read() -- read exactly one byte from fd 0. -1 for EOF, for an error,
// and for "no byte arrived" when the terminal is in timed mode. Uses the
// current VMIN/VTIME, so it blocks in blocking mode and times out in timed
// mode. Pushback is drained first, so a pushed-back byte never costs a
// syscall.
def raw_read() -> long {
    let p = pop_key();
    if (p >= 0) {
        return p;
    };
    let n = syscall(0, 0, &KEY_BUF[0], 1);
    if (n != 1) {
        return -1;
    };
    KEY_BUF[0]
};

// ---------------------------------------------------------------------------
// classify the bytes in SQ (SQ_N of them, everything after the ESC)
// ---------------------------------------------------------------------------
def classify() -> long {
    let n = SQ_N;
    if (n < 1) {
        return KEY_ESC;
    };
    let b0 = SQ[0];
    if (b0 == 91) {
        // CSI: ESC [ ...
        if (n == 2) {
            let c = SQ[1];
            if (c == 65) { return KEY_UP; };
            if (c == 66) { return KEY_DOWN; };
            if (c == 67) { return KEY_RIGHT; };
            if (c == 68) { return KEY_LEFT; };
            if (c == 70) { return KEY_END; };
            if (c == 72) { return KEY_HOME; };
            return KEY_UNKNOWN;
        };
        if (SQ[n - 1] != 126) {
            return KEY_UNKNOWN;
        };
        // ESC [ <digits> ~
        let num = 0;
        let bad = 0;
        let i = 1;
        while (i < n - 1) {
            let c = SQ[i];
            if (c >= 48 && c <= 57) {
                num = num * 10 + (c - 48);
                if (num > 99) { bad = 1; };
            } else {
                bad = 1;
            };
            i = i + 1;
        };
        if (bad != 0 || num < 1) {
            return KEY_UNKNOWN;
        };
        if (num == 1) { return KEY_HOME; };
        if (num == 2) { return KEY_INSERT; };
        if (num == 3) { return KEY_DELETE; };
        if (num == 4) { return KEY_END; };
        if (num == 5) { return KEY_PGUP; };
        if (num == 6) { return KEY_PGDN; };
        if (num == 7) { return KEY_HOME; };
        if (num == 8) { return KEY_END; };
        if (num == 11) { return KEY_F1; };
        if (num == 12) { return KEY_F2; };
        if (num == 13) { return KEY_F3; };
        if (num == 14) { return KEY_F4; };
        if (num == 15) { return KEY_F5; };
        if (num == 17) { return KEY_F6; };
        if (num == 18) { return KEY_F7; };
        if (num == 19) { return KEY_F8; };
        if (num == 20) { return KEY_F9; };
        if (num == 21) { return KEY_F10; };
        if (num == 23) { return KEY_F11; };
        if (num == 24) { return KEY_F12; };
        return KEY_UNKNOWN;
    };
    if (b0 == 79 && n == 2) {
        // SS3: ESC O x -- application cursor mode and F1..F4
        let c = SQ[1];
        if (c == 65) { return KEY_UP; };
        if (c == 66) { return KEY_DOWN; };
        if (c == 67) { return KEY_RIGHT; };
        if (c == 68) { return KEY_LEFT; };
        if (c == 70) { return KEY_END; };
        if (c == 72) { return KEY_HOME; };
        if (c == 80) { return KEY_F1; };
        if (c == 81) { return KEY_F2; };
        if (c == 82) { return KEY_F3; };
        if (c == 83) { return KEY_F4; };
        return KEY_UNKNOWN;
    };
    KEY_UNKNOWN
};

// ---------------------------------------------------------------------------
// decode_esc() -- called with the byte just after an ESC. Collects the rest
// of the sequence with a NON-BLOCKING read (ESC_WAIT_MS, rounded up to a
// decisecond -- VTIME has 100 ms granularity and 0.1 ms rounds down to
// nothing), then classifies it.
//
// A sequence the user never finished resolves to KEY_ESC or KEY_UNKNOWN
// instead of blocking, and an unrecognised sequence's bytes go back on the
// pushback stack so the next read_key() returns them as ordinary keys.
// ---------------------------------------------------------------------------
def decode_esc() -> long {
    SQ_N = 0;
    if (!IN_RAW) {
        // Not raw: no safe way to time out a partial sequence, so take one
        // byte and see. Good enough for a piped script, never hangs on a
        // tty because a tty always has raw mode set by now.
        let b = raw_read();
        if (b < 0) {
            return KEY_ESC;
        };
        SQ[0] = b;
        SQ_N = 1;
        let k = classify();
        if (k == KEY_UNKNOWN) {
            push_key(SQ_N);
        };
        return k;
    };
    // deciseconds, at least 1
    let ds = (ESC_WAIT_MS + 99) / 100;
    if (ds < 1) { ds = 1; };
    if (ds > 255) { ds = 255; };
    timeout_mode(ds);
    let more = true;
    while (more) {
        let b = raw_read();
        if (b < 0) {
            more = false;
        } else {
            SQ[SQ_N] = b;
            SQ_N = SQ_N + 1;
            // Stop as soon as the sequence cannot continue with a digit,
            // ';', '<' or '?' -- a letter or '~' ends it. The SQ_N >= 2
            // guard matters: '[' and 'O' are both outside 48..63, and the
            // byte right after the ESC is always one of them, so without it
            // ESC [ A would be collected as one byte and never recognised.
            let last = SQ[SQ_N - 1];
            let stop = SQ_N >= 2 && (last < 48 || last > 63);
            if (SQ_N >= 15 || stop) {
                more = false;
            };
        };
    };
    blocking_mode();
    let k = classify();
    if (k == KEY_UNKNOWN) {
        push_key(SQ_N);
    };
    k
};

// ---------------------------------------------------------------------------
// read_key() -- block until one key is pressed.
//
// A plain byte comes back as itself. A named key comes back as its
// KEY_* constant. ESC never comes back as 27: it is KEY_ESC, or the
// sequence it starts is decoded. KEY_NONE means EOF on stdin, or a read
// error, or an interrupt -- never a trap.
// ---------------------------------------------------------------------------
def read_key() -> long {
    blocking_mode();
    let b = raw_read();
    if (b < 0) {
        return KEY_NONE;
    };
    if (b != 27) {
        return b;
    };
    decode_esc()
};

// ---------------------------------------------------------------------------
// read_key_timeout(ms) -- the same decoding with a deadline.
//
// Implemented with VMIN=0 / VTIME on the terminal itself, NOT with poll(2)
// or select(2). VTIME counts deciseconds, so the deadline is rounded UP to
// the next 10 ms and a request below 10 ms becomes 10 ms; 0 ms is an
// immediate poll. Returns KEY_NONE when nothing arrived in time, and the
// usual key otherwise. While decoding an escape sequence the continuation
// gets ESC_WAIT_MS as well, so `read_key_timeout(10)` on a bare ESC can
// take about half a second -- pass a large ms only if that is what you
// want.
//
// If raw mode is not held this degrades to a plain blocking read, because
// VMIN/VTIME have no effect in canonical mode.
// ---------------------------------------------------------------------------
def read_key_timeout(ms: long) -> long {
    let b = -1;
    if (IN_RAW) {
        let ds = (ms + 99) / 100;
        if (ds < 0) { ds = 0; };
        if (ds > 255) { ds = 255; };
        timeout_mode(ds);
        b = raw_read();
        blocking_mode();
    } else {
        b = raw_read();
    };
    if (b < 0) {
        return KEY_NONE;
    };
    if (b != 27) {
        return b;
    };
    decode_esc()
};

// ===========================================================================
// output -- the module's own byte buffer, then one write(2)
// ===========================================================================

def buf_reset() {
    ESC_LEN = 0;
};

// buf_len() -- how many bytes are in the buffer right now
def buf_len() -> long {
    ESC_LEN
};

// buf_at(i) -- byte i of the buffer, for a caller that wants to inspect or
// copy what was built. Reads past the end return 0; ESC_BUF is 64 bytes.
def buf_at(i: long) -> long {
    if (i < 0 || i >= 64) {
        return 0;
    };
    ESC_BUF[i]
};

// put_byte(b) -- append one byte
def put_byte(b: long) {
    if (ESC_LEN < 64) {
        ESC_BUF[ESC_LEN] = b & 255;
    };
    ESC_LEN = ESC_LEN + 1;
};

// put_num(v) -- append a non-negative long in decimal, no leading zeros, and
// always at least one digit (0 prints "0", which cursor_to(1,1) needs).
// A long is at most 19 digits, so it always fits in the 64-byte buffer.
def put_num(v: long) {
    let n = v;
    if (n < 0) {
        n = 0;
    };
    let k = 0;
    let more = true;
    while (more) {
        DEC_BUF[k] = n % 10;
        k = k + 1;
        n = n / 10;
        more = n > 0;
    };
    let i = k;
    while (i > 0) {
        i = i - 1;
        put_byte(48 + DEC_BUF[i]);
    };
};

// put_str(s) -- append a string's bytes
def put_str(s: str) {
    for i in 0..len(s) {
        put_byte(byte_at(s, i));
    };
};

// put_csi() -- append ESC [
def put_csi() {
    put_byte(27);
    put_byte(91);
};

// ---------------------------------------------------------------------------
// esc_* APPENDERS. They never syscall and never allocate: they build the
// escape sequence into ESC_BUF and return the new length. A renderer in a
// per-frame loop wants THESE, not the sgr_* emitters below -- one write(2)
// per frame instead of one per colour change.
//
//   esc_fg(r,g,b)      -> ESC [ 0;38;2;R;G;B m
//   esc_bg(r,g,b)      -> ESC [ 0;48;2;R;G;B m
//   esc_rg(fr,fg,fb,br,bg,bb) -> ESC [ 0;38;2;R;G;B;48;2;R;G;B m
//   esc_reset()        -> ESC [ 0 m
//   esc_clear()        -> ESC [ 2 J   (whole screen, not the scrollback)
//   esc_home()         -> ESC [ H
//   esc_cursor(r,c)    -> ESC [ R ; C H  (1-based, as CUP wants them)
// ---------------------------------------------------------------------------
def esc_fg(r: long, g: long, b: long) -> long {
    put_csi();
    put_byte(48); put_byte(59);                 // 0;
    put_str("38;2;");
    put_num(clamp255(r)); put_byte(59);
    put_num(clamp255(g)); put_byte(59);
    put_num(clamp255(b));
    put_byte(109);                              // m
    ESC_LEN
};

def esc_bg(r: long, g: long, b: long) -> long {
    put_csi();
    put_byte(48); put_byte(59);
    put_str("48;2;");
    put_num(clamp255(r)); put_byte(59);
    put_num(clamp255(g)); put_byte(59);
    put_num(clamp255(b));
    put_byte(109);
    ESC_LEN
};

def esc_rg(fr: long, fg: long, fb: long, br: long, bg: long, bb: long) -> long {
    put_csi();
    put_byte(48); put_byte(59);
    put_str("38;2;");
    put_num(clamp255(fr)); put_byte(59);
    put_num(clamp255(fg)); put_byte(59);
    put_num(clamp255(fb)); put_byte(59);
    put_str("48;2;");
    put_num(clamp255(br)); put_byte(59);
    put_num(clamp255(bg)); put_byte(59);
    put_num(clamp255(bb));
    put_byte(109);
    ESC_LEN
};

def esc_reset() -> long {
    put_csi();
    put_byte(48);
    put_byte(109);
    ESC_LEN
};

def esc_clear() -> long {
    put_csi();
    put_byte(50); put_byte(74);                 // 2J
    ESC_LEN
};

def esc_home() -> long {
    put_csi();
    put_byte(72);                               // H
    ESC_LEN
};

def esc_cursor(row: long, col: long) -> long {
    put_csi();
    put_num(row);
    put_byte(59);
    put_num(col);
    put_byte(72);                               // H
    ESC_LEN
};

// clamp255 -- SGR colour components are one byte; a caller that divides or
// scales without clamping should not produce an illegal sequence.

// ---------------------------------------------------------------------------
// sgr_* EMITTERS. Each builds its sequence with the esc_* appender above
// and writes ESC_BUF with ONE write(2). Fine for setup and for occasional
// highlights; wrong for a per-cell loop -- use the appenders there.
// ---------------------------------------------------------------------------
def sgr_fg(r: long, g: long, b: long) {
    buf_reset();
    esc_fg(r, g, b);
    out_flush();
};

def sgr_bg(r: long, g: long, b: long) {
    buf_reset();
    esc_bg(r, g, b);
    out_flush();
};

def sgr_rg(fr: long, fg: long, fb: long, br: long, bg: long, bb: long) {
    buf_reset();
    esc_rg(fr, fg, fb, br, bg, bb);
    out_flush();
};

def sgr_reset() {
    buf_reset();
    esc_reset();
    out_flush();
};

// out_flush() -- write whatever is in ESC_BUF to fd 1 and empty it. One write.
def out_flush() -> void {
    if (ESC_LEN > 0) {
        syscall(1, 1, &ESC_BUF[0], ESC_LEN);
    };
    ESC_LEN = 0;
};

// ---------------------------------------------------------------------------
// the screen-state helpers. Each is the esc_* appender plus one out_flush(), so
// each is exactly one write(2) of a few bytes.
// ---------------------------------------------------------------------------
def enter_alt_screen() {
    buf_reset();
    put_csi();
    put_str("?1049h");
    out_flush();
};

def leave_alt_screen() {
    buf_reset();
    put_csi();
    put_str("?1049l");
    out_flush();
};

def hide_cursor() {
    buf_reset();
    put_csi();
    put_str("?25l");
    out_flush();
};

def show_cursor() {
    buf_reset();
    put_csi();
    put_str("?25h");
    out_flush();
};

def clear_screen() {
    buf_reset();
    esc_clear();
    out_flush();
};

def home() {
    buf_reset();
    esc_home();
    out_flush();
};

def cursor_to(row: long, col: long) {
    buf_reset();
    esc_cursor(row, col);
    out_flush();
};

// ---------------------------------------------------------------------------
// enter_screen() / leave_screen() -- the compound pair, and the one the
// header's pattern calls. enter_screen hides the cursor and switches to the
// alternate screen buffer (ESC[?1049h: save cursor, switch, clear).
// leave_screen is the exact inverse and is safe to call when
// enter_screen() was never called.
// ---------------------------------------------------------------------------
def enter_screen() {
    enter_alt_screen();
    hide_cursor();
};

def leave_screen() {
    show_cursor();
    leave_alt_screen();
};

// restore_all_exit(code) -- the most forgettable exit there is: alt screen
// off, cursor on, cooked mode, exit. Use this instead of restore_exit()
// unless the program never entered the alt screen (calling it anyway is
// harmless: the two escape sequences are no-ops on a normal screen).
def restore_all_exit(code: long) {
    show_cursor();
    leave_alt_screen();
    restore_exit(code)
};

let tm_ts: [long; 2] = [0; 2];
let tm_rm: [long; 2] = [0; 2];

// ── the clock ────────────────────────────────────────────────────────────

// clock_us() -> long -- microseconds from CLOCK_MONOTONIC.  Allocation-free:
// one syscall, one reused buffer, and the answer is a long.

// (clock_us() / 1000) -> long -- the same clock in milliseconds, for a progress line
// rather than for scheduling.

// ── the pacer ────────────────────────────────────────────────────────────

type Pacer = { period_us: long, sched: long, frames: long, dropped: long, last: long };

// pacer_new(fps) -> Pacer -- a pacer for `fps` frames per second.  An fps
// below 1 (or above a million, whose period would round to 0) is clamped
// rather than left to divide by zero.
def pacer_new(fps: long) -> Pacer {
    let f = fps;
    if (f < 1) { f = 1; };
    let per = 1000000 / f;
    if (per < 1) { per = 1; };
    { period_us: per, sched: clock_us(), frames: 0, dropped: 0, last: 0 }
};

// pacer_start(p) -- re-base the schedule on the clock now and zero the
// counters.  pacer_new() has already done this, so a second run of the
// animation is the only reason to call it.
def pacer_start(p: Pacer) {
    p.sched = clock_us();
    p.frames = 0;
    p.dropped = 0;
    p.last = 0
};

// pacer_next(p) -> long -- one frame's wait.  See "the pacer contract".
// Returns the microseconds slept (draw now) or the negative lag (drop the
// frame).  Allocation-free: the deadline lives in the Pacer record.
def pacer_next(p: Pacer) -> long {
    p.sched = p.sched + p.period_us;
    let d = p.sched - clock_us();
    if (d <= 0 - p.period_us) {
        // At least a whole frame late: draw nothing and let the schedule
        // come back on its own, rather than trying to catch up.
        p.dropped = p.dropped + 1;
        p.last = d;
        d
    } else {
        let slept = 0;
        let left = d;
        while (left > 0) {
            // Keep 1 ms in hand (as badapple80x30.y does), so that a small
            // overshoot cannot stretch the schedule.
            let sl = left;
            if (left > 1200) { sl = left - 1000; };
            nap_us(sl);
            slept = slept + sl;
            left = p.sched - clock_us();
        };
        p.frames = p.frames + 1;
        p.last = left;
        slept
    }
};

// pacer_period_us(p) -> long -- the frame period in microseconds.
def pacer_period_us(p: Pacer) -> long { p.period_us };

// pacer_frames(p) -> long -- frames presented (not dropped).
def pacer_frames(p: Pacer) -> long { p.frames };

// pacer_dropped(p) -> long -- frames dropped for being late.
def pacer_dropped(p: Pacer) -> long { p.dropped };

// pacer_lag_us(p) -> long -- how late the last pacer_next() found the
// schedule: 0 or negative, and negative whenever a frame was dropped.
def pacer_lag_us(p: Pacer) -> long { p.last };

// ── the rate meter ───────────────────────────────────────────────────────
//
// A frame counter with a window.  Call fps_tick once per frame *drawn* (not
// per frame scheduled), then read the rate.  Rates are hundredths of a
// frame per second, because there is no float -> long (§2.4a): 3000 is
// 30.00 fps.  fps_line() does the formatting for a status line.

type Fps = { win_us: long, t_beg: long, t0: long, f0: long, n: long, x100: long };

// fps_new(win_us = 500000) -> Fps -- a meter over windows of `win_us`
// microseconds (half a second by default).  A window shorter than a
// millisecond is raised to one, so a rate is never divided by nothing.
def fps_new(win_us: long = 500000) -> Fps {
    let w = win_us;
    if (w < 1000) { w = 1000; };
    let t = clock_us();
    { win_us: w, t_beg: t, t0: t, f0: 0, n: 0, x100: 0 }
};

// fps_tick(f) -- count one drawn frame, and close the window when it is
// full.  Allocation-free, one clock read.
def fps_tick(f: Fps) {
    f.n = f.n + 1;
    let t = clock_us();
    let d = t - f.t0;
    if (d >= f.win_us) {
        f.x100 = (f.n - f.f0) * 100000000 / d;
        f.t0 = t;
        f.f0 = f.n;
    }
};

// fps_x100(f) -> long -- the rate over the last completed window, in
// hundredths of a frame per second; 0 until the first window closes.
def fps_x100(f: Fps) -> long { f.x100 };

// fps_frames(f) -> long -- frames counted since fps_new().
def fps_frames(f: Fps) -> long { f.n };

// fps_avg_x100(f) -> long -- the rate since fps_new(), in hundredths of a
// frame per second.  Before the first frame it reports the window rate
// rather than dividing by a zero-length span.
def fps_avg_x100(f: Fps) -> long {
    let d = clock_us() - f.t_beg;
    if (d < 1000) { f.x100 } else { f.n * 100000000 / d }
};

// fps_line(f) -> str -- "29.94 fps now, 29.97 avg over 300 frames", for a
// status line at the end of a run.  This one allocates (it builds a
// string); it is not for a per-frame path.
def fps_line(f: Fps) -> str {
    f"{fps_x100(f) / 100.0:.2f} fps now, {fps_avg_x100(f) / 100.0:.2f} avg over {fps_frames(f)} frames"
};

// nap_us(us) -> long -- nanosleep (syscall 35), returning the microseconds
// actually slept, so an overshoot reads over `us` and an interrupted wait reads
// under it.
//
// nanosleep returns EARLY when a signal arrives, leaving the time it did not
// sleep in its second buffer, so what is left is resumed -- which is what keeps
// a Ctrl-C's SIGINT from shortening the wait.  A us of 0 or less returns at
// once.  The turns cap is a belt-and-braces guard: a storm of signals must not
// spin this loop forever.
//
// The first version of this function was six lines: one nanosleep, no retry, no
// remainder, and a LOCAL `[long; 2]`, so it allocated 56 bytes a call and
// returned a bare 0.  The toolkit's own suite caught both -- "nap_us(2000)
// returns" failed against a wait that had plainly happened.  tm_ts/tm_rm are
// module-level, so the buffers are allocated once.
def nap_us(us: long) -> long {
    let left = us;
    let slept = 0;
    let turns = 0;
    while (left > 0 && turns < 64) {
        let s = left / 1000000;
        tm_ts[0] = s;
        tm_ts[1] = (left - s * 1000000) * 1000;
        let r = syscall(35, &tm_ts[0], &tm_rm[0]);
        if (r == 0) {
            left = 0;
        } else {
            left = tm_rm[0] * 1000000 + tm_rm[1] / 1000
        };
        turns = turns + 1
    };
    slept + us - left
};

// ── the additions that were sink.y and textout.y ────────────────────────
//
// Nine folders wanted "render this Surface as text and give me a digest of
// it", and each wrote it: sink.y in five, textout.y in four, with
// out_capture carrying two different signatures inside the same file. The only
// reason it was ever separate is that `capture_*` existed but nothing folded a
// Surface into it.
//
// grid_text RETURNS a str. sink's wrote into the capture buffer and returned
// nothing, which is why the four textout copies and the five sink copies
// disagree.
// FNV-1a 64 over every cell's CODEPOINT AND FOREGROUND. The vendored
// textout.y/sink.y copies this, which is why two different surfaces hashed to
// the same number: it was written as capture_checksum(), so the `s` was never
// read and the answer described whatever had last been flushed rather than the
// surface asked about. A frame that changed colour but not shape has to be a
// different digest -- that is what makes the per-frame line in a deterministic
// dump evidence rather than decoration -- so both fields go in.
const GRID_SEED: long = -3750763034362895579;   // 14695981039346656037, signed
const GRID_PRIME: long = 1099511628211;

def grid_digest(s: Surface) -> long {
    let h: long = GRID_SEED;
    let n = s.rows * s.cols;
    let i = 0;
    while (i < n) {
        h = (h ^ s.ch[i]) * GRID_PRIME;
        h = (h ^ s.fg[i]) * GRID_PRIME;
        i = i + 1;
    };
    h
};

def grid_text(s: Surface) -> str {
    let out = "";
    let r = 0;
    while (r < s.rows) {
        let c = 0;
        while (c < s.cols) {
            out = out + chr(s.ch[r * s.cols + c]);
            c = c + 1
        };
        out = out + "\n";
        r = r + 1
    };
    out
};

def rows(s: Surface) -> long { s.rows };
def cols(s: Surface) -> long { s.cols };
def key_pending() -> long { buf_len() };

export {
  Size, Surface, Pacer, Fps,
  // The twenty-seven below were NOT in the API the campaign agreed. They are
  // here because twenty-six of them are called by an example that vendored
  // term.y or fb.y, and the twenty-seventh (out_flush) is what term.flush()
  // was: the surface form of flush() won the name and the output-buffer form
  // needed one of its own. Measured by listing every term.* and fb.* call site
  // in the corpus and checking each against this export block.
  buf_reset, buf_len, buf_at, key_pending,
  put_byte, put_num, put_str, put_csi,
  esc_fg, esc_bg, esc_rg, esc_reset, esc_clear, esc_home, esc_cursor,
  sgr_fg, sgr_bg, sgr_rg, sgr_reset,
  rd16, rd32, restore_all_exit, out_flush,
  put_at, braille_mask, frame_bytes, row_bytes, row_count, set_fd, fd, spill,
  is_tty, raw_mode, cooked_mode, active, restore, restore_exit, arm_watchdog,
  size, set_size, read_key, read_key_timeout, push_key, pop_key, key_pending,
  enter_screen, leave_screen, enter_alt_screen, leave_alt_screen,
  hide_cursor, show_cursor, clear_screen, home, cursor_to,
  rgb, r_of, g_of, b_of, grey, lerp_rgb, clamp255,
  new, resize, rows, cols, clear, fill, put, put_skip, get, key_at, text,
  hline, vline, rect, fill_rect, blit,
  utf8_len, utf8_byte, width_of,
  ramp_index, shade, shade_ascii, shade_blocks, shade_half, shade_braille,
  shade_len, braille, braille_cp, braille_put,
  begin_frame, cell_same, cell_commit, flush, flush_diff, end_frame,
  capture_on, capture_off, capture_reset, capture_len, capture_byte,
  capture_str, capture_checksum, grid_digest, grid_text,
  pacer_new, pacer_start, pacer_next, pacer_period_us, pacer_frames,
  pacer_dropped, pacer_lag_us,
  fps_new, fps_tick, fps_x100, fps_frames, fps_avg_x100, fps_line
};
