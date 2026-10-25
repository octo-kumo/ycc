// ac97 -- the Intel ICH AC97 controller (qemu `-device AC97`, 8086:2415).
//
// ac97_put_frame, ac97_flush, ac97_hz and ac97_vra are additions used by dsp.y.
//
// The PCM-out engine plays a 32-entry buffer descriptor list.  Every data entry
// owns one page (1024 stereo frames, 21 ms at 48 kHz).  The write position is
// the STAGE entry, LVI + 1: samples collect there and the entry is committed
// (its length set, LVI moved onto it) when the page is full, or from the tick
// when the engine would otherwise run dry.  The engine never halts by itself:
// when no data is queued the tick appends short SILENCE entries (all pointing at
// one zero page) so an underrun is quiet, and after half a second of nothing the
// engine is stopped, the next commit restarts it from entry 0.  No interrupts
// are used: ac97_poll (from the 1 kHz tick) reads CIV and PICB.
import kernel;
import pci from "./pci.y";

const AC_PAGE = 4096;
// NABM (bus master) PCM-out box registers
const AC_BDBAR = 16;
const AC_CIV = 20;
const AC_LVI = 21;
const AC_SR = 22;
const AC_PICB = 24;
const AC_CR = 27;
const AC_GLOB_CNT = 44;
const AC_GLOB_STA = 48;

let ac97_ok = false;
let ac97_nam = 0;
let ac97_nabm = 0;
let ac97_bdl = 0;
let ac97_sil = 0;
let ac97_vra = false;
let ac97_rate = 48000;
let ac97_pages: [long] = [];
let ac97_lens: [long] = [];
let ac97_data: [long] = [];
let ac97_run = false;
let ac97_civ = 0;
let ac97_lvi = 0;
let ac97_stage = 0;
let ac97_stlen = 0;
let ac97_idle = 0;
let ac97_dq = 0;

/** Find and start the controller; false when there is none. */
def ac97_init() -> bool {
    let bdf = pci.pci_find(32902, 9237);
    if (bdf < 0) { return false; };
    pci.pci_enable_busmaster(bdf);
    ac97_nam = pci.pci_bar(bdf, 0);
    ac97_nabm = pci.pci_bar(bdf, 1);
    if (ac97_nam == 0 || ac97_nabm == 0) { return false; };
    // release the cold reset, wait for the primary codec
    kernel.outl(ac97_nabm + AC_GLOB_CNT, 2);
    let spin = 0;
    while (spin < 100000 && kernel.inl(ac97_nabm + AC_GLOB_STA) & 256 == 0) { spin = spin + 1; };
    if (spin >= 100000) { return false; };
    kernel.outw(ac97_nam, 0);
    // master, headphone, mono, PCM out: 0 dB, unmuted
    kernel.outw(ac97_nam + 2, 0);
    kernel.outw(ac97_nam + 4, 0);
    kernel.outw(ac97_nam + 6, 0);
    kernel.outw(ac97_nam + 24, 0);
    // variable rate audio, when the codec has it
    ac97_vra = false;
    if (kernel.inw(ac97_nam + 40) & 1 != 0) {
        kernel.outw(ac97_nam + 42, kernel.inw(ac97_nam + 42) | 1);
        ac97_vra = kernel.inw(ac97_nam + 42) & 1 != 0;
    };
    ac97_bdl = kernel.page_alloc();
    ac97_sil = kernel.page_alloc();
    if (ac97_bdl == 0 || ac97_sil == 0) { return false; };
    kernel.acct_add(kernel.ACCT_DEV, 2 * 4096 + 32 * 4096);
    ac97_pages = [];
    ac97_lens = [];
    ac97_data = [];
    let i = 0;
    while (i < 32) {
        let p = kernel.page_alloc();
        if (p == 0) { return false; };
        ac97_pages += p;
        ac97_lens += 0;
        ac97_data += 0;
        i = i + 1;
    };
    ac97_run = false;
    ac97_stage = 0;
    ac97_stlen = 0;
    ac97_rate = 48000;
    ac97_ok = true;
    true
};

/** Is there a controller. */
def ac97_present() -> bool { ac97_ok };

/** Does the codec take other rates than 48 kHz (variable rate audio). */
def ac97_vra_on() -> bool { ac97_vra };

/** The hardware rate in effect. */
def ac97_hz() -> long { ac97_rate };

/** Ask for `hz` samples/s: the rate in effect (48000 without VRA). */
def ac97_set_rate(hz: long) -> long {
    if (!ac97_ok) { return 48000; };
    if (!ac97_vra) { ac97_rate = 48000; return 48000; };
    let want = hz;
    if (want < 8000) { want = 8000; };
    if (want > 48000) { want = 48000; };
    if (want == ac97_rate) { return want; };
    // the codec reopens its voice on a rate change: do it with the engine stopped
    ac97_reset();
    kernel.outw(ac97_nam + 44, want);
    let got = kernel.inw(ac97_nam + 44);
    if (got < 8000 || got > 48000) { got = 48000; };
    ac97_rate = got;
    got
};

/** Valid entries: CIV .. LVI while the engine runs. */
def ac97_count() -> long {
    if (!ac97_run) { return 0; };
    ((ac97_lvi - ac97_civ) & 31) + 1
};

/** Room in the ring, in bytes. */
def ac97_free_bytes() -> long {
    if (!ac97_ok) { return 0; };
    let n = ac97_count();
    if (n > 30) { return 0; };
    (31 - n) * AC_PAGE - ac97_stlen
};

/** Data bytes queued: committed and not yet played, plus the stage. */
def ac97_queued_bytes() -> long { ac97_dq + ac97_stlen };

/** Add up the data in the entries CIV .. LVI (less what the playing one has played). */
def ac97_scan() -> void {
    let dq = 0;
    if (ac97_run) {
        let n = ac97_count();
        let i = 0;
        while (i < n) {
            let e = (ac97_civ + i) & 31;
            if (ac97_data[e] == 1) { dq = dq + ac97_lens[e]; };
            i = i + 1;
        };
        if (ac97_data[ac97_civ] == 1) {
            let played = ac97_lens[ac97_civ] - 2 * kernel.inw(ac97_nabm + AC_PICB);
            if (played > 0 && played <= ac97_lens[ac97_civ]) { dq = dq - played; };
        };
    };
    ac97_dq = dq;
};

/** Stop the engine and forget the ring. */
def ac97_reset() -> void {
    if (!ac97_ok) { return; };
    if (ac97_run) {
        kernel.outb(ac97_nabm + AC_CR, 0);
        kernel.outb(ac97_nabm + AC_CR, 2);
    };
    ac97_run = false;
    ac97_stage = 0;
    ac97_stlen = 0;
    ac97_idle = 0;
    ac97_dq = 0;
    ac97_civ = 0;
    ac97_lvi = 0;
};

/** Hand the stage entry to the engine (silence: a page of zeros); start it when stopped. */
def ac97_commit(data: long) -> void {
    let s = ac97_stage;
    let e = ac97_bdl + s * 8;
    let addr = ac97_sil;
    if (data == 1) { addr = ac97_pages[s]; };
    kernel.poke32(e, addr);
    kernel.poke32(e + 4, ac97_stlen / 2);
    ac97_lens[s] = ac97_stlen;
    ac97_data[s] = data;
    if (!ac97_run) {
        // registers reset: CIV = 0, which is where the stage is while stopped
        kernel.outb(ac97_nabm + AC_CR, 2);
        let spin = 0;
        while (spin < 100000 && kernel.inb(ac97_nabm + AC_CR) & 2 != 0) { spin = spin + 1; };
        kernel.outl(ac97_nabm + AC_BDBAR, ac97_bdl);
        kernel.outw(ac97_nabm + AC_SR, 28);
        kernel.outb(ac97_nabm + AC_LVI, s);
        kernel.outb(ac97_nabm + AC_CR, 1);
        ac97_run = true;
        ac97_civ = 0;
    } else {
        kernel.outb(ac97_nabm + AC_LVI, s);
    };
    ac97_lvi = s;
    ac97_stage = (s + 1) & 31;
    if (data == 1) { ac97_dq = ac97_dq + ac97_stlen; };
    ac97_stlen = 0;
    ac97_idle = 0;
};

/** Queue one stereo frame (two s16 samples): false when the ring is full. */
def ac97_put_frame(l: long, r: long) -> bool {
    if (!ac97_ok) { return false; };
    if (ac97_run && ac97_count() > 30) { return false; };
    kernel.poke32(ac97_pages[ac97_stage] + ac97_stlen, (l & 65535) | ((r & 65535) << 16));
    ac97_stlen = ac97_stlen + 4;
    if (ac97_stlen == AC_PAGE) { ac97_commit(1); };
    true
};

/** Queue up to `len` bytes of s16le stereo PCM from user VA `buf`: bytes taken. */
def ac97_write_pcm(buf: long, len: long) -> long {
    if (!ac97_ok) { return 0; };
    let done = 0;
    let more = true;
    while (more && done + 4 <= len) {
        if (ac97_run && ac97_count() > 30) {
            more = false;
        } else {
            let room = AC_PAGE - ac97_stlen;
            let n = len - done;
            n = n - (n & 3);
            if (n > room) { n = room; };
            kernel.kcopy(kernel.DIRECT_BASE + ac97_pages[ac97_stage] + ac97_stlen, buf + done, n);
            ac97_stlen = ac97_stlen + n;
            done = done + n;
            if (ac97_stlen == AC_PAGE) { ac97_commit(1); };
        };
    };
    done
};

/** Commit a partly filled stage entry so it plays; true when nothing is left in it. */
def ac97_flush() -> bool {
    if (!ac97_ok || ac97_stlen == 0) { return true; };
    if (ac97_run && ac97_count() > 30) { return false; };
    ac97_commit(1);
    true
};

/** From the timer tick: advance the ring. */
def ac97_poll() -> void {
    if (!ac97_ok) { return; };
    if (!ac97_run) {
        if (ac97_stlen > 0) { ac97_commit(1); };
        return;
    };
    if (kernel.inw(ac97_nabm + AC_SR) & 1 != 0) {
        // the engine ran dry and halted (a tick came late): start over from
        // entry 0, carrying the stage's samples across
        let st = ac97_stlen;
        let from = ac97_pages[ac97_stage];
        ac97_reset();
        if (st > 0) {
            if (from != ac97_pages[0]) { kernel.kcopy(kernel.DIRECT_BASE + ac97_pages[0], kernel.DIRECT_BASE + from, st); };
            ac97_stlen = st;
        };
        return;
    };
    ac97_civ = kernel.inb(ac97_nabm + AC_CIV) & 31;
    ac97_scan();
    // bytes the engine still has before it runs dry
    let ahead = 0;
    let n = ac97_count();
    let i = 0;
    while (i < n) {
        ahead = ahead + ac97_lens[(ac97_civ + i) & 31];
        i = i + 1;
    };
    let played = ac97_lens[ac97_civ] - 2 * kernel.inw(ac97_nabm + AC_PICB);
    if (played > 0 && played <= ac97_lens[ac97_civ]) { ahead = ahead - played; };
    if (ac97_dq == 0 && ac97_stlen == 0) {
        ac97_idle = ac97_idle + 1;
        if (ac97_idle > 500) {
            ac97_reset();
            return;
        };
    } else {
        ac97_idle = 0;
    };
    if (ahead < 8192 && n <= 30) {
        if (ac97_stlen > 0) {
            ac97_commit(1);
        } else {
            // underrun: silence
            let keep = ac97_idle;
            ac97_stlen = AC_PAGE;
            ac97_commit(0);
            ac97_idle = keep;
        };
    };
};
