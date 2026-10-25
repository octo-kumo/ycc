#!/usr/bin/env python3
# Independent reference for t412_zlib.y: builds the same inputs, decodes the
# fixtures with Python's zlib, and prints the expected decoder/checksum lines.
# The encoder lines the test pins (sizes, round trips) are checked by Python's
# own zlib when run with `--verify` against the Y encoder's output.
import binascii
import sys
import zlib

sys.path.insert(0, "test/data/zlib")
import make

ins = make.inputs()
blob = open("test/data/zlib/fixtures.bin", "rb").read()
print("decode")
p = 0
while p < len(blob):
    nl = blob[p]
    name = blob[p + 1:p + 1 + nl].decode()
    kind = blob[p + 1 + nl]
    n = int.from_bytes(blob[p + 2 + nl:p + 6 + nl], "little")
    s = blob[p + 6 + nl:p + 6 + nl + n]
    p += 6 + nl + n
    w = {0: 15, 1: -15, 2: 31}[kind]
    out = zlib.decompress(s, w)
    which = int(name[1:name.index("_")])
    print(name, kind, n, "true" if out == ins[which] else "false", len(out), binascii.crc32(out))
