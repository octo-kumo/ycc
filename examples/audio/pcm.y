// pcm.y -- an ALSA PCM player in raw syscalls: open, negotiate hw_params,
// writei, drain, close.
//
// WHAT THIS IS.  There is no sound library in Y and no FFI, so the whole
// player is two syscalls and six ioctls.  That is not a stunt: it is the
// shortest honest path, because ALSA's PCM interface is a device file plus
// those ioctls, and `aplay -D hw:3,0 file.wav` reaches the hardware through
// exactly them (measured here with strace; the numbers are in the README).
//
// THE IOCTL NUMBERS.  Every request here is written the way the kernel's uapi
// header writes it, `_IOC(dir, type, nr, size)`:
//
//     (dir << 30) | (size << 16) | (type << 8) | nr          x86_64
//
// and the components are kept as named constants so the arithmetic is
// checkable rather than a table of magic hex.  The property battery
// recomputes every request from its own (dir, nr, size) quadruple and asserts
// the result equals the constant compiled in -- so a typo in either
// representation is caught, which a bare hex table could not do.
//
// `ioctl` is syscall 16 and its three arguments go in KERNEL REGISTER ORDER
// (ORCHESTRATOR.md section 2.1): rdi = fd, rsi = request, rdx = arg.  So it
// is `syscall(16, fd, REQUEST, arg)`.  Written the other way round it answers
// -25 (ENOTTY) and looks exactly like a compiler bug.
//
// THE STRUCT LAYOUTS are the ones measured by compiling offsetof() against
// this machine's /usr/include/sound/asound.h -- README carries the numbers and
// the command that produced them.  In short:
//
//   snd_pcm_hw_params (608 bytes)
//      0 flags        4 masks[3] (32 bytes each: ACCESS, FORMAT, SUBFORMAT)
//    100 mres[5]    260 intervals[12] (12 bytes each: min, max, flags; the
//                                array is indexed from SAMPLE_BITS = 8)
//    404 ires[9]    512 rmask    516 cmask    520 info     524 msbits
//    528 rate_num   532 rate_den  536 fifo_size  544 sync[16]  560 reserved[48]
//
//   snd_pcm_sw_params (136 bytes)
//      0 tstamp_mode   4 period_step   8 sleep_min  16 avail_min  24 xfer_align
//     32 start_threshold  40 stop_threshold  48 silence_threshold
//     56 silence_size  64 boundary  72 proto  76 tstamp_type
//
//   snd_xferi (24 bytes): 0 result (frames), 8 buf (pointer to the samples)
//   snd_pcm_info (288 bytes): 8 stream, 12 card, 16 id, 80 name
//
// WHY A RECORD WITH A `*byte` FIELD.  `snd_xferi.buf` is a user pointer, and
// Y has no way to turn a pointer into an integer -- `p + n` is a type error on
// a pointer and `p[]` does not index.  Putting the pointer in a record with a
// `*byte` field sidesteps the conversion completely: the record's address is
// handed to the ioctl and the kernel reads the pointer straight out of it.
// SUGGESTIONS.md #12 is what makes this shape necessary rather than merely
// convenient.

import fs;

// ── the ALSA ABI, as named constants ──────────────────────────────────────
const IOC_DIRSHIFT: long = 30;
const IOC_SIZESHIFT: long = 16;
const IOC_TYPESHIFT: long = 8;
const IOC_NRSHIFT: long = 0;
const IOC_WRITE: long = 1;
const IOC_READ: long = 2;
const ALSA_TYPE: long = 65;              // 'A'

const PC_STREAM_PLAYBACK: long = 0;
const PC_STREAM_CAPTURE: long = 1;

const PARAM_ACCESS: long = 0;
const PARAM_FORMAT: long = 1;
const PARAM_SUBFORMAT: long = 2;
const PARAM_FIRST_MASK: long = 0;
const PARAM_FIRST_INTERVAL: long = 8;    // SAMPLE_BITS
const PARAM_SAMPLE_BITS: long = 8;
const PARAM_FRAME_BITS: long = 9;
const PARAM_PERIOD_BYTES: long = 14;
const PARAM_BUFFER_BYTES: long = 18;
const PARAM_PERIODS: long = 15;
const PARAM_TICK_TIME: long = 19;
const NINTERVAL: long = 12;              // LAST_INTERVAL - FIRST_INTERVAL + 1
const PERIODS: long = 4;                 // the ring is PERIODS periods long
const PARAM_CHANNELS: long = 10;
const PARAM_RATE: long = 11;
const PARAM_PERIOD_TIME: long = 12;
const PARAM_PERIOD_SIZE: long = 13;
const PARAM_BUFFER_TIME: long = 16;
const PARAM_BUFFER_SIZE: long = 17;

const ACCESS_RW_INTERLEAVED: long = 3;
const FORMAT_S16_LE: long = 2;
const SUBFORMAT_STD: long = 0;

const STRATEGY_FULL: long = 0;         // every interval pinned and consistent
const STRATEGY_RATE: long = 1;         // rate and channels only
const STRATEGY_MIN: long = 2;          // the three masks alone
const NSTRATEGY: long = 3;

const HW_PARAMS_OFF_MASKS: long = 4;
const HW_PARAMS_OFF_INTERVALS: long = 260;
const HW_PARAMS_OFF_RMASK: long = 512;

const SW_OFF_AVAIL_MIN: long = 16;
const SW_OFF_START_THRESHOLD: long = 32;
const SW_OFF_STOP_THRESHOLD: long = 40;
const SW_OFF_BOUNDARY: long = 64;

const SIZE_HW_PARAMS: long = 608;
const SIZE_SW_PARAMS: long = 136;
const SIZE_PCM_INFO: long = 288;

const INFO_OFF_STREAM: long = 8;
const INFO_OFF_CARD: long = 12;
const INFO_OFF_NAME: long = 80;
const INFO_NAME_LEN: long = 32;

const O_WRONLY: long = 1;
const O_NONBLOCK: long = 2048;
const F_SETFL: long = 4;
const SYS_NANOSLEEP: long = 35;       // nanosleep(2)
const SLEEP_MAX_STALLS: long = 1000; // 1000 x 2 ms = 2 s of waiting, then give up
// fcntl is syscall 72 on x86-64.  ORCHESTRATOR.md 2.1 lists the syscall
// numbers it measured and fcntl is not among them, so the first draft guessed
// 55 -- which is getsockopt, and answered -88 = ENOTSOCK, which is a wonderfully
// unhelpful way to find out.  Verified by strace on a C program doing the same
// call, and by F_GETFL reporting the flag cleared afterwards.
const SYS_FCNTL: long = 72;

const AT_FDCWD: long = -100;
const FRAME_BYTES: long = 4;             // 2 channels of s16

// The requests, and the (dir, nr, size) they are built from.  Two
// representations of the same number, on purpose.
const HW_PARAMS_DIR: long = 3;          // _IOC_READ | _IOC_WRITE
const HW_PARAMS_NR: long = 17;          // 0x11
const SW_PARAMS_NR: long = 19;          // 0x13
const INFO_NR: long = 1;                // 0x01
const PREPARE_NR: long = 64;            // 0x40
const DRAIN_NR: long = 68;              // 0x44
const DROP_NR: long = 67;               // 0x43
const WRITEI_NR: long = 80;             // 0x50
const SIZE_WRITEI: long = 24;           // struct snd_xferi
const INFO_DIR: long = 2;               // _IOC_READ

// ioc(dir, nr, size): the request number for an ALSA PCM ioctl.
def ioc(dir: long, nr: long, size: long) -> long {
    (dir << IOC_DIRSHIFT) | (size << IOC_SIZESHIFT) |
    (ALSA_TYPE << IOC_TYPESHIFT) | (nr << IOC_NRSHIFT)
};

const REQ_INFO: long = 2166374657;       // 0x81204101
const REQ_HW_PARAMS: long = 3261088017;  // 0xc2604111
const REQ_SW_PARAMS: long = 3230155027;  // 0xc0884113
const REQ_PREPARE: long = 16704;         // 0x4140
const REQ_DRAIN: long = 16708;           // 0x4144
const REQ_DROP: long = 16707;            // 0x4143
const REQ_WRITEI: long = 1075331408;     // 0x40184150

// ── errno, as a name ──────────────────────────────────────────────────────
//
// A failed open or ioctl answers a negative errno, and "the device said -16"
// is not a diagnostic.  Every refusal path here reports the name instead,
// which is what makes `--devices` readable and what lets a program on a
// machine with a different permission model say *why* it cannot play.
def errno_name(e: long) -> str {
    let n = 0 - e;
    let s = "errno " + tostring(n);
    if (n == 1) { s = "EPERM"; }
    else if (n == 2) { s = "ENOENT"; }
    else if (n == 5) { s = "EIO"; }
    else if (n == 6) { s = "ENXIO"; }
    else if (n == 9) { s = "EBADF"; }
    else if (n == 11) { s = "EAGAIN"; }
    else if (n == 12) { s = "ENOMEM"; }
    else if (n == 13) { s = "EACCES"; }
    else if (n == 14) { s = "EFAULT"; }
    else if (n == 16) { s = "EBUSY"; }
    else if (n == 19) { s = "ENODEV"; }
    else if (n == 20) { s = "ENOTDIR"; }
    else if (n == 22) { s = "EINVAL"; }
    else if (n == 25) { s = "ENOTTY"; }
    else if (n == 24) { s = "EMFILE"; }
    else if (n == 32) { s = "EPIPE"; }
    else if (n == 86) { s = "ESTRPIPE"; };
    s
};

// ── the three structs, as fixed module-level buffers ──────────────────────
//
// A `[byte; N]` does not unify with `[byte]` (SUGGESTIONS.md #12) and a
// `*byte` cannot be walked, so no helper here can take a buffer by parameter.
// The accessors therefore take an offset into the one buffer that owns it.
// That is the shape the language constraint forces; it is written down here
// so the next reader does not read it as an accident.
let hwbuf: [byte; 608] = [0; 608];
let swbuf: [byte; 136] = [0; 136];
let infobuf: [byte; 288] = [0; 288];

// The one record with a pointer field in the whole program.  `buf` cannot be
// initialised to 0 -- there is no null pointer in Y, and `*byte` is not a
// `long` -- so it starts pointing at the hw_params buffer and is overwritten
// with the sample pointer immediately before every WRITEI.  Both are real
// addresses of real bytes, so the record never holds a bad pointer.
type Xferi = { result: long, buf: *byte };
let xfer: Xferi = { result: 0, buf: &hwbuf[0] };

def hw_clear() {
    let i = 0;
    while (i < 608) { hwbuf[i] = 0; i = i + 1; }
};

def hw32(off: long, v: long) {
    hwbuf[off] = v & 255;
    hwbuf[off + 1] = (v >> 8) & 255;
    hwbuf[off + 2] = (v >> 16) & 255;
    hwbuf[off + 3] = (v >> 24) & 255
};

def hwr32(off: long) -> long {
    hwbuf[off] + hwbuf[off + 1]*256 + hwbuf[off + 2]*65536 + hwbuf[off + 3]*16777216
};

def sw_clear() {
    let i = 0;
    while (i < 136) { swbuf[i] = 0; i = i + 1; }
};

def sw32(off: long, v: long) {
    swbuf[off] = v & 255;
    swbuf[off + 1] = (v >> 8) & 255;
    swbuf[off + 2] = (v >> 16) & 255;
    swbuf[off + 3] = (v >> 24) & 255
};

def io_r32(off: long) -> long {
    infobuf[off] + infobuf[off + 1]*256 + infobuf[off + 2]*65536 +
    infobuf[off + 3]*16777216
};

// io_ok: whether the buffer holds a SUCCESSFUL INFO.  The buffer is zeroed
// before every query, and a zeroed stream field reads as 0 -- which is
// SNDRV_PCM_STREAM_PLAYBACK -- so without this flag a caller that ignored the
// ioctl's return value would see every node as a playback node.  It is the same
// shape of bug as "the value was absent and the comparison passed".
let io_ok: bool = false;

def io_clear() {
    let i = 0;
    while (i < 288) { infobuf[i] = 0; i = i + 1; };
    io_ok = false
};

// io_query(fd): zero the buffer and issue SNDRV_PCM_IOCTL_INFO.  Answers the
// ioctl's own return, so the caller can refuse on a negative one.
def io_query(fd: long) -> long {
    io_clear();
    let rc = ioctl3(fd, REQ_INFO, &infobuf[0]);
    if (rc == 0) { io_ok = true; } else { io_ok = false; };
    rc
};

// io_stream(): the stream direction the last successful INFO reported, or -1.
// -1 is a safe answer: it is not SNDRV_PCM_STREAM_PLAYBACK, so a caller that
// checks nothing still refuses rather than claiming a capture node can play.
def io_stream() -> long {
    if (!io_ok) { return 0 - 1; };
    io_r32(INFO_OFF_STREAM)
};

def io_card() -> long {
    if (!io_ok) { return 0 - 1; };
    io_r32(INFO_OFF_CARD)
};

// io_name(): the device's own name from INFO, with the kernel's trailing NULs
// dropped.  A `char[32]` from the kernel, so it is not guaranteed short and
// not guaranteed printable.
def io_name() -> str {
    if (!io_ok) { return "(no INFO)"; };
    info_str(INFO_OFF_NAME, INFO_NAME_LEN)
};;

// info_str(off, n): n bytes of the device's name, as a str, with the trailing
// NULs dropped and anything non-printable turned into a dot -- a device name
// is a fixed char[32] from the kernel and there is no guarantee it is short.
def info_str(off: long, n: long) -> str {
    let s = "";
    let i = 0;
    while (i < n) {
        let c = infobuf[off + i];
        let ch = ".";
        if (c >= 32 && c < 127) { ch = chr(c); };
        s += ch;
        i = i + 1;
    };
    s.trim()
};

// hw_mask_bit(param, value): set one bit of a snd_mask, which is 8
// little-endian u32 words.  A mask is the bitmap of allowed values, so asking
// for exactly one value means setting exactly one bit.
def hw_mask_bit(param: long, value: long) {
    let idx = param - PARAM_FIRST_MASK;
    let off = HW_PARAMS_OFF_MASKS + idx * 32 + (value >> 5) * 4;
    hw32(off, hwr32(off) | (1 << (value & 31)))
};

// INTERVAL_INTEGER is bit 2 of an interval's flag word: `struct snd_interval`
// is `unsigned int min, max, openmin:1, openmax:1, integer:1, empty:1`, and on
// little-endian x86-64 the bitfields start at the low end of the third word.
// `integer` means "this parameter has to come out as a whole number of units",
// which for the RATE means the rate must be an exact integer division of the
// device's clock.
//
// IT IS SET, AND IT IS NOT WHAT MAKES THE DIFFERENCE.  That correction is
// recorded here rather than tidied away, because the first version of this
// comment asserted the opposite and the claim looked well-founded: every C
// program that was refused with EINVAL also had the flag clear, and every one
// that was accepted also had it set.  It was a confound.  Clearing it here --
// on every interval, in the shipped program, with the real device -- leaves
// `./audio devices` reporting the same 7 of 8 usable.  What actually makes the
// difference is the pin set, below.  So the flag stays set, because a real
// client sets it (alsa-lib's snd_pcm_hw_params_any() sets it on all of them)
// and because an exact rate is what this program asked for, but nothing in this
// example should be read as claiming it is load-bearing.
const INTERVAL_INTEGER: long = 4;

// hw_set_interval(param, lo, hi, want_integer): pin one interval parameter.
// min == max is how a raw hardware rate is asked for, so the driver cannot
// quietly hand back a different rate and leave the caller to resample.
def hw_set_interval(param: long, lo: long, hi: long, want_integer: bool) {
    let off = HW_PARAMS_OFF_INTERVALS + (param - PARAM_FIRST_INTERVAL) * 12;
    hw32(off, lo);
    hw32(off + 4, hi);
    if (want_integer) { hw32(off + 8, INTERVAL_INTEGER); }
    else { hw32(off + 8, 0) }
};

// hw_pin(param, value): the interval pinned to exactly one whole-number value.
def hw_pin(param: long, value: long) {
    hw_set_interval(param, value, value, true)
};

// hw_integer_all(): mark every interval `integer`, which is what a real client
// does (alsa-lib's snd_pcm_hw_params_any() sets it on all of them) and which is
// not, on this hardware, what makes the request acceptable -- see
// INTERVAL_INTEGER above.
def hw_integer_all() {
    let k = 0;
    while (k < NINTERVAL) {
        hw32(HW_PARAMS_OFF_INTERVALS + k * 12 + 8, INTERVAL_INTEGER);
        k = k + 1;
    }
};

// hw_req(param): declare in rmask that this parameter is one we are pinning.
// Measured, not assumed: the aplay that works sends rmask == 0 (dumped out of
// a real aplay with an LD_PRELOAD shim over ioctl), so rmask is left alone
// here rather than being filled in on the strength of a plausible-sounding
// reading of the ABI.
def hw_req(param: long) {
    hw32(HW_PARAMS_OFF_RMASK, hwr32(HW_PARAMS_OFF_RMASK) | (1 << param))
};

def hw_ival(param: long) -> long {
    hwr32(HW_PARAMS_OFF_INTERVALS + (param - PARAM_FIRST_INTERVAL) * 12)
};

// hw_mask_val(param): the bit index the kernel settled on, or -1 when it
// chose nothing.  This is how the negotiated access and format are read back
// rather than assumed.
def hw_mask_val(param: long) -> long {
    let off = HW_PARAMS_OFF_MASKS + (param - PARAM_FIRST_MASK) * 32;
    let found = 0 - 1;
    let w = 0;
    while (w < 8 && found < 0) {
        let cur = hwr32(off + w * 4);
        let b = 0;
        while (b < 32 && found < 0) {
            if ((cur >> b) & 1 == 1) { found = w * 32 + b; };
            b = b + 1;
        };
        w = w + 1;
    };
    found
};

// ── what was negotiated, read back from the struct the kernel filled in ────
type Hw = {
    ok: bool, err: long, strategy: long,
    rate: long, channels: long, period_size: long, buffer_size: long,
    access: long, format: long, subformat: long
};

def hw_empty() -> Hw {
    let h: Hw = {
        ok: false, err: 0, strategy: 0 - 1, rate: 0, channels: 0,
        period_size: 0, buffer_size: 0, access: 0 - 1, format: 0 - 1,
        subformat: 0 - 1
    };
    h
};

// ── hw_params negotiation ─────────────────────────────────────────────────

// The three request shapes, from most constrained to least.
//
//   FULL  every interval pinned to a whole number, and every derived quantity
//         consistent with every other: frame bits from the channel count, byte
//         counts from the frame size, and both times from the rate.
//   RATE  only the rate and the channel count, which is what a device that
//         chooses its own period wants.
//   MIN   the three masks alone, which is what a device that chooses
//         everything wants.
//
// FULL is tried first because it is the only one this machine's hardware
// accepts, and that is not one device's quirk: measured across all seven
// openable playback nodes -- four USB Audio and three NVidia HDMI -- dropping
// ANY ONE of the nine pins turns HW_PARAMS into EINVAL, and so does a request
// pinning only the rate and channels.  That is genuinely surprising, because
// leaving a parameter out is supposed to mean "you choose", and the two looser
// strategies are exactly that.  Both are still tried, in order: the point of a
// player is to work on hardware nobody has measured yet, and WHICH shape was
// accepted is reported, so a reader never has to guess which path ran.
def hw_fill(rate: long, channels: long, strategy: long) {
    hw_clear();
    hw_mask_bit(PARAM_ACCESS, ACCESS_RW_INTERLEAVED);
    hw_mask_bit(PARAM_FORMAT, FORMAT_S16_LE);
    hw_mask_bit(PARAM_SUBFORMAT, SUBFORMAT_STD);
    if (strategy == STRATEGY_FULL) {
        let fb = channels * 2;                     // bytes per frame
        let per = rate / 100;                      // a 10 ms period
        if (per < 1) { per = 1; };
        let buf = per * PERIODS;                   // a 40 ms ring
        let pt = (per * 1000000) / rate;           // period time, in us
        let bt = pt * PERIODS;                     // buffer time, in us
        hw_integer_all();
        hw_pin(PARAM_SAMPLE_BITS, 16);
        hw_pin(PARAM_FRAME_BITS, 16 * channels);
        hw_pin(PARAM_CHANNELS, channels);
        hw_pin(PARAM_RATE, rate);
        hw_pin(PARAM_PERIOD_SIZE, per);
        hw_pin(PARAM_BUFFER_SIZE, buf);
        hw_pin(PARAM_PERIOD_BYTES, fb * per);
        hw_pin(PARAM_BUFFER_BYTES, fb * buf);
        hw_pin(PARAM_PERIODS, PERIODS);
        hw_pin(PARAM_PERIOD_TIME, pt);
        hw_pin(PARAM_BUFFER_TIME, bt);
        hw_pin(PARAM_TICK_TIME, 0);
    } else if (strategy == STRATEGY_RATE) {
        hw_pin(PARAM_RATE, rate);
        hw_pin(PARAM_CHANNELS, channels);
    } else {
        // Nothing pinned: the masks alone.
    }
};

// hw_negotiate(fd, rate, channels): try the three request shapes in order and
// keep the first the device accepts.  Every field of the answer is read out of
// the struct the kernel wrote, so what the program reports about the device is
// measured rather than assumed.
def hw_negotiate(fd: long, rate: long, channels: long) -> Hw {
    let out = hw_empty();
    let k = 0;
    let rc = 0 - 5;
    while (k < NSTRATEGY) {
        hw_fill(rate, channels, k);
        rc = ioctl3(fd, REQ_HW_PARAMS, &hwbuf[0]);
        if (rc == 0) {
            out.strategy = k;
            k = NSTRATEGY;
        } else {
            k = k + 1;
        };
    };
    if (rc < 0) {
        out.ok = false;
        out.err = rc;
        return out;
    };
    out.ok = true;
    out.rate = hw_ival(PARAM_RATE);
    out.channels = hw_ival(PARAM_CHANNELS);
    out.period_size = hw_ival(PARAM_PERIOD_SIZE);
    out.buffer_size = hw_ival(PARAM_BUFFER_SIZE);
    out.access = hw_mask_val(PARAM_ACCESS);
    out.format = hw_mask_val(PARAM_FORMAT);
    out.subformat = hw_mask_val(PARAM_SUBFORMAT);
    out
};

def ioctl3(fd: long, req: long, arg: *byte) -> long {
    syscall(16, fd, req, arg)
};

// The same call with a struct argument instead of a byte buffer.  Two
// wrappers rather than one generic one because Y has no generics and a
// `*{record}` will not pass to a `*byte` parameter.
def writei_ioctl(fd: long, x: *Xferi) -> long {
    syscall(16, fd, REQ_WRITEI, x)
}

// sw_setup(fd, h): avail_min one period, start on the very first write, never
// stop on its own, and wrap the ring at the buffer size.  start_threshold is
// the interesting one: at the buffer size the stream only begins once a whole
// ring is queued, which for a short clip means the tail is never played.
def sw_setup(fd: long, h: Hw) -> long {
    sw_clear();
    sw32(SW_OFF_AVAIL_MIN, h.period_size);
    sw32(SW_OFF_START_THRESHOLD, 1);
    sw32(SW_OFF_STOP_THRESHOLD, 4294967295);
    sw32(SW_OFF_BOUNDARY, h.buffer_size);
    ioctl3(fd, REQ_SW_PARAMS, &swbuf[0])
};

// ── enumeration ───────────────────────────────────────────────────────────

const SND_DIR: str = "/dev/snd";

type Node = {
    name: str, path: str, playable: bool, card: long, stream: long,
    err: long, why: str
};

let nodes: [Node] = [];
let nnodes = 0;

// is_playback_node(name): a PCM node whose name ends in `p`.  ALSA puts the
// direction in the node name -- `pcmC3D0p` plays, `pcmC0D0c` captures -- which
// is the cheap way to keep capture devices out of the candidate list without
// opening them at all.
def is_playback_node(name: str) -> bool {
    if (!name.starts_with("pcm")) { return false; };
    let n = len(name);
    if (n < 5) { return false; };
    let last = chr(name[n - 1]);
    last == "p" || last == "P"
};

def node_reset() { nodes = []; nnodes = 0 };

// enumerate(dir, rate, channels, probe): list `dir`, keep the playback PCM
// nodes, and -- when `probe` -- try each one for real, recording why each was
// accepted or refused.  Answers how many candidates there were.
//
// `dir` is a parameter so the degradation paths can be exercised against a
// directory that is not /dev/snd: a machine with no sound hardware has none,
// and the behaviour there has to be identical to here.
def enumerate(dir: str, rate: long, channels: long, probe: bool) -> long {
    node_reset();
    let names: [str]? = fs.list_dir(dir);
    if (names == none) { return 0 - 1; };
    let list: [str] = names!;
    let i = 0;
    while (i < len(list)) {
        let nm = list[i];
        if (is_playback_node(nm)) {
            let path = dir + "/" + nm;
            let card = 0 - 1;
            let stream = 0 - 1;
            let err = 0;
            let why = "";
            let ok = false;
            if (probe) {
                let fd = open_dev(path);
                if (fd < 0) {
                    err = fd;
                    why = "open: " + errno_name(fd);
                } else {
                    let ir = io_query(fd);
                    if (ir < 0) {
                        err = ir;
                        why = "INFO: " + errno_name(ir);
                    } else {
                        stream = io_stream();
                        card = io_card();
                        if (stream != PC_STREAM_PLAYBACK) {
                            err = 0 - 5;
                            why = "INFO.stream = " + tostring(stream) +
                                  ", not playback";
                        } else {
                            let h = hw_negotiate(fd, rate, channels);
                            if (!h.ok) {
                                err = h.err;
                                why = "hw_params: " + errno_name(h.err);
                            } else {
                                ok = true;
                            };
                        };
                    };
                    syscall(3, fd);
                };
            };
            let n: Node = {
                name: nm, path: path, playable: ok, card: card,
                stream: stream, err: err, why: why
            };
            nodes += n;
            nnodes = nnodes + 1;
        };
        i = i + 1;
    };
    nnodes
};

// open_dev(path): open a PCM node for writing, NON-BLOCKING.  The raw openat
// rather than fs.open_file, because fs collapses every failure to -1 and the
// errno is the entire point of the enumeration.
//
// O_NONBLOCK at open time is not a detail, it is the whole enumeration.  A PCM
// node another process already holds answers **EBUSY** to a non-blocking open
// and **BLOCKS FOR EVER** to a blocking one -- measured on this machine with
// `/dev/snd/pcmC2D3p`, which the sound server holds: `open(O_WRONLY)` had to be
// killed by a 10 s timeout, and `open(O_WRONLY|O_NONBLOCK)` answered EBUSY at
// once.  An enumerator that opened blocking would hang on the first busy node,
// which is exactly what the first version of `audio devices` did.
def open_dev(path: str) -> long {
    syscall(257, AT_FDCWD, path, O_WRONLY + O_NONBLOCK, 0)
};

// set_blocking(fd): clear O_NONBLOCK with fcntl(F_SETFL, 0).  Needed because
// the two requirements are opposite and only one flag can hold them: a
// non-blocking descriptor is the only way to LEARN that a node is busy, and a
// blocking descriptor is the only way to make SNDRV_PCM_IOCTL_DRAIN work --
// drain is a wait, and on a non-blocking fd it answers -EAGAIN every time.
// Measured: open non-blocking, negotiate, PREPARE, clear the flag, write,
// DRAIN -- every step returns 0.
def set_blocking(fd: long) -> long {
    syscall(SYS_FCNTL, fd, F_SETFL, 0)
};

// pick(dir, rate, channels): the first node in `dir` that negotiates, opened
// and ready to write.  The fd comes back; `why` says what went wrong when
// there is none.
let pick_why: str = "";

def pick(dir: str, rate: long, channels: long) -> long {
    pick_why = "";
    let names: [str]? = fs.list_dir(dir);
    if (names == none) {
        pick_why = "no sound devices: " + dir + " could not be read";
        return 0 - 1;
    };
    let list: [str] = names!;
    let i = 0;
    let tried = 0;
    while (i < len(list)) {
        let nm = list[i];
        if (is_playback_node(nm)) {
            let path = dir + "/" + nm;
            let fd = open_dev(path);
            tried = tried + 1;
            if (fd >= 0) {
                let ir = io_query(fd);
                if (ir >= 0) {
                    let stream = io_stream();
                    if (stream == PC_STREAM_PLAYBACK) {
                        let h = hw_negotiate(fd, rate, channels);
                        if (h.ok) {
                            sw_setup(fd, h);
                            syscall(16, fd, REQ_PREPARE, 0);
                            return fd;
                        };
                    };
                };
                syscall(3, fd);
            } else {
                pick_why = path + ": " + errno_name(fd);
            };
        };
        i = i + 1;
    };
    if (tried == 0) {
        pick_why = "no playback PCM node under " + dir +
                   " (looked for pcm*p)";
    };
    0 - 1
};

// napms(ms): sleep, for the EAGAIN retry.  A fixed [byte; 16] timespec, filled
// in place: `nanosleep` takes a POINTER to one, and a record would do as well
// except that a record's address is its type descriptor.
let tspec: [byte; 16] = [0; 16];

def napms(ms: long) -> long {
    let ns = ms * 1000000;
    tspec[0] = 0;
    tspec[1] = 0;
    tspec[2] = 0;
    tspec[3] = 0;
    tspec[4] = 0;
    tspec[5] = 0;
    tspec[6] = 0;
    tspec[7] = 0;
    tspec[8] = ns & 255;
    tspec[9] = (ns >> 8) & 255;
    tspec[10] = (ns >> 16) & 255;
    tspec[11] = (ns >> 24) & 255;
    tspec[12] = 0;
    tspec[13] = 0;
    tspec[14] = 0;
    tspec[15] = 0;
    syscall(SYS_NANOSLEEP, &tspec[0], 0)
};

// ── the transfer ──────────────────────────────────────────────────────────
//
// TWO WAYS TO MOVE SAMPLES, AND WHY THE DEFAULT IS NOT THE OBVIOUS ONE.
//
//   writei    SNDRV_PCM_IOCTL_WRITEI_FRAMES is ALSA's own transfer: an ioctl
//             carrying a `struct snd_xferi { uframes result; void *buf; }`,
//             where `result` goes in as the frame count and comes back as the
//             frames actually written, and `buf` is a POINTER TO THE SAMPLES.
//             That pointer has to be stored as an integer inside the struct the
//             kernel reads, and **Y has no pointer-to-integer conversion** --
//             `let n: long = p` where p is a `*byte` is a compile error
//             (`expected long, got *byte`), and `&rec` on a record is a pointer
//             to the record's TYPE DESCRIPTOR rather than to its data, so a
//             record cannot stand in for the struct either.  Measured: with
//             the ioctl issued from C it writes (4 frames for 480 requested,
//             a textbook short write); issued from Y it answers -EFAULT,
//             because the struct the kernel reads holds zeros where the pointer
//             should be.  Both facts are in this comment because the obvious
//             reading of "ALSA's PCM API is a device file plus six ioctls" is
//             wrong by exactly one of them.
//
//   write(2)  plain write() on the same descriptor.  Measured to be the same
//             ring, not a side channel: after PREPARE the stream is PREPARED
//             with appl_ptr = 0; after write(2) of 480 frames the stream is
//             RUNNING with appl_ptr = 480 and avail = 1440; after two writes
//             appl_ptr = 960; and 60 ms later hw_ptr has advanced to 2640 while
//             appl_ptr is still 960, so the hardware really is consuming the
//             ring.  SNDRV_PCM_IOCTL_DRAIN then returns 0.
//
// write(2) is therefore the default, and --transfer=writei is there so the
// failure above can be reproduced on demand rather than taken on trust.

// A sink is "given a device token and a frame count, answer the frames it
// actually accepted, or a negative errno".  writei is the real one.  The
// property battery substitutes a scripted sink, which is the only way to test
// the short-write arithmetic on a machine with no sound card -- and, since a
// real device rarely short-writes on demand, the only way to test it at all.
//
// A `prep` is the same idea for SNDRV_PCM_IOCTL_PREPARE, and it has to be
// injectable too: the recovery from an underrun issues PREPARE, so a battery
// that used the real one would be calling PREPARE on whatever `dev` happened to
// be, and would be told ENOTTY and would never reach the recovery arithmetic
// it exists to check.  That is not hypothetical -- it is what the first run of
// this battery did, and it reported "recoveries 1, err -25 (EPIPE)" for what
// should have been two clean recoveries.
type Sink = (long, long) -> long;
type Prep = (long) -> long;

type Xfer = {
    ok: bool, frames_written: long, short_writes: long, recoveries: long,
    stalls: long, err: long, why: str
};

let pcm_bytes: [byte] = [];
let cursor: long = 0;

def xfer_load(b: [byte]) {
    pcm_bytes = b;
    cursor = 0;
    xfer.result = 0
};

// write2_sink(dev, frames): the transfer this program actually uses.  write(2)
// on a PCM descriptor answers BYTES, so it is converted to whole frames here,
// and a partial frame is dropped rather than handed on -- a half frame is not
// a thing the ring can hold.
def write2_sink(dev: long, frames: long) -> long {
    let n = frames * FRAME_BYTES;
    if (cursor + n > len(pcm_bytes)) { n = len(pcm_bytes) - cursor; };
    if (n < FRAME_BYTES) { return 0; };
    let w = syscall(1, dev, &pcm_bytes[cursor], n);
    if (w < 0) { return w; };
    if (w % FRAME_BYTES != 0) { w = w - w % FRAME_BYTES; };
    cursor = cursor + w;
    w / FRAME_BYTES
};

// writei_sink(dev, frames): ALSA's own transfer, kept because it is the
// canonical one and because --transfer=writei needs it.  It cannot succeed
// from Y; see the comment above for exactly why, and for the C measurement that
// the ioctl itself is fine.
def writei_sink(dev: long, frames: long) -> long {
    let avail = (len(pcm_bytes) - cursor) / 4;
    let want = if (frames > avail) { avail } else { frames };
    if (want <= 0) { return 0; };
    xfer.result = want;
    xfer.buf = &pcm_bytes[cursor];
    let rc = writei_ioctl(dev, &xfer);
    if (rc < 0) { return rc; };
    cursor = cursor + xfer.result * 4;
    xfer.result
};

// real_prep(dev): SNDRV_PCM_IOCTL_PREPARE on a real device.  The only recovery
// from an underrun: the stream is in XRUN state and nothing else moves it.
def real_prep(dev: long) -> long {
    syscall(16, dev, REQ_PREPARE, 0)
};

// real_drain(dev): SNDRV_PCM_IOCTL_DRAIN -- wait for the queued frames to be
// played out.  It needs a BLOCKING descriptor; see set_blocking.
def real_drain(dev: long) -> long {
    syscall(16, dev, REQ_DRAIN, 0)
};

// feed(dev, frames, sink, prep): push `frames` frames through `sink` and
// account for every one of them.
//
// The three things everybody gets wrong are all here, and all three are
// handled rather than assumed:
//   * writei answers FRAMES WRITTEN, which is routinely fewer than asked for.
//     A short write is progress, not an error; treating it as one stops
//     playback after the first period and is the classic first bug.
//   * a write of zero frames makes no progress, and looping on it for ever is
//     a hang -- so it is counted and given up on.
//   * -EPIPE means the device underran and the stream is in XRUN state; the
//     only recovery is PREPARE, and the frames in flight are lost.
def feed(dev: long, frames: long, sink: Sink, prep: Prep) -> Xfer {
    let out: Xfer = {
        ok: false, frames_written: 0, short_writes: 0, recoveries: 0,
        stalls: 0, err: 0, why: ""
    };
    if (frames <= 0) {
        out.ok = true;
        return out;
    };
    let left = frames;
    let guard = 0;
    // Termination, since there is no `break`: `left` falls by at least one on
    // every productive pass, and the stall and recovery counters are each
    // capped at 8, so the loop runs at most frames + 16 iterations whatever
    // the sink does.  That bound is the proof.
    while (left > 0 && guard < frames + 16) {
        guard = guard + 1;
        let got = sink(dev, left);
        if (got > 0) {
            if (got > left) { got = left; };
            out.frames_written = out.frames_written + got;
            if (got < left) { out.short_writes = out.short_writes + 1; };
            left = left - got;
        } else if (got == 0) {
            // A sink that answers zero frames has made no progress, and no
            // amount of waiting changes that, so this is given up on quickly.
            out.stalls = out.stalls + 1;
            if (out.stalls > 8) {
                out.err = 0 - 11;
                out.why = "the device accepted no frames 9 times";
                return out;
            };
        } else if (got == 0 - 11) {
            // EAGAIN: the ring is full.  This is NOT an error -- it is the
            // normal state of a device whose buffer is being consumed at the
            // sample rate, and the answer is to wait.  Measured: with a
            // 1920-frame ring, a blocking write(2) of 5760 frames answered
            // 1920 (a short write of what fitted) and the next one answered
            // -EAGAIN until the hardware had caught up.  Treating EAGAIN as
            // fatal stops playback after one period, which is the same bug as
            // treating a short write as fatal, one level down.
            out.stalls = out.stalls + 1;
            if (out.stalls > SLEEP_MAX_STALLS) {
                out.err = got;
                out.why = "the ring stayed full for 2 s (EAGAIN " +
                          tostring(out.stalls) + " times)";
                return out;
            };
            napms(2);
        } else if (got == 0 - 32) {
            out.recoveries = out.recoveries + 1;
            if (out.recoveries > 8) {
                out.err = got;
                out.why = "underran 9 times (EPIPE), giving up";
                return out;
            };
            let pr = prep(dev);
            if (pr < 0) {
                out.err = pr;
                out.why = "PREPARE after EPIPE: " + errno_name(pr);
                return out;
            };
        } else if (got == 0 - 86) {
            out.err = got;
            out.why = "stream suspended (ESTRPIPE); needs RESUME, not done here";
            return out;
        } else {
            out.err = got;
            out.why = "transfer: " + errno_name(got);
            return out;
        };
    };
    if (left > 0) {
        out.err = 0 - 11;
        out.why = "gave up with " + tostring(left) + " frame(s) unwritten";
        return out;
    };
    out.ok = true;
    out
};

export {
    REQ_INFO, REQ_HW_PARAMS, REQ_SW_PARAMS, REQ_PREPARE, REQ_DRAIN, REQ_DROP,
    REQ_WRITEI, SIZE_HW_PARAMS, SIZE_SW_PARAMS, SIZE_PCM_INFO, ALSA_TYPE,
    HW_PARAMS_DIR, HW_PARAMS_NR, SW_PARAMS_NR, INFO_NR, INFO_DIR,
    PREPARE_NR, DRAIN_NR, DROP_NR, WRITEI_NR, SIZE_WRITEI,
    PARAM_ACCESS, PARAM_FORMAT, PARAM_SUBFORMAT, PARAM_FIRST_INTERVAL,
    PARAM_SAMPLE_BITS, PARAM_FRAME_BITS, PARAM_CHANNELS, PARAM_RATE,
    PARAM_PERIOD_SIZE, PARAM_BUFFER_SIZE, PARAM_PERIOD_TIME, PARAM_BUFFER_TIME,
    PARAM_TICK_TIME, NINTERVAL, PERIODS,
    STRATEGY_FULL, STRATEGY_RATE, STRATEGY_MIN, NSTRATEGY,
    hw_pin, hw_set_interval, hw_integer_all, INTERVAL_INTEGER,
    ACCESS_RW_INTERLEAVED, FORMAT_S16_LE, SUBFORMAT_STD,
    HW_PARAMS_OFF_MASKS, HW_PARAMS_OFF_INTERVALS, HW_PARAMS_OFF_RMASK,
    INFO_OFF_STREAM, INFO_OFF_CARD, INFO_OFF_NAME, INFO_NAME_LEN,
    PC_STREAM_PLAYBACK, PC_STREAM_CAPTURE, SND_DIR,
    ioc, errno_name, open_dev, ioctl3, writei_ioctl, hw_negotiate, hw_fill,
    hw_ival,
    hw_mask_val, sw_setup, enumerate, is_playback_node, pick, pick_why,
    node_reset, nodes, nnodes, Node, info_str, infobuf,
    io_clear, io_query, io_stream, io_card, io_name, set_blocking, F_SETFL,
    SYS_FCNTL,
    feed, writei_sink, write2_sink, real_prep, real_drain, xfer_load,
    napms, SLEEP_MAX_STALLS,
    Sink, Prep, Xfer, Hw, FRAME_BYTES
};