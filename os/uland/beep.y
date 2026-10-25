// beep [hz [ms]] -- play a tone (default 440 Hz, 300 ms) on /dev/dsp.
// 22050 Hz mono S16_LE triangle wave; the kernel converts to what the card plays.
import ulib;

const RATE = 22050;
const SNDCTL_DSP_SYNC = 20481;
const SNDCTL_DSP_SPEED = 3221508098;
const SNDCTL_DSP_SETFMT = 3221508101;
const SNDCTL_DSP_CHANNELS = 3221508102;

/** The decimal number in `s`, or `dflt`. */
def num(s: str, dflt: long) -> long {
    if (len(s) == 0) { return dflt; };
    let v = 0;
    let i = 0;
    while (i < len(s)) {
        if (s[i] < 48 || s[i] > 57) { return dflt; };
        v = v * 10 + s[i] - 48;
        i = i + 1;
    };
    v
};

/** ioctl(fd, req, &int) with the int set to `v`: the value the kernel left. */
def ioctl_int(fd: long, req: long, v: long) -> long {
    let cell: [long; 1] = [v];
    syscall(16, fd, req, ptr_addr(&cell[0]));
    cell[0] & 4294967295
};

let a = argv();
let hz = 440;
let ms = 300;
if (len(a) > 1) { hz = num(a[1], 440); };
if (len(a) > 2) { ms = num(a[2], 300); };
if (hz < 20 || hz > 10000 || ms < 1 || ms > 10000) {
    puts("usage: beep [hz [ms]]\n");
    exit(1);
};
let fd = ulib.open("/dev/dsp", 1);
if (fd < 0) {
    puts("beep: cannot open /dev/dsp\n");
    exit(1);
};
ioctl_int(fd, SNDCTL_DSP_SETFMT, 16);
ioctl_int(fd, SNDCTL_DSP_CHANNELS, 1);
ioctl_int(fd, SNDCTL_DSP_SPEED, RATE);
puts("beep: " + tostring(hz) + " Hz " + tostring(ms) + " ms\n");
let n = RATE * ms / 1000;
let pcm: [byte] = [];
let i = 0;
while (i < n) {
    // triangle: phase in 0..RATE per period of RATE/hz samples
    let ph = (i * hz) % RATE;
    let t = ph * 4 / RATE;
    let w = ph * 4 % RATE;
    let v = 0;
    if (t == 0) { v = w; } else if (t == 1) { v = RATE - w; } else if (t == 2) { v = 0 - w; } else { v = w - RATE; };
    let s = v * 12000 / RATE;
    if (s < 0) { s = s + 65536; };
    pcm += s & 255;
    pcm += (s >> 8) & 255;
    i = i + 1;
};
let off = 0;
let total = len(pcm);
let base = ptr_addr(&pcm[0]);
while (off < total) {
    let k = syscall(1, fd, base + off, total - off);
    if (k <= 0) {
        puts("beep: write failed\n");
        exit(1);
    };
    off = off + k;
};
syscall(16, fd, SNDCTL_DSP_SYNC, 0);
ulib.close(fd);
puts("beep: done\n");
