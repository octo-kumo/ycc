// tty -- the serial console as a terminal: receive ring, termios, job control.
//
// Input.  COM1's receiver interrupt (IRQ 4, `tty_on_rx`) drains the UART into a
// 4096-byte ring.  Three counters run over the ring: `tty_head` (the reader),
// `tty_tail` (end of the COMMITTED bytes: what a read may take) and `tty_edit`
// (end of the line being typed, canonical mode only; tail <= edit).  In raw mode
// every byte is committed as it arrives.  A parallel flag array marks a byte
// that ends a canonical read (1: newline / EOL / the last byte before a ^D) and
// the EOF token a ^D on an empty line leaves (2: no data, one read returns 0).
//
// Termios is Linux's `struct termios` (36 bytes: four u32 flag words, c_line, and
// c_cc[19]; TCGETS2/TCSETS2 add two u32 speeds).  The boot state is "sane":
// ICANON ECHO ISIG, ICRNL, OPOST|ONLCR.  Read blocking uses block_restart on
// the channel fdt_chan(TTY, 0): a read that cannot finish records its VTIME
// deadline per task slot and is re-executed when woken.
//
// Job control.  `tty_fg` is the foreground process group (TIOCSPGRP).  While it
// is unset, ^C goes to the group of the task that read the tty last.
//
// The UART receive interrupt is armed lazily (the first tty operation), so a
// kernel whose fd 0 still goes through kernel.y's polling read (before fdt
// routes the console here) is not starved of bytes.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import proc from "./proc.y";
import time from "./time.y";
import console from "./console.y";

const TTY_RING = 4096;
const TTY_MASK = 4095;

// c_lflag
const TTY_L_ISIG = 1;
const TTY_L_ICANON = 2;
const TTY_L_ECHO = 8;
const TTY_L_ECHOE = 16;
const TTY_L_ECHOK = 32;
const TTY_L_ECHONL = 64;
const TTY_L_NOFLSH = 128;
const TTY_L_ECHOCTL = 512;
const TTY_L_ECHOKE = 2048;
const TTY_L_IEXTEN = 32768;
// c_iflag
const TTY_I_ISTRIP = 32;
const TTY_I_INLCR = 64;
const TTY_I_IGNCR = 128;
const TTY_I_ICRNL = 256;
const TTY_I_IXON = 1024;
// c_oflag
const TTY_O_OPOST = 1;
const TTY_O_ONLCR = 4;
// c_cc indexes
const TTY_V_INTR = 0;
const TTY_V_QUIT = 1;
const TTY_V_ERASE = 2;
const TTY_V_KILL = 3;
const TTY_V_EOF = 4;
const TTY_V_TIME = 5;
const TTY_V_MIN = 6;
const TTY_V_START = 8;
const TTY_V_STOP = 9;
const TTY_V_SUSP = 10;
const TTY_V_EOL = 11;
const TTY_V_WERASE = 14;
const TTY_V_LNEXT = 15;

let tty_rows = 24;
let tty_cols = 80;
let tty_armed = false;

let tty_iflag = 0;
let tty_oflag = 0;
let tty_cflag = 0;
let tty_lflag = 0;
let tty_line = 0;
let tty_cc: [byte; 19] = [0; 19];

let tty_q: [byte; 4096] = [0; 4096];
let tty_qf: [byte; 4096] = [0; 4096];
let tty_head = 0;
let tty_tail = 0;
let tty_edit = 0;
let tty_lnext = false;

let tty_fg = 0;
let tty_last_pgid = 0;

// per task slot: the VTIME deadline of a read in progress (0 none), and the
// committed byte count the inter-byte timer last saw
let tty_rd_dl: [long] = [];
let tty_rd_seen: [long] = [];

/** The Linux defaults (what `stty sane` sets). */
def tty_set_sane() -> void {
    tty_iflag = 256 | 1024;
    tty_oflag = 1 | 4;
    tty_cflag = 15 | 48 | 128 | 1024;
    tty_lflag = 1 | 2 | 8 | 16 | 32 | 512 | 2048 | 32768;
    tty_line = 0;
    tty_cc[TTY_V_INTR] = 3;
    tty_cc[TTY_V_QUIT] = 28;
    tty_cc[TTY_V_ERASE] = 127;
    tty_cc[TTY_V_KILL] = 21;
    tty_cc[TTY_V_EOF] = 4;
    tty_cc[TTY_V_TIME] = 0;
    tty_cc[TTY_V_MIN] = 1;
    tty_cc[7] = 0;
    tty_cc[TTY_V_START] = 17;
    tty_cc[TTY_V_STOP] = 19;
    tty_cc[TTY_V_SUSP] = 26;
    tty_cc[TTY_V_EOL] = 0;
    tty_cc[12] = 18;
    tty_cc[13] = 15;
    tty_cc[TTY_V_WERASE] = 23;
    tty_cc[TTY_V_LNEXT] = 22;
    tty_cc[16] = 0;
    tty_cc[17] = 0;
    tty_cc[18] = 0;
};

/** Boot: the size from the kernel command line (0 = keep the default). */
def tty_init(rows: long, cols: long) -> void {
    tty_set_size(rows, cols);
    tty_set_sane();
    tty_head = 0;
    tty_tail = 0;
    tty_edit = 0;
};

def tty_set_size(rows: long, cols: long) -> void {
    if (rows > 0) { tty_rows = rows; };
    if (cols > 0) { tty_cols = cols; };
};

def tty_get_rows() -> long { tty_rows };
def tty_get_cols() -> long { tty_cols };

/** Turn the UART's receive interrupt on (once). */
def tty_arm() -> void {
    if (!tty_armed) {
        tty_armed = true;
        kernel.serial_irq_on();
    };
};

// ── output ──────────────────────────────────────────────────────────────
/** One byte to the line, with the output processing (ONLCR). */
def tty_out(c: long) -> void {
    if (c == 10 && (tty_oflag & TTY_O_OPOST) != 0 && (tty_oflag & TTY_O_ONLCR) != 0) { console.con_putc(13); };
    console.con_putc(c);
};

/** "\b \b": rub one column out. */
def tty_rub() -> void {
    tty_out(8);
    tty_out(32);
    tty_out(8);
};

/** The echo of a typed byte `c`: itself, or ^X for a control character. */
def tty_echo_char(c: long) -> void {
    if (c == 10 || c == 9) {
        tty_out(c);
    } else if (c < 32 && (tty_lflag & TTY_L_ECHOCTL) != 0) {
        tty_out(94);
        tty_out(c + 64);
    } else if (c == 127 && (tty_lflag & TTY_L_ECHOCTL) != 0) {
        tty_out(94);
        tty_out(63);
    } else {
        tty_out(c);
    };
};

/** Columns the echo of `c` took. */
def tty_echo_width(c: long) -> long {
    if (c == 9 || c == 10) { return 1; };
    if ((c < 32 || c == 127) && (tty_lflag & TTY_L_ECHOCTL) != 0) { return 2; };
    1
};

// ── input ───────────────────────────────────────────────────────────────
def tty_used() -> long { tty_edit - tty_head };

/** Append byte `c` to the ring with flag `f` (dropped when the ring is full). */
def tty_push(c: long, f: long) -> bool {
    if (tty_used() >= TTY_RING - 1) { return false; };
    let i = tty_edit & TTY_MASK;
    tty_q[i] = c & 255;
    tty_qf[i] = f;
    tty_edit = tty_edit + 1;
    true
};

/** Everything typed so far is readable. */
def tty_commit() -> void {
    tty_tail = tty_edit;
    fdt.fdt_notify(kconst.TTY, 0);
};

/** Throw away unread input (a signal, TCFLSH, TCSETSF). */
def tty_flush_in() -> void {
    tty_tail = tty_head;
    tty_edit = tty_head;
};

def tty_signal(sig: long) -> void {
    let g = tty_fg;
    if (g == 0) { g = tty_last_pgid; };
    if (g > 0) { proc.proc_signal_group(g, sig); };
};

/** Erase one character off the line being edited. */
def tty_erase() -> void {
    if (tty_edit > tty_tail) {
        let c = tty_q[(tty_edit - 1) & TTY_MASK];
        tty_edit = tty_edit - 1;
        if ((tty_lflag & TTY_L_ECHO) != 0 && (tty_lflag & TTY_L_ECHOE) != 0) {
            let w = tty_echo_width(c);
            while (w > 0) { tty_rub(); w = w - 1; };
        };
    };
};

/** Kill the whole line being edited. */
def tty_kill() -> void {
    if ((tty_lflag & TTY_L_ECHO) != 0) {
        if ((tty_lflag & TTY_L_ECHOKE) != 0 || (tty_lflag & TTY_L_ECHOE) != 0) {
            while (tty_edit > tty_tail) {
                let c = tty_q[(tty_edit - 1) & TTY_MASK];
                tty_edit = tty_edit - 1;
                let w = tty_echo_width(c);
                while (w > 0) { tty_rub(); w = w - 1; };
            };
        } else {
            tty_edit = tty_tail;
            if ((tty_lflag & TTY_L_ECHOK) != 0) { tty_out(10); };
        };
    } else {
        tty_edit = tty_tail;
    };
};

/** ^W: erase the word before the cursor. */
def tty_werase() -> void {
    while (tty_edit > tty_tail && tty_q[(tty_edit - 1) & TTY_MASK] == 32) { tty_erase(); };
    while (tty_edit > tty_tail && tty_q[(tty_edit - 1) & TTY_MASK] != 32) { tty_erase(); };
};

/** The terminal's size changed: SIGWINCH to the foreground group. */
def tty_winch() -> void { tty_signal(28); };

/** One byte `c0` arrived from the line: the whole input discipline. */
def tty_input(c0: long) -> void {
    let c = c0 & 255;
    if ((tty_iflag & TTY_I_ISTRIP) != 0) { c = c & 127; };
    let canon = (tty_lflag & TTY_L_ICANON) != 0;
    if (tty_lnext) {
        // ^V: the next byte goes in as it is
        tty_lnext = false;
        if (tty_push(c, 0)) {
            if ((tty_lflag & TTY_L_ECHO) != 0) { tty_echo_char(c); };
            if (!canon) { tty_commit(); };
        };
        return;
    };
    if (c == 13) {
        if ((tty_iflag & TTY_I_IGNCR) != 0) { return; };
        if ((tty_iflag & TTY_I_ICRNL) != 0) { c = 10; };
    } else if (c == 10 && (tty_iflag & TTY_I_INLCR) != 0) {
        c = 13;
    };
    if ((tty_lflag & TTY_L_ISIG) != 0) {
        let sig = 0;
        if (c == tty_cc[TTY_V_INTR] && c != 0) { sig = 2; }
        else if (c == tty_cc[TTY_V_QUIT] && c != 0) { sig = 3; }
        else if (c == tty_cc[TTY_V_SUSP] && c != 0) { sig = 20; };
        if (sig != 0) {
            if ((tty_lflag & TTY_L_NOFLSH) == 0) { tty_flush_in(); };
            if ((tty_lflag & TTY_L_ECHO) != 0) { tty_echo_char(c); };
            tty_signal(sig);
            return;
        };
    };
    if ((tty_iflag & TTY_I_IXON) != 0 && c != 0 && (c == tty_cc[TTY_V_START] || c == tty_cc[TTY_V_STOP])) { return; };
    if (!canon) {
        if (tty_push(c, 0)) {
            if ((tty_lflag & TTY_L_ECHO) != 0) { tty_echo_char(c); };
            tty_commit();
        };
        return;
    };
    // canonical editing
    if (c == 127 || c == 8 || (c == tty_cc[TTY_V_ERASE] && c != 0)) { tty_erase(); return; };
    if (c == tty_cc[TTY_V_KILL] && c != 0) { tty_kill(); return; };
    if ((tty_lflag & TTY_L_IEXTEN) != 0) {
        if (c == tty_cc[TTY_V_WERASE] && c != 0) { tty_werase(); return; };
        if (c == tty_cc[TTY_V_LNEXT] && c != 0) {
            tty_lnext = true;
            if ((tty_lflag & TTY_L_ECHO) != 0) { tty_out(94); tty_out(8); };
            return;
        };
    };
    if (c == tty_cc[TTY_V_EOF] && c != 0) {
        if (tty_edit > tty_tail) {
            // the partial line is readable as it stands
            tty_qf[(tty_edit - 1) & TTY_MASK] = 1;
        } else {
            tty_push(0, 2);
        };
        tty_commit();
        return;
    };
    if (c == 10 || (c == tty_cc[TTY_V_EOL] && c != 0)) {
        if (tty_push(c, 1)) {
            if ((tty_lflag & TTY_L_ECHO) != 0 || (tty_lflag & TTY_L_ECHONL) != 0) { tty_out(10); };
            tty_commit();
        };
        return;
    };
    if (tty_used() < TTY_RING - 2 && tty_push(c, 0)) {
        if ((tty_lflag & TTY_L_ECHO) != 0) { tty_echo_char(c); };
    };
};

/** IRQ 4: bytes arrived on COM1. */
def tty_on_rx() -> void {
    let n = 0;
    while ((kernel.inb(1021) & 1) != 0 && n < 256) {
        tty_input(kernel.inb(1016));
        n = n + 1;
    };
};

// ── the file operations ─────────────────────────────────────────────────
/** Open /dev/tty (or the console): the obj (0: there is one console). */
def tty_open(flags: long) -> long {
    tty_arm();
    0
};

def tty_slot_grow(slot: long) -> void {
    while (len(tty_rd_dl) <= slot) {
        tty_rd_dl += 0;
        tty_rd_seen += 0;
    };
};

/** A slot starts or ends a task: forget the previous one's read timer. */
def tty_on_task(slot: long) -> void {
    tty_slot_grow(slot);
    tty_rd_dl[slot] = 0;
    tty_rd_seen[slot] = 0;
};

/** Copy up to `n` committed bytes to the user buffer; canonical stops after a line. */
def tty_take(buf: long, n: long, canon: bool) -> long {
    let k = 0;
    let stop = false;
    while (k < n && tty_head < tty_tail && !stop) {
        let i = tty_head & TTY_MASK;
        let f = tty_qf[i];
        if (f == 2) {
            if (k == 0) { tty_head = tty_head + 1; };
            stop = true;
        } else {
            kernel.poke_va8(buf + k, tty_q[i]);
            k = k + 1;
            tty_head = tty_head + 1;
            if (canon && f == 1) { stop = true; };
        };
    };
    k
};

def tty_read(obj: long, buf: long, len: long, flags: long) -> long {
    tty_arm();
    if (len <= 0) { return 0; };
    if (!kernel.user_ok(buf, len)) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    tty_slot_grow(slot);
    tty_last_pgid = proc.proc_pgid(slot);
    let chan = fdt.fdt_chan(kconst.TTY, 0);
    let nonblock = (flags & kconst.O_NONBLOCK) != 0;
    let avail = tty_tail - tty_head;
    if ((tty_lflag & TTY_L_ICANON) != 0) {
        if (avail == 0) {
            if (nonblock) { return kconst.EAGAIN; };
            return kernel.block_restart(chan, 0);
        };
        return tty_take(buf, len, true);
    };
    let vmin = tty_cc[TTY_V_MIN];
    let vtime = tty_cc[TTY_V_TIME];
    let want = vmin;
    if (want > len) { want = len; };
    if (vmin == 0 && vtime == 0) {
        return tty_take(buf, len, false);
    };
    let now = time.now_us();
    if (tty_rd_dl[slot] != 0 && now - tty_rd_dl[slot] > 1000000) { tty_rd_dl[slot] = 0; tty_rd_seen[slot] = 0; };
    if (vmin == 0) {
        // VMIN=0, VTIME>0: a byte, or VTIME tenths of a second
        if (avail > 0) {
            tty_rd_dl[slot] = 0;
            return tty_take(buf, len, false);
        };
        if (nonblock) { return 0; };
        if (tty_rd_dl[slot] == 0) {
            tty_rd_dl[slot] = now + vtime * 100000;
        } else if (now >= tty_rd_dl[slot]) {
            tty_rd_dl[slot] = 0;
            return 0;
        };
        return kernel.block_restart(chan, tty_rd_dl[slot]);
    };
    if (avail >= want) {
        tty_rd_dl[slot] = 0;
        tty_rd_seen[slot] = 0;
        return tty_take(buf, len, false);
    };
    if (nonblock) { return kconst.EAGAIN; };
    if (vtime == 0 || avail == 0) {
        // no timer until the first byte (VMIN>0): wait for bytes
        tty_rd_dl[slot] = 0;
        tty_rd_seen[slot] = avail;
        return kernel.block_restart(chan, 0);
    };
    // VMIN>0, VTIME>0: the inter-byte timer restarts with every byte
    if (avail != tty_rd_seen[slot] || tty_rd_dl[slot] == 0) {
        tty_rd_seen[slot] = avail;
        tty_rd_dl[slot] = now + vtime * 100000;
    } else if (now >= tty_rd_dl[slot]) {
        tty_rd_dl[slot] = 0;
        tty_rd_seen[slot] = 0;
        return tty_take(buf, len, false);
    };
    kernel.block_restart(chan, tty_rd_dl[slot])
};

def tty_write(obj: long, buf: long, len: long, flags: long) -> long {
    tty_arm();
    if (len <= 0) { return 0; };
    if (!kernel.user_ok(buf, len)) { return kconst.EFAULT; };
    let i = 0;
    while (i < len) {
        tty_out(kernel.peek_va8(buf + i));
        i = i + 1;
    };
    let rep = console.con_take_reply();
    let k = 0;
    while (k < rep.length) {
        tty_input(rep[k]);
        k = k + 1;
    };
    len
};

def tty_u32_at(p: long) -> long {
    kernel.peek_va8(p) | (kernel.peek_va8(p + 1) << 8) | (kernel.peek_va8(p + 2) << 16) | (kernel.peek_va8(p + 3) << 24)
};

/** TCGETS / TCGETS2: the termios at user address `arg`. */
def tty_get_termios(arg: long, ext: bool) -> long {
    let size = 36;
    if (ext) { size = 44; };
    if (!kernel.user_ok(arg, size)) { return kconst.EFAULT; };
    kernel.poke_va32(arg, tty_iflag);
    kernel.poke_va32(arg + 4, tty_oflag);
    kernel.poke_va32(arg + 8, tty_cflag);
    kernel.poke_va32(arg + 12, tty_lflag);
    kernel.poke_va8(arg + 16, tty_line);
    let i = 0;
    while (i < 19) { kernel.poke_va8(arg + 17 + i, tty_cc[i]); i = i + 1; };
    if (ext) {
        kernel.poke_va32(arg + 36, 38400);
        kernel.poke_va32(arg + 40, 38400);
    };
    0
};

/** TCSETS*: install the termios at `arg`; `flush` drops unread input first. */
def tty_set_termios(arg: long, ext: bool, flush: bool) -> long {
    let size = 36;
    if (ext) { size = 44; };
    if (!kernel.user_ok(arg, size)) { return kconst.EFAULT; };
    let was_canon = (tty_lflag & TTY_L_ICANON) != 0;
    if (flush) { tty_flush_in(); };
    tty_iflag = tty_u32_at(arg);
    tty_oflag = tty_u32_at(arg + 4);
    tty_cflag = tty_u32_at(arg + 8);
    tty_lflag = tty_u32_at(arg + 12);
    tty_line = kernel.peek_va8(arg + 16);
    let i = 0;
    while (i < 19) { tty_cc[i] = kernel.peek_va8(arg + 17 + i); i = i + 1; };
    if (was_canon && (tty_lflag & TTY_L_ICANON) == 0) {
        // leaving canonical mode: a half-typed line becomes readable
        tty_commit();
    } else if (!was_canon && (tty_lflag & TTY_L_ICANON) != 0) {
        tty_lnext = false;
    };
    // readers re-evaluate VMIN/VTIME
    fdt.fdt_notify(kconst.TTY, 0);
    0
};

def tty_put_int(arg: long, v: long) -> long {
    if (!kernel.user_ok(arg, 4)) { return kconst.EFAULT; };
    kernel.poke_va32(arg, v);
    0
};

def tty_ioctl(obj: long, req: long, arg: long) -> long {
    tty_arm();
    if (req == 21505) { return tty_get_termios(arg, false); };
    if (req == 21506 || req == 21507) { return tty_set_termios(arg, false, false); };
    if (req == 21508) { return tty_set_termios(arg, false, true); };
    if (req == 2150388778) { return tty_get_termios(arg, true); };
    if (req == 1076646955 || req == 1076646956) { return tty_set_termios(arg, true, false); };
    if (req == 1076646957) { return tty_set_termios(arg, true, true); };
    if (req == 21523) {
        // TIOCGWINSZ
        if (!kernel.user_ok(arg, 8)) { return kconst.EFAULT; };
        kernel.poke_va32(arg, (tty_cols << 16) | tty_rows);
        kernel.poke_va32(arg + 4, 0);
        return 0;
    };
    if (req == 21524) {
        // TIOCSWINSZ
        if (!kernel.user_ok(arg, 8)) { return kconst.EFAULT; };
        let r = kernel.peek_va8(arg) | (kernel.peek_va8(arg + 1) << 8);
        let c = kernel.peek_va8(arg + 2) | (kernel.peek_va8(arg + 3) << 8);
        if (r != tty_rows || c != tty_cols) {
            tty_rows = r;
            tty_cols = c;
            tty_signal(28);
        };
        return 0;
    };
    if (req == 21519) {
        // TIOCGPGRP
        let g = tty_fg;
        if (g == 0) { g = proc.proc_pgid(kernel.task_slot()); };
        return tty_put_int(arg, g);
    };
    if (req == 21520) {
        // TIOCSPGRP
        if (!kernel.user_ok(arg, 4)) { return kconst.EFAULT; };
        let g = tty_u32_at(arg);
        if (g <= 0) { return kconst.EINVAL; };
        tty_fg = g;
        return 0;
    };
    if (req == 21545) { return tty_put_int(arg, proc.proc_sid(kernel.task_slot())); };
    if (req == 21531) {
        // FIONREAD
        let n = 0;
        let i = tty_head;
        while (i < tty_tail) {
            if (tty_qf[i & TTY_MASK] != 2) { n = n + 1; };
            i = i + 1;
        };
        return tty_put_int(arg, n);
    };
    if (req == 21521) {
        // TIOCOUTQ
        return tty_put_int(arg, 0);
    };
    if (req == 21515) {
        // TCFLSH: 0 input, 1 output, 2 both
        if (arg == 0 || arg == 2) { tty_flush_in(); };
        return 0;
    };
    // TIOCSCTTY, TIOCNOTTY, TCSBRK, TCXONC: accepted, nothing to do
    if (req == 21518 || req == 21538 || req == 21513 || req == 21514) { return 0; };
    kconst.ENOTTY
};

def tty_poll(obj: long, events: long) -> long {
    tty_arm();
    let r = 0;
    if ((events & kconst.POLLIN) != 0 && tty_tail > tty_head) { r = r | kconst.POLLIN; };
    if ((events & kconst.POLLOUT) != 0) { r = r | kconst.POLLOUT; };
    r
};

def tty_close(obj: long) -> long { 0 };
