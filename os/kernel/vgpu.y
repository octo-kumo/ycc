// vgpu -- the virtio-gpu 2D device (`-device virtio-gpu-pci`): a display whose size the host can
// change. Two resources back what fb.y draws into: 1 is the VT's buffer, 2 the GUI's, both
// attached to the guest pages fb.y allocated (one contiguous run each, rows `w * 4` bytes apart).
// Showing a buffer is SET_SCANOUT; a flush is TRANSFER_TO_HOST_2D + RESOURCE_FLUSH of a rectangle,
// queued without waiting (the clock-tick handler cannot spin on the device). The setup commands
// wait for the answer. The host resizing its window sets the config's events_read bit 0:
// `vgpu_poll` sees it and reads the new size (GET_DISPLAY_INFO).
import kernel;
import virtio from "./virtio.y";

const VG_GET_DISPLAY_INFO = 256;
const VG_RESOURCE_CREATE_2D = 257;
const VG_RESOURCE_UNREF = 258;
const VG_SET_SCANOUT = 259;
const VG_RESOURCE_FLUSH = 260;
const VG_TRANSFER_TO_HOST_2D = 261;
const VG_RESOURCE_ATTACH_BACKING = 262;
const VG_OK_NODATA = 4352;
const VG_OK_DISPLAY_INFO = 4353;
const VG_FORMAT_BGRX = 2;

let vg_h = 0 - 1;
let vg_q = 0 - 1;
let vg_area = 0;
let vg_phys = 0;
let vg_busy: [byte; 32] = [0; 32];
let vg_made1 = false;
let vg_made2 = false;
let vg_w = 0;
let vg_h_px = 0;

// area layout: the synchronous command at 0 (512 bytes), its answer at 512 (1536), then 31
// asynchronous slots of 128 bytes (96 command, 32 answer) from 2048
const VG_SYNC_CMD = 0;
const VG_SYNC_RESP = 512;
const VG_SLOTS = 2048;

/** Find and start the device; false when there is none. */
def vgpu_probe() -> bool {
    let h = virtio.virtio_probe(16, 0);
    if (h < 0) { return false; };
    if (!virtio.virtio_start(h)) { return false; };
    let q = virtio.virtio_queue(h, 0);
    if (q < 0) { return false; };
    vg_phys = kernel.pages_alloc(8192);
    if (vg_phys == 0) { return false; };
    kernel.acct_add(kernel.ACCT_DEV, 8192);
    kernel.kzero_phys(vg_phys, 8192);
    vg_area = kernel.DIRECT_BASE + vg_phys;
    vg_h = h;
    vg_q = q;
    virtio.virtio_ready(h);
    true
};

/** Collect finished asynchronous commands. */
def vg_reap() -> void {
    let d = virtio.virtio_used_head(vg_q);
    while (d >= 0) {
        if (d >= 2) { vg_busy[(d - 2) / 2] = 0; };
        d = virtio.virtio_used_head(vg_q);
    };
};

/** Run the command in the synchronous slot (`n` bytes) and wait; the answer's type (0 on timeout). */
def vg_sync(n: long, resp_len: long) -> long {
    virtio.virtio_desc(vg_q, 0, vg_phys + VG_SYNC_CMD, n, 1, 1);
    virtio.virtio_desc(vg_q, 1, vg_phys + VG_SYNC_RESP, resp_len, 2, 0);
    virtio.virtio_submit(vg_q, 0);
    let spin = 0;
    while (spin < 20000000) {
        let d = virtio.virtio_used_head(vg_q);
        while (d >= 0) {
            if (d == 0) { return virtio.rd32(vg_area + VG_SYNC_RESP); };
            if (d >= 2) { vg_busy[(d - 2) / 2] = 0; };
            d = virtio.virtio_used_head(vg_q);
        };
        spin = spin + 1;
    };
    0
};

def vg_hdr(base: long, ty: long) -> void {
    let i = 0;
    while (i < 24) { virtio.wr8(base + i, 0); i = i + 1; };
    virtio.wr32(base, ty);
};

def vg_rect(base: long, x: long, y: long, w: long, h: long) -> void {
    virtio.wr32(base, x);
    virtio.wr32(base + 4, y);
    virtio.wr32(base + 8, w);
    virtio.wr32(base + 12, h);
};

/** The host's preferred size of scanout 0 into `out`[0], `out`[1]; false when it has none. */
def vgpu_display_size(out: [long]) -> bool {
    let c = vg_area + VG_SYNC_CMD;
    vg_hdr(c, VG_GET_DISPLAY_INFO);
    if (vg_sync(24, 408) != VG_OK_DISPLAY_INFO) { return false; };
    let r = vg_area + VG_SYNC_RESP + 24;
    out[0] = virtio.rd32(r + 8);
    out[1] = virtio.rd32(r + 12);
    virtio.rd32(r + 16) != 0 && out[0] > 0 && out[1] > 0
};

def vg_create(id: long, w: long, h: long) -> bool {
    let c = vg_area + VG_SYNC_CMD;
    vg_hdr(c, VG_RESOURCE_CREATE_2D);
    virtio.wr32(c + 24, id);
    virtio.wr32(c + 28, VG_FORMAT_BGRX);
    virtio.wr32(c + 32, w);
    virtio.wr32(c + 36, h);
    vg_sync(40, 24) == VG_OK_NODATA
};

def vg_unref(id: long) -> void {
    let c = vg_area + VG_SYNC_CMD;
    vg_hdr(c, VG_RESOURCE_UNREF);
    virtio.wr32(c + 24, id);
    virtio.wr32(c + 28, 0);
    vg_sync(32, 24);
};

def vg_attach(id: long, phys: long, bytes: long) -> bool {
    let c = vg_area + VG_SYNC_CMD;
    vg_hdr(c, VG_RESOURCE_ATTACH_BACKING);
    virtio.wr32(c + 24, id);
    virtio.wr32(c + 28, 1);
    virtio.wr64(c + 32, phys);
    virtio.wr32(c + 40, bytes);
    virtio.wr32(c + 44, 0);
    vg_sync(48, 24) == VG_OK_NODATA
};

/** (Re)create resources 1 (and 2, when there is a GUI buffer) at `w` x `h`, backed by the given pages. */
def vgpu_config(w: long, h: long, vt_phys: long, gui_phys: long) -> bool {
    if (vg_made1) { vg_unref(1); };
    if (vg_made2) { vg_unref(2); };
    vg_made1 = false;
    vg_made2 = false;
    vg_w = w;
    vg_h_px = h;
    if (!vg_create(1, w, h) || !vg_attach(1, vt_phys, w * h * 4)) { return false; };
    vg_made1 = true;
    if (gui_phys != 0) {
        if (!vg_create(2, w, h) || !vg_attach(2, gui_phys, w * h * 4)) { return false; };
        vg_made2 = true;
    };
    true
};

/** Make resource `which` (1 VT, 2 GUI) what the display shows. */
def vgpu_scanout(which: long) -> bool {
    let c = vg_area + VG_SYNC_CMD;
    vg_hdr(c, VG_SET_SCANOUT);
    vg_rect(c + 24, 0, 0, vg_w, vg_h_px);
    virtio.wr32(c + 40, 0);
    virtio.wr32(c + 44, which);
    vg_sync(48, 24) == VG_OK_NODATA
};

/** A free asynchronous slot (0..30), reaping finished ones; -1 when all are busy. */
def vg_slot() -> long {
    vg_reap();
    let s = 0;
    while (s < 31) {
        if (vg_busy[s] == 0) { return s; };
        s = s + 1;
    };
    0 - 1
};

/** Show rectangle (x, y, w, h) of resource `which`: transfer, then flush, both queued; false when the queue was full. */
def vgpu_flush(which: long, x: long, y: long, w: long, h: long) -> bool {
    let s1 = vg_slot();
    if (s1 < 0) { return false; };
    vg_busy[s1] = 1;
    let s2 = vg_slot();
    if (s2 < 0) { vg_busy[s1] = 0; return false; };
    vg_busy[s2] = 1;
    let c1 = vg_area + VG_SLOTS + s1 * 128;
    vg_hdr(c1, VG_TRANSFER_TO_HOST_2D);
    vg_rect(c1 + 24, x, y, w, h);
    virtio.wr64(c1 + 40, (y * vg_w + x) * 4);
    virtio.wr32(c1 + 48, which);
    virtio.wr32(c1 + 52, 0);
    let c2 = vg_area + VG_SLOTS + s2 * 128;
    vg_hdr(c2, VG_RESOURCE_FLUSH);
    vg_rect(c2 + 24, x, y, w, h);
    virtio.wr32(c2 + 40, which);
    virtio.wr32(c2 + 44, 0);
    let d1 = 2 + 2 * s1;
    virtio.virtio_desc(vg_q, d1, vg_phys + VG_SLOTS + s1 * 128, 56, 1, d1 + 1);
    virtio.virtio_desc(vg_q, d1 + 1, vg_phys + VG_SLOTS + s1 * 128 + 96, 24, 2, 0);
    virtio.virtio_submit(vg_q, d1);
    let d2 = 2 + 2 * s2;
    virtio.virtio_desc(vg_q, d2, vg_phys + VG_SLOTS + s2 * 128, 48, 1, d2 + 1);
    virtio.virtio_desc(vg_q, d2 + 1, vg_phys + VG_SLOTS + s2 * 128 + 96, 24, 2, 0);
    virtio.virtio_submit(vg_q, d2);
    true
};

/** True when the host changed the display (its window was resized): the event is cleared. */
def vgpu_poll() -> bool {
    if (vg_h < 0) { return false; };
    let cfg = virtio.virtio_devcfg(vg_h);
    if (cfg == 0) { return false; };
    if ((virtio.rd32(cfg) & 1) == 0) { return false; };
    virtio.wr32(cfg + 4, 1);
    true
};
