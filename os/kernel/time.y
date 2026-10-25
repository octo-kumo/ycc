// time -- the clock, the PIT tick, sleeping.
//
// The clock: the PIT (channel 0, mode 2) ticks at about 1 kHz; now_us() is the tick
// count in exact microseconds (the divisor is 1193, so a tick is 999.848 us) plus a
// refinement from the TSC inside the current tick, clamped below one tick so the
// clock never steps back.  The TSC rate is learned from tick to tick (a running
// average of the cycles between two ticks): integer arithmetic only, because the
// user's XMM registers are live in IRQs and syscalls alike.
// CLOCK_REALTIME is the CMOS RTC read once at boot plus now_us().
//
// Sleeping: nanosleep and clock_nanosleep keep their deadline per task slot and
// `kernel.block_restart(0, deadline)`; the call re-executes when the deadline has
// passed (or a wake came early) and returns 0 once now >= deadline.
//
// Time slicing: every SLICE_TICKS ticks `kernel.sched_tick()` asks for a switch,
// so a task spinning in user mode (a runtime lock, a poll loop) cannot starve the
// others: the IRQ that interrupted ring 3 switches at once.
//
// time_on_tick runs in IRQ 0 (boot.y's `irq 0 def`), interrupts off: no floats, no
// blocking, keep it short.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import dsp from "./dsp.y";
import mm from "./mm.y";
import kstat from "./kstat.y";

const PIT_HZ = 1000;
const PIT_DIV = 1193;
const PIT_BASE = 1193182;
const SLICE_TICKS = 10;

let time_ticks = 0;
let time_tick_tsc = 0;        // the TSC at the last tick
let time_cycles = 0;          // TSC cycles per tick (running average), 0 = unknown
let time_real_base = 0;       // CLOCK_REALTIME in microseconds at now_us() == 0
let time_pend: [long] = [];   // per slot: the deadline of the sleep in progress, 0 none
let time_pend_arg: [long] = []; // per slot: the request pointer it belongs to

// ── the CMOS RTC ────────────────────────────────────────────────────────
def time_cmos(reg: long) -> long {
    kernel.outb(112, reg);
    kernel.inb(113)
};

def time_bcd(v: long) -> long { (v >> 4) * 10 + (v & 15) };

/** Days from 1970-01-01 to y-m-d (proleptic Gregorian). */
def time_days(year: long, month: long, day: long) -> long {
    let y = year;
    if (month <= 2) { y = y - 1; };
    let era = y / 400;
    let yoe = y - era * 400;
    let mp = month + 9;
    if (month > 2) { mp = month - 3; };
    let doy = (153 * mp + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
};

/** Seconds since the epoch according to the RTC (UTC). */
def time_rtc_secs() -> long {
    // wait out an update in progress, then read twice until the reads agree
    let guard = 0;
    while ((time_cmos(10) & 128) != 0 && guard < 100000) { guard = guard + 1; };
    let sec = time_cmos(0);
    let min = time_cmos(2);
    let hour = time_cmos(4);
    let day = time_cmos(7);
    let mon = time_cmos(8);
    let yr = time_cmos(9);
    let cen = time_cmos(50);
    let sb = time_cmos(11);
    let pm = (hour & 128) != 0;
    if ((sb & 4) == 0) {
        sec = time_bcd(sec);
        min = time_bcd(min);
        hour = time_bcd(hour & 127);
        day = time_bcd(day);
        mon = time_bcd(mon);
        yr = time_bcd(yr);
        cen = time_bcd(cen);
    } else {
        hour = hour & 127;
    };
    if ((sb & 2) == 0) {
        if (pm && hour < 12) { hour = hour + 12; };
        if (!pm && hour == 12) { hour = 0; };
    };
    let full = yr + 2000;
    if (cen >= 19 && cen <= 30) { full = cen * 100 + yr; };
    if (mon < 1 || mon > 12 || day < 1 || day > 31) { return 0; };
    time_days(full, mon, day) * 86400 + hour * 3600 + min * 60 + sec
};

/** Program the PIT (channel 0, mode 2) to PIT_HZ and read the RTC.  boot -> sys.sys_boot_init. */
def time_init() -> void {
    kernel.outb(67, 52);
    kernel.outb(64, PIT_DIV & 255);
    kernel.outb(64, (PIT_DIV >> 8) & 255);
    time_tick_tsc = kernel.rdtsc();
    time_real_base = time_rtc_secs() * 1000000 - now_us();
};

/** Microseconds since boot (monotonic). */
def now_us() -> long {
    let base = time_ticks * 1000 * PIT_DIV * 1000 / PIT_BASE;
    let frac = 0;
    if (time_cycles > 0 && time_tick_tsc != 0) {
        frac = (kernel.rdtsc() - time_tick_tsc) * 999 / time_cycles;
        if (frac > 999) { frac = 999; };
        if (frac < 0) { frac = 0; };
    };
    base + frac
};

/** CLOCK_REALTIME in microseconds since the epoch. */
def time_real_us() -> long { time_real_base + now_us() };

/** TSC cycles in one clock tick, as measured (0 until two ticks have passed). */
def time_tick_cycles() -> long { time_cycles };

/** IRQ 0. */
def time_on_tick() -> void {
    let t = kernel.rdtsc();
    if (time_tick_tsc != 0) {
        let d = t - time_tick_tsc;
        if (d > 0) {
            if (time_cycles == 0) { time_cycles = d; } else { time_cycles = (time_cycles * 7 + d) / 8; };
        };
    };
    time_tick_tsc = t;
    time_ticks = time_ticks + 1;
    kstat.kstat_tick();
    if (time_ticks % SLICE_TICKS == 0) { kernel.sched_tick(); };
    kernel.wake_expired(now_us());
    dsp.dsp_on_tick();
};

// ── user memory ─────────────────────────────────────────────────────────
def time_put_ts(tp: long, us: long) -> void {
    kernel.poke_va64(tp, us / 1000000);
    kernel.poke_va64(tp + 8, (us % 1000000) * 1000);
};

/** Microseconds in the timespec at `tp` (rounded up), or -1 when it is invalid. */
def time_get_ts(tp: long) -> long {
    let sec = kernel.peek_va64(tp);
    let nsec = kernel.peek_va64(tp + 8);
    if (sec < 0 || nsec < 0 || nsec >= 1000000000) { return 0 - 1; };
    if (sec > 4000000000000) { sec = 4000000000000; };
    sec * 1000000 + (nsec + 999) / 1000
};

/** A clock id's reading, or -1 for an id this kernel does not have.
 *  0 REALTIME, 1 MONOTONIC, 4 MONOTONIC_RAW, 5 REALTIME_COARSE, 6 MONOTONIC_COARSE, 7 BOOTTIME;
 *  the CPU-time clocks 2 and 3 read as the monotonic clock. */
def time_clock(clk: long) -> long {
    if (clk == 0 || clk == 5) { return time_real_us(); };
    if (clk == 1 || clk == 2 || clk == 3 || clk == 4 || clk == 6 || clk == 7) { return now_us(); };
    0 - 1
};

def sys_clock_gettime(clk: long, tp: long) -> long {
    let us = time_clock(clk);
    if (us < 0) { return kconst.EINVAL; };
    if (!mm.mm_ok(tp, 16)) { return kconst.EFAULT; };
    time_put_ts(tp, us);
    0
};

def sys_clock_getres(clk: long, tp: long) -> long {
    if (time_clock(clk) < 0) { return kconst.EINVAL; };
    if (tp != 0) {
        if (!mm.mm_ok(tp, 16)) { return kconst.EFAULT; };
        kernel.poke_va64(tp, 0);
        kernel.poke_va64(tp + 8, 1000000);
    };
    0
};

def sys_gettimeofday(tv: long, tz: long) -> long {
    if (tv != 0) {
        if (!mm.mm_ok(tv, 16)) { return kconst.EFAULT; };
        let us = time_real_us();
        kernel.poke_va64(tv, us / 1000000);
        kernel.poke_va64(tv + 8, us % 1000000);
    };
    if (tz != 0) {
        if (!mm.mm_ok(tz, 8)) { return kconst.EFAULT; };
        kernel.poke_va64(tz, 0);
    };
    0
};

def sys_time(tloc: long) -> long {
    let secs = time_real_us() / 1000000;
    if (tloc != 0) {
        if (!mm.mm_ok(tloc, 8)) { return kconst.EFAULT; };
        kernel.poke_va64(tloc, secs);
    };
    secs
};

// ── sleeping ────────────────────────────────────────────────────────────
def time_ensure(slot: long) -> void {
    while (len(time_pend) <= slot) { time_pend += 0; time_pend_arg += 0; };
};

/** A slot starts or ends a task: forget the previous one's pending sleep (a task killed
 *  in nanosleep leaves its deadline and request address behind). */
def time_on_task(slot: long) -> void {
    time_ensure(slot);
    time_pend[slot] = 0;
    time_pend_arg[slot] = 0;
};

/** Sleep until `deadline` (now_us clock) for the call identified by `key`:
 *  0 when it has passed, else the block_restart verdict. */
def time_sleep_until(slot: long, key: long, deadline: long, rem: long) -> long {
    if (now_us() >= deadline) {
        time_pend[slot] = 0;
        if (rem != 0 && mm.mm_ok(rem, 16)) { time_put_ts(rem, 0); };
        return 0;
    };
    time_pend[slot] = deadline;
    time_pend_arg[slot] = key;
    kernel.block_restart(0, deadline)
};

def sys_nanosleep(req: long, rem: long) -> long {
    let slot = kernel.task_slot();
    time_ensure(slot);
    if (time_pend[slot] != 0 && time_pend_arg[slot] == req) {
        return time_sleep_until(slot, req, time_pend[slot], rem);
    };
    if (!mm.mm_ok(req, 16)) { return kconst.EFAULT; };
    let us = time_get_ts(req);
    if (us < 0) { return kconst.EINVAL; };
    if (us == 0) { kernel.sched_ready(); return 0; };
    time_sleep_until(slot, req, now_us() + us, rem)
};

def sys_clock_nanosleep(clk: long, flags: long, req: long, rem: long) -> long {
    let slot = kernel.task_slot();
    time_ensure(slot);
    if (time_pend[slot] != 0 && time_pend_arg[slot] == req) {
        return time_sleep_until(slot, req, time_pend[slot], 0);
    };
    let base = time_clock(clk);
    if (base < 0 || clk == 2 || clk == 3) { return kconst.EINVAL; };
    if (!mm.mm_ok(req, 16)) { return kconst.EFAULT; };
    let us = time_get_ts(req);
    if (us < 0) { return kconst.EINVAL; };
    let deadline = 0;
    if ((flags & 1) != 0) {
        // TIMER_ABSTIME: us is a time on clock `clk`
        deadline = us - base + now_us();
        if (deadline <= now_us()) { kernel.sched_ready(); return 0; };
    } else {
        if (us == 0) { kernel.sched_ready(); return 0; };
        deadline = now_us() + us;
    };
    time_sleep_until(slot, req, deadline, if ((flags & 1) != 0) { 0 } else { rem })
};

def sys_sched_yield() -> long {
    kernel.sched_ready();
    0
};
