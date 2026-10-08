#!/usr/bin/env python3
"""Attribute a std pack's bytes to its units and fields.

Usage: pack_stats.py PACK-FILE

PACK-FILE is what `ycc --std-pack FILE` writes: the pack, then an 8-digit
decimal length and the magic "YCCPACK1" (see ycc.y write_std_pack). The pack
itself is the netstring framing native.y's std_pack writes:

    "ycc-std-pack N\\n"          version line, a literal (not framed)
    count:...                    how many units
    per unit:  name:...          the unit's name
               fields:...        pack_unit_fields, itself netstringed; from
                                 pack 9 each unit's fields are stored on their
                                 own (method byte 1 = compressed), the frame
                                 plain, before that the whole pack was

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

def lz_decode(b):
    """The in-tree codec's inverse (native.y lz_decode), for the audit: an
    independent implementation of the same format, so a reader that agrees with
    this one on the real pack is not agreeing with itself."""
    out = bytearray()
    at = 0
    n = len(b)
    while at < n:
        t = b[at]; at += 1
        ll = t >> 4
        mh = t & 15
        if ll == 15:
            while True:
                if at >= n: raise Bad("truncated literal length")
                x = b[at]; at += 1
                ll += x
                if x != 255: break
        if at + ll > n: raise Bad("literals past end")
        out += b[at:at + ll]; at += ll
        if at >= n: break
        if at + 2 > n: raise Bad("truncated match offset")
        moff = b[at] | (b[at + 1] << 8); at += 2
        mlen = mh + 4
        if mh == 15:
            while True:
                if at >= n: raise Bad("truncated match length")
                x = b[at]; at += 1
                mlen += x
                if x != 255: break
        if moff == 0 or moff > len(out): raise Bad("match offset %d" % moff)
        for _ in range(mlen):
            out.append(out[len(out) - moff])
    return bytes(out)


def payload_of(raw):
    """The pack payload: the last [8 digits][YCCPACK1] frame, decoded when the
    method byte says the store compressed it."""
    if len(raw) < 16 or raw[-8:] != b"YCCPACK1":
        raise Bad("no YCCPACK1 trailer")
    n = int(raw[-16:-8])
    pack = raw[len(raw) - 16 - n:len(raw) - 16]
    stored = len(pack)
    if pack[:1] == b"\x01":
        pack = lz_decode(pack[1:])
    return pack, stored


FIELDS = ["files", "iface", "init", "bodies", "btext", "labels", "rodata", "globals"]
# pack 8 added `tys` (a unit's own type aliases, as `name\ntcode`), after globals.
FIELDS8 = FIELDS + ["tys"]


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


def parse_fields(payload, fields=None):
    """Walk pack_unit_fields; return [(field, bytes)] and the end position."""
    if fields is None:
        fields = FIELDS
    got = []
    p = 0
    for f in fields:
        start = p
        if f == "init":
            _, p = nstr(payload, p)
        elif f == "iface":
            p = iface(payload, p)
        elif f == "btext":
            p = run(payload, p, "run")
        elif f in ("refs", "rodata"):
            p = run(payload, p, "run")
        else:                      # files, bodies, labels, globals, tys
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
        pack, stored = payload_of(open(sys.argv[2], "rb").read())
        print("stored %d" % stored)
        g, x = target(pack)
        print("payload %d  gzip -9 %d (%.2fx)  xz -9 %d (%.2fx)"
              % (len(pack), g, float(len(pack)) / g, x, float(len(pack)) / x))
        return 0
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__.split("\n\n")[0] + "\n")
        return 2
    pack, stored = payload_of(open(sys.argv[1], "rb").read())
    if stored != len(pack):
        print("stored %d bytes, decoded to %d" % (stored, len(pack)))

    nl = pack.find(b"\n")
    if nl < 0:
        sys.stderr.write("no version line\n")
        return 2
    version = pack[:nl + 1]
    p = nl + 1
    # Which fields a unit has depends on the pack version: 8 added `tys`.
    vnum = 0
    for w in version.decode(errors="replace").split():
        if w.isdigit():
            vnum = int(w)
    fields = FIELDS8 if vnum >= 8 else FIELDS
    cnt, p = num(pack, p, "unit count")
    print("version %s" % version.decode(errors="replace").strip())
    print("payload %d bytes, %d units\n" % (len(pack), cnt))

    totals = dict((f, 0) for f in fields)
    rows = []
    unit_stored = 0
    for _ in range(cnt):
        name, p = nstr(pack, p)
        body, p = nstr(pack, p)
        unit_stored += len(body)
        if vnum >= 9 and body[:1] == b"\x01":
            body = lz_decode(body[1:])
        got, end = parse_fields(body, fields)
        if end != len(body):
            raise Bad("unit %s: %d of %d field bytes used"
                      % (name.decode(), end, len(body)))
        for f, sz in got:
            totals[f] += sz
        rows.append((name.decode(), len(body), got))
    if p != len(pack):
        raise Bad("%d bytes left after the units" % (len(pack) - p))

    if vnum >= 9:
        print("units stored in %d bytes (frame %d)\n" % (unit_stored, len(pack) - unit_stored))
    for name, total, got in rows:
        big = "  ".join("%s=%d" % (f, sz) for f, sz in got if sz > 200)
        print("%-10s %8d   %s" % (name, total, big))
    print("")
    # the decoded field bytes (from pack 9 the frame holds stored units)
    dec = sum(totals.values()) or 1
    for f in sorted(fields, key=lambda x: -totals[x]):
        print("%-8s %8d  %5.1f%%" % (f, totals[f], 100.0 * totals[f] / dec))
    print("%-8s %8d" % ("TOTAL", dec))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Bad as e:
        sys.stderr.write("bad pack: %s\n" % e)
        sys.exit(1)
