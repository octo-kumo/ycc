#!/usr/bin/env python3
"""Check that an ELF's .bss section lies inside its R+W PT_LOAD segment.

asm.y places the .bss labels from the code's start, so the .bss begins
code_off bytes into the R+W segment's page (elf.y elf_build). The segment
used to map only bss_len bytes from the page start, leaving the .bss's last
code_off bytes unmapped (a SIGSEGV once they crossed a page), and -g's .bss
section header added the load base twice. Needs a -g build (section headers).
Prints the two ranges; exit 1 when the section is not covered."""
import struct, sys

data = open(sys.argv[1], 'rb').read()
phoff, shoff = struct.unpack_from('<QQ', data, 32)
phentsize, phnum, shentsize, shnum, shstrndx = struct.unpack_from('<HHHHH', data, 54)
rw = None
for i in range(phnum):
    p_type, p_flags, _, p_vaddr, _, _, p_memsz, _ = struct.unpack_from('<IIQQQQQQ', data, phoff + i * phentsize)
    if p_type == 1 and p_flags & 2:
        rw = (p_vaddr, p_vaddr + p_memsz)
shdr = lambda i: struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shentsize)
stroff = shdr(shstrndx)[4]
bss = None
for i in range(shnum):
    s = shdr(i)
    name = data[stroff + s[0]:data.index(b'\0', stroff + s[0])]
    if name == b'.bss':
        bss = (s[3], s[3] + s[5])
if rw is None or bss is None:
    print('no R+W segment or no .bss section')
    sys.exit(1)
print('segment %#x-%#x, .bss %#x-%#x' % (rw + bss))
sys.exit(0 if rw[0] <= bss[0] and bss[1] <= rw[1] else 1)
