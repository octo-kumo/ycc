#!/usr/bin/env python3
# Builds test/data/zlib/fixtures.bin: the same eight inputs t412_zlib.y
# regenerates, each compressed by Python's zlib in every way it knows (stored,
# levels 1/6/9, fixed Huffman, Huffman only, RLE, raw deflate, gzip). Record:
# u8 name length, name, u8 kind (0 zlib, 1 raw, 2 gzip), u32 LE length, bytes.
import struct
import zlib

state = 12345


def rnd(m):
    global state
    state = (state * 1103515245 + 12345) & 2147483647
    return (state >> 8) % m


def rbyte():
    global state
    state = (state * 1103515245 + 12345) & 2147483647
    return (state >> 16) & 255


def inputs():
    out = [b"", b"a", b"a" * 100000, bytes(rbyte() for _ in range(2500))]
    words = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "zlib", "deflate", "stream", "huffman"]
    t = ""
    while len(t) < 9000:
        t += words[rnd(12)] + " "
    out.append(t[:9000].encode())
    out.append(b"".join(struct.pack("<I", i * 3 + rnd(4)) for i in range(2000)))
    blk = bytes(rbyte() for _ in range(2000))
    out.append(blk * 3)
    out.append(bytes(range(256)) * 12)
    return out


def variants(d):
    def co(level, strategy=zlib.Z_DEFAULT_STRATEGY, wbits=15):
        c = zlib.compressobj(level, zlib.DEFLATED, wbits, 9, strategy)
        return c.compress(d) + c.flush()

    big = len(d) > 10000   # a stored or Huffman-only stream of it would be as big as it
    if not big:
        yield "z0", 0, co(0)
    yield "z1", 0, co(1)
    yield "z6", 0, co(6)
    yield "z9", 0, co(9)
    yield "fixed", 0, co(9, zlib.Z_FIXED)
    if not big:
        yield "huff", 0, co(9, zlib.Z_HUFFMAN_ONLY)
    yield "rle", 0, co(9, zlib.Z_RLE)
    yield "raw", 1, co(6, wbits=-15)
    yield "gz", 2, co(6, wbits=31)


if __name__ == "__main__":
    buf = bytearray()
    for i, d in enumerate(inputs()):
        for name, kind, z in variants(d):
            n = ("i%d_%s" % (i, name)).encode()
            buf += bytes([len(n)]) + n + bytes([kind]) + struct.pack("<I", len(z)) + z
    open("test/data/zlib/fixtures.bin", "wb").write(buf)
    print(len(buf))
