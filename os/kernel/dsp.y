// dsp -- /dev/dsp, OSS-style PCM output over ac97.
//
// Several openers share one stream (pulsed keeps it open).  The client format is S16_LE, 1 or 2 channels,
// SNDCTL_DSP_SPEED hertz.  With variable rate audio the codec plays that rate
// itself; without it (or for a rate it refuses) dsp resamples to the rate the
// controller runs at, by linear interpolation in 16.16 fixed point.  A write
// returns the bytes it took (a short count when the ring fills), or blocks with
// block_restart when it took none; on_tick wakes the sleepers.  on_tick runs in
// IRQ 0: no floats, no blocking.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import ac97 from "./ac97.y";


let dsp_opens = 0;
let dsp_rate = 48000;
let dsp_hw = 48000;
let dsp_ch = 2;
let dsp_step = 65536;
let dsp_maxout = 2;
let dsp_first = true;
let dsp_pos = 0;
let dsp_pl = 0;
let dsp_pr = 0;
let dsp_waiters = false;
let dsp_lowfree = false;

/** Boot (sys.sys_boot_init): bring the sound card up if there is one. */
def dsp_init() -> void {
    ac97.ac97_init();
};

/** From time.on_tick (IRQ 0). */
def dsp_on_tick() -> void {
    ac97.ac97_poll();
    if (dsp_waiters || dsp_lowfree) {
        if (ac97.ac97_free_bytes() >= 8192 || (dsp_waiters && ac97.ac97_queued_bytes() == 0)) {
            dsp_waiters = false;
            dsp_lowfree = false;
            fdt.fdt_notify(kconst.DSP, 0);
        };
    };
};

/** Recompute the conversion constants after a rate change. */
def dsp_set_rate(hz: long) -> long {
    let r = hz;
    if (r < 4000) { r = 4000; };
    if (r > 48000) { r = 48000; };
    let hw = ac97.ac97_set_rate(r);
    dsp_rate = r;
    dsp_hw = hw;
    if (r == hw) {
        dsp_step = 65536;
        dsp_maxout = 1;
    } else {
        dsp_step = r * 65536 / hw;
        dsp_maxout = hw / r + 2;
    };
    dsp_first = true;
    r
};

def dsp_defaults() -> void {
    dsp_ch = 2;
    dsp_waiters = false;
    dsp_lowfree = false;
    dsp_set_rate(48000);
};

def dsp_open(flags: long) -> long {
    if (!ac97.ac97_present()) { return kconst.ENODEV; };
    if (flags & kconst.O_ACCMODE == 0) { return kconst.EINVAL; };
    if (dsp_opens == 0) { dsp_defaults(); };
    dsp_opens = dsp_opens + 1;
    1
};

def dsp_read(obj: long, buf: long, len: long, flags: long) -> long { kconst.EINVAL };

def dsp_s16(a: long) -> long {
    let v = kernel.peek_va8(a) | (kernel.peek_va8(a + 1) << 8);
    if (v >= 32768) { v - 65536 } else { v }
};

/** The sample `v` placed between the previous frame and this one: queue the
frames of one input frame; the ring has room for dsp_maxout of them. */
def dsp_emit(l: long, r: long) -> void {
    if (dsp_first) {
        dsp_first = false;
        dsp_pl = l;
        dsp_pr = r;
        dsp_pos = 0;
    };
    while (dsp_pos < 65536) {
        ac97.ac97_put_frame(dsp_pl + (((l - dsp_pl) * dsp_pos) >> 16), dsp_pr + (((r - dsp_pr) * dsp_pos) >> 16));
        dsp_pos = dsp_pos + dsp_step;
    };
    dsp_pos = dsp_pos - 65536;
    dsp_pl = l;
    dsp_pr = r;
};

def dsp_write(obj: long, buf: long, len: long, flags: long) -> long {
    if (!kernel.user_ok(buf, len)) { return kconst.EFAULT; };
    if (len == 0) { return 0; };
    let fs = dsp_ch * 2;
    let frames = len / fs;
    if (frames == 0) { return len; };
    let took = 0;
    if (dsp_ch == 2 && dsp_rate == dsp_hw) {
        took = ac97.ac97_write_pcm(buf, frames * 4);
    } else {
        let avail = ac97.ac97_free_bytes() / 4;
        let i = 0;
        while (i < frames && avail >= dsp_maxout) {
            let a = buf + i * fs;
            let l = dsp_s16(a);
            let r = l;
            if (dsp_ch == 2) { r = dsp_s16(a + 2); };
            dsp_emit(l, r);
            avail = ac97.ac97_free_bytes() / 4;
            i = i + 1;
        };
        took = i * fs;
    };
    if (took == 0) {
        if (flags & kconst.O_NONBLOCK != 0) { return kconst.EAGAIN; };
        dsp_waiters = true;
        return kernel.block_restart(fdt.fdt_chan(kconst.DSP, 0), 0);
    };
    if (took == frames * fs) {
        // every whole frame went in: the tail short of a frame is dropped
        return len;
    };
    took
};

def dsp_arg(arg: long) -> long {
    kernel.peek_va8(arg) | (kernel.peek_va8(arg + 1) << 8) | (kernel.peek_va8(arg + 2) << 16) | (kernel.peek_va8(arg + 3) << 24)
};

def dsp_ioctl(obj: long, req: long, arg: long) -> long {
    // no-argument requests
    if (req == 20480) {
        // SNDCTL_DSP_RESET
        ac97.ac97_reset();
        dsp_first = true;
        dsp_waiters = false;
        fdt.fdt_notify(kconst.DSP, 0);
        return 0;
    };
    if (req == 20481 || req == 20488) {
        // SNDCTL_DSP_SYNC, SNDCTL_DSP_POST: let the queued samples play out
        ac97.ac97_flush();
        if (req == 20481 && ac97.ac97_queued_bytes() > 0) {
            dsp_waiters = true;
            return kernel.block_restart(fdt.fdt_chan(kconst.DSP, 0), 0);
        };
        return 0;
    };
    if (!kernel.user_ok(arg, 4)) { return kconst.EFAULT; };
    if (req == 3221508098) {
        // SNDCTL_DSP_SPEED
        let r = dsp_set_rate(dsp_arg(arg));
        kernel.poke_va32(arg, r);
        return 0;
    };
    if (req == 3221508101) {
        // SNDCTL_DSP_SETFMT: S16_LE is the one format
        kernel.poke_va32(arg, 16);
        return 0;
    };
    if (req == 3221508102) {
        // SNDCTL_DSP_CHANNELS
        let c = dsp_arg(arg);
        if (c != 1) { c = 2; };
        dsp_ch = c;
        kernel.poke_va32(arg, c);
        return 0;
    };
    if (req == 3221508099) {
        // SNDCTL_DSP_STEREO
        dsp_ch = if (dsp_arg(arg) != 0) { 2 } else { 1 };
        kernel.poke_va32(arg, dsp_ch - 1);
        return 0;
    };
    if (req == 2147766283) {
        // SNDCTL_DSP_GETFMTS
        kernel.poke_va32(arg, 16);
        return 0;
    };
    if (req == 3221508106) {
        // SNDCTL_DSP_SETFRAGMENT: the ring has its own geometry
        return 0;
    };
    if (req == 2148552716) {
        // SNDCTL_DSP_GETOSPACE: audio_buf_info {fragments, fragstotal, fragsize, bytes}
        if (!kernel.user_ok(arg, 16)) { return kconst.EFAULT; };
        let hwb = ac97.ac97_free_bytes();
        let bytes = hwb / 4 * dsp_rate / dsp_hw * dsp_ch * 2;
        kernel.poke_va32(arg, bytes / 4096);
        kernel.poke_va32(arg + 4, 30);
        kernel.poke_va32(arg + 8, 4096);
        kernel.poke_va32(arg + 12, bytes);
        return 0;
    };
    kconst.ENOTTY
};

def dsp_poll(obj: long, events: long) -> long {
    let ev = 0;
    if (events & kconst.POLLOUT != 0) {
        if (ac97.ac97_free_bytes() >= 4096) {
            ev = kconst.POLLOUT;
        } else {
            dsp_lowfree = true;
        };
    };
    ev
};

def dsp_close(obj: long) -> long {
    ac97.ac97_flush();
    if (dsp_opens > 0) { dsp_opens = dsp_opens - 1; };
    0
};
