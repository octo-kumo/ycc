// tbrender.y -- shared pixel -> text renderer for the bad apple Y players.
//
// Imported by badapple160x60.y (160x60 cells) and badapple80x30.y (80x30
// cells); badapple.y is the C reference's own rendering logic and stands
// alone.  A player hands us one 4x8 cell bitmap per screen cell (plus the
// soft per-subpixel coverage sums it accumulated while upsampling) and we
// emit the ANSI text row: the Hamming-optimal termblocks (character, flip)
// glyph and the color.
//
// The matcher is the termblocks scoring function: for every candidate
// mask M of the 284-entry charset (block elements first, braille last,
// space at the very end) the error is popcount(mask XOR M), the flipped
// variant costs 32 - err, and the strict best wins with termblocks'
// lexicographic (err, charset index, no-flip) tie-break -- early exit on
// a zero error keeps the common exact cases fast.
//
// Color: mode "mono" is the classic white-on-black with the flip SGR.
// The fitted modes are the termblocks color pipeline adapted to a binary
// source: with the glyph already chosen, the two cell colors are the
// least-squares fit of the soft coverage v (0..64 per subpixel, straight
// from the player's bilinear stage) over the DISPLAYED ink set -- because
// the mask is binary the 2x2 system decouples into two means, so
//   fg_byte = mean v over ink subpixels   * 255/64
//   bg_byte = mean v over background      * 255/64
// (a flip swaps the two sets, which is why fitted modes need no flip
// SGR; the colors carry the polarity).  The bytes are quantized to 8
// levels to cut SGR churn, then mapped onto a tint ramp: white (gray),
// phosphor green, amber or ice.  Flat cells come out as a space whose
// background carries the cell tone, exactly like the reference demo.
//
// Options are runtime, parsed by tb_opt() from argv:
//   --color=mono | gray | green | amber | ice   (bare "gray" also works)
//
// Row protocol used by the players:
//   tb_row_reset();            // start a terminal row
//   tb_paint(m, sumv, summv);  // once per cell, left to right
//   tb_row_flush(row);         // diff against last frame, write, remember
// where sumv = total soft coverage in the cell (0..2048) and
// summv = soft coverage on the cell's 1-bits.  tb_row_len() reports how
// many bytes the row produced (handy for assertions).

// The charset, in termblocks' vocab priority order: the 27 block and shade
// glyphs first (their codepoints as u16s in TBCP, their 4x8 ink masks as u32s
// in TBMK), then all 256 braille glyphs U+2800..U+28FF, then the space, which
// scores worst on any ink and so is only ever an all-blank cell's fallback.
// The other 257 entries are fully implied by their place in the list and by
// the dot geometry below (the eight squares at the end of TBMK), so the whole
// 284-entry table is 194 bytes of data: no table file to ship, and
// gen_masks.y writes the full table out again -- the one termblocks itself
// emits, which these bytes reproduce exactly.
let TBCP = "\x88\x25\x80\x25\x84\x25\x8c\x25\x90\x25\x81\x25\x82\x25\x83\x25\x85\x25\x86\x25\x87\x25\x94\x25\x8e\x25\x8a\x25\x91\x25\x92\x25\x93\x25\x98\x25\x9d\x25\x96\x25\x97\x25\x9a\x25\x9e\x25\x99\x25\x9b\x25\x9c\x25\x9f\x25";
let TBMK = "\xff\xff\xff\xff\xff\xff\x00\x00\x00\x00\xff\xff\x33\x33\x33\x33\xcc\xcc\xcc\xcc\x00\x00\x00\xf0\x00\x00\x00\xff\x00\x00\xf0\xff\x00\xf0\xff\xff\x00\xff\xff\xff\xf0\xff\xff\xff\x0f\x00\x00\x00\x11\x11\x11\x11\x77\x77\x77\x77\x81\x24\x81\x24\xa5\xa5\xa5\xa5\x7e\xdb\x7e\xdb\x33\x33\x00\x00\xcc\xcc\x00\x00\x00\x00\x33\x33\x00\x00\xcc\xcc\x33\x33\xcc\xcc\xcc\xcc\x33\x33\x33\x33\xff\xff\xff\xff\x33\x33\xff\xff\xcc\xcc\xcc\xcc\xff\xff\x33\x00\x00\x00\x00\x33\x00\x00\x00\x00\x33\x00\xcc\x00\x00\x00\x00\xcc\x00\x00\x00\x00\xcc\x00\x00\x00\x00\x33\x00\x00\x00\xcc";


let tbMK: [long; 284] = [0; 284];   // each glyph's 4x8 ink mask
let tbCP: [long; 284] = [0; 284];   // ... and its codepoint

let tbCUP = "\x1b[00;1H";
let tb_obuf: [byte; 8192] = [0; 8192];   // the CUP above, then the row's glyphs
let tb_pbuf: [byte; 491520] = [0; 491520];   // 60 rows x 8192 B previous-frame cache
let tb_plen: [long; 60] = [0; 60];
let tb_len = 0;
let tb_mode = 0;                             // 0 mono, 1 fitted
let tb_tint: [long; 3] = [255; 3];           // the tint ramp
let tb_lastkey = -1;                         // per-row SGR change detector

// A little-endian u32 out of a packed string.
def tb_u32(s: str, i: long) -> long {
    byte_at(s, i) | (byte_at(s, i + 1) << 8) | (byte_at(s, i + 2) << 16)
        | (byte_at(s, i + 3) << 24)
};

// The ink mask of the braille glyph whose raised dots are the bits of
// `dots`: one 2x2 subpixel square per raised dot, the squares themselves
// being the eight that follow the 27 block masks in TBMK.  Dot b paints the
// square at its own row R and column C of the cell's 2x4 dot grid, and
// Unicode numbers the dots down the left column (b 0..2), down the right
// (3..5), then across the bottom row (6, 7).
def tb_braille(dots: long) -> long {
    let m = 0;
    for b in 0..8 {
        if (((dots >> b) & 1) == 1) { m = m | tb_u32(TBMK, 108 + b * 4) };
    };
    m
};

def tb_init() {
    // The masks are read once per charset entry per cell, so they are unpacked
    // into longs here; the codepoints ride along in the same order.
    for i in 0..27 {
        let b = i * 2;
        tbMK[i] = tb_u32(TBMK, i * 4);
        tbCP[i] = byte_at(TBCP, b) | (byte_at(TBCP, b + 1) << 8);
    };
    for d in 0..256 {
        tbMK[27 + d] = tb_braille(d);
        tbCP[27 + d] = 0x2800 + d;
    };
    tbMK[283] = 0;
    tbCP[283] = 32;
    // the row buffer opens with the CUP "ESC [ r c ; 1 H"; the row number
    // goes into bytes 2 and 3 when the row is flushed
    for k in 0..7 { tb_obuf[k] = byte_at(tbCUP, k) };
};

def tb_ink(m: long) -> long {
    let v = m - ((m >> 1) & 0x55555555);
    v = (v & 0x33333333) + ((v >> 2) & 0x33333333);
    v = (v + (v >> 4)) & 0x0f0f0f0f;
    ((v * 0x01010101) >> 24) & 255
};

def tb_best_cell(m: long) -> long {
    let best = 33;
    let r = 32;
    for k in 0..284 {
        let e = tb_ink(m ^ tbMK[k]);
        let fl = 32 - e;
        let c = 0;
        let cf = 0;
        if (fl < e) { c = fl; cf = 1; } else { c = e; cf = 0; };
        if (c < best) {
            best = c;
            r = (cf << 20) | tbCP[k];
            if (best == 0) { return r; };
        };
    };
    r
};

def tb_byte(b: long) {
    tb_obuf[tb_len] = b;
    tb_len ++;
};

def tb_num(v: long) {
    // decimal, 0..255, no leading zeros (SGR channel values)
    let hi = v / 100;
    let r = v - hi * 100;
    let lo = r / 10;
    if (hi > 0) {
        tb_byte(48 + hi);
        tb_byte(48 + lo);
    } else if (lo > 0) {
        tb_byte(48 + lo);
    };
    tb_byte(48 + r - lo * 10);
};

def tb_row_reset() {
    // the row's own bytes start after the CUP in the head of the buffer
    tb_len = 7;
    tb_lastkey = -1;
};

def tb_row_len() -> long {
    tb_len
};

def tb_q8(x: long) -> long {
    // round to an 8-level byte, clamp (255 rounds up and pins)
    let q = (x + 4) - ((x + 4) & 7);
    if (q > 255) { q = 255; };
    q
};

def tb_mono_sgr(f: long) {
    let e = if f == 0 { "\x1b[0;37;40m" } else { "\x1b[0;30;47m" };
    for k in 0..10 {
        tb_byte(byte_at(e, k));
    };
};

def tb_paint(m: long, sumv: long, summv: long) {
    let sel = tb_best_cell(m);
    let g = sel & 1048575;
    let f = sel >> 20;
    let key = 0;
    if (tb_mode == 0) {
        // mono: one SGR per polarity change in the row
        key = 256 + f;
        if (key != tb_lastkey) {
            tb_lastkey = key;
            tb_mono_sgr(f);
        };
    } else {
        // least-squares two-color fit: binary mask -> two means over the
        // DISPLAYED ink set (a flip swaps ink and background)
        let pop = tb_ink(m);
        let icnt = pop;
        let isum = summv;
        if (f != 0) {
            icnt = 32 - pop;
            isum = sumv - summv;
        };
        let bcnt = 32 - icnt;
        let bsum = sumv - isum;
        let flat = (sumv * 255 + 1024) / 2048;
        let k8 = flat;
        let d8 = flat;
        if (icnt > 0) { k8 = (isum * 255 + (icnt << 5)) / (icnt << 6); };
        if (bcnt > 0) { d8 = (bsum * 255 + (bcnt << 5)) / (bcnt << 6); };
        k8 = tb_q8(k8);
        d8 = tb_q8(d8);
        // The SGR run, \x1b[0;38;2;R;G;B;48;2;R;G;Bm, is built in place at
        // tb_len -- the fixed head, then the two levels through the tint ramp,
        // and the change key packed the same way round (fg high, bg low).  It
        // is kept only when the key changed, so a cell that repeats the row's
        // colors leaves no bytes behind.
        let p = tb_len;
        tb_byte(27); tb_byte(91); tb_byte(48); tb_byte(59);
        tb_byte(51); tb_byte(56); tb_byte(59); tb_byte(50); tb_byte(59);
        let fg = 0;
        for c in 0..3 {
            let kv = (k8 * tb_tint[c] + 127) / 255;
            tb_num(kv);
            tb_byte(59);
            fg = (fg << 8) | kv;
        };
        tb_byte(52); tb_byte(56); tb_byte(59); tb_byte(50); tb_byte(59);
        let bg = 0;
        for c in 0..3 {
            let dv = (d8 * tb_tint[c] + 127) / 255;
            tb_num(dv);
            // the separators go between the channels; the last one is the m
            if (c != 2) { tb_byte(59) };
            bg = (bg << 8) | dv;
        };
        tb_byte(109);
        key = (fg << 24) | bg;
        if (key == tb_lastkey) {
            tb_len = p;
        } else {
            tb_lastkey = key;
        };
    };
    if (g == 32) {
        tb_byte(32);
    } else {
        tb_byte(224 | (g >> 12));
        tb_byte(128 | ((g >> 6) & 63));
        tb_byte(128 | (g & 63));
    };
};

def tb_row_flush(row: long) {
    // diff the finished row against the previous frame's copy; write the
    // CUP + row only when something changed.  row is 1-based, 1..60.  The
    // CUP lives in the head of the row buffer, so a changed row costs one
    // write(2) instead of two.
    let n = 0;
    let base = (row - 1) * 8192;
    for i in 7..tb_len {
        let nv = tb_obuf[i];
        n = n | (tb_pbuf[base + i - 7] ^ nv);
        tb_pbuf[base + i - 7] = nv;
    };
    if (n != 0 || tb_len != tb_plen[row - 1]) {
        let tens = row / 10;
        tb_obuf[2] = 48 + tens;
        tb_obuf[3] = 48 + row - tens * 10;
        syscall(1, 1, &tb_obuf[0], tb_len);
        tb_plen[row - 1] = tb_len;
    };
};

// The options, packed: every name a mode byte (1 mono, 2 gray, 3 green,
// 4 amber, 5 ice, 6 --help), a NUL, the name itself and a closing NUL, so
// "\0" + the argument + "\0" matches one whole name and never part of one,
// and the byte in front of the match is the mode it stands for.  The tint
// ramps follow at 121, three bytes each, gray first.
let TBOPT = "\x01\x00\x6d\x6f\x6e\x6f\x00\x02\x00\x67\x72\x61\x79\x00\x03\x00\x67\x72\x65\x65\x6e\x00\x04\x00\x61\x6d\x62\x65\x72\x00\x05\x00\x69\x63\x65\x00\x01\x00\x2d\x2d\x63\x6f\x6c\x6f\x72\x3d\x6d\x6f\x6e\x6f\x00\x02\x00\x2d\x2d\x63\x6f\x6c\x6f\x72\x3d\x67\x72\x61\x79\x00\x03\x00\x2d\x2d\x63\x6f\x6c\x6f\x72\x3d\x67\x72\x65\x65\x6e\x00\x04\x00\x2d\x2d\x63\x6f\x6c\x6f\x72\x3d\x61\x6d\x62\x65\x72\x00\x05\x00\x2d\x2d\x63\x6f\x6c\x6f\x72\x3d\x69\x63\x65\x00\x06\x00\x2d\x2d\x68\x65\x6c\x70\x00\xff\xff\xff\x60\xff\x80\xff\xb0\x30\x88\xc0\xff";

// tb_opt: apply one option token.  1 = a color option was applied,
// 0 = not ours, -1 = --help.
def tb_opt(s: str) -> long {
    let a = TBOPT.index_of("\x00" + s + "\x00");
    let c = 0;
    if (a > 0) { c = byte_at(TBOPT, a - 1) };
    if (c == 6) { return -1 };
    if (c == 0) { return 0 };
    if (c == 1) {
        tb_mode = 0;
    } else {
        tb_mode = 1;
        let t = 121 + (c - 2) * 3;
        for k in 0..3 { tb_tint[k] = byte_at(TBOPT, t + k) };
    };
    1
};

def tb_print_usage() {
    puts("render options: --color=mono | --color=gray | --color=green | --color=amber | --color=ice\n");
    puts("  mono   classic white-on-black with flip SGRs (default)\n");
    puts("  gray   per-cell least-squares truecolor grays (soft edges)\n");
    puts("  green / amber / ice   the same fit on a phosphor tint\n");
};

export { tb_init, tb_opt, tb_print_usage, tb_row_reset, tb_paint, tb_row_flush, tb_row_len, tbMK, tbCP };
