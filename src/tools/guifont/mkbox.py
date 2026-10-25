#!/usr/bin/env python3
"""The box-drawing table of std/gui.y: for U+2500..U+257F the weight of each of the
four arms, read from the Unicode names, packed L | R<<2 | U<<4 | D<<6 with 0 none,
1 light, 2 heavy, 3 double. Prints the Y literal."""
import unicodedata

DIRS = {"LEFT": ["L"], "RIGHT": ["R"], "UP": ["U"], "DOWN": ["D"],
        "VERTICAL": ["U", "D"], "HORIZONTAL": ["L", "R"]}
W = {"LIGHT": 1, "SINGLE": 1, "HEAVY": 2, "DOUBLE": 3}

def arms(name):
    words = name.replace("BOX DRAWINGS ", "").split()
    words = [w for w in words if w not in ("ARC", "DASH", "TRIPLE", "QUADRUPLE")]
    # "LIGHT DOUBLE DASH HORIZONTAL": DOUBLE there is the dash count, not the weight
    if "DOUBLE" in name and "DASH" in name:
        words = [w for w in words if w != "DOUBLE"]
    groups, cur = [], []
    for w in words:
        if w == "AND":
            groups.append(cur); cur = []
        else:
            cur.append(w)
    groups.append(cur)
    out = {"L": 0, "R": 0, "U": 0, "D": 0}
    last = 1
    for g in groups:
        adj = [W[w] for w in g if w in W]
        weight = adj[0] if adj else last
        last = weight
        for w in g:
            for d in DIRS.get(w, []):
                out[d] = weight
    return out

vals = []
for cp in range(0x2500, 0x2580):
    n = unicodedata.name(chr(cp))
    if "DIAGONAL" in n:
        vals.append(0)
        continue
    a = arms(n)
    vals.append(a["L"] | a["R"] << 2 | a["U"] << 4 | a["D"] << 6)

def chk(cp, **kw):
    a = vals[cp - 0x2500]
    got = dict(L=a & 3, R=a >> 2 & 3, U=a >> 4 & 3, D=a >> 6 & 3)
    for k, v in kw.items():
        assert got[k] == v, (hex(cp), k, got)
chk(0x2500, L=1, R=1, U=0, D=0); chk(0x2502, U=1, D=1, L=0, R=0)
chk(0x250C, D=1, R=1, L=0, U=0); chk(0x254B, L=2, R=2, U=2, D=2)
chk(0x2551, U=3, D=3); chk(0x2568, U=3, L=1, R=1, D=0)
chk(0x257F, U=2, D=1); chk(0x2554, D=3, R=3); chk(0x2553, D=3, R=1)

lines = []
for i in range(0, 128, 16):
    lines.append("    " + ", ".join(str(v) for v in vals[i:i + 16]))
print("let BOXT: [long; 128] = [\n" + ",\n".join(lines) + "\n];")
