// virtio -- the modern (1.0) virtio-over-PCI transport, polled.
//
// A device is a PCI function 1af4:(0x1040 + id). Its registers sit in memory BARs found through
// the vendor capabilities (common config, notify, device config); `virtio_probe` maps them.
// `virtio_start` runs the status handshake (only VIRTIO_F_VERSION_1 is negotiated). A queue is
// one physically contiguous page (descriptors, available ring, used ring; 64 entries) that the
// device is told about by physical address. There are no interrupts: the clock tick looks at the
// used rings (`virtio_used`), which costs a load per queue and keeps the driver small.
//
// Device handles are small integers into the arrays below (at most 4 devices, 8 queues).
import kernel;
import pci from "./pci.y";
import mmio from "./mmio.y";

const VQ_SIZE = 64;

const VS_ACK = 1;
const VS_DRIVER = 2;
const VS_DRIVER_OK = 4;
const VS_FEATURES_OK = 8;
const VS_FAILED = 128;

let vd_bdf: [long; 4] = [0; 4];
let vd_common: [long; 4] = [0; 4];
let vd_notify: [long; 4] = [0; 4];
let vd_mult: [long; 4] = [0; 4];
let vd_devcfg: [long; 4] = [0; 4];
let vd_n = 0;

// queues: the device, the ring addresses (virtual), the notify address and the used index we have seen
let vq_dev: [long; 8] = [0; 8];
let vq_desc: [long; 8] = [0; 8];
let vq_avail: [long; 8] = [0; 8];
let vq_used: [long; 8] = [0; 8];
let vq_note: [long; 8] = [0; 8];
let vq_seen: [long; 8] = [0; 8];
let vq_qi: [long; 8] = [0; 8];
let vq_n = 0;

def rd8(va: long) -> long {
    let p: *i8 = ptr_from(va);
    *p & 255
};

def wr8(va: long, v: long) -> void {
    let p: *i8 = ptr_from(va);
    *p = v;
};

def rd16(va: long) -> long {
    let p: *u16 = ptr_from(va);
    *p
};

def wr16(va: long, v: long) -> void {
    let p: *u16 = ptr_from(va);
    *p = v;
};

def rd32(va: long) -> long {
    let p: *u32 = ptr_from(va);
    *p
};

def wr32(va: long, v: long) -> void {
    let p: *u32 = ptr_from(va);
    *p = v;
};

def wr64(va: long, v: long) -> void {
    wr32(va, v & 4294967295);
    wr32(va + 4, (v >> 32) & 4294967295);
};

/** Find the `nth` device with virtio id `id` (16 gpu, 18 input) and map its registers: a handle, or -1. */
def virtio_probe(id: long, nth: long) -> long {
    if (vd_n >= 4) { return 0 - 1; };
    let bdf = pci.pci_find_nth(6900, 4160 + id, nth);
    if (bdf < 0) { return 0 - 1; };
    pci.pci_enable_busmaster(bdf);
    let h = vd_n;
    let common = 0;
    let notify = 0;
    let mult = 0;
    let devcfg = 0;
    let p = pci.pci_cfg_read32(bdf, 52) & 255;
    let guard = 0;
    while (p >= 64 && guard < 48) {
        let w = pci.pci_cfg_read32(bdf, p);
        if ((w & 255) == 9) {
            let ty = (w >> 24) & 255;
            let bar = pci.pci_cfg_read32(bdf, p + 4) & 255;
            let off = pci.pci_cfg_read32(bdf, p + 8);
            let size = pci.pci_cfg_read32(bdf, p + 12);
            let base = pci.pci_bar_mem(bdf, bar);
            if (base != 0) {
                let va = mmio.mmio_map(base + off, size);
                if (va != 0) {
                    if (ty == 1) { common = va; }
                    else if (ty == 2) { notify = va; mult = pci.pci_cfg_read32(bdf, p + 16); }
                    else if (ty == 4) { devcfg = va; };
                };
            };
        };
        p = (w >> 8) & 255;
        guard = guard + 1;
    };
    if (common == 0 || notify == 0) { return 0 - 1; };
    vd_bdf[h] = bdf;
    vd_common[h] = common;
    vd_notify[h] = notify;
    vd_mult[h] = mult;
    vd_devcfg[h] = devcfg;
    vd_n = vd_n + 1;
    h
};

def virtio_devcfg(h: long) -> long { vd_devcfg[h] };

/** Reset the device and take it through ACK, DRIVER and FEATURES_OK (VERSION_1 only); false on refusal. */
def virtio_start(h: long) -> bool {
    let c = vd_common[h];
    wr8(c + 20, 0);
    let n = 0;
    while (rd8(c + 20) != 0 && n < 100000) { n = n + 1; };
    wr8(c + 20, VS_ACK);
    wr8(c + 20, VS_ACK | VS_DRIVER);
    wr32(c + 0, 1);
    if ((rd32(c + 4) & 1) == 0) { wr8(c + 20, VS_FAILED); return false; };
    wr32(c + 8, 0);
    wr32(c + 12, 0);
    wr32(c + 8, 1);
    wr32(c + 12, 1);
    wr8(c + 20, VS_ACK | VS_DRIVER | VS_FEATURES_OK);
    if ((rd8(c + 20) & VS_FEATURES_OK) == 0) { wr8(c + 20, VS_FAILED); return false; };
    true
};

/** Make queue `qi` of device `h` (64 entries, one page): the queue handle, or -1. */
def virtio_queue(h: long, qi: long) -> long {
    if (vq_n >= 8) { return 0 - 1; };
    let c = vd_common[h];
    wr16(c + 22, qi);
    let max = rd16(c + 24);
    if (max == 0) { return 0 - 1; };
    let size = VQ_SIZE;
    if (max < size) { size = max; };
    let phys = kernel.pages_alloc(4096);
    if (phys == 0) { return 0 - 1; };
    kernel.acct_add(kernel.ACCT_DEV, 4096);
    kernel.kzero_phys(phys, 4096);
    let va = kernel.DIRECT_BASE + phys;
    let q = vq_n;
    vq_n = vq_n + 1;
    vq_dev[q] = h;
    vq_desc[q] = va;
    vq_avail[q] = va + 1024;
    vq_used[q] = va + 2048;
    vq_seen[q] = 0;
    wr16(c + 24, size);
    wr64(c + 32, phys);
    wr64(c + 40, phys + 1024);
    wr64(c + 48, phys + 2048);
    wr16(c + 28, 1);
    vq_note[q] = vd_notify[h] + rd16(c + 30) * vd_mult[h];
    vq_qi[q] = qi;
    q
};

/** Tell the device the driver is ready (after every queue is set up). */
def virtio_ready(h: long) -> void {
    let c = vd_common[h];
    wr8(c + 20, VS_ACK | VS_DRIVER | VS_FEATURES_OK | VS_DRIVER_OK);
};

/** Descriptor `d` of queue `q`: a buffer at physical `addr`, `len` bytes, `flags` (1 next, 2 device-writes), `next`. */
def virtio_desc(q: long, d: long, addr: long, len: long, flags: long, next: long) -> void {
    let p = vq_desc[q] + d * 16;
    wr64(p, addr);
    wr32(p + 8, len);
    wr16(p + 12, flags);
    wr16(p + 14, next);
};

/** Offer the chain starting at descriptor `head` to the device and notify it. */
def virtio_submit(q: long, head: long) -> void {
    let a = vq_avail[q];
    let idx = rd16(a + 2);
    wr16(a + 4 + (idx % VQ_SIZE) * 2, head);
    wr16(a + 2, idx + 1);
    wr16(vq_note[q], vq_qi[q]);
};

/** Chains the device has finished since the last call: the head descriptor and the length written, one at a time (-1 when none). */
def virtio_used_head(q: long) -> long {
    let u = vq_used[q];
    let idx = rd16(u + 2);
    if (idx == (vq_seen[q] & 65535)) { return 0 - 1; };
    let e = u + 4 + (vq_seen[q] % VQ_SIZE) * 8;
    let head = rd32(e);
    vq_seen[q] = vq_seen[q] + 1;
    head
};

/** The byte count the device wrote for the chain `virtio_used_head` just returned. */
def virtio_used_len(q: long) -> long {
    let u = vq_used[q];
    rd32(u + 4 + ((vq_seen[q] - 1) % VQ_SIZE) * 8 + 4)
};
