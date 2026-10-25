#!/usr/bin/env python3
"""Generate os/assets/font8x16.bin: the 8x16 console font of Y-OS.

One-off tool (run it by hand, commit its output; the build never runs it; os/kernel/font.y
embeds the file and holds the list of EXTRAS, which must match):

    python3 -I os/tools/genfont.py [path/to/SourceCodePro-Regular.otf] > os/assets/font8x16.bin

Glyphs: ASCII, Latin-1, a few symbols, drawn from Source Code Pro (SIL OFL 1.1,
https://github.com/adobe-fonts/source-code-pro) at 13 px with FreeType's monochrome
rasteriser and the baseline on row 12; the box-drawing (U+2500..257F) and block
(U+2580..259F) characters are drawn here, not taken from the font, so they meet
the neighbouring cell exactly. Braille is drawn by the kernel (font.y).
"""
import sys
import unicodedata
from PIL import Image, ImageDraw, ImageFont

W, H = 8, 16
PATH = sys.argv[1] if len(sys.argv) > 1 else "/usr/share/fonts/adobe-source-code-pro-fonts/SourceCodePro-Regular.otf"
font = ImageFont.truetype(PATH, 13)

EXTRAS = [0x2022, 0x2026, 0x2190, 0x2191, 0x2192, 0x2193, 0x2194, 0x2195, 0x2713, 0x2717,
          0x25CF, 0x25CB, 0x25A0, 0x25A1, 0x25B2, 0x25BC, 0x25C6, 0x2605, 0x2606, 0x20AC,
          0x2018, 0x2019, 0x201C, 0x201D, 0x2013, 0x2014, 0x2264, 0x2265, 0x2260, 0x2248]


def from_font(cp):
    """Rows (16 ints of 8 bits) of a glyph from the font, or None when the font lacks it."""
    img = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(img)
    d.fontmode = "1"
    d.text((0, 12), chr(cp), font=font, fill=255, anchor="ls")
    rows = []
    for y in range(H):
        v = 0
        for x in range(W):
            if img.getpixel((x, y)) > 127:
                v |= 0x80 >> x
        rows.append(v)
    if cp != 0x20 and not any(rows):
        return None
    return rows


def blank():
    return [[0] * W for _ in range(H)]


def pack(g):
    out = []
    for y in range(H):
        v = 0
        for x in range(W):
            if g[y][x]:
                v |= 0x80 >> x
        out.append(v)
    return out


def box(cp):
    """A box-drawing character from its name: arms (left, right, up, down) of weight 0/1/2/3 (none/light/heavy/double)."""
    name = unicodedata.name(chr(cp))
    words = name.replace("BOX DRAWINGS ", "").split()
    if "DIAGONAL" in words:
        g = blank()
        for y in range(H):
            xr = round(y * 7 / 15)
            if "CROSS" in name or "RIGHT TO LOWER LEFT" in name:
                g[y][7 - xr] = 1
            if "CROSS" in name or "LEFT TO LOWER RIGHT" in name:
                g[y][xr] = 1
        return pack(g)
    groups = " ".join(words).replace("ARC ", "LIGHT ").split(" AND ")
    lead = None
    for w in words:
        if w in ("LIGHT", "HEAVY", "SINGLE", "DOUBLE"):
            lead = w
            break
    wt = {"LIGHT": 1, "SINGLE": 1, "HEAVY": 2, "DOUBLE": 3}
    arms = {"L": 0, "R": 0, "U": 0, "D": 0}
    for grp in groups:
        gw = grp.split()
        mod = next((wt[w] for w in gw if w in wt), None)
        if mod is None:
            mod = wt.get(lead, 1)
        for w in gw:
            for k, dirs in (("L", ("LEFT", "HORIZONTAL")), ("R", ("RIGHT", "HORIZONTAL")),
                            ("U", ("UP", "VERTICAL")), ("D", ("DOWN", "VERTICAL"))):
                if w in dirs:
                    arms[k] = mod
    g = blank()
    L, R, U, D = (arms[k] for k in "LRUD")
    if 3 in (L, R, U, D):
        L, R, U, D = (3 if a else 0 for a in (L, R, U, D))
        def hline(y, a, b):
            for x in range(a, b + 1):
                g[y][x] = 1
        def vline(x, a, b):
            for y in range(a, b + 1):
                g[y][x] = 1
        if L or R:
            for y, closed in ((6, not U), (9, not D)):
                a = 0 if L else 2
                b = 7 if R else 5
                if closed:
                    hline(y, a, b)
                else:
                    if L:
                        hline(y, 0, 2)
                    if R:
                        hline(y, 5, 7)
        if U or D:
            for x, has_h in ((2, L), (5, R)):
                c = 0 if U else 6
                d = 15 if D else 9
                if has_h:
                    vline(x, c, 6)
                    vline(x, 9, d)
                else:
                    vline(x, c, d)
        return pack(g)
    def th(a):
        return 2 if a == 2 else 1
    if L:
        for t in range(th(L)):
            for x in range(0, 4 + (1 if L == 2 else 0)):
                g[7 + t][x] = 1
    if R:
        for t in range(th(R)):
            for x in range(3, 8):
                g[7 + t][x] = 1
    if U:
        for t in range(th(U)):
            for y in range(0, 8 + (1 if U == 2 else 0)):
                g[y][3 + t] = 1
    if D:
        for t in range(th(D)):
            for y in range(7, 16):
                g[y][3 + t] = 1
    return pack(g)


def block(cp):
    g = blank()
    def fill(x0, y0, x1, y1):
        for y in range(y0, y1):
            for x in range(x0, x1):
                g[y][x] = 1
    if cp == 0x2580:
        fill(0, 0, 8, 8)
    elif 0x2581 <= cp <= 0x2588:
        n = cp - 0x2580
        fill(0, 16 - 2 * n, 8, 16)
    elif 0x2589 <= cp <= 0x258F:
        fill(0, 0, 8 - (cp - 0x2588), 16)
    elif cp == 0x2590:
        fill(4, 0, 8, 16)
    elif cp in (0x2591, 0x2592, 0x2593):
        for y in range(H):
            for x in range(W):
                if cp == 0x2591:
                    g[y][x] = 1 if (x + 2 * y) % 4 == 0 and y % 2 == 0 or (x % 4 == 2 and y % 2 == 1 and False) else 0
                elif cp == 0x2592:
                    g[y][x] = 1 if (x + y) % 2 == 0 else 0
                else:
                    g[y][x] = 0 if (x % 2 == 1 and y % 2 == 1 and (x // 2 + y // 2) % 2 == 0) else 1
        if cp == 0x2591:
            g = blank()
            for y in range(0, H, 2):
                for x in range((y // 2) % 2 * 2, W, 4):
                    g[y][x] = 1
    elif cp == 0x2594:
        fill(0, 0, 8, 2)
    elif cp == 0x2595:
        fill(7, 0, 8, 16)
    else:
        q = {0x2596: "LL", 0x2597: "LR", 0x2598: "UL", 0x2599: "UL LL LR", 0x259A: "UL LR",
             0x259B: "UL UR LL", 0x259C: "UL UR LR", 0x259D: "UR", 0x259E: "UR LL", 0x259F: "UR LL LR"}[cp]
        for part in q.split():
            fill(0 if part[1] == "L" else 4, 0 if part[0] == "U" else 8, 4 if part[1] == "L" else 8, 8 if part[0] == "U" else 16)
    return pack(g)


def notdef():
    g = blank()
    for y in range(2, 14):
        for x in range(1, 7):
            if y in (2, 13) or x in (1, 6):
                g[y][x] = 1
    return pack(g)


glyphs = []  # (codepoint or None, rows)
for cp in range(32, 127):
    glyphs.append(from_font(cp))
for cp in range(0xA0, 0x100):
    glyphs.append(from_font(cp) or notdef())
for cp in range(0x2500, 0x2580):
    glyphs.append(box(cp))
for cp in range(0x2580, 0x25A0):
    glyphs.append(block(cp))
extra_cps = []
for cp in EXTRAS:
    r = from_font(cp)
    if r is not None:
        extra_cps.append(cp)
        glyphs.append(r)
glyphs.append(notdef())

assert extra_cps == EXTRAS, "the font lacks an extra glyph: update EXTRAS and font.y's font_extra"
assert len(glyphs) == 382, "font.y's FONT_NOTDEF and font_bits size assume 382 glyphs"
sys.stdout.buffer.write(bytes(b for g in glyphs for b in g))
