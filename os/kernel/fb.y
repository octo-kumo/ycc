// fb -- the display: a 32-bit linear framebuffer behind a small interface.
//
// Two RAM buffers of the display's size are what the rest of the kernel draws into: the VT's
// (vt.y renders the text terminal there) and, once /dev/fb0 is opened, the GUI's (a program draws
// there through its mapping). `fb_show(view)` picks which of them the screen shows (1 the VT's,
// 2 the GUI's) and `fb_flush(buf, x, y, w, h)` makes a rectangle of the shown one visible.
// Pixels are 0x00RRGGBB, `fb_width() * 4` bytes a row.
//
// Backends:
//  * virtio-gpu (`-device virtio-gpu-pci`, vgpu.y): the size follows the host window; `fb_poll`
//    (the clock tick calls it) notices a change, re-creates the resources and returns true.
//  * the Bochs/QEMU standard VGA (`-vga std`, `-device bochs-display`; PCI 1234:1111): the
//    "dispi" registers set a mode, PCI BAR 0 is the framebuffer, a flush copies the rectangle
//    there. Its size is fixed.
// The buffers are allocated once at the largest size the backend can show, so a mode change
// never allocates.
import kernel;
import pci from "./pci.y";
import mmio from "./mmio.y";
import vgpu from "./vgpu.y";

const FB_NONE = 0;
const FB_VGA = 1;
const FB_VIRTIO = 2;

const VBE_INDEX = 462;
const VBE_DATA = 463;
const VBE_ID = 0;
const VBE_XRES = 1;
const VBE_YRES = 2;
const VBE_BPP = 3;
const VBE_ENABLE = 4;
const VBE_VRAM64K = 10;

let fb_kind = 0;
let fb_w = 0;
let fb_h = 0;
let fb_maxw = 0;
let fb_maxh = 0;
let fb_lfb = 0;
let fb_vram = 0;
let fb_vt = 0;
let fb_gui = 0;
let fb_gui_phys = 0;
let fb_vt_phys = 0;
let fb_epoch = 0;
let fb_view = 1;
let fb_lost = false;
// the view the virtio scanout currently shows (0: none set since the last re-creation of the resources)
let fb_scan = 0;

def vbe_write(i: long, v: long) -> void {
    kernel.outw(VBE_INDEX, i);
    kernel.outw(VBE_DATA, v);
};

def vbe_read(i: long) -> long {
    kernel.outw(VBE_INDEX, i);
    kernel.inw(VBE_DATA)
};

def fb_present() -> bool { fb_kind != FB_NONE };
def fb_width() -> long { fb_w };
def fb_height() -> long { fb_h };
def fb_stride() -> long { fb_w * 4 };
def fb_vt_buf() -> long { fb_vt };
def fb_vt_phys_addr() -> long { fb_vt_phys };
def fb_gui_buf() -> long { fb_gui };
def fb_gui_phys_addr() -> long { fb_gui_phys };
def fb_max_bytes() -> long { fb_maxw * fb_maxh * 4 };
def fb_max_width() -> long { fb_maxw };
def fb_max_height() -> long { fb_maxh };
def fb_resizable() -> bool { fb_kind == FB_VIRTIO };
/** Counts mode changes, so a client can tell its picture of the size is stale. */
def fb_generation() -> long { fb_epoch };
def fb_current_view() -> long { fb_view };

/** Make the standard VGA show `w` x `h` (clamped to what it can do); false when it refused. */
def fb_vga_mode(w: long, h: long) -> bool {
    if (w > fb_maxw) { w = fb_maxw; };
    if (h > fb_maxh) { h = fb_maxh; };
    if (w < 640) { w = 640; };
    if (h < 400) { h = 400; };
    if (w * h * 4 > fb_vram) { return false; };
    vbe_write(VBE_ENABLE, 0);
    vbe_write(VBE_XRES, w);
    vbe_write(VBE_YRES, h);
    vbe_write(VBE_BPP, 32);
    vbe_write(VBE_ENABLE, 65);
    fb_w = vbe_read(VBE_XRES);
    fb_h = vbe_read(VBE_YRES);
    fb_epoch = fb_epoch + 1;
    fb_w == w && fb_h == h
};

/** Give the virtio-gpu a `w` x `h` display (clamped), re-creating its resources. */
def fb_virtio_mode(w: long, h: long) -> bool {
    if (w > fb_maxw) { w = fb_maxw; };
    if (h > fb_maxh) { h = fb_maxh; };
    if (w < 640) { w = 640; };
    if (h < 400) { h = 400; };
    fb_w = w;
    fb_h = h;
    fb_epoch = fb_epoch + 1;
    fb_scan = 0;
    if (!vgpu.vgpu_config(w, h, fb_vt_phys, fb_gui_phys)) { return false; };
    fb_scan = fb_view;
    if (!vgpu.vgpu_scanout(fb_view)) { return false; };
    // new resources start black on the host: send the picture again
    fb_flush(fb_buf_of(fb_view), 0, 0, fb_w, fb_h);
    true
};

def fb_init_vga(w: long, h: long) -> bool {
    let bdf = pci.pci_find(4660, 4369);
    if (bdf < 0) { return false; };
    let id = vbe_read(VBE_ID);
    if (id < 45248 || id > 45263) { return false; };
    let bar = pci.pci_bar_mem(bdf, 0);
    if (bar == 0) { return false; };
    pci.pci_enable_busmaster(bdf);
    fb_vram = vbe_read(VBE_VRAM64K) * 65536;
    let size = pci.pci_bar_size(bdf, 0);
    if (size > 0 && size < fb_vram) { fb_vram = size; };
    if (fb_vram < 1048576) { return false; };
    fb_lfb = mmio.mmio_map(bar, fb_vram);
    if (fb_lfb == 0) { return false; };
    fb_maxw = 2560;
    fb_maxh = 1600;
    fb_vt_phys = kernel.pages_alloc(fb_max_bytes());
    if (fb_vt_phys == 0) { return false; };
    kernel.acct_add(kernel.ACCT_FB, fb_max_bytes());
    fb_vt = kernel.DIRECT_BASE + fb_vt_phys;
    if (w == 0) { w = 1280; h = 800; };
    if (!fb_vga_mode(w, h) && !fb_vga_mode(1024, 768) && !fb_vga_mode(640, 480)) { return false; };
    fb_kind = FB_VGA;
    true
};

def fb_init_virtio(w: long, h: long) -> bool {
    if (!vgpu.vgpu_probe()) { return false; };
    fb_maxw = 3840;
    fb_maxh = 2160;
    fb_vt_phys = kernel.pages_alloc(fb_max_bytes());
    if (fb_vt_phys == 0) { return false; };
    kernel.acct_add(kernel.ACCT_FB, fb_max_bytes());
    fb_vt = kernel.DIRECT_BASE + fb_vt_phys;
    if (w == 0) {
        let sz = [0, 0];
        if (vgpu.vgpu_display_size(sz)) { w = sz[0]; h = sz[1]; } else { w = 1280; h = 800; };
    };
    fb_kind = FB_VIRTIO;
    if (!fb_virtio_mode(w, h)) { fb_kind = FB_NONE; return false; };
    true
};

/** Look for a display (once, at boot) and start it at `w` x `h` (0: the host's size, else 1280x800). */
def fb_init(w: long, h: long) -> bool {
    if (fb_kind != FB_NONE) { return true; };
    if (fb_init_virtio(w, h)) { return true; };
    fb_init_vga(w, h)
};

/** The GUI's buffer: allocated on first use (it is as big as the display can be). */
def fb_gui_alloc() -> long {
    if (fb_gui_phys == 0 && fb_kind != FB_NONE) {
        fb_gui_phys = kernel.pages_alloc(fb_max_bytes());
        if (fb_gui_phys != 0) {
            kernel.acct_add(kernel.ACCT_FB, fb_max_bytes());
            fb_gui = kernel.DIRECT_BASE + fb_gui_phys;
            if (fb_kind == FB_VIRTIO) { fb_virtio_mode(fb_w, fb_h); };
        };
    };
    fb_gui_phys
};

def fb_buf_of(view: long) -> long {
    if (view == 1) { fb_vt } else { fb_gui }
};

/** Show rectangle (x, y, w, h) of `buf` (fb_vt_buf or fb_gui_buf) -- when it is the buffer on screen. */
def fb_flush(buf: long, x: long, y: long, w: long, h: long) -> void {
    if (fb_kind == FB_NONE) { return; };
    if (buf != fb_buf_of(fb_view)) { return; };
    if (x < 0) { w = w + x; x = 0; };
    if (y < 0) { h = h + y; y = 0; };
    if (x + w > fb_w) { w = fb_w - x; };
    if (y + h > fb_h) { h = fb_h - y; };
    if (w <= 0 || h <= 0) { return; };
    if (fb_kind == FB_VIRTIO) {
        if (!vgpu.vgpu_flush(fb_view, x, y, w, h)) { fb_lost = true; };
        return;
    };
    let stride = fb_w * 4;
    if (w == fb_w) {
        kernel.kcopy(fb_lfb + y * stride, buf + y * stride, h * stride);
        return;
    };
    let r = 0;
    while (r < h) {
        let off = (y + r) * stride + x * 4;
        kernel.kcopy(fb_lfb + off, buf + off, w * 4);
        r = r + 1;
    };
};

/** Make buffer `view` (1 the VT's, 2 the GUI's) the one on screen, and show all of it. */
def fb_show(view: long) -> void {
    if (fb_kind == FB_NONE) { return; };
    if (view == 2 && fb_gui == 0) { return; };
    fb_view = view;
    if (fb_kind == FB_VIRTIO && fb_scan != view) {
        vgpu.vgpu_scanout(view);
        fb_scan = view;
    };
    fb_flush(fb_buf_of(view), 0, 0, fb_w, fb_h);
};

/** The clock tick's housekeeping: true when the display's size just changed (the host resized it). */
def fb_poll() -> bool {
    if (fb_kind != FB_VIRTIO) { return false; };
    if (fb_lost) {
        fb_lost = false;
        fb_flush(fb_buf_of(fb_view), 0, 0, fb_w, fb_h);
    };
    if (!vgpu.vgpu_poll()) { return false; };
    let sz = [0, 0];
    if (!vgpu.vgpu_display_size(sz)) { return false; };
    let w = sz[0];
    let h = sz[1];
    if (w > fb_maxw) { w = fb_maxw; };
    if (h > fb_maxh) { h = fb_maxh; };
    if (w < 640) { w = 640; };
    if (h < 400) { h = 400; };
    if (w == fb_w && h == fb_h) { return false; };
    fb_virtio_mode(w, h)
};
