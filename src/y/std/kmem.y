// kmem -- the kernel's raw memory access, a unit of its own so that yfs (which
// reads and writes the image through it) does not have to import kernel.
// kernel.y re-exposes every name here under the same name (peek8, poke_va8, ...).
// ptr_from turns an integer address into a pointer, so every access below is
// one dereference. (Before it existed an 8-byte global was the anchor and each
// access moved a pointer to it by arithmetic.) That is why the kernel can touch
// page tables, the Multiboot structure and device memory with no assembly.

// The kernel's own mapping is ONE 2 MB page at 1 MB (arch_x64.y's trampoline):
// the image and nothing else in the low half, so that 0x400000 -- where a
// Linux executable is linked -- stays free for user space.  Everything else
// in RAM is reached through the direct map the trampoline also builds, all of
// RAM in 2 MB pages at 0xFFFF888000000000.  As a signed 64-bit long that base
// is negative, and Y's pointer arithmetic carries it exactly.
//
// CONVENTION: peek*/poke* take a PHYSICAL address and add this; the Y heap's
// own pointers are direct-map VIRTUAL addresses (phys_init sets them up that
// way).  Mixing the two is the one way to get this wrong.
const DIRECT_BASE = -131391639519232;

// Bulk copies (arch/kernel.s, `rep movsb` / `rep stosb`), VIRTUAL addresses in
// the current address space; a physical one is DIRECT_BASE + phys.
ndef y_kcopy(dst: long, src: long, n: long) -> long = "y_kcopy";
ndef y_kzero(dst: long, n: long) -> long = "y_kzero";

def kcopy(dst: long, src: long, n: long) -> void {
    if (n > 0) { y_kcopy(dst, src, n); };
};

def kzero(dst: long, n: long) -> void {
    if (n > 0) { y_kzero(dst, n); };
};

def peek_word(addr: long) -> long {
    let p: *long = ptr_from(addr + DIRECT_BASE);
    *p
};

def poke_word(addr: long, v: long) -> void {
    let p: *long = ptr_from(addr + DIRECT_BASE);
    *p = v;
};

def peek32(addr: long) -> long {
    let sh = (addr & 7) * 8;
    ((peek_word(addr - (addr & 7)) >> sh) << 32) >>> 32
};

def poke32(addr: long, v: long) -> void {
    let base = addr - (addr & 7);
    let sh = (addr & 7) * 8;
    let w = peek_word(base);
    let mask = 4294967295 << sh;
    poke_word(base, (w & ~mask) | (((v << 32) >>> 32) << sh));
};

def peek_va64(addr: long) -> long {
    let p: *long = ptr_from(addr);
    *p
};

def poke_va64(addr: long, v: long) -> void {
    let p: *long = ptr_from(addr);
    *p = v;
};

def peek64(addr: long) -> long {
    peek32(addr) | (peek32(addr + 4) << 32)
};

def poke64(addr: long, v: long) -> void {
    poke32(addr, v);
    poke32(addr + 4, v >> 32);
};

def peek8(addr: long) -> long {
    let sh = (addr & 7) * 8;
    (peek_word(addr - (addr & 7)) >> sh) & 255
};

def poke8(addr: long, v: long) -> void {
    let base = addr - (addr & 7);
    let sh = (addr & 7) * 8;
    let w = peek_word(base);
    let mask = 255 << sh;
    poke_word(base, (w & ~mask) | ((v & 255) << sh));
};

def peek_va8(addr: long) -> long {
    let sh = (addr & 7) * 8;
    (peek_va64(addr - (addr & 7)) >> sh) & 255
};

def poke_va32(addr: long, v: long) -> void {
    let base = addr - (addr & 7);
    let sh = (addr & 7) * 8;
    let w = peek_va64(base);
    let mask = 4294967295 << sh;
    poke_va64(base, (w & ~mask) | (((v << 32) >>> 32) << sh));
};

def poke_va8(addr: long, v: long) -> void {
    let base = addr - (addr & 7);
    let sh = (addr & 7) * 8;
    let w = peek_va64(base);
    let mask = 255 << sh;
    poke_va64(base, (w & ~mask) | ((v & 255) << sh));
};

