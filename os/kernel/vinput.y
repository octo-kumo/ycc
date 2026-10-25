// vinput -- virtio-input devices (`-device virtio-keyboard-pci`, `virtio-tablet-pci`, `virtio-mouse-pci`).
//
// The device streams Linux evdev events (le16 type, le16 code, le32 value) into buffers the driver
// posts on its event queue; `vinput_poll` (the clock tick) hands each to input.input_event and
// posts the buffer again. A tablet reports absolute positions (ABS_X, ABS_Y in 0..32767), which is
// what lets the host's pointer and the guest's agree with no grab.
import kernel;
import virtio from "./virtio.y";
import input from "./input.y";

let vi_q: [long; 4] = [0; 4];
let vi_buf: [long; 4] = [0; 4];
let vi_n = 0;

/** Start every virtio-input device found; how many. */
def vinput_init() -> long {
    let nth = 0;
    while (nth < 4) {
        let h = virtio.virtio_probe(18, nth);
        if (h < 0) { return vi_n; };
        nth = nth + 1;
        if (!virtio.virtio_start(h)) { continue; };
        let q = virtio.virtio_queue(h, 0);
        if (q < 0) { continue; };
        let phys = kernel.pages_alloc(4096);
        if (phys == 0) { continue; };
        kernel.acct_add(kernel.ACCT_DEV, 4096);
        kernel.kzero_phys(phys, 4096);
        let i = 0;
        while (i < virtio.VQ_SIZE) {
            virtio.virtio_desc(q, i, phys + i * 8, 8, 2, 0);
            virtio.virtio_submit(q, i);
            i = i + 1;
        };
        virtio.virtio_ready(h);
        vi_q[vi_n] = q;
        vi_buf[vi_n] = kernel.DIRECT_BASE + phys;
        vi_n = vi_n + 1;
    };
    vi_n
};

/** Deliver what the devices have queued. */
def vinput_poll() -> void {
    let k = 0;
    while (k < vi_n) {
        let q = vi_q[k];
        let d = virtio.virtio_used_head(q);
        while (d >= 0) {
            let e = vi_buf[k] + d * 8;
            let value = virtio.rd32(e + 4);
            if (value >= 2147483648) { value = value - 4294967296; };
            input.input_event(virtio.rd16(e), virtio.rd16(e + 2), value);
            virtio.virtio_submit(q, d);
            d = virtio.virtio_used_head(q);
        };
        k = k + 1;
    };
};
