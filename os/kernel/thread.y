// thread -- clone, futex, TLS (FS base), thread exit.
//
// Besides the common interface it exports thread_tgid, thread_tid,
// thread_shares_mm, thread_is_thread.
//
// A thread is a task slot of its own (own kernel stack, own saved frame) on the
// SAME address space as its group leader.  The group is the set of slots whose
// th_lead is the leader's slot; the process id (tgid) is the leader's pid, every
// slot keeps its own pid as its tid.  clone with CLONE_THREAD makes a slot with
// kernel.sched_add and runs the fork hooks on it (th_clone says "share, don't copy"
// to mm); a clone without CLONE_VM is a fork.
//
// Ending: exit(60) ends one thread (CHILD_CLEARTID: 0 is written to the tid word and
// the futex on it is woken -- that is what join waits for); from the leader, or alone,
// it is exit_group.  exit_group from any thread of a group (thread_on_exit) dooms the
// others: a doomed slot is woken and, when the scheduler switches to it
// (thread_on_switch), runs kernel.sys_exit_group itself -- nothing outside kernel.y
// can change another task's state.
//
// Futex: the word's PHYSICAL address is the key (CH_FUTEX channel).  A wait is
// restartable: th_fw is 0 (idle), 1 (waiting; th_fdl its deadline) or 2 (a WAKE
// chose it), so a retry after the wake returns 0 instead of sleeping again.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import proc from "./proc.y";
import time from "./time.y";
import mm from "./mm.y";

const TH_FS_BASE = 3221225728;      // MSR 0xC0000100

let th_lead: [long] = [];           // per slot: the group leader's slot (itself for a process)
let th_clear: [long] = [];          // per slot: CLONE_CHILD_CLEARTID / set_tid_address word
let th_fs: [long] = [];             // per slot: the FS base
let th_fw: [long] = [];             // per slot: futex wait state 0/1/2
let th_fphys: [long] = [];          // per slot: the futex word's physical address while waiting
let th_fdl: [long] = [];            // per slot: its deadline (0 none)
let th_doom: [long] = [];           // per slot: -1, or the exit status it must die with
let th_fs_cur = 0;                  // what the FS base MSR holds now
let th_clone_child = 0 - 1;         // the slot clone is creating (its fork hooks run now)
let th_single = 0 - 1;              // the slot ending alone (exit 60)

def thread_ensure(slot: long) -> void {
    while (len(th_lead) <= slot) {
        th_lead += len(th_lead);
        th_clear += 0;
        th_fs += 0;
        th_fw += 0;
        th_fphys += 0;
        th_fdl += 0;
        th_doom += 0 - 1;
    };
};

// ── what other modules ask ──────────────────────────────────────────────
/** Is `slot` a thread (not its group's leader)? */
def thread_is_thread(slot: long) -> bool {
    thread_ensure(slot);
    th_lead[slot] != slot
};

/** Does `slot`, being made by the fork hooks, share its creator's address space? */
def thread_shares_mm(slot: long) -> bool { slot == th_clone_child };

/** The slot of `slot`'s group leader. */
def thread_leader(slot: long) -> long {
    thread_ensure(slot);
    th_lead[slot]
};

/** The process id of the group `slot` belongs to (what getpid answers). */
def thread_tgid(slot: long) -> long { kernel.task_pid(thread_leader(slot)) };

/** The thread id (what gettid answers): the slot's own pid. */
def thread_tid(slot: long) -> long { kernel.task_pid(slot) };

def thread_alive(slot: long) -> bool {
    let st = kernel.task_state(slot);
    st != kernel.TASK_DEAD && st != kernel.TASK_REAPED && st != kernel.TASK_FREE
};

/** How many live slots besides `slot` are in its group. */
def thread_siblings(slot: long) -> long {
    let lead = thread_leader(slot);
    let n = 0;
    let i = 0;
    while (i < kernel.task_count()) {
        thread_ensure(i);
        if (i != slot && th_lead[i] == lead && thread_alive(i)) { n = n + 1; };
        i = i + 1;
    };
    n
};

/** getpid: the group's pid. */
def thread_sys_getpid() -> long { thread_tgid(kernel.task_slot()) };
/** gettid: this slot's pid. */
def thread_sys_gettid() -> long { thread_tid(kernel.task_slot()) };

// ── 32-bit user words ───────────────────────────────────────────────────
/** Store a 32-bit word in `slot`'s space (physically, so any current CR3 will do). */
def thread_put32(slot: long, va: long, v: long) -> void {
    if ((va & 3) != 0) { return; };
    let p = mm.mm_phys(slot, va);
    if (p != 0) { kernel.poke32(p, v); };
};

// ── futex ───────────────────────────────────────────────────────────────
def thread_futex_wake(phys: long, n: long) -> long {
    let woken = 0;
    let i = 0;
    while (i < len(th_fw) && woken < n) {
        if (th_fw[i] == 1 && th_fphys[i] == phys) {
            th_fw[i] = 2;
            kernel.wake_task(i);
            woken = woken + 1;
        };
        i = i + 1;
    };
    woken
};

def sys_futex(uaddr: long, op: long, val: long, timeout: long, uaddr2: long, val3: long) -> long {
    let cmd = op & 127;
    let slot = kernel.task_slot();
    thread_ensure(slot);
    if (cmd == 0 || cmd == 9) {
        // WAIT / WAIT_BITSET
        let st = th_fw[slot];
        if (st == 2) {
            th_fw[slot] = 0;
            th_fdl[slot] = 0;
            return 0;
        };
        if (st == 1) {
            // woken early or by the deadline: time is up, or sleep again
            if (th_fdl[slot] != 0 && time.now_us() >= th_fdl[slot]) {
                th_fw[slot] = 0;
                th_fdl[slot] = 0;
                return kconst.ETIMEDOUT;
            };
            return kernel.block_restart(fdt.fdt_chan(kconst.CH_FUTEX, th_fphys[slot]), th_fdl[slot]);
        };
        if ((uaddr & 3) != 0) { return kconst.EINVAL; };
        let phys = mm.mm_phys(slot, uaddr);
        if (phys == 0) { return kconst.EFAULT; };
        if (kernel.peek32(phys) != (val & 4294967295)) { return kconst.EAGAIN; };
        let dl = 0;
        if (timeout != 0) {
            if (!mm.mm_ok(timeout, 16)) { return kconst.EFAULT; };
            let us = time.time_get_ts(timeout);
            if (us < 0) { return kconst.EINVAL; };
            if (cmd == 9) {
                // absolute, on CLOCK_MONOTONIC unless FUTEX_CLOCK_REALTIME (256)
                if ((op & 256) != 0) { dl = us - time.time_real_us() + time.now_us(); } else { dl = us; };
                if (dl <= time.now_us()) { return kconst.ETIMEDOUT; };
            } else {
                dl = time.now_us() + us;
                if (us == 0) { return kconst.ETIMEDOUT; };
            };
        };
        th_fw[slot] = 1;
        th_fphys[slot] = phys;
        th_fdl[slot] = dl;
        return kernel.block_restart(fdt.fdt_chan(kconst.CH_FUTEX, phys), dl);
    };
    if (cmd == 1 || cmd == 10) {
        // WAKE / WAKE_BITSET
        if ((uaddr & 3) != 0) { return kconst.EINVAL; };
        let phys = mm.mm_phys(slot, uaddr);
        if (phys == 0) { return kconst.EFAULT; };
        let n = val;
        if (n > 2147483647) { n = 2147483647; };
        return thread_futex_wake(phys, n);
    };
    if (cmd == 3 || cmd == 4) {
        // REQUEUE / CMP_REQUEUE: wake `val`, move up to `timeout` (a count here) to uaddr2
        if ((uaddr & 3) != 0 || (uaddr2 & 3) != 0) { return kconst.EINVAL; };
        let p1 = mm.mm_phys(slot, uaddr);
        let p2 = mm.mm_phys(slot, uaddr2);
        if (p1 == 0 || p2 == 0) { return kconst.EFAULT; };
        if (cmd == 4 && kernel.peek32(p1) != (val3 & 4294967295)) { return kconst.EAGAIN; };
        let woken = thread_futex_wake(p1, val);
        let moved = 0;
        let i = 0;
        while (i < len(th_fw) && moved < timeout) {
            if (th_fw[i] == 1 && th_fphys[i] == p1) {
                th_fphys[i] = p2;
                kernel.wake_task(i);   // it retries its wait on the new word
                moved = moved + 1;
            };
            i = i + 1;
        };
        return woken + moved;
    };
    kconst.ENOSYS
};

// ── per-task state across fork, exec, switch ────────────────────────────
def thread_on_fork(parent: long, child: long) -> void {
    thread_ensure(parent);
    thread_ensure(child);
    if (child != th_clone_child) {
        th_lead[child] = child;
        th_fs[child] = th_fs[parent];
    };
    th_clear[child] = 0;
    th_fw[child] = 0;
    th_fdl[child] = 0;
    th_doom[child] = 0 - 1;
};

def thread_doom(slot: long, status: long) -> void {
    th_doom[slot] = status;
    if (kernel.task_state(slot) == kernel.TASK_BLOCKED) { kernel.task_complete(slot, 0); };
    kernel.sched_ready();
};

def thread_on_exec(slot: long) -> void {
    thread_ensure(slot);
    // the other threads of the old image die with it
    let lead = th_lead[slot];
    let i = 0;
    while (i < kernel.task_count()) {
        thread_ensure(i);
        if (i != slot && th_lead[i] == lead && thread_alive(i)) { thread_doom(i, 0); };
        i = i + 1;
    };
    th_lead[slot] = slot;
    th_clear[slot] = 0;
    th_fw[slot] = 0;
    th_fs[slot] = 0;
    th_fs_cur = 0;
    kernel.msr_write(TH_FS_BASE, 0);
};

/** A thread that ended is waited for by nobody: give back its stacks. */
def thread_reap_dead(cur: long) -> void {
    let i = 0;
    while (i < kernel.task_count()) {
        thread_ensure(i);
        if (i != cur && th_lead[i] != i && kernel.task_state(i) == kernel.TASK_DEAD) { kernel.task_reap(i); };
        i = i + 1;
    };
};

def thread_on_exit(slot: long) -> void {
    thread_ensure(slot);
    thread_reap_dead(slot);
    let c = th_clear[slot];
    if (c != 0) {
        th_clear[slot] = 0;
        let p = mm.mm_phys(slot, c);
        if (p != 0 && (c & 3) == 0) {
            kernel.poke32(p, 0);
            thread_futex_wake(p, 2147483647);
        };
    };
    th_fw[slot] = 0;
    th_fdl[slot] = 0;
    if (th_single == slot) { return; };
    // the whole group goes with it
    let status = kernel.task_exit_status(slot);
    let lead = th_lead[slot];
    let i = 0;
    while (i < kernel.task_count()) {
        thread_ensure(i);
        if (i != slot && th_lead[i] == lead && thread_alive(i)) { thread_doom(i, status); };
        i = i + 1;
    };
};

/** The scheduler moves from slot `prev_slot` to slot `next_slot` (CR3 and FPU done). */
def thread_on_switch(prev_slot: long, next_slot: long) -> void {
    thread_ensure(next_slot);
    if (th_doom[next_slot] >= 0 && thread_alive(next_slot)) {
        let status = th_doom[next_slot];
        th_doom[next_slot] = 0 - 1;
        // next_slot is the running task now: it exits like exit_group would
        kernel.sys_exit_group(status);
    };
    if (th_fs[next_slot] != th_fs_cur) {
        th_fs_cur = th_fs[next_slot];
        kernel.msr_write(TH_FS_BASE, th_fs_cur);
    };
};

// ── syscalls ────────────────────────────────────────────────────────────
def sys_clone(flags: long, stack: long, ptid: long, ctid: long, tls: long) -> long {
    let slot = kernel.task_slot();
    thread_ensure(slot);
    if ((flags & 256) == 0) {
        // no CLONE_VM: a new process
        let r = proc.sys_fork();
        if (r == kernel.SYS_FALLBACK) { r = kernel.sys_fork(); };
        if (r > 0) {
            let child = kernel.task_slot_of_pid(r);
            if (child >= 0 && stack != 0) { kernel.poke_va64(kernel.task_rsp(child) + 144, stack); };
            if (child >= 0 && (flags & 1048576) != 0 && ptid != 0) { thread_put32(slot, ptid, r); };
        };
        return r;
    };
    if ((flags & 65536) == 0 || stack == 0) { return kconst.EINVAL; };
    let kstack = kernel.kstack_alloc();
    if (kstack == 0) { return kconst.ENOMEM; };
    let ktop = kstack + 65536;
    let src = kernel.cur_frame();
    if (src == 0) { return kconst.EFAULT; };
    let dst = ktop - 160;
    let i = 0;
    while (i < 20) {
        kernel.poke_va64(dst + i * 8, kernel.peek_va64(src + i * 8));
        i = i + 1;
    };
    kernel.poke_va64(dst + 48, 0);
    kernel.poke_va64(dst + 144, stack);
    let child = kernel.sched_add(kernel.task_cr3(slot), ktop, dst, "fork");
    kernel.task_pool_stack(child);
    thread_ensure(child);
    th_lead[child] = th_lead[slot];
    th_fs[child] = th_fs[slot];
    if ((flags & 524288) != 0) { th_fs[child] = tls; };
    // the child resumes with the creator's live FPU/SSE state
    let cfx = kernel.fpu_area(child);
    if (cfx != 0) { kernel.y_fxsave(cfx); };
    th_clone_child = child;
    kernel.y_os_task_forked(slot, child);
    th_clone_child = 0 - 1;
    let tid = kernel.task_pid(child);
    if ((flags & 1048576) != 0) { thread_put32(slot, ptid, tid); };
    if ((flags & 16777216) != 0) { thread_put32(slot, ctid, tid); };
    if ((flags & 2097152) != 0) { th_clear[child] = ctid; };
    tid
};

def sys_clone3(args: long, size: long) -> long { kconst.ENOSYS };

def sys_exit(status: long) -> long {
    let slot = kernel.task_slot();
    thread_ensure(slot);
    if (th_lead[slot] == slot || thread_siblings(slot) == 0) {
        return kernel.sys_exit_group(status);
    };
    th_single = slot;
    kernel.task_exit();
    th_single = 0 - 1;
    status
};

def sys_set_tid_address(tidptr: long) -> long {
    let slot = kernel.task_slot();
    thread_ensure(slot);
    th_clear[slot] = tidptr;
    kernel.task_pid(slot)
};

def sys_set_robust_list(head: long, size: long) -> long { 0 };

def sys_arch_prctl(code: long, addr: long) -> long {
    let slot = kernel.task_slot();
    thread_ensure(slot);
    if (code == 4098) {
        th_fs[slot] = addr;
        th_fs_cur = addr;
        kernel.msr_write(TH_FS_BASE, addr);
        return 0;
    };
    if (code == 4099) {
        if (!mm.mm_ok(addr, 8)) { return kconst.EFAULT; };
        kernel.poke_va64(addr, th_fs[slot]);
        return 0;
    };
    kconst.EINVAL
};

def sys_sched_getaffinity(pid: long, size: long, mask: long) -> long {
    if (size < 8 || (size & 7) != 0) { return kconst.EINVAL; };
    if (!mm.mm_ok(mask, 8)) { return kconst.EFAULT; };
    kernel.poke_va64(mask, 1);
    8
};
