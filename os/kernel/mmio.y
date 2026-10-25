// mmio -- device memory in the kernel's direct map.
//
// The trampoline maps the first 1 GB of RAM at DIRECT_BASE with 2 MB pages and nothing
// above it, but a PCI memory BAR (a framebuffer, a virtio device's registers) lives
// near 4 GB. PML4[273] -- the direct map -- is shared by every address space, so a
// page directory added under it is seen by all of them. `mmio_map` makes the 2 MB pages
// that cover a physical range uncached and returns the address to use: DIRECT_BASE + phys,
// the same convention as every peek/poke here.
import kernel;

const MMIO_PS_UC = 155;          // present, writable, 2 MB page, write-through + cache-disable

/** Map [phys, phys + size) uncached into the direct map; the virtual address of `phys`. */
def mmio_map(phys: long, size: long) -> long {
    let first = phys >> 21;
    let last = (phys + size - 1) >> 21;
    let pml4 = kernel.vm_current() & kernel.PHYS_MASK;
    let pdpt = kernel.peek64(pml4 + 273 * 8) & kernel.PHYS_MASK;
    let c = first;
    while (c <= last) {
        let gi = c >> 9;
        if (gi >= 512) { return 0; };
        // 1 GB entry 0 is the RAM the trampoline mapped, as 2 MB pages
        let e = kernel.peek64(pdpt + gi * 8);
        let pd = 0;
        if ((e & 1) == 0) {
            pd = kernel.page_alloc();
            if (pd == 0) { return 0; };
            kernel.poke64(pdpt + gi * 8, pd | 3);
        } else {
            pd = e & kernel.PHYS_MASK;
        };
        let slot = pd + (c & 511) * 8;
        if ((kernel.peek64(slot) & 1) == 0) { kernel.poke64(slot, (c << 21) | MMIO_PS_UC); };
        c = c + 1;
    };
    kernel.DIRECT_BASE + phys
};
