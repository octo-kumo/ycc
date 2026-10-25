// kmon -- the GUI's resource monitor (F3): the machine's and the kernel's counters, redrawn twice a second.
//
// `sample()` asks the kernel for a snapshot (FB_STATS, kernel/kstat.y has the layout) and turns the
// counters into rates against the previous one; `draw()` paints the panel: CPU load and its history,
// memory split into who holds it, the kernel's activity per second, the busiest system calls, the
// display, and a table of every task with its share of the CPU and its resident memory. The memory
// section is the whole of RAM, each byte in one place (`mem_calc`): user pages, page tables, the kernel's
// heap (used and reserved), framebuffers, stacks, pipes and device rings, the image and filesystem, pages
// freed and waiting, and what was never touched; below it, the heap of the process that draws the panel
// (`memstat`).
import gfx;
import memstat;

const FB_STATS = 17924;
const HEADER = 64;
const NHIST = 72;
const BUFSZ = 65536;

let fd = 0 - 1;
let buf = 0;
let have = false;
// the latest snapshot's header and the one before it
let cur: [long; 64] = [0; 64];
let prev: [long; 64] = [0; 64];
let ntask = 0;
// the task rows of the latest snapshot: pid, ppid, state, ticks, pages, thread, name0, name1
let t_pid: [long; 96] = [0; 96];
let t_ppid: [long; 96] = [0; 96];
let t_state: [long; 96] = [0; 96];
let t_ticks: [long; 96] = [0; 96];
let t_pages: [long; 96] = [0; 96];
let t_thread: [long; 96] = [0; 96];
let t_name: [str] = [];
let t_w0: [long; 96] = [0; 96];
let t_w1: [long; 96] = [0; 96];
let t_cpu: [long; 96] = [0; 96];
// the previous rows' ticks by pid, to take the difference
let p_pid: [long; 96] = [0; 96];
let p_ticks: [long; 96] = [0; 96];
let pn = 0;
// RAM by owner (mem_calc), in bytes, in the order of SEG_NAME
const NSEG = 11;
let seg: [long] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
// the sampling process's own heap, and how much it handed out in the last interval
let heap_prev = 0;
let heap_rate = 0;
let census: [long] = [];
// derived per-interval figures
let dt_us = 0;
let cpu_x10 = 0;           // CPU busy, tenths of a percent
let hist_cpu: [long] = [];
let hist_sys: [long] = [];
let hist_n = 0;
let samples = 0;
let top_sys = 0;

def r64(a: long, i: long) -> long {
    let q: *long = ptr_from(a);
    *(q + i)
};

/** Open nothing itself: the GUI hands over its /dev/fb0 descriptor. */
def init(fbfd: long) -> bool {
    fd = fbfd;
    buf = gfx.alloc(BUFSZ);
    let k = 0;
    while (k < NHIST) { hist_cpu += 0; hist_sys += 0; k = k + 1; };
    buf != 0
};

def name_of(w0: long, w1: long) -> str {
    let s = "";
    let i = 0;
    while (i < 16) {
        let w = if (i < 8) { w0 } else { w1 };
        let c = (w >> ((i & 7) * 8)) & 255;
        if (c != 0) { s += chr(c); } else { i = 16; };
        i = i + 1;
    };
    s
};

def prev_ticks(pid: long) -> long {
    let i = 0;
    while (i < pn) {
        if (p_pid[i] == pid) { return p_ticks[i]; };
        i = i + 1;
    };
    0 - 1
};

/** Take a snapshot; false when the kernel would not give one. */
def sample() -> bool {
    if (buf == 0) { return false; };
    let arg = buf + BUFSZ - 16;
    let q: *long = ptr_from(arg);
    *q = buf;
    *(q + 1) = BUFSZ - 64;
    if (syscall(16, fd, FB_STATS, arg) <= 0) { return false; };
    let i = 0;
    while (i < 64) {
        prev[i] = cur[i];
        cur[i] = r64(buf, i);
        i = i + 1;
    };
    // remember the old rows
    pn = ntask;
    i = 0;
    while (i < pn) { p_pid[i] = t_pid[i]; p_ticks[i] = t_ticks[i]; i = i + 1; };
    ntask = gfx.min(cur[26], 96);
    let row = cur[27];
    let dtk = cur[2] - prev[2];
    i = 0;
    while (i < ntask) {
        let b = HEADER + i * row;
        t_pid[i] = r64(buf, b);
        t_ppid[i] = r64(buf, b + 1);
        t_state[i] = r64(buf, b + 2);
        t_ticks[i] = r64(buf, b + 3);
        t_pages[i] = r64(buf, b + 4);
        t_thread[i] = r64(buf, b + 5);
        // the name is rebuilt only when its bytes changed: a string a sample is garbage for the collector
        let w0 = r64(buf, b + 6);
        let w1 = r64(buf, b + 7);
        if (i >= len(t_name)) { t_name += name_of(w0, w1); } else if (w0 != t_w0[i] || w1 != t_w1[i]) { t_name[i] = name_of(w0, w1); };
        t_w0[i] = w0;
        t_w1[i] = w1;
        let pt = prev_ticks(t_pid[i]);
        t_cpu[i] = if (have && pt >= 0 && dtk > 0) { (t_ticks[i] - pt) * 1000 / dtk } else { 0 };
        i = i + 1;
    };
    dt_us = cur[1] - prev[1];
    if (have && dtk > 0) {
        cpu_x10 = gfx.clamp((dtk - (cur[3] - prev[3])) * 1000 / dtk, 0, 1000);
    };
    if (have) {
        // history, oldest first
        let k = 0;
        while (k + 1 < NHIST) { hist_cpu[k] = hist_cpu[k + 1]; hist_sys[k] = hist_sys[k + 1]; k = k + 1; };
        hist_cpu[NHIST - 1] = cpu_x10;
        hist_sys[NHIST - 1] = rate(4);
        if (hist_n < NHIST) { hist_n = hist_n + 1; };
    };
    mem_calc();
    let hu = heap_used();
    if (have && dt_us > 0) { heap_rate = gfx.max(hu - heap_prev, 0) * 1000000 / dt_us; };
    heap_prev = hu;
    census = memstat.census();
    have = true;
    samples = samples + 1;
    true
};

const SEG_USER = 0;
const SEG_PTAB = 1;
const SEG_KHEAP = 2;
const SEG_KRES = 3;
const SEG_FB = 4;
const SEG_STACK = 5;
const SEG_DEV = 6;
const SEG_KOTHER = 7;
const SEG_IMAGE = 8;
const SEG_LOW = 9;
const SEG_RECYC = 10;

/** Split RAM by owner from the latest snapshot. What the kernel tags (framebuffers, stacks, pipes, device
rings) and what a walk of the address spaces finds (user pages, page tables) is exact; "other kernel" is
what is left of the page region, and "low memory" the first MiB plus alignment gaps. */
def mem_calc() -> void {
    let total = cur[7];
    let user = cur[29] * 4096;
    let ptab = cur[42] * 4096;
    let hu = cur[11];
    let hres = gfx.max(cur[10] - hu, 0);
    let pd = cur[45] + cur[46];
    let carved = cur[47];
    let tracked = user + ptab + cur[43] + cur[44] + pd + cur[9];
    seg[SEG_USER] = user;
    seg[SEG_PTAB] = ptab;
    seg[SEG_KHEAP] = hu;
    seg[SEG_KRES] = hres;
    seg[SEG_FB] = cur[43];
    seg[SEG_STACK] = cur[44];
    seg[SEG_DEV] = pd;
    seg[SEG_KOTHER] = gfx.max(carved - tracked, 0);
    seg[SEG_IMAGE] = cur[30] + cur[31];
    seg[SEG_RECYC] = cur[9];
    seg[SEG_LOW] = gfx.max(total - cur[8] - cur[30] - cur[31] - cur[10] - carved, 0);
};

/** Header counter `w` per second over the last interval. */
def rate(w: long) -> long {
    if (dt_us <= 0) { return 0; };
    (cur[w] - prev[w]) * 1000000 / dt_us
};

// ── formatting ──────────────────────────────────────────────────────────

const SPACES = "                                                                ";

def pad_l(s: str, w: long) -> str {
    if (len(s) >= w || w > 64) { s } else { SPACES[0:w - len(s)] + s }
};

def pad_r(s: str, w: long) -> str {
    if (len(s) >= w || w > 64) { s } else { s + SPACES[0:w - len(s)] }
};

def two(n: long) -> str { if (n < 10) { "0" + tostring(n) } else { tostring(n) } };

/** 1234567 -> "1.2 MiB". */
def bytes_str(n: long) -> str {
    if (n < 1024) { return tostring(n) + " B"; };
    if (n < 1048576) { return tostring(n / 1024) + "." + tostring(n * 10 / 1024 % 10) + " KiB"; };
    if (n < 1073741824) { return tostring(n / 1048576) + "." + tostring(n * 10 / 1048576 % 10) + " MiB"; };
    tostring(n / 1073741824) + "." + tostring(n * 10 / 1073741824 % 10) + " GiB"
};

def tenths(v: long) -> str { tostring(v / 10) + "." + tostring(v % 10) };

def uptime_str(us: long) -> str {
    let s = us / 1000000;
    tostring(s / 3600) + ":" + two(s / 60 % 60) + ":" + two(s % 60)
};

def sys_name(nr: long) -> str {
    if (nr == 0) { return "read"; };
    if (nr == 1) { return "write"; };
    if (nr == 3) { return "close"; };
    if (nr == 7) { return "poll"; };
    if (nr == 8) { return "lseek"; };
    if (nr == 9) { return "mmap"; };
    if (nr == 11) { return "munmap"; };
    if (nr == 12) { return "brk"; };
    if (nr == 16) { return "ioctl"; };
    if (nr == 22) { return "pipe"; };
    if (nr == 24) { return "sched_yield"; };
    if (nr == 32) { return "dup"; };
    if (nr == 35) { return "nanosleep"; };
    if (nr == 39) { return "getpid"; };
    if (nr == 57) { return "fork"; };
    if (nr == 59) { return "execve"; };
    if (nr == 60) { return "exit"; };
    if (nr == 61) { return "wait4"; };
    if (nr == 79) { return "getcwd"; };
    if (nr == 96) { return "gettimeofday"; };
    if (nr == 217) { return "getdents64"; };
    if (nr == 228) { return "clock_gettime"; };
    if (nr == 231) { return "exit_group"; };
    if (nr == 257) { return "openat"; };
    if (nr == 262) { return "newfstatat"; };
    if (nr == 263) { return "unlinkat"; };
    "syscall " + tostring(nr)
};

def state_str(st: long) -> str {
    if (st == 1) { return "RUN"; };
    if (st == 2) { return "RDY"; };
    if (st == 4) { return "SLP"; };
    if (st == 5) { return "BOOT"; };
    "?"
};

// ── drawing ─────────────────────────────────────────────────────────────

const BG = 0xEC10141C;
const EDGE = 0xFF2E3646;
const HEAD = 0xFF9FB4D6;
const DIM = 0xFF7F8CA3;
const TXT = 0xFFE6EDF3;
const GREEN = 0xFF4ADE80;
const AMBER = 0xFFFBBF24;
const RED = 0xFFF87171;
const BLUE = 0xFF60A5FA;
const VIOLET = 0xFFA78BFA;
const TEAL = 0xFF2DD4BF;
const TRACK = 0xFF232B3A;

def load_color(x10: long) -> long {
    if (x10 < 500) { GREEN } else if (x10 < 800) { AMBER } else { RED }
};

def line_at(s: gfx.Surf, x: long, y: long, t: str, c: long) -> void { gfx.text(s, x, y, t, 1, c); };

/** A horizontal meter: `frac` of 1000 filled. */
def meter(s: gfx.Surf, x: long, y: long, w: long, h: long, frac: long, c: long) -> void {
    gfx.rect(s, x, y, x + w, y + h, TRACK);
    let fw = w * gfx.clamp(frac, 0, 1000) / 1000;
    if (fw > 0) { gfx.rect(s, x, y, x + fw, y + h, c); };
};

def heading(s: gfx.Surf, x: long, y: long, w: long, t: str) -> void {
    line_at(s, x, y, t, HEAD);
    gfx.rect(s, x, y + 17, x + w, y + 18, EDGE);
};

/** `hist` as columns, newest at the right, `top` being the full-height value. */
def graph(s: gfx.Surf, x: long, y: long, w: long, h: long, hist: [long], top: long, c: long) -> void {
    gfx.rect(s, x, y, x + w, y + h, TRACK);
    let colw = gfx.max(w / NHIST, 1);
    let k = 0;
    while (k < NHIST) {
        let v = hist[k];
        if (k >= NHIST - hist_n && top > 0) {
            let bh = gfx.clamp(h * v / top, 0, h);
            if (bh == 0 && v > 0) { bh = 1; };
            let bx = x + w - (NHIST - k) * colw;
            gfx.rect(s, bx, y + h - bh, bx + colw - 1, y + h, c);
        };
        k = k + 1;
    };
};

/** One stacked bar: segment `i` takes `vals[i]` of `total`, in colour `cols[i]`. */
def stack(s: gfx.Surf, x: long, y: long, w: long, h: long, total: long, vals: [long], cols: [long]) -> void {
    gfx.rect(s, x, y, x + w, y + h, TRACK);
    if (total <= 0) { return; };
    let acc = 0;
    let i = 0;
    while (i < len(vals)) {
        let x0 = x + w * acc / total;
        acc = acc + vals[i];
        let x1 = x + w * acc / total;
        if (x1 > x0) { gfx.rect(s, x0, y, x1, y + h, cols[i]); };
        i = i + 1;
    };
};

def swatch(s: gfx.Surf, x: long, y: long, c: long) -> void { gfx.rect(s, x, y + 3, x + 10, y + 13, c); };

const SKY = 0xFF38BDF8;
const KRES = 0xFF5B4B8A;
const ROSE = 0xFFFB7185;
const ORANGE = 0xFFFB923C;
const GREY = 0xFF94A3B8;
const SLATE = 0xFF64748B;
const DARK = 0xFF475569;
let seg_col: [long] = [BLUE, SKY, VIOLET, KRES, ROSE, AMBER, ORANGE, GREY, SLATE, DARK, TEAL];

/** The panel's box for a screen `sw` x `sh` whose dock starts at `dock_top`. */
def panel_h(sh: long, dock_top: long) -> long { gfx.max(dock_top - 64, 300) };

/** One legend row of the memory section: a swatch, a label and the size (and a note). */
def seg_row(s: gfx.Surf, x: long, y: long, c: long, label: str, bytes: long, note: str) -> long {
    swatch(s, x, y, c);
    line_at(s, x + 16, y, pad_r(label, 16) + pad_l(bytes_str(bytes), 10) + note, TXT);
    y + 18
};

/** CPU load, its history, the context switches; the y after it. */
def draw_cpu(s: gfx.Surf, x: long, y: long, w: long) -> long {
    heading(s, x, y, w, "CPU");
    y = y + 24;
    meter(s, x, y + 2, w - 130, 14, cpu_x10, load_color(cpu_x10));
    line_at(s, x + w - 120, y, pad_l(tenths(cpu_x10), 5) + "% busy", TXT);
    y = y + 22;
    graph(s, x, y, w, 44, hist_cpu, 1000, load_color(cpu_x10));
    y = y + 50;
    line_at(s, x, y, "idle " + tenths(1000 - cpu_x10) + "%   clock " + tostring(rate(2)) + " Hz   " + tostring(cur[2]) + " ticks", DIM);
    y = y + 18;
    line_at(s, x, y, "context switches " + pad_l(tostring(rate(5)), 6) + "/s   total " + tostring(cur[5]), TXT);
    y + 28
};

/** RAM by owner, then the heap of this process. */
def draw_mem(s: gfx.Surf, x: long, y: long, w: long, bottom: long) -> long {
    heading(s, x, y, w, "Memory");
    y = y + 24;
    let total = cur[7];
    let free = cur[8];
    let used = total - free - cur[9];
    stack(s, x, y, w, 16, total, seg, seg_col);
    y = y + 22;
    line_at(s, x, y, bytes_str(used) + " of " + bytes_str(total) + " in use (" + tenths(used * 1000 / gfx.max(total, 1)) + "%)", TXT);
    y = y + 20;
    y = seg_row(s, x, y, BLUE, "user pages", seg[SEG_USER], "  " + tostring(cur[29]) + " pages");
    y = seg_row(s, x, y, SKY, "page tables", seg[SEG_PTAB], "  " + tostring(cur[42]) + " pages");
    y = seg_row(s, x, y, VIOLET, "kernel heap", seg[SEG_KHEAP], "  used");
    y = seg_row(s, x, y, KRES, "  reserved", seg[SEG_KRES], "  unused");
    y = seg_row(s, x, y, ROSE, "framebuffers", seg[SEG_FB], "  vt + gui, at max size");
    y = seg_row(s, x, y, AMBER, "kernel stacks", seg[SEG_STACK], "  " + tostring(cur[48]) + " pooled");
    y = seg_row(s, x, y, ORANGE, "pipes, devices", seg[SEG_DEV], "");
    y = seg_row(s, x, y, GREY, "other kernel", seg[SEG_KOTHER], "");
    y = seg_row(s, x, y, SLATE, "image + fs", seg[SEG_IMAGE], "  fs " + bytes_str(cur[31]));
    y = seg_row(s, x, y, DARK, "low memory", seg[SEG_LOW], "  + gaps");
    y = seg_row(s, x, y, TEAL, "recycled pages", seg[SEG_RECYC], "  free list");
    y = seg_row(s, x, y, TRACK, "never used", free, "");
    line_at(s, x, y, "page faults " + pad_l(tostring(rate(6)), 5) + "/s   total " + tostring(cur[6]), TXT);
    y = y + 28;
    // the sampling process's own heap
    if (y + 18 * 5 < bottom && len(census) > memstat.C_LARGEST) {
        heading(s, x, y, w, "This process: Y heap");
        y = y + 24;
        let c = census;
        line_at(s, x, y, "handed out " + pad_l(bytes_str(heap_used()), 10) + "  mapped " + bytes_str(memstat.mapped()), TXT);
        y = y + 18;
        line_at(s, x, y, "live blocks " + pad_l(tostring(c[memstat.C_LIVE_BLOCKS]), 6) + "  " + bytes_str(c[memstat.C_LIVE_BYTES]) + " (" + bytes_str(c[memstat.C_PF_BYTES]) + " raw)", TXT);
        y = y + 18;
        line_at(s, x, y, "free blocks " + pad_l(tostring(c[memstat.C_FREE_BLOCKS]), 6) + "  " + bytes_str(c[memstat.C_FREE_BYTES]) + ", never used " + bytes_str(c[memstat.C_TAIL_BYTES]), TXT);
        y = y + 18;
        line_at(s, x, y, "gc: live " + bytes_str(memstat.live()) + ", next at +" + bytes_str(memstat.gc_trigger() - memstat.since_gc()), TXT);
        y = y + 18;
        line_at(s, x, y, "garbage " + pad_l(bytes_str(heap_rate), 9) + "/s   gfx mmap " + bytes_str(gfx.mapped), TXT);
        y = y + 24;
    };
    y
};

/** Kernel activity and the busiest system calls. */
def draw_act(s: gfx.Surf, x: long, y: long, w: long, bottom: long) -> long {
    heading(s, x, y, w, "Kernel activity");
    y = y + 24;
    line_at(s, x, y, "system calls " + pad_l(tostring(rate(4)), 8) + "/s   total " + tostring(cur[4]), TXT);
    y = y + 18;
    graph(s, x, y, w, 28, hist_sys, gfx.max(maxof(hist_sys), 10), BLUE);
    y = y + 34;
    line_at(s, x, y, "IRQ/s timer " + pad_l(tostring(rate(13)), 4) + " kbd " + pad_l(tostring(rate(14)), 3) + " mouse " + pad_l(tostring(rate(15)), 3) + " ser " + tostring(rate(16)), TXT);
    y = y + 18;
    line_at(s, x, y, "input events " + pad_l(tostring(rate(17)), 5) + "/s   total " + tostring(cur[17]), TXT);
    y = y + 18;
    line_at(s, x, y, "processes: " + tostring(cur[18]) + " forked, " + tostring(cur[19]) + " exec'd, " + tostring(cur[20]) + " exited", TXT);
    y = y + 18;
    line_at(s, x, y, "tasks " + tostring(cur[12]) + " (" + tostring(cur[28]) + " sleeping)   display " + tostring(cur[21]) + "x" + tostring(cur[22]) + " gen " + tostring(cur[23]), TXT);
    y = y + 18;
    line_at(s, x, y, "screen blits " + pad_l(tostring(rate(24)), 4) + "/s  " + pad_l(bytes_str(rate(25)), 9) + "/s", TXT);
    y = y + 24;
    if (y + 18 * 3 < bottom) {
        heading(s, x, y, w, "Busiest system calls");
        y = y + 22;
        let k = 0;
        while (k < 5 && y + 18 < bottom) {
            let n = cur[33 + k * 2];
            if (n > 0) {
                let share = n * 1000 / gfx.max(cur[4], 1);
                line_at(s, x, y, pad_r(sys_name(cur[32 + k * 2]), 16) + pad_l(tostring(n), 10) + "  " + pad_l(tenths(share), 5) + "%", TXT);
                y = y + 18;
            };
            k = k + 1;
        };
    };
    y
};

/** The task table; `wide` adds the parent and tick columns. */
def draw_tasks(s: gfx.Surf, tx: long, ty: long, tw: long, bottom: long, wide: bool) -> void {
    heading(s, tx, ty, tw, "Tasks");
    ty = ty + 24;
    line_at(s, tx, ty, if (wide) { " PID PPID ST    CPU%   TICKS     RES  NAME" } else { " PID ST    CPU%     RES  NAME" }, DIM);
    ty = ty + 20;
    let i = 0;
    while (i < ntask && ty + 18 <= bottom - 8) {
        let c = TXT;
        if (t_thread[i] != 0) { c = DIM; };
        let st = state_str(t_state[i]);
        let res = if (t_thread[i] != 0) { "       -" } else { pad_l(tostring(t_pages[i] * 4) + "K", 8) };
        let nm = (if (t_thread[i] != 0) { "+ " } else { "" }) + t_name[i];
        let row = if (wide) { pad_l(tostring(t_pid[i]), 4) + pad_l(tostring(t_ppid[i]), 5) + " " + pad_r(st, 4) + pad_l(tenths(t_cpu[i]), 6) + pad_l(tostring(t_ticks[i]), 8) + res + "  " + nm }
            else { pad_l(tostring(t_pid[i]), 4) + " " + pad_r(st, 4) + pad_l(tenths(t_cpu[i]), 6) + res + "  " + nm };
        line_at(s, tx, ty, row, c);
        // a small meter under the CPU column
        let mx = if (wide) { tx + 8 * 14 } else { tx + 8 * 9 };
        if (t_cpu[i] > 0) { gfx.rect(s, mx, ty + 14, mx + gfx.clamp(t_cpu[i] * 56 / 1000, 1, 56), ty + 16, load_color(t_cpu[i])); };
        ty = ty + 18;
        i = i + 1;
    };
    if (i < ntask) { line_at(s, tx, ty, "... " + tostring(ntask - i) + " more", DIM); };
};

def draw(s: gfx.Surf, px: long, py: long, pw: long, ph: long) -> void {
    if (px >= gfx.clip_x1 || px + pw <= gfx.clip_x0 || py >= gfx.clip_y1 || py + ph <= gfx.clip_y0) { return; };
    gfx.rect(s, px, py, px + pw, py + ph, BG);
    gfx.rect(s, px, py, px + pw, py + 1, EDGE);
    gfx.rect(s, px, py + ph - 1, px + pw, py + ph, EDGE);
    gfx.rect(s, px, py, px + 1, py + ph, EDGE);
    gfx.rect(s, px + pw - 1, py, px + pw, py + ph, EDGE);
    line_at(s, px + 14, py + 8, "Resource monitor", TXT);
    if (!have) {
        line_at(s, px + 14, py + 34, "waiting for the first sample...", DIM);
        return;
    };
    let hdr = "uptime " + uptime_str(cur[1]) + "   sample " + tostring(samples) + "   every " + tostring(dt_us / 1000) + " ms   F3 closes";
    line_at(s, px + pw - 14 - len(hdr) * 8, py + 8, hdr, DIM);
    let bottom = py + ph - 6;
    let top = py + 34;
    if (pw >= 1150) {
        // three columns: CPU and the kernel's activity, memory, tasks
        let x1 = px + 14;
        let w1 = 370;
        let x2 = x1 + w1 + 22;
        let w2 = 420;
        let x3 = x2 + w2 + 22;
        let w3 = px + pw - 14 - x3;
        let y = draw_cpu(s, x1, top, w1);
        draw_act(s, x1, y, w1, bottom);
        draw_mem(s, x2, top, w2, bottom);
        draw_tasks(s, x3, top, w3, py + ph, w3 >= 470);
    } else {
        let lw = gfx.clamp(pw * 45 / 100, 360, 520);
        let x = px + 14;
        let y = draw_cpu(s, x, top, lw);
        y = draw_mem(s, x, y, lw, bottom);
        if (y + 24 + 18 * 8 < bottom) { draw_act(s, x, y, lw, bottom); };
        let tx = px + 14 + lw + 24;
        let tw = px + pw - 14 - tx;
        if (tw >= 300) { draw_tasks(s, tx, top, tw, py + ph, tw >= 470); };
    };
};

def maxof(h: [long]) -> long {
    let m = 0;
    let k = 0;
    while (k < NHIST) { if (h[k] > m) { m = h[k]; }; k = k + 1; };
    m
};
