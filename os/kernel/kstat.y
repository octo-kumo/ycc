// kstat -- what the kernel counts about itself, for the GUI's resource monitor (F3).
//
// The counters are bumped by the places that own the events (the syscall table, the clock tick,
// the page-fault handler, the scheduler hooks, the interrupt handlers); `kstat_snapshot` copies
// them and a row per task into a caller's buffer (the FB_STATS ioctl, fbdev.y). Nothing here
// allocates in the kernel heap on the hot paths: they are plain increments.
//
// The snapshot is an array of 64-bit words (the layout is fixed, `W_*` below): a header of
// HEADER words, then `ntasks` rows of ROW words.
//
//   header: 0 version, 1 uptime us, 2 ticks, 3 idle ticks, 4 syscalls, 5 context switches,
//           6 page faults, 7 RAM bytes, 8 never-used RAM bytes, 9 recycled-page bytes,
//           10 kernel heap bytes, 11 kernel heap in use, 12 live tasks, 13..16 IRQs (timer, keyboard,
//           mouse, serial), 17 input events, 18 forks, 19 execs, 20 exits, 21 display width,
//           22 display height, 23 display generation, 24 blits, 25 blit bytes, 26 rows written,
//           27 words per row, 28 sleeping tasks, 29 mapped user pages (all spaces),
//           30 kernel image bytes, 31 boot module bytes (the filesystem), 32.. the five busiest syscalls as
//           (number, count) pairs (to word 41), 42 page-table pages (all spaces), 43 framebuffer bytes,
//           44 kernel stack bytes carved, 45 pipe buffer bytes, 46 device buffer bytes, 47 bytes carved from
//           the page region since boot, 48 reaped kernel stacks waiting for reuse (pool)
//   row:    0 pid, 1 parent pid, 2 state, 3 ticks run, 4 resident pages (0 for a thread: it shares
//           its leader's space), 5 1 if a thread, 6..7 the name (16 bytes), 8 kernel stack bytes
import kernel;

const HEADER = 64;
const ROW = 10;
const MAX_TASKS = 96;
const NSYS = 400;

let ks_ticks = 0;
let ks_idle = 0;
let ks_sys = 0;
let ks_ctx = 0;
let ks_pf = 0;
let ks_irq_timer = 0;
let ks_irq_kbd = 0;
let ks_irq_mouse = 0;
let ks_irq_serial = 0;
let ks_input = 0;
let ks_forks = 0;
let ks_execs = 0;
let ks_exits = 0;
let ks_blits = 0;
let ks_blit_bytes = 0;
let ks_by_nr: [long; 400] = [0; 400];
// page-table pages seen by the last kstat_user_pages walks (the snapshot resets and sums it)
let ks_tab = 0;
// ticks the task in each slot was the running one (a slot freed and reused starts again)
let ks_task_ticks: [long; 256] = [0; 256];

def kstat_syscall(nr: long) -> void {
    ks_sys = ks_sys + 1;
    if (nr >= 0 && nr < NSYS) { ks_by_nr[nr] = ks_by_nr[nr] + 1; };
};

/** IRQ 0: the running task is charged the tick, else the machine was idle. */
def kstat_tick() -> void {
    ks_irq_timer = ks_irq_timer + 1;
    ks_ticks = ks_ticks + 1;
    let cur = kernel.task_current();
    if (cur >= 0 && cur < 256 && kernel.task_state(cur) == kernel.TASK_RUNNING && cur != 0) {
        ks_task_ticks[cur] = ks_task_ticks[cur] + 1;
    } else {
        ks_idle = ks_idle + 1;
    };
};

def kstat_switch() -> void { ks_ctx = ks_ctx + 1; };
def kstat_fault() -> void { ks_pf = ks_pf + 1; };
def kstat_irq_kbd() -> void { ks_irq_kbd = ks_irq_kbd + 1; };
def kstat_irq_mouse() -> void { ks_irq_mouse = ks_irq_mouse + 1; };
def kstat_irq_serial() -> void { ks_irq_serial = ks_irq_serial + 1; };
def kstat_input() -> void { ks_input = ks_input + 1; };
def kstat_fork(child: long) -> void {
    ks_forks = ks_forks + 1;
    if (child >= 0 && child < 256) { ks_task_ticks[child] = 0; };
};
def kstat_exec() -> void { ks_execs = ks_execs + 1; };
def kstat_exit() -> void { ks_exits = ks_exits + 1; };
def kstat_blit(bytes: long) -> void {
    ks_blits = ks_blits + 1;
    ks_blit_bytes = ks_blit_bytes + bytes;
};

/** The user pages mapped in the address space `cr3` (a walk of its tables below the kernel half). */
def kstat_user_pages(cr3: long) -> long {
    let n = 0;
    let i4 = 0;
    ks_tab = ks_tab + 1;
    while (i4 < 256) {
        let e4 = kernel.peek64(cr3 + i4 * 8);
        if ((e4 & kernel.PTE_P) != 0) {
            let t3 = e4 & kernel.PHYS_MASK;
            ks_tab = ks_tab + 1;
            let i3 = 0;
            while (i3 < 512) {
                let e3 = kernel.peek64(t3 + i3 * 8);
                if ((e3 & kernel.PTE_P) != 0 && (e3 & kernel.PTE_PS) == 0) {
                    let t2 = e3 & kernel.PHYS_MASK;
                    ks_tab = ks_tab + 1;
                    let i2 = 0;
                    while (i2 < 512) {
                        let e2 = kernel.peek64(t2 + i2 * 8);
                        if ((e2 & kernel.PTE_P) != 0) {
                            if ((e2 & kernel.PTE_PS) != 0) {
                                // the kernel's own identity map is a 2 MB page without PTE_U in every space: not the process's
                                if ((e2 & kernel.PTE_U) != 0) { n = n + 512; };
                            } else {
                                let t1 = e2 & kernel.PHYS_MASK;
                                ks_tab = ks_tab + 1;
                                let i1 = 0;
                                while (i1 < 512) {
                                    if ((kernel.peek64(t1 + i1 * 8) & kernel.PTE_P) != 0) { n = n + 1; };
                                    i1 = i1 + 1;
                                };
                            };
                        };
                        i2 = i2 + 1;
                    };
                };
                i3 = i3 + 1;
            };
        };
        i4 = i4 + 1;
    };
    n
};

def put(buf: long, w: long, v: long) -> void { kernel.poke_va64(buf + w * 8, v); };

/** Up to 8 bytes of `s` from `from`, packed little-endian. */
def name_word(s: str, from: long) -> long {
    let v = 0;
    let k = 7;
    while (k >= 0) {
        let c = 0;
        if (from + k < len(s)) { c = s[from + k] & 255; };
        v = (v << 8) | c;
        k = k - 1;
    };
    v
};

/** The bytes a snapshot with `n` rows takes. */
def kstat_size(n: long) -> long { (HEADER + n * ROW) * 8 };

/** Fill `buf` (room for `cap` bytes, already checked as the caller's) with a snapshot; the bytes written.
 *  `uptime`, `heap`, the display and the free-RAM figures come from the caller, which can see the modules this one cannot. */
def kstat_snapshot(buf: long, cap: long, uptime: long, heap_total: long, heap_use: long, fbw: long, fbh: long, fbgen: long) -> long {
    let maxrows = (cap / 8 - HEADER) / ROW;
    if (maxrows < 0) { return 0 - 1; };
    if (maxrows > MAX_TASKS) { maxrows = MAX_TASKS; };
    let w = 0;
    while (w < HEADER) { put(buf, w, 0); w = w + 1; };
    put(buf, 0, 1);
    put(buf, 1, uptime);
    put(buf, 2, ks_ticks);
    put(buf, 3, ks_idle);
    put(buf, 4, ks_sys);
    put(buf, 5, ks_ctx);
    put(buf, 6, ks_pf);
    put(buf, 7, kernel.mb_mem_upper_kb() * 1024 + 1048576);
    put(buf, 8, kernel.phys_free_bytes());
    put(buf, 9, kernel.pages_freed() * 4096);
    put(buf, 10, heap_total);
    put(buf, 11, heap_use);
    put(buf, 13, ks_irq_timer);
    put(buf, 14, ks_irq_kbd);
    put(buf, 15, ks_irq_mouse);
    put(buf, 16, ks_irq_serial);
    put(buf, 17, ks_input);
    put(buf, 18, ks_forks);
    put(buf, 19, ks_execs);
    put(buf, 20, ks_exits);
    put(buf, 21, fbw);
    put(buf, 22, fbh);
    put(buf, 23, fbgen);
    put(buf, 24, ks_blits);
    put(buf, 25, ks_blit_bytes);
    put(buf, 27, ROW);
    put(buf, 30, kernel.image_bytes());
    put(buf, 31, kernel.module_bytes());
    put(buf, 43, kernel.acct_get(kernel.ACCT_FB));
    put(buf, 44, kernel.acct_get(kernel.ACCT_STACK));
    put(buf, 45, kernel.acct_get(kernel.ACCT_PIPE));
    put(buf, 46, kernel.acct_get(kernel.ACCT_DEV));
    put(buf, 47, kernel.phys_bump_bytes());
    put(buf, 48, kernel.kstack_pool_count());
    ks_tab = 0;
    // the five busiest syscalls
    let top = 0;
    while (top < 5) {
        let best = 0 - 1;
        let bc = 0;
        let nr = 0;
        while (nr < NSYS) {
            if (ks_by_nr[nr] > bc) {
                // not one already listed
                let seen = false;
                let k = 0;
                while (k < top) { if (kernel.peek_va64(buf + (32 + k * 2) * 8) == nr && kernel.peek_va64(buf + (33 + k * 2) * 8) > 0) { seen = true; }; k = k + 1; };
                if (!seen) { best = nr; bc = ks_by_nr[nr]; };
            };
            nr = nr + 1;
        };
        if (best >= 0) { put(buf, 32 + top * 2, best); put(buf, 33 + top * 2, bc); };
        top = top + 1;
    };
    // a row per live task
    let n = kernel.task_count();
    let rows = 0;
    let live = 0;
    let sleeping = 0;
    let pages = 0;
    let i = 1;
    while (i < n) {
        let st = kernel.task_state(i);
        if (st != kernel.TASK_FREE && st != kernel.TASK_REAPED && st != kernel.TASK_DEAD) {
            live = live + 1;
            if (st == kernel.TASK_BLOCKED) { sleeping = sleeping + 1; };
            if (rows < maxrows) {
                // a thread shares an earlier slot's space
                let thread = 0;
                let j = 1;
                while (j < i) {
                    let sj = kernel.task_state(j);
                    if (sj != kernel.TASK_FREE && sj != kernel.TASK_REAPED && sj != kernel.TASK_DEAD && kernel.task_cr3(j) == kernel.task_cr3(i)) { thread = 1; };
                    j = j + 1;
                };
                let rss = 0;
                if (thread == 0) { rss = kstat_user_pages(kernel.task_cr3(i)); };
                pages = pages + rss;
                let ppid = 0;
                let par = kernel.task_parent(i);
                if (par >= 0 && par < n) { ppid = kernel.task_pid(par); };
                let b = HEADER + rows * ROW;
                let nm = kernel.task_name(i);
                put(buf, b, kernel.task_pid(i));
                put(buf, b + 1, ppid);
                put(buf, b + 2, st);
                put(buf, b + 3, if (i < 256) { ks_task_ticks[i] } else { 0 });
                put(buf, b + 4, rss);
                put(buf, b + 5, thread);
                put(buf, b + 6, name_word(nm, 0));
                put(buf, b + 7, name_word(nm, 8));
                put(buf, b + 8, 65536);
                rows = rows + 1;
            };
        };
        i = i + 1;
    };
    put(buf, 12, live);
    put(buf, 26, rows);
    put(buf, 28, sleeping);
    put(buf, 29, pages);
    put(buf, 42, ks_tab);
    kstat_size(rows)
};
