// pci -- PCI configuration space through the legacy ports 0xCF8/0xCFC.
//
// It provides cfg_read32/cfg_write32, find(vendor, device) scanning bus 0..255 / dev 0..31 /
// fn 0..7; bar(bdf, i) (I/O BARs: the port base with the low bits masked);
// enable_busmaster(bdf) (command register bits 0 = I/O, 2 = bus master).
//
// A `bdf` is bus << 8 | dev << 3 | fn.
import kernel;

def pci_addr(bdf: long, off: long) -> long {
    2147483648 | (bdf << 8) | (off & 252)
};

def pci_cfg_read32(bdf: long, off: long) -> long {
    kernel.outl(3320, pci_addr(bdf, off));
    kernel.inl(3324)
};

def pci_cfg_write32(bdf: long, off: long, v: long) -> void {
    kernel.outl(3320, pci_addr(bdf, off));
    kernel.outl(3324, v);
};

/** The first function with this vendor:device id, or -1. */
def pci_find(vendor: long, device: long) -> long {
    let want = (device << 16) | vendor;
    let bus = 0;
    while (bus < 256) {
        let dev = 0;
        while (dev < 32) {
            let bdf = (bus << 8) | (dev << 3);
            let id = pci_cfg_read32(bdf, 0);
            if (id != 4294967295) {
                if (id == want) { return bdf; };
                // header type bit 7: a multi-function device, so look at fn 1..7
                if ((pci_cfg_read32(bdf, 12) >> 16) & 128 != 0) {
                    let fn = 1;
                    while (fn < 8) {
                        let f = bdf | fn;
                        if (pci_cfg_read32(f, 0) == want) { return f; };
                        fn = fn + 1;
                    };
                };
            };
            dev = dev + 1;
        };
        bus = bus + 1;
    };
    0 - 1
};

/** Base address register `i` (0..5) of `bdf`, decoded: an I/O port base (low
bits masked) or a memory address. */
def pci_bar(bdf: long, i: long) -> long {
    let v = pci_cfg_read32(bdf, 16 + 4 * i);
    if (v & 1 != 0) { v & 65532 } else { v & 4294967280 }
};

/** Turn on I/O decoding, memory decoding and bus mastering (command bits 0, 1, 2). */
def pci_enable_busmaster(bdf: long) -> void {
    // the upper half of this dword is the status register, whose bits clear when
    // written as 1: write the command half alone
    let cmd = pci_cfg_read32(bdf, 4) & 65535;
    pci_cfg_write32(bdf, 4, cmd | 7);
};

/** The memory BAR `i` of `bdf`: its physical base, 64-bit ones included (0 when it is an I/O BAR or unset). */
def pci_bar_mem(bdf: long, i: long) -> long {
    let v = pci_cfg_read32(bdf, 16 + 4 * i);
    if ((v & 1) != 0) { return 0; };
    let base = v & 4294967280;
    if (((v >> 1) & 3) == 2) { base = base | (pci_cfg_read32(bdf, 20 + 4 * i) << 32); };
    base
};

/** The size of memory BAR `i` in bytes, found the standard way (write ones, read back, restore). */
def pci_bar_size(bdf: long, i: long) -> long {
    let off = 16 + 4 * i;
    let old = pci_cfg_read32(bdf, off);
    if ((old & 1) != 0) { return 0; };
    let wide = ((old >> 1) & 3) == 2;
    let cmd = pci_cfg_read32(bdf, 4) & 65535;
    pci_cfg_write32(bdf, 4, cmd & ~3);
    pci_cfg_write32(bdf, off, 4294967295);
    let lo = pci_cfg_read32(bdf, off) & 4294967280;
    pci_cfg_write32(bdf, off, old);
    let size = 0;
    if (wide) {
        let old_hi = pci_cfg_read32(bdf, off + 4);
        pci_cfg_write32(bdf, off + 4, 4294967295);
        let hi = pci_cfg_read32(bdf, off + 4);
        pci_cfg_write32(bdf, off + 4, old_hi);
        size = 0 - ((hi << 32) | lo);
    } else if (lo != 0) {
        size = ((0 - lo) << 32) >>> 32;
    };
    pci_cfg_write32(bdf, 4, cmd);
    size
};

/** The first function whose class code (the top 16 bits of the class dword) is `cls`, or -1. */
def pci_find_class(cls: long) -> long {
    let bus = 0;
    while (bus < 256) {
        let dev = 0;
        while (dev < 32) {
            let bdf = (bus << 8) | (dev << 3);
            if (pci_cfg_read32(bdf, 0) != 4294967295) {
                let fn = 0;
                while (fn < 8) {
                    let f = bdf | fn;
                    if (pci_cfg_read32(f, 0) != 4294967295 && (pci_cfg_read32(f, 8) >> 16) == cls) { return f; };
                    fn = fn + 1;
                };
            };
            dev = dev + 1;
        };
        bus = bus + 1;
    };
    0 - 1
};

/** The offset of the first capability with id `id` in the capability list of `bdf`, or 0. */
def pci_cap_find(bdf: long, id: long) -> long {
    if ((pci_cfg_read32(bdf, 4) >> 16) & 16 == 0) { return 0; };
    let p = pci_cfg_read32(bdf, 52) & 255;
    let n = 0;
    while (p >= 64 && n < 48) {
        let w = pci_cfg_read32(bdf, p);
        if ((w & 255) == id) { return p; };
        p = (w >> 8) & 255;
        n = n + 1;
    };
    0
};

/** The `n`th (from 0) function with this vendor:device id, or -1. */
def pci_find_nth(vendor: long, device: long, n: long) -> long {
    let want = (device << 16) | vendor;
    let seen = 0;
    let bus = 0;
    while (bus < 256) {
        let dev = 0;
        while (dev < 32) {
            let bdf = (bus << 8) | (dev << 3);
            if (pci_cfg_read32(bdf, 0) != 4294967295) {
                let fn = 0;
                while (fn < 8) {
                    let f = bdf | fn;
                    if (pci_cfg_read32(f, 0) == want) {
                        if (seen == n) { return f; };
                        seen = seen + 1;
                    };
                    fn = fn + 1;
                };
            };
            dev = dev + 1;
        };
        bus = bus + 1;
    };
    0 - 1
};
