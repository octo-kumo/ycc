#!/usr/bin/env python3
"""Attribute a std pack's bytes to its units and fields.

Usage: pack_stats.py PACK-FILE

PACK-FILE is what `ycc --std-pack FILE` writes: the pack, then an 8-digit
decimal length and the magic "YCCPACK1" (see ycc.y write_std_pack). The pack
itself is the netstring framing native.y's std_pack writes:

    "ycc-std-pack N\\n"          version line, a literal (not framed)
    count:...                    how many units
    per unit:  name:...          the unit's name
               fields:...        pack_unit_fields, itself netstringed

Inside those fields, in order (native.y pack_unit_fields), the shapes are:

    files    pack_strs  -> count, then one netstring per file name
    iface    count, then per export name/label/tcode, then count, then per
             default its name and a pack_strs of values
    init     one netstring (pack_put)
    bodies   pack_strs  -> count, then one netstring per body blob
    btext    pack_strss -> count, then per body a pack_strs of its raw lines
    labels   pack_strs  -> count, then one netstring per body label
    rodata   count, then per entry a pack_strs
    globals  pack_strs  -> count, then one netstring per global

The shape that matters: pack_strs/pack_strss write the count as its OWN
netstring and do NOT wrap the run in an outer length. Reading a run as a
single netstring (as an earlier hand parse did) consumes only the count and
leaves the cursor inside the run, and every later field then reads garbage.

A unit's `refs` is NOT in the pack: refs[i] is exactly ir_refs(bodies[i]), so
the reader recomputes it from each body's item blob (native.y blob_refs).

The audit is only useful if it is exact, so the top level must end exactly at
the pack's end and each unit must consume its fields byte for byte.
"""

import sys

FIELDS = ["files", "iface", "init", "bodies", "btext", "labels", "rodata", "globals"]


class Bad(Exception):
    pass


def nstr(s, p):
    """One netstring: 'LEN:TEXT'. Returns (text, next position)."""
    q = s.find(b":", p)
    if q < 0:
        raise Bad("no ':' at %d" % p)
    head = s[p:q]
    if not head.isdigit():
        raise Bad("length %r at %d is not decimal" % (head[:20], p))
    n = int(head)
    start = q + 1
    end = start + n
    if end > len(s):
        raise Bad("netstring at %d wants %d bytes, %d left" % (p, n, len(s) - start))
    return s[start:end], end


def num(s, p, what):
    t, p = nstr(s, p)
    if not t.isdigit():
        raise Bad("%s: count %r is not decimal" % (what, t[:20]))
    return int(t), p


def run(s, p, each):
    """pack_strs/pack_strss: a count netstring then that many items.

    each='put'  one netstring per item
    each='run'  a nested count-plus-items run per item (pack_strss)
    """
    n, p = num(s, p, "run")
    for _ in range(n):
        if each == "put":
            _, p = nstr(s, p)
        else:
            p = run(s, p, "put")
    return p


def iface(s, p):
    n, p = num(s, p, "iface exports")
    for _ in range(n):
        _, p = nstr(s, p)          # name
        _, p = nstr(s, p)          # label
        _, p = nstr(s, p)          # tcode
    n, p = num(s, p, "iface defaults")
    for _ in range(n):
        _, p = nstr(s, p)          # name
        p = run(s, p, "put")       # pack_strs of values
    return p


def parse_fields(payload):
    """Walk pack_unit_fields; return [(field, bytes)] and the end position."""
    got = []
    p = 0
    for f in FIELDS:
        start = p
        if f == "init":
            _, p = nstr(payload, p)
        elif f == "iface":
            p = iface(payload, p)
        elif f == "btext":
            p = run(payload, p, "run")
        elif f in ("refs", "rodata"):
            p = run(payload, p, "run")
        else:                      # files, bodies, labels, globals
            p = run(payload, p, "put")
        got.append((f, p - start))
    return got, p


def target(pack):
    """What an in-tree codec has to be measured against: gzip and xz of the
    same payload. Not a gate -- the codec is deterministic and has no
    dictionary, so it will not reach these; they are the size the entropy
    allows, which is how the encoder's Format is judged."""
    import gzip
    import lzma
    return len(gzip.compress(pack, 9)), len(lzma.compress(pack, preset=9))


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--target":
        raw = open(sys.argv[2], "rb").read()
        n = int(raw[-16:-8])
        pack = raw[len(raw) - 16 - n:len(raw) - 16]
        g, x = target(pack)
        print("payload %d  gzip -9 %d (%.2fx)  xz -9 %d (%.2fx)"
              % (len(pack), g, float(len(pack)) / g, x, float(len(pack)) / x))
        return 0
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        return 2
    raw = open(sys.argv[1], "rb").read()
    if len(raw) < 16 or raw[-8:] != b"YCCPACK1":
        sys.stderr.write("not a pack: no YCCPACK1 trailer\n")
        return 2
    head = raw[-16:-8]
    if not head.isdigit():
        sys.stderr.write("not a pack: %r is not an 8-digit length\n" % head)
        return 2
    n = int(head)
    pack = raw[len(raw) - 16 - n:len(raw) - 16]
    if len(pack) != n:
        sys.stderr.write("pack is %d bytes, trailer says %d\n" % (len(pack), n))
        return 2

    nl = pack.find(b"\n")
    if nl < 0:
        sys.stderr.write("no version line\n")
        return 2
    version = pack[:nl + 1]
    p = nl + 1
    cnt, p = num(pack, p, "unit count")
    print("version %s" % version.decode(errors="replace").strip())
    print("payload %d bytes, %d units\n" % (len(pack), cnt))

    totals = dict((f, 0) for f in FIELDS)
    rows = []
    for _ in range(cnt):
        name, p = nstr(pack, p)
        fields, p = nstr(pack, p)
        got, end = parse_fields(fields)
        if end != len(fields):
            raise Bad("unit %s: %d of %d field bytes used"
                      % (name.decode(), end, len(fields)))
        for f, sz in got:
            totals[f] += sz
        rows.append((name.decode(), len(fields), got))
    if p != len(pack):
        raise Bad("%d bytes left after the units" % (len(pack) - p))

    for name, total, got in rows:
        big = "  ".join("%s=%d" % (f, sz) for f, sz in got if sz > 200)
        print("%-10s %8d   %s" % (name, total, big))
    print("")
    for f in sorted(FIELDS, key=lambda x: -totals[x]):
        print("%-8s %8d  %5.1f%%" % (f, totals[f], 100.0 * totals[f] / len(pack)))
    print("%-8s %8d" % ("TOTAL", len(pack)))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Bad as e:
        sys.stderr.write("bad pack: %s\n" % e)
        sys.exit(1)
