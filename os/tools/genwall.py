#!/usr/bin/env python3
"""Generate os/assets/wallpaper.yvg: the desktop's character as a vector image.

One-off tool (run it by hand, commit its output; the build never runs it). Needs python3 with
numpy and Pillow, and gcc (a small labelling helper is compiled into a temp directory):

    python3 -I os/tools/genwall.py [os/assets/wallpaper.png] > os/assets/wallpaper.yvg
    python3 -I os/tools/genwall.py --svg out.svg < os/assets/wallpaper.yvg   # look at the result

The source (not kept in the repository) is a 1254 x 1254 picture of the character on white. The tool:

  1. cuts the white away (the near-white neutral component that touches the border, and the enclosed
     neutral holes: the loops in the hair and the tail; the warmer whites of the frills stay);
  2. flattens the grain with a Kuwahara filter (edges stay sharp), clusters the pixels into K colours
     (k-means in Lab) and rounds the region borders with a Gaussian mode filter;
  3. paints the colours largest first. A layer is its own region plus a COLLAR px reach into the
     regions painted after it (neighbours overlap, no seam) with the holes that hold only later
     colours filled in, so every border is drawn once and little is painted twice;
  4. blurs each layer's mask, takes its 0.5 contour at sub-pixel precision (marching squares),
     resamples it, splits it at corners and fits cubic Beziers (Schneider, EPS source pixels);
  5. stores the curves as they are: a node is a position, a direction and two handle lengths.

File format (YVG2), little-endian, varints are LEB128:

    "YVG2"  u16 grid  u16 layers
    per layer:   u8 r, g, b   varint outlines
    per outline: varint nodes, then per node
                 varint (zigzag dx << 1 | corner)  varint zigzag dy   (grid units, from the previous node)
                 u8 angle (1/256 turn: the direction the curve leaves the node)
                 [u8 angle of the arriving direction, only for a corner]
                 varint out-handle length, varint in-handle length

Node i to i+1 is the cubic P_i, P_i + out_i d_out_i, P_i+1 - in_i+1 d_in_i+1, P_i+1; an outline wraps
round. Layers are painted in file order, non-zero winding (a hole winds the other way). The grid is
GRID units across the picture. os/uland/vec.y reads it.
"""
import argparse
import ctypes
import math
import multiprocessing
import os
import struct
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageFilter

GRID = 2048
K = 18          # colours
MODE = 2.0      # sigma of the mode filter on the label map (source pixels)
COLLAR = 2      # px a layer reaches under the layers painted after it
SMOOTH = 1.3    # sigma of the blur on a layer's mask before its contour is taken
EPS = 1.0       # Bezier fitting tolerance, source pixels
MINAREA = 16    # outlines enclosing fewer source pixels than this are dropped

# ---------------------------------------------------------------- connected components (C helper)

CC_SRC = r'''
#include <stdint.h>
#include <stdlib.h>
/* 4-connected labelling of a uint8 mask: labels 1..n, 0 for background; returns n */
int label4(const uint8_t *m, int32_t *lab, int w, int h) {
    int n = 0;
    int32_t *st = malloc(sizeof(int32_t) * (size_t)w * h);
    for (int i = 0; i < w * h; i++) lab[i] = 0;
    for (int s = 0; s < w * h; s++) {
        if (!m[s] || lab[s]) continue;
        n++;
        int sp = 0;
        st[sp++] = s;
        lab[s] = n;
        while (sp) {
            int p = st[--sp], x = p % w, y = p / w;
            int nb[4] = { x > 0 ? p - 1 : -1, x < w - 1 ? p + 1 : -1, y > 0 ? p - w : -1, y < h - 1 ? p + w : -1 };
            for (int k = 0; k < 4; k++) {
                int q = nb[k];
                if (q >= 0 && m[q] && !lab[q]) { lab[q] = n; st[sp++] = q; }
            }
        }
    }
    free(st);
    return n;
}
'''
_lib = None


def label4(mask):
    """(labels, count) of the 4-connected components of a boolean mask."""
    global _lib
    if _lib is None:
        d = tempfile.mkdtemp(prefix="genwall")
        c, so = os.path.join(d, "cc.c"), os.path.join(d, "cc.so")
        open(c, "w").write(CC_SRC)
        subprocess.run(["gcc", "-O2", "-shared", "-fPIC", "-o", so, c], check=True)
        _lib = ctypes.CDLL(so)
    h, w = mask.shape
    m = np.ascontiguousarray(mask.astype(np.uint8))
    lab = np.zeros((h, w), np.int32)
    n = _lib.label4(m.ctypes.data_as(ctypes.c_void_p), lab.ctypes.data_as(ctypes.c_void_p), w, h)
    return lab, n


# ---------------------------------------------------------------- the picture

def boxmean(a, r):
    """Mean over a (2r+1)^2 window, edge-padded; a is HxW or HxWxC."""
    extra = ((0, 0),) * (a.ndim - 2)
    p = np.pad(a, ((r, r), (r, r)) + extra, mode="edge")
    c = np.pad(p.cumsum(0).cumsum(1), ((1, 0), (1, 0)) + extra)
    k = 2 * r + 1
    return (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) / (k * k)


def kuwahara(img, r):
    """Each pixel takes the mean of the least-varying of the four (r/2+1)^2 windows that touch it."""
    h = r // 2
    mm = boxmean(img, h)
    var = boxmean(img * img, h).sum(2) - (mm * mm).sum(2)
    means = []
    vars_ = []
    for dy in (-h, h):
        for dx in (-h, h):
            means.append(np.roll(np.roll(mm, -dy, 0), -dx, 1))
            vars_.append(np.roll(np.roll(var, -dy, 0), -dx, 1))
    pick = np.stack(vars_).argmin(0)
    return np.take_along_axis(np.stack(means), pick[None, :, :, None], 0)[0]


def lab_of(rgb):
    c = rgb / 255.0
    c = np.where(c > 0.04045, ((c + 0.055) / 1.055) ** 2.4, c / 12.92)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1, 1.08883])
    f = np.where(xyz > 0.008856, np.cbrt(xyz), 7.787 * xyz + 16 / 116)
    return np.stack([116 * f[..., 1] - 16, 500 * (f[..., 0] - f[..., 1]), 200 * (f[..., 1] - f[..., 2])], -1)


def background(im):
    """Mask of the white: neutral near-white components that touch the border or are not warm."""
    mx, mn = im.max(2), im.min(2)
    lab, n = label4((mn >= 238) & ((mx - mn) <= 3))
    areas = np.bincount(lab.ravel())
    border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
    bg = np.zeros(lab.shape, bool)
    for k in range(1, n + 1):
        if areas[k] < 100 and k not in border:
            continue
        sel = lab == k
        # the frills and the apron are a little warm (red above blue); the hair loops are not
        if k in border or (im[sel][:, 0] - im[sel][:, 2]).mean() < 0.4:
            bg |= sel
    return bg


def blur(a, sigma):
    r = int(sigma * 3) + 1
    x = np.arange(-r, r + 1)
    k = np.exp(-x * x / (2 * sigma * sigma))
    k /= k.sum()
    p = np.pad(a, ((r, r), (0, 0)), mode="edge")
    t = sum(k[i] * p[i:i + a.shape[0]] for i in range(2 * r + 1))
    p = np.pad(t, ((0, 0), (r, r)), mode="edge")
    return sum(k[i] * p[:, i:i + a.shape[1]] for i in range(2 * r + 1))


def quantize(im, seed=1):
    """Label map (0..K-1, K for the background)."""
    h, w, _ = im.shape
    bg = background(im)
    lab = lab_of(kuwahara(im, 2))
    rng = np.random.default_rng(seed)
    idx = np.flatnonzero(~bg.ravel())
    x = lab.reshape(-1, 3)[idx]
    s = x[rng.choice(len(x), min(len(x), 120000), replace=False)]
    c = [s[rng.integers(len(s))]]
    for _ in range(K - 1):
        d = np.min(((s[:, None, :] - np.array(c)[None]) ** 2).sum(2), 1)
        c.append(s[rng.choice(len(s), p=d / d.sum())])
    c = np.array(c)
    for _ in range(30):
        a = ((s[:, None, :] - c[None]) ** 2).sum(2).argmin(1)
        for j in range(K):
            if (a == j).any():
                c[j] = s[a == j].mean(0)
    lbl = np.full(h * w, K, np.int32)
    for i in range(0, len(x), 200000):
        lbl[idx[i:i + 200000]] = ((x[i:i + 200000, None, :] - c[None]) ** 2).sum(2).argmin(1)
    lbl = lbl.reshape(h, w)
    best = np.zeros((h, w), np.int32)
    bv = None
    for j in range(K + 1):
        g = blur((lbl == j).astype(np.float64), MODE)
        if bv is None:
            bv = g
        else:
            m = g > bv
            best[m] = j
            bv = np.where(m, g, bv)
    return best


# ---------------------------------------------------------------- contours

# marching squares; corner bits TL=1 TR=2 BR=4 BL=8, edges T R B L; every segment runs with the
# inside on its right (y down), so an outline and a hole wind opposite ways
T_, R_, B_, L_ = 0, 1, 2, 3
TABLE = {1: [(T_, L_)], 2: [(R_, T_)], 4: [(B_, R_)], 8: [(L_, B_)], 3: [(R_, L_)], 6: [(B_, T_)],
         12: [(L_, R_)], 9: [(T_, B_)], 14: [(L_, T_)], 13: [(T_, R_)], 11: [(R_, B_)], 7: [(B_, L_)]}


def contours(f, level=0.5):
    """Closed sub-pixel contours of f > level: arrays (n, 2) of (x, y) in pixel-centre coordinates."""
    p = np.pad(f, 1, constant_values=0.0)
    hp, wp = p.shape
    ins = p > level
    code = ins[:-1, :-1] * 1 + ins[:-1, 1:] * 2 + ins[1:, 1:] * 4 + ins[1:, :-1] * 8
    cy, cx = np.nonzero((code > 0) & (code < 15))
    cc = code[cy, cx]

    def eid(edge, y, x):
        if edge == T_:
            return 2 * (y * wp + x)
        if edge == B_:
            return 2 * ((y + 1) * wp + x)
        if edge == L_:
            return 2 * (y * wp + x) + 1
        return 2 * (y * wp + x + 1) + 1

    a_, b_ = [], []
    for c, segs in TABLE.items():
        m = cc == c
        for a, b in segs:
            a_.append(eid(a, cy[m], cx[m]))
            b_.append(eid(b, cy[m], cx[m]))
    for c in (5, 10):  # saddles: the centre decides whether the inside joins
        m = cc == c
        y, x = cy[m], cx[m]
        cen = (p[y, x] + p[y, x + 1] + p[y + 1, x + 1] + p[y + 1, x]) / 4 > level
        if c == 5:
            joined, apart = [(T_, R_), (B_, L_)], [(T_, L_), (B_, R_)]
        else:
            joined, apart = [(L_, T_), (R_, B_)], [(R_, T_), (L_, B_)]
        for segs, sel in ((joined, cen), (apart, ~cen)):
            for a, b in segs:
                a_.append(eid(a, y[sel], x[sel]))
                b_.append(eid(b, y[sel], x[sel]))
    if not a_:
        return []
    a_ = np.concatenate(a_)
    b_ = np.concatenate(b_)
    nxt = np.full(2 * hp * wp, -1, np.int64)
    nxt[a_] = b_

    def pos(e):
        horiz = (e & 1) == 0
        k = e >> 1
        y, x = k // wp, k % wp
        x2, y2 = np.where(horiz, x + 1, x), np.where(horiz, y, y + 1)
        t = (level - p[y, x]) / (p[y2, x2] - p[y, x])
        return np.where(horiz, x + t, x * 1.0), np.where(horiz, y * 1.0, y + t)

    seen, out = set(), []
    for s in np.unique(a_).tolist():
        if s in seen:
            continue
        cyc, e = [], s
        while e != -1 and e not in seen:
            seen.add(e)
            cyc.append(e)
            e = nxt[e]
        if e == s and len(cyc) >= 3:
            px, py = pos(np.array(cyc, np.int64))
            out.append(np.stack([px - 1 + 0.5, py - 1 + 0.5], 1))
    return out


def resample(pts, step=1.0):
    """Uniform arc-length resampling of a closed polyline."""
    q = np.vstack([pts, pts[:1]])
    s = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(q, axis=0).T))])
    n = max(int(round(s[-1] / step)), 4)
    t = np.linspace(0, s[-1], n, endpoint=False)
    return np.stack([np.interp(t, s, q[:, 0]), np.interp(t, s, q[:, 1])], 1)


def area(pts):
    x, y = pts[:, 0], pts[:, 1]
    return 0.5 * np.sum(x * np.roll(y, -1) - np.roll(x, -1) * y)


# ---------------------------------------------------------------- Bezier fitting (Schneider)

def find_corners(p, k=4, thr=math.radians(50)):
    n = len(p)
    if n < 3 * k:
        return []
    a = p - np.roll(p, k, 0)
    b = np.roll(p, -k, 0) - p
    mag = np.abs(np.arctan2(a[:, 0] * b[:, 1] - a[:, 1] * b[:, 0], (a * b).sum(1)))
    out = []
    for i in np.flatnonzero(mag > thr):
        if mag[i] >= mag[[(i + j) % n for j in range(-k, k + 1)]].max() and mag[i] > mag[[(i + j) % n for j in range(-k, 0)]].max():
            out.append(i)
    return out


def bez(p, u):
    u = u[:, None]
    v = 1 - u
    return v ** 3 * p[0] + 3 * v * v * u * p[1] + 3 * v * u * u * p[2] + u ** 3 * p[3]


def bez1(p, u):
    u = u[:, None]
    v = 1 - u
    return 3 * v * v * (p[1] - p[0]) + 6 * v * u * (p[2] - p[1]) + 3 * u * u * (p[3] - p[2])


def bez2(p, u):
    u = u[:, None]
    v = 1 - u
    return 6 * v * (p[2] - 2 * p[1] + p[0]) + 6 * u * (p[3] - 2 * p[2] + p[1])


def generate(pts, u, tl, tr):
    """The cubic through the end points with the given end directions, handle lengths by least squares."""
    p0, p3 = pts[0], pts[-1]
    v = 1 - u
    b0, b1, b2, b3 = v ** 3, 3 * v * v * u, 3 * v * u * u, u ** 3
    a1, a2 = tl[None, :] * b1[:, None], tr[None, :] * b2[:, None]
    c00, c01, c11 = (a1 * a1).sum(), (a1 * a2).sum(), (a2 * a2).sum()
    tmp = pts - (np.outer(b0 + b1, p0) + np.outer(b2 + b3, p3))
    x0, x1 = (a1 * tmp).sum(), (a2 * tmp).sum()
    det = c00 * c11 - c01 * c01
    seg = np.hypot(*(p3 - p0))
    al = be = None
    if abs(det) > 1e-12:
        al, be = (x0 * c11 - x1 * c01) / det, (c00 * x1 - c01 * x0) / det
    if al is None or al < 1e-3 * seg or be < 1e-3 * seg or al > 2.5 * seg or be > 2.5 * seg:
        al = be = seg / 3
    return np.array([p0, p0 + tl * al, p3 + tr * be, p3])


def max_err(pts, bz, u):
    d = np.hypot(*(bez(bz, u) - pts).T)
    i = int(d.argmax())
    return d[i], i


def reparam(pts, bz, u):
    q, q1, q2 = bez(bz, u), bez1(bz, u), bez2(bz, u)
    num = ((q - pts) * q1).sum(1)
    den = (q1 * q1).sum(1) + ((q - pts) * q2).sum(1)
    return np.clip(u - num / np.where(np.abs(den) < 1e-12, 1, den), 0, 1)


def unit(v):
    n = math.hypot(v[0], v[1])
    return v / n if n > 0 else np.array([1.0, 0.0])


def fit(pts, tl, tr, eps, depth=0):
    m = len(pts)
    if m == 2:
        d = np.hypot(*(pts[1] - pts[0])) / 3
        return [np.array([pts[0], pts[0] + tl * d, pts[1] + tr * d, pts[1]])]
    u = np.concatenate([[0], np.cumsum(np.hypot(*np.diff(pts, axis=0).T))])
    u /= u[-1]
    bz = generate(pts, u, tl, tr)
    e, i = max_err(pts, bz, u)
    if e < eps:
        return [bz]
    if e < eps * 6:
        for _ in range(8):
            u = reparam(pts, bz, u)
            bz = generate(pts, u, tl, tr)
            e, i = max_err(pts, bz, u)
            if e < eps:
                return [bz]
    if depth > 40 or m < 4:
        return [bz]
    i = min(max(i, 1), m - 2)
    tc = unit(pts[i - 1] - pts[i + 1])
    return fit(pts[:i + 1], tl, tc, eps, depth + 1) + fit(pts[i:], -tc, tr, eps, depth + 1)


def fit_loop(p, k=4, kt=3):
    """A closed contour (1 px steps) as consecutive cubic Beziers (4x2 arrays)."""
    n = len(p)
    cor = find_corners(p, k)

    def tangent(i, mode):
        if mode == "c":
            return unit(p[(i + kt) % n] - p[(i - kt) % n])
        if mode == "f":
            return unit(p[(i + kt) % n] - p[i])
        return unit(p[i] - p[(i - kt) % n])

    starts = sorted(cor) if cor else [0]
    out = []
    for si, a in enumerate(starts):
        b = starts[(si + 1) % len(starts)]
        cnt = (b - a) % n or n
        seg = p[[(a + j) % n for j in range(cnt + 1)]]
        if cor:
            tl, tr = tangent(a, "f"), -tangent(b, "b")
        else:
            tl, tr = tangent(a, "c"), -tangent(b, "c")
        out += fit(seg, tl, tr, EPS)
    return out


# ---------------------------------------------------------------- file format

def zz(v):
    return (-v * 2 - 1) if v < 0 else v * 2


def varint(z):
    b = bytearray()
    while True:
        c = z & 127
        z >>= 7
        if z:
            b.append(c | 128)
        else:
            b.append(c)
            return bytes(b)


def angle(d):
    return int(round(math.atan2(d[1], d[0]) / (2 * math.pi) * 256)) & 255


def encode(width, layers):
    """layers: [(rgb, [loop, ...])], a loop a list of 4x2 Beziers in source pixels."""
    k = GRID / width
    out = bytearray(b"YVG2" + struct.pack("<HH", GRID, len(layers)))
    px = py = 0
    for col, loops in layers:
        out += bytes(col) + varint(len(loops))
        for loop in loops:
            out += varint(len(loop))
            for i, b in enumerate(loop):
                pb = loop[i - 1]
                x, y = int(round(b[0][0] * k)), int(round(b[0][1] * k))
                dout, din = b[1] - b[0], pb[3] - pb[2]
                lo, li = int(round(np.hypot(*dout) * k)), int(round(np.hypot(*din) * k))
                if np.hypot(*dout) < 1e-9:
                    dout = b[3] - b[0]
                if np.hypot(*din) < 1e-9:
                    din = pb[3] - pb[0]
                ao, ai = angle(dout), angle(din)
                corner = 1 if min((ao - ai) & 255, (ai - ao) & 255) > 3 else 0
                out += varint((zz(x - px) << 1) | corner) + varint(zz(y - py))
                px, py = x, y
                out += bytes([ao])
                if corner:
                    out += bytes([ai])
                out += varint(lo) + varint(li)
    return bytes(out)


def decode(data):
    """(grid, [(rgb, [loop, ...])]) with the Beziers in grid units, as vec.y builds them."""
    assert data[:4] == b"YVG2"
    grid, nl = struct.unpack("<HH", data[4:8])
    i = 8

    def rv():
        nonlocal i
        z = s = 0
        while True:
            c = data[i]
            i += 1
            z |= (c & 127) << s
            s += 7
            if not c & 128:
                return z

    def dz(z):
        return (z >> 1) if not z & 1 else -((z + 1) >> 1)

    layers = []
    px = py = 0
    for _ in range(nl):
        col = tuple(data[i:i + 3])
        i += 3
        loops = []
        for _ in range(rv()):
            nodes = []
            for _ in range(rv()):
                v = rv()
                px += dz(v >> 1)
                py += dz(rv())
                ao = data[i]
                i += 1
                ai = ao
                if v & 1:
                    ai = data[i]
                    i += 1
                nodes.append((px, py, ao, ai, rv(), rv()))
            loop = []
            for j, a in enumerate(nodes):
                b = nodes[(j + 1) % len(nodes)]
                p0, p3 = np.array(a[:2], float), np.array(b[:2], float)
                t, u = a[2] / 256 * 2 * math.pi, b[3] / 256 * 2 * math.pi
                loop.append(np.array([p0, p0 + a[4] * np.array([math.cos(t), math.sin(t)]),
                                      p3 - b[5] * np.array([math.cos(u), math.sin(u)]), p3]))
            loops.append(loop)
        layers.append((col, loops))
    return grid, layers


def to_svg(data, path):
    grid, layers = decode(data)
    s = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="1024" height="1024">' % (grid, grid),
         '<rect width="100%" height="100%" fill="#16161c"/>']
    for (r, g, b), loops in layers:
        d = ""
        for loop in loops:
            d += "M%.2f %.2f" % tuple(loop[0][0])
            for bz in loop:
                d += "C" + " ".join("%.2f %.2f" % tuple(q) for q in bz[1:])
            d += "Z"
        s.append('<path fill="#%02x%02x%02x" d="%s"/>' % (r, g, b, d))
    s.append("</svg>")
    open(path, "w").write("\n".join(s))


# ---------------------------------------------------------------- main

def layer_masks(lbl, order):
    """Per layer, its region plus the collar under later layers, with later-only holes filled."""
    rk = np.full(lbl.shape, -1, np.int32)
    for r, j in enumerate(order):
        rk[lbl == j] = r
    for r in range(len(order)):
        a = rk == r
        later = rk > r
        grown = np.array(Image.fromarray((a * 255).astype("uint8")).filter(ImageFilter.MaxFilter(2 * COLLAR + 1))) > 0
        m = a | (grown & later)
        lab, n = label4(~m)
        if n > 1:
            tot = np.bincount(lab.ravel(), minlength=n + 1)
            lat = np.bincount(lab[later & ~m].ravel(), minlength=n + 1)
            border = set(np.unique(np.concatenate([lab[0], lab[-1], lab[:, 0], lab[:, -1]]))) - {0}
            for c in range(1, n + 1):
                if c not in border and tot[c] == lat[c]:
                    m |= lab == c
        yield m


def fit_one(p):
    return fit_loop(p)


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--svg":
        to_svg(sys.stdin.buffer.read(), sys.argv[2])
        return
    src = sys.argv[1] if len(sys.argv) > 1 else "os/assets/wallpaper.png"
    im = np.array(Image.open(src).convert("RGB")).astype(np.float64)
    h, w, _ = im.shape
    lbl = quantize(im)
    area_of = [int((lbl == j).sum()) for j in range(K)]
    pal = []
    for j in range(K):
        m = lbl == j
        core = m & (boxmean(m.astype(float), 1) > 0.99)
        pal.append(im[core].mean(0) if core.sum() > 20 else (im[m].mean(0) if m.any() else np.zeros(3)))
    order = [j for j in np.argsort(-np.array(area_of)) if area_of[j] > 0]
    jobs = []
    for j, m in zip(order, layer_masks(lbl, order)):
        loops = []
        for c in contours(blur(m.astype(np.float64), SMOOTH)):
            if abs(area(c)) >= MINAREA:
                p = resample(c, 1.0)
                if len(p) >= 6:
                    loops.append(p)
        jobs.append((tuple(int(round(v)) for v in pal[j]), loops))
    layers = []
    with multiprocessing.get_context("fork").Pool(min(6, os.cpu_count() or 1)) as pool:
        for col, ps in jobs:
            layers.append((col, pool.map(fit_one, ps, chunksize=4)))
    data = encode(w, layers)
    sys.stdout.buffer.write(data)
    sys.stderr.write("genwall: %d layers, %d outlines, %d curves, %d bytes\n" % (
        len(layers), sum(len(l) for _, l in layers), sum(len(o) for _, l in layers for o in l), len(data)))


if __name__ == "__main__":
    main()
