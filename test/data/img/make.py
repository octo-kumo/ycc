#!/usr/bin/env python3
# Builds test/data/img/fixtures.bin: one pattern, written by ImageMagick in
# every format and variant img.y reads, each followed by the RGBA ImageMagick
# itself decodes it to (the reference). Record: u8 name length, name, u8 tol
# (largest per-channel difference the Y decoder may show: 0 except JPEG),
# u32 w, u32 h, u32 file length, file, w*h*4 reference bytes.
import os
import struct
import subprocess
import tempfile

tmp = tempfile.mkdtemp()


def run(*a):
    subprocess.run(a, check=True)


def im(*args):
    run("magick", *args)


# a gradient with alpha, and a busy picture for JPEG
im("-size", "31x17", "gradient:red-blue", "(", "-size", "31x17", "gradient:white-black", "-rotate", "90", "-resize", "31x17!", ")",
   "-compose", "CopyOpacity", "-composite", os.path.join(tmp, "pat.png"))
im("rose:", "-crop", "67x45+0+0", "+repage", os.path.join(tmp, "rose.png"))
im("rose:", "-crop", "40x30+5+5", "+repage", "-colorspace", "Gray", os.path.join(tmp, "rosegray.png"))
pat = os.path.join(tmp, "pat.png")
rose = os.path.join(tmp, "rose.png")
gray = os.path.join(tmp, "rosegray.png")

cases = []  # (name, tol, path)


def add(name, tol, src, *opts, ext):
    path = os.path.join(tmp, name + "." + ext)
    im(src, *opts, path)
    cases.append((name, tol, path))


for ct, depth in [(6, 8), (6, 16), (2, 8), (2, 16), (4, 8), (0, 8), (0, 16)]:
    add("png_t%d_d%d" % (ct, depth), 0, pat, *(["-colorspace", "Gray"] if ct == 4 else ["-alpha", "off", "-colorspace", "Gray"] if ct == 0 else ["-alpha", "off"] if ct == 2 else []), "-define", "png:color-type=%d" % ct, "-define", "png:bit-depth=%d" % depth, ext="png")
for depth in (1, 2, 4):
    add("png_gray%d" % depth, 0, gray, "-alpha", "off", "-colorspace", "Gray", "-depth", str(depth), "-define", "png:color-type=0", "-define", "png:bit-depth=%d" % depth, ext="png")
add("png_pal8", 0, rose, "-colors", "200", "-define", "png:color-type=3", ext="png")
add("png_pal4", 0, rose, "-colors", "16", "-define", "png:color-type=3", "-define", "png:bit-depth=4", ext="png")
add("png_pal_trns", 0, pat, "-colors", "32", "-define", "png:color-type=3", ext="png")
add("png_interlaced", 0, rose, "-interlace", "PNG", ext="png")
add("png_interlaced_rgba", 0, pat, "-interlace", "PNG", "-define", "png:color-type=6", ext="png")
add("png_big", 0, rose, "-resize", "300x200!", ext="png")
add("bmp24", 0, rose, ext="bmp", *["-define", "bmp:format=bmp3"])
add("bmp32", 0, pat, ext="bmp", *["-define", "bmp:format=bmp4"])
add("bmp8", 0, rose, "-colors", "256", "-type", "palette", ext="bmp")
add("bmp4", 0, rose, "-colors", "16", "-type", "palette", "-depth", "4", ext="bmp")
add("bmp1", 0, gray, "-monochrome", ext="bmp")
for nm, opts in [("ppm", ["-compress", "none"]), ("ppm_raw", []), ]:
    pass
add("ppm_raw", 0, rose, "-depth", "8", ext="ppm")
add("ppm_plain", 0, rose, "-compress", "none", "-depth", "8", ext="ppm")
add("ppm_16", 0, rose, "-depth", "16", ext="ppm")
add("pgm_raw", 0, gray, "-depth", "8", ext="pgm")
add("pgm_plain", 0, gray, "-compress", "none", ext="pgm")
add("pbm_raw", 0, gray, "-monochrome", ext="pbm")
add("pbm_plain", 0, gray, "-monochrome", "-compress", "none", ext="pbm")
add("gif", 0, rose, "-colors", "128", ext="gif")
add("gif_interlaced", 0, rose, "-colors", "64", "-interlace", "GIF", ext="gif")
add("gif_transparent", 0, pat, "-colors", "16", ext="gif")
add("gif_2color", 0, gray, "-monochrome", ext="gif")
for nm, opts, tol in [
    ("jpeg_444", ["-sampling-factor", "1x1", "-quality", "85"], 3),
    ("jpeg_420", ["-sampling-factor", "2x2", "-quality", "75"], 3),
    ("jpeg_422", ["-sampling-factor", "2x1", "-quality", "90"], 3),
    ("jpeg_gray", ["-colorspace", "Gray", "-quality", "80"], 3),
    ("jpeg_prog_420", ["-interlace", "JPEG", "-sampling-factor", "2x2", "-quality", "80"], 3),
    ("jpeg_prog_444", ["-interlace", "JPEG", "-sampling-factor", "1x1", "-quality", "60"], 3),
    ("jpeg_restart", ["-define", "jpeg:restart-interval=3", "-sampling-factor", "2x2", "-quality", "70"], 3),
    ("jpeg_lowq", ["-quality", "10"], 3),
]:
    src = gray if nm == "jpeg_gray" else rose
    add(nm, tol, src, *opts, ext="jpg")

# a top-down BMP: negate the height and reverse the rows of a 24-bit one
b = bytearray(open(os.path.join(tmp, "bmp24.bmp"), "rb").read())
w, h = struct.unpack_from("<ii", b, 18)
off = struct.unpack_from("<I", b, 10)[0]
rb = (w * 24 + 31) // 32 * 4
rows = [b[off + i * rb: off + (i + 1) * rb] for i in range(h)]
struct.pack_into("<i", b, 22, -h)
b[off:off + rb * h] = b"".join(reversed(rows))
td = os.path.join(tmp, "bmp24_topdown.bmp")
open(td, "wb").write(b)
cases.append(("bmp24_topdown", 0, td))

buf = bytearray()
for name, tol, path in cases:
    w, h = map(int, subprocess.check_output(["identify", "-format", "%w %h", path + "[0]"]).split())
    ref = subprocess.check_output(["magick", path + "[0]", "-depth", "8", "rgba:-"])
    if name.startswith("jpeg_gray"):
        pass
    assert len(ref) == w * h * 4, (name, len(ref), w, h)
    data = open(path, "rb").read()
    n = name.encode()
    buf += bytes([len(n)]) + n + bytes([tol]) + struct.pack("<III", w, h, len(data)) + data + ref
open("test/data/img/fixtures.bin", "wb").write(buf)
print(len(buf), len(cases))
