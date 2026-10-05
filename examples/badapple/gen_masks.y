// gen_masks.y -- write `termblocks_masks`, the charset table that termblocks'
// matcher scores every 4x8 cell against.
//
//   ycc -o gen_masks gen_masks.y && ./gen_masks [OUT]
//
// Format: NM x 8 bytes, little-endian (mask u32, codepoint u32), in
// termblocks' vocab priority order -- the 27 block and shade glyphs first
// (the matcher's early exit), then all 256 braille glyphs, then the space,
// which is what an all-blank cell falls back to.  A mask is one cell's
// idealized 4x8 coverage binarized (> 0.5): exactly the ink a terminal
// paints for that glyph, and what the matcher's Hamming score counts.
//
// The table is built by the shared renderer (tbrender.y, the one the players
// import), so this generator and the players cannot drift apart: the block
// and shade glyphs come out of the packed (codepoint, ink mask) pairs there,
// the braille block out of the dot geometry there, and the space last.  The
// Python original read the vocab out of the termblocks package instead; this
// needs nothing but the compiler.

import fs;
import tbrender;

const NM = 284;      // 27 blocks + 256 braille + the space

// One vocab entry as (mask, codepoint), hex, the way the Python original
// printed them.
def show(i: long) -> str {
    "(" + f"0x{tbrender.tbMK[i]:08x}" + ", " + f"0x{tbrender.tbCP[i]:04x}" + ")"
};

// The entries lo..hi as a Python-style list.
def show_all(lo: long, hi: long) -> str {
    let s = "[";
    for i in lo..hi {
        if (i != lo) { s = s + ", " };
        s = s + show(i);
    };
    s + "]"
};

let buf: [byte] = [];

tbrender.tb_init();
for i in 0..NM {
    let m = tbrender.tbMK[i];
    let cp = tbrender.tbCP[i];
    for k in 0..4 { buf += (m >>> (k * 8)) & 255 };
    for k in 0..4 { buf += (cp >>> (k * 8)) & 255 };
};

// The invariants the matcher leans on: the full block is first so a full
// cell can early-exit on it, and the space is last because its empty mask
// scores worst on any ink at all.
if (tbrender.tbMK[0] != 4294967295 || tbrender.tbCP[0] != 0x2588) {
    eputs("gen_masks: full block must be first (early exit)\n");
    exit(1);
};
if (tbrender.tbMK[NM - 1] != 0 || tbrender.tbCP[NM - 1] != 0x20) {
    eputs("gen_masks: space (empty mask) must be last\n");
    exit(1);
};
// U+28FF (every dot) must score the same as U+2588 (the whole cell inked),
// and U+2800 (no dot) as the space.
if (tbrender.tbMK[NM - 2] != 4294967295 || tbrender.tbMK[27] != 0) {
    eputs("gen_masks: braille block does not span the cell\n");
    exit(1);
};

let out = "termblocks_masks";
let args = argv();
if (len(args) > 1) { out = args[1] };
if (!fs.write_bytes(out, buf)) {
    eputs("gen_masks: cannot write ");
    eputs(out);
    eputs("\n");
    exit(1);
};
puts(tostring(NM) + " masks -> " + out + " (" + tostring(len(buf)) + " bytes)\n");
puts("first 8: " + show_all(0, 8) + "\n");
puts("last 4 : " + show_all(NM - 4, NM) + "\n");