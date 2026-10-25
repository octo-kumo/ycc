// fbdev -- /dev/fb0 and /dev/input: what a GUI program uses of the display and the pointer.
//
// /dev/fb0 (ioctl only; opening it allocates the GUI's display buffer, which makes F1/F12 able
// to switch to the GUI view):
//   0x4600 FB_INFO   arg -> six longs: width, height, stride in bytes, bits per pixel (32), the
//                    mode generation (changes when the display is resized), 1 if the host can resize it
//   0x4601 FB_BLIT   arg -> six longs: src, src stride, x, y, w, h: copy that rectangle of a
//                    32-bit 0x00RRGGBB image in the caller's memory (laid out like the screen:
//                    pixel (x, y) at src + y * stride + x * 4) to the display buffer and show it
//   0x4602 FB_VIEW   arg 1: show the GUI view; 0: the text terminal
//   0x4603 FB_TYPE   arg -> (pointer, length): type that text into the tty as if it came from
//                    the keyboard (after Ctrl-U, which kills what was half typed there) and
//                    switch to the terminal -- how the GUI opens a program in the shell
//   0x4604 FB_STATS  arg -> (pointer, capacity in bytes): fill it with a snapshot of the kernel's
//                    counters and a row per task (kstat.y has the layout); answers the bytes written
// /dev/input: read 16-byte events (input.y: u16 type, u16 code, i32 value, u64 time in us), only
// while the GUI view is up (in the terminal view the keys go to the tty). Type 32 is the kernel's
// "the display changed size". Blocks unless O_NONBLOCK; poll works.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import fb from "./fb.y";
import input from "./input.y";
import console from "./console.y";
import kstat from "./kstat.y";
import time from "./time.y";

const FB_INFO = 17920;
const FB_BLIT = 17921;
const FB_VIEW = 17922;
const FB_TYPE = 17923;
const FB_STATS = 17924;

/** How many descriptors on /dev/fb0 are open: the view goes back to the terminal when the last one closes
 *  (a shell that flips the view with a descriptor of its own must not undo it by closing it). */
let fb_opens = 0;

def fb_open(flags: long) -> long {
    if (!fb.fb_present()) { return kconst.ENODEV; };
    if (fb.fb_gui_alloc() == 0) { return kconst.ENOMEM; };
    fb_opens = fb_opens + 1;
    0
};

def fb_close(obj: long) -> long {
    if (fb_opens > 0) { fb_opens = fb_opens - 1; };
    if (fb_opens == 0) { console.con_set_mode(console.CON_TEXT); };
    0
};

def fb_write(obj: long, buf: long, cnt: long, flags: long) -> long { kconst.EINVAL };

def fb_ioctl(obj: long, req: long, arg: long) -> long {
    if (req == FB_INFO) {
        if (!kernel.user_ok(arg, 48)) { return kconst.EFAULT; };
        kernel.poke_va64(arg, fb.fb_width());
        kernel.poke_va64(arg + 8, fb.fb_height());
        kernel.poke_va64(arg + 16, fb.fb_stride());
        kernel.poke_va64(arg + 24, 32);
        kernel.poke_va64(arg + 32, fb.fb_generation());
        kernel.poke_va64(arg + 40, if (fb.fb_resizable()) { 1 } else { 0 });
        return 0;
    };
    if (req == FB_BLIT) {
        if (!kernel.user_ok(arg, 48)) { return kconst.EFAULT; };
        let src = kernel.peek_va64(arg);
        let sstride = kernel.peek_va64(arg + 8);
        let x = kernel.peek_va64(arg + 16);
        let y = kernel.peek_va64(arg + 24);
        let w = kernel.peek_va64(arg + 32);
        let h = kernel.peek_va64(arg + 40);
        if (x < 0) { w = w + x; x = 0; };
        if (y < 0) { h = h + y; y = 0; };
        if (x + w > fb.fb_width()) { w = fb.fb_width() - x; };
        if (y + h > fb.fb_height()) { h = fb.fb_height() - y; };
        if (w <= 0 || h <= 0) { return 0; };
        if (!kernel.user_ok(src + y * sstride + x * 4, (h - 1) * sstride + w * 4)) { return kconst.EFAULT; };
        let dst = fb.fb_gui_buf();
        let stride = fb.fb_stride();
        let r = 0;
        while (r < h) {
            let off = (y + r) * stride + x * 4;
            kernel.kcopy(dst + off, src + (y + r) * sstride + x * 4, w * 4);
            r = r + 1;
        };
        fb.fb_flush(dst, x, y, w, h);
        kstat.kstat_blit(w * h * 4);
        return 0;
    };
    if (req == FB_VIEW) {
        if (arg == 1) { console.con_set_mode(console.CON_GUI); } else { console.con_set_mode(console.CON_TEXT); };
        return 0;
    };
    if (req == FB_TYPE) {
        if (!kernel.user_ok(arg, 16)) { return kconst.EFAULT; };
        let p = kernel.peek_va64(arg);
        let n = kernel.peek_va64(arg + 8);
        if (n < 0 || n > 4096 || !kernel.user_ok(p, n)) { return kconst.EFAULT; };
        console.con_set_mode(console.CON_TEXT);
        input.input_type_byte(21);
        let i = 0;
        while (i < n) {
            input.input_type_byte(kernel.peek_va8(p + i));
            i = i + 1;
        };
        return 0;
    };
    if (req == FB_STATS) {
        if (!kernel.user_ok(arg, 16)) { return kconst.EFAULT; };
        let p = kernel.peek_va64(arg);
        let cap = kernel.peek_va64(arg + 8);
        if (cap < 1024 || cap > 1048576 || !kernel.user_ok(p, cap)) { return kconst.EFAULT; };
        return kstat.kstat_snapshot(p, cap, time.now_us(), kernel.heap_bytes(), heap_used(), fb.fb_width(), fb.fb_height(), fb.fb_generation());
    };
    kconst.ENOTTY
};

def input_open(flags: long) -> long {
    if (!fb.fb_present()) { return kconst.ENODEV; };
    input.input_flush();
    0
};

def input_read(obj: long, buf: long, len: long, flags: long) -> long {
    if (len < 16) { return kconst.EINVAL; };
    if (!kernel.user_ok(buf, len)) { return kconst.EFAULT; };
    if (input.input_pending() == 0) {
        if ((flags & kconst.O_NONBLOCK) != 0) { return kconst.EAGAIN; };
        return kernel.block_restart(fdt.fdt_chan(kconst.INPUT, 0), 0);
    };
    let k = 0;
    while (k + 16 <= len && input.input_pending() > 0) {
        kernel.poke_va64(buf + k, input.input_head_word(0));
        kernel.poke_va64(buf + k + 8, input.input_head_word(1));
        input.input_drop();
        k = k + 16;
    };
    k
};

def input_ioctl(obj: long, req: long, arg: long) -> long { kconst.ENOTTY };

def input_poll(obj: long, events: long) -> long {
    let r = 0;
    if ((events & kconst.POLLIN) != 0 && input.input_pending() > 0) { r = kconst.POLLIN; };
    r
};
