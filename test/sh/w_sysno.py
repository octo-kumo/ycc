#!/usr/bin/env python3
"""Print the NT syscall number wine's own ntdll uses for each named Nt*
function, read from the export's syscall stub (`mov $imm,%eax; syscall`).

The numbers in arch_x64.y's w_sysno are pinned to one ntdll sample. This is how
to check one against the ntdll actually installed, which is the only authority
that matters for a probe run under this wine.
"""
import struct, sys
DLL = "/home/aiagent/.wine/drive_c/windows/system32/ntdll.dll"
d = open(DLL, "rb").read()
pe = struct.unpack_from("<I", d, 0x3C)[0]
nsec, = struct.unpack_from("<H", d, pe + 6)
optsz, = struct.unpack_from("<H", d, pe + 20)
opt = pe + 24
magic, = struct.unpack_from("<H", d, opt)
ddoff = opt + (112 if magic == 0x20B else 96)
erva, esz = struct.unpack_from("<II", d, ddoff)
secs = []
so = opt + optsz
for i in range(nsec):
    b = so + 40 * i
    vsz, va, rsz, ra = struct.unpack_from("<IIII", d, b + 8)
    secs.append((va, max(vsz, rsz), ra))

def off(rva):
    for va, sz, ra in secs:
        if va <= rva < va + sz:
            return ra + (rva - va)
    return None

chars, ts, maj, mn, dname, base, nfuncs, nnames, aaddr, anames, aord = \
    struct.unpack_from("<IIHHIIIIIII", d, off(erva))
want = set(sys.argv[1:]) or {"NtClose"}
for i in range(nnames):
    nr, = struct.unpack_from("<I", d, off(anames) + 4 * i)
    o = off(nr)
    nm = d[o:d.index(b"\0", o)].decode()
    if nm not in want:
        continue
    oi, = struct.unpack_from("<H", d, off(aord) + 2 * i)
    fr, = struct.unpack_from("<I", d, off(aaddr) + 4 * oi)
    stub = d[off(fr):off(fr) + 9]
    # The stub is `mov %rcx, %r10` (4c 8b d1) then `mov $imm32, %eax` (b8) then
    # `syscall` (0f 05): ntdll moves the first argument out of rcx, which
    # `syscall` destroys. Reading byte 0 as the opcode is the mistake that made
    # this tool report "not a syscall stub" for every function.
    num = struct.unpack_from("<I", stub, 4)[0] if stub[3] == 0xB8 else None
    print(f"{nm:32s} num={num if num is not None else 'not a syscall stub'}"
          f"   rva={fr:#08x} stub={stub.hex()}")
