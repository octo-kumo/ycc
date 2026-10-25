// font -- the 8x16 console font: glyph lookup by code point.
//
// os/assets/font8x16.bin holds the glyphs (os/tools/genfont.py made it): 382 glyphs of
// 16 bytes, one byte a row with the high bit leftmost. Slots: 0..94 are U+0020..U+007E,
// 95..190 U+00A0..U+00FF, 191..350 U+2500..U+259F, then FONT_EXTRA in order, and the last
// is the 'no such glyph' box. ASCII, Latin-1 and the extras are from Source Code Pro (SIL
// Open Font License 1.1, Copyright 2010-2023 Adobe), rasterised at 13 px; box and block
// characters are drawn. `font_init` copies the file into `font_bits` and draws the 256
// braille patterns (U+2800..28FF: two columns of four dots, the dot numbering of the
// Unicode block) after them.
embed FONT_RAW from "../assets/font8x16.bin";

const FONT_W = 8;
const FONT_H = 16;
const FONT_NOTDEF = 381;
const FONT_BRAILLE = 382;

let font_bits: [byte; 10208] = [0; 10208];
/** The code points of the extra glyphs, from slot 351 on (genfont.py's EXTRAS). */
let font_extra: [long] = [8226, 8230, 8592, 8593, 8594, 8595, 8596, 8597, 10003, 10007, 9679, 9675, 9632, 9633, 9650, 9660, 9670, 9733, 9734, 8364, 8216, 8217, 8220, 8221, 8211, 8212, 8804, 8805, 8800, 8776];
let font_ready = false;

/** Load the glyph table; idempotent. */
def font_init() -> void {
    if (font_ready) { return; };
    font_ready = true;
    let n = len(FONT_RAW);
    let i = 0;
    while (i < n) {
        font_bits[i] = FONT_RAW[i];
        i = i + 1;
    };
    // braille: dot k of the pattern sits at (column, row) of the 2x4 grid
    let dcol = [0, 0, 0, 1, 1, 1, 0, 1];
    let drow = [0, 1, 2, 0, 1, 2, 3, 3];
    let p = 0;
    while (p < 256) {
        let base = (FONT_BRAILLE + p) * 16;
        let k = 0;
        while (k < 8) {
            if (((p >> k) & 1) != 0) {
                let bits = 96;
                if (dcol[k] == 1) { bits = 6; };
                let y = 1 + drow[k] * 4;
                font_bits[base + y] = font_bits[base + y] | bits;
                font_bits[base + y + 1] = font_bits[base + y + 1] | bits;
            };
            k = k + 1;
        };
        p = p + 1;
    };
};

/** The glyph slot of code point `cp` (FONT_NOTDEF when there is none). */
def font_slot(cp: long) -> long {
    if (cp >= 32 && cp <= 126) { return cp - 32; };
    if (cp >= 160 && cp <= 255) { return 95 + cp - 160; };
    if (cp >= 9472 && cp <= 9631) { return 191 + cp - 9472; };
    if (cp >= 10240 && cp <= 10495) { return FONT_BRAILLE + cp - 10240; };
    let i = 0;
    while (i < len(font_extra)) {
        if (font_extra[i] == cp) { return 351 + i; };
        i = i + 1;
    };
    FONT_NOTDEF
};

/** Row `y` (0..15) of glyph `slot`: 8 pixels, the high bit leftmost. */
def font_row(slot: long, y: long) -> long { font_bits[slot * 16 + y] };
