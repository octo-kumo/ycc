#!/usr/bin/env python3
"""Bake std/gui.font: an 8x16 anti-aliased cell font for std/gui.y.

    python3 src/tools/guifont/mkfont.py > src/y/std/gui.font

Glyphs come from DejaVu Sans Mono (Bitstream Vera licence: free to embed), with
DejaVu Sans for the code points the mono face lacks. No installed face has the
Runic block, so the sixteen runes of the game's rune set are drawn here, as
strokes. Box drawing,
block elements and braille are NOT baked: gui.y draws them from rules so they
tile exactly. File layout (little endian):

    "YGF2"  u16 count  u8 cell_w  u8 cell_h
    count x u32 code point, ascending
    count x cell_w*cell_h/2 bytes of 4-bit coverage (0..15), row by row, two pixels a
    byte: the even pixel in the low nibble
"""
import struct, sys
from fontTools.ttLib import TTFont
from PIL import Image, ImageDraw, ImageFont

MONO = "/usr/share/fonts/dejavu-sans-mono-fonts/DejaVuSansMono.ttf"
SANS = "/usr/share/fonts/dejavu-sans-fonts/DejaVuSans.ttf"
SYM2 = "/usr/share/fonts/google-noto/NotoSansSymbols2-Regular.ttf"   # OFL
CW, CH, BASE = 8, 16, 12

RANGES = [
    (0x20, 0x7E), (0xA0, 0xFF),          # ASCII, Latin-1
    (0x100, 0x17F),                      # Latin Extended-A
    (0x370, 0x3FF),                      # Greek
    (0x2010, 0x2027), (0x2030, 0x203A),  # punctuation
    (0x2190, 0x21FF),                    # arrows
    (0x2200, 0x22FF),                    # math (incl. the game's infinity, bullet operator and square cup)
    (0x25A0, 0x25FF),                    # geometric shapes (the game's triangles, circles)
    (0x2600, 0x26FF),                    # miscellaneous symbols (hearts, moons, suns)
    (0x2714, 0x2718), (0x2726, 0x2727), (0x2736, 0x273B), (0x2764, 0x2764),
    (0x28C, 0x28C),                      # turned v
]

# sixteen Elder Futhark runes as polylines in a
# 3.5 x 10 box, y down
RUNES = {
    0x16A0: [[(0,0),(0,10)], [(0,3.5),(3.5,0.5)], [(0,7),(3.5,4)]],
    0x16A2: [[(0,10),(0,0),(3.5,3),(3.5,10)]],
    0x16A6: [[(0,0),(0,10)], [(0,2.5),(3.5,5),(0,7.5)]],
    0x16A8: [[(0,0),(0,10)], [(0,1),(3.5,3.5)], [(0,4.5),(3.5,7)]],
    0x16B1: [[(0,0),(0,10)], [(0,0),(3.5,2.5),(0,5)], [(0,5),(3.5,10)]],
    0x16B2: [[(3.5,2.5),(0,5),(3.5,7.5)]],
    0x16B7: [[(0,1),(3.5,9)], [(3.5,1),(0,9)]],
    0x16B9: [[(0,0),(0,10)], [(0,0),(3.5,2.5),(0,5)]],
    0x16BA: [[(0,0),(0,10)], [(3.5,0),(3.5,10)], [(0,3.5),(3.5,6.5)]],
    0x16BE: [[(1.75,0),(1.75,10)], [(0,3),(3.5,6)]],
    0x16C1: [[(1.75,0),(1.75,10)]],
    0x16C3: [[(1.75,0.5),(0,3),(1.75,5.5)], [(1.75,4.5),(3.5,7),(1.75,9.5)]],
    0x16C7: [[(1.75,0),(1.75,10)], [(1.75,0),(3.5,2.5)], [(1.75,10),(0,7.5)]],
    0x16C8: [[(0,0),(0,10)], [(0,0),(3.5,2.5),(0,5)], [(0,5),(3.5,7.5),(0,10)]],
    0x16C9: [[(1.75,10),(1.75,0)], [(0,2.5),(1.75,5.5)], [(3.5,2.5),(1.75,5.5)]],
    0x16CA: [[(3.5,0),(0,4),(3.5,6),(0,10)]],
}

def rune(strokes):
    ss = 8
    img = Image.new("L", (CW * ss, CH * ss), 0)
    d = ImageDraw.Draw(img)
    for poly in strokes:
        pts = [((2.2 + u) * ss, (2.2 + v * 1.07) * ss) for u, v in poly]
        d.line(pts, fill=255, width=int(1.15 * ss), joint="curve")
    return bytes(img.resize((CW, CH), Image.BOX).tobytes())

def covered(cm, cp):
    return cp in cm

def main():
    tm = TTFont(MONO); cmm = tm.getBestCmap()
    ts = TTFont(SANS); cms = ts.getBestCmap()
    t2 = TTFont(SYM2); cm2 = t2.getBestCmap()
    f2 = ImageFont.truetype(SYM2, 12)
    fm = ImageFont.truetype(MONO, 13)
    fs = ImageFont.truetype(SANS, 12)
    glyphs = {}
    for lo, hi in RANGES:
        for cp in range(lo, hi + 1):
            if cp in glyphs: continue
            if cp != 0x20 and cp < 0xA1 and cp not in cmm: continue
            if covered(cmm, cp):
                font, mono = fm, True
            elif covered(cms, cp):
                font, mono = fs, False
            elif covered(cm2, cp):
                font, mono = f2, False
            else:
                continue
            if cp in (0xAD,) or 0x80 <= cp < 0xA0: continue
            img = Image.new("L", (CW * 3, CH * 2), 0)
            d = ImageDraw.Draw(img)
            ch = chr(cp)
            if mono:
                d.text((CW, BASE + 2), ch, fill=255, font=font, anchor="ls")
                box = img.crop((CW, 2, CW * 2, CH + 2))
            else:
                l, t, r, b = d.textbbox((CW, BASE + 2), ch, font=font, anchor="ls")
                w = r - l
                x0 = CW + (CW - w) // 2
                d.rectangle((0, 0, CW * 3, CH * 2), fill=0)
                d.text((x0 - (l - CW), BASE + 2), ch, fill=255, font=font, anchor="ls")
                box = img.crop((CW, 2, CW * 2, CH + 2))
            data = box.tobytes()
            if cp != 0x20 and not any(data): continue
            glyphs[cp] = data
    for cp, strokes in RUNES.items():
        glyphs[cp] = rune(strokes)
    cps = sorted(glyphs)
    out = b"YGF2" + struct.pack("<HBB", len(cps), CW, CH)
    out += b"".join(struct.pack("<I", c) for c in cps)
    def pack(g):
        return bytes((((g[i + 1] + 8) // 17) << 4) | ((g[i] + 8) // 17) for i in range(0, len(g), 2))
    out += b"".join(pack(glyphs[c]) for c in cps)
    sys.stdout.buffer.write(out)
    sys.stderr.write("%d glyphs, %d bytes\n" % (len(cps), len(out)))

main()
