// proc -- per-process state that is not the fd table: cwd, ids, process
// groups, signals, exec with envp, wait4, kill, uname, rlimits.
//
// Signals are "terminate or ignore": there are no handlers.  A signal whose
// default is to terminate (and that the target has not set to SIG_IGN) ends the
// target as if it had called exit_group(128 + sig).  Another task is ended by
// rewriting its saved frame so that it executes exit_group the next time it runs
// (kill_task); the running task cannot be (tty calls from IRQ 4), so that one
// gets the signal recorded in pend[] and dies at its next syscall that calls
// proc_check_pending (read, write, poll, wait4, ... and kill itself).
//
// Per-slot arrays: index = kernel.task_slot() (a slot is reused once its task is reaped:
// every module with per-slot state resets it in the lifecycle hooks of sys.y).
// Grow them on demand with proc_ensure(slot): a slot made by the boot path never
// went through proc_on_fork.
import kernel;
import kconst from "./kconst.y";
import fdt from "./fdt.y";
import vfs from "./vfs.y";
import time from "./time.y";
import elf from "./elfload.y";
import yfs;

let cwd_inos: [long] = [];
let cwd_paths: [str] = [];
let pgids: [long] = [];
let sids: [long] = [];
let sig_ign: [long] = [];
let sig_pend: [long] = [];
let env_blobs: [str] = [];
let proc_umask_v = 18;

def proc_ensure(slot: long) -> void {
    while (len(cwd_inos) <= slot) {
        cwd_inos += yfs.yfs_root;
        cwd_paths += "/";
        pgids += 0;
        sids += 0;
        sig_ign += 0;
        sig_pend += 0;
        env_blobs += "";
    };
};

// ── accessors (used by vfs, tty, thread, ...) ───────────────────────────
/** The inode of task `slot`'s working directory (the root until chdir). */
def cwd_ino(slot: long) -> long { proc_ensure(slot); cwd_inos[slot] };
/** Its absolute path, "/" for the root, no trailing slash otherwise. */
def cwd_path(slot: long) -> str { proc_ensure(slot); cwd_paths[slot] };
/** Set it (vfs's chdir/fchdir call this after resolving the path). */
def set_cwd(slot: long, ino: long, path: str) -> void {
    proc_ensure(slot);
    cwd_inos[slot] = ino;
    cwd_paths[slot] = path;
};
/** The process group / session of `slot` (0 until setsid/setpgid: the pid). */
def proc_pgid(slot: long) -> long {
    proc_ensure(slot);
    if (pgids[slot] == 0) { kernel.task_pid(slot) } else { pgids[slot] }
};
def proc_sid(slot: long) -> long {
    proc_ensure(slot);
    if (sids[slot] == 0) { kernel.task_pid(slot) } else { sids[slot] }
};
def proc_set_pgid(slot: long, g: long) -> void { proc_ensure(slot); pgids[slot] = g; };
def proc_uid(slot: long) -> long { 1000 };
def proc_gid(slot: long) -> long { 1000 };
/** Task `slot`'s environment as set by its last execve: NAME=value, each followed
 *  by a NUL (what /proc/self/environ reads). */
def proc_environ(slot: long) -> str { proc_ensure(slot); env_blobs[slot] };

def proc_live(s: long) -> bool {
    let st = kernel.task_state(s);
    st == kernel.TASK_RUNNING || st == kernel.TASK_READY || st == kernel.TASK_BLOCKED
};

/** Does a signal `sig` do nothing to `slot`?  (default-ignored, or SIG_IGN set) */
def proc_sig_ignored(slot: long, sig: long) -> bool {
    if (sig == 9) { return false; };
    if (sig == 17 || sig == 18 || sig == 19 || sig == 20 || sig == 21 || sig == 22 || sig == 23 || sig == 28) { return true; };
    proc_ensure(slot);
    ((sig_ign[slot] >> sig) & 1) != 0
};

/** End another (suspended) task as exit_group(128 + sig): its saved frame gets
 *  rax = 231, rdi = status, and a `syscall` instruction (0F 05) is written over
 *  the instruction it would run next. */
def kill_task(s: long, sig: long) -> void {
    proc_ensure(s);
    let fr = kernel.task_rsp(s);
    if (s == kernel.task_slot() || fr == 0) { sig_pend[s] = sig; return; };
    let rip = kernel.peek_va64(fr + 120);
    let cr3 = kernel.task_cr3(s);
    let p0 = kernel.vm_translate(cr3, rip);
    let p1 = kernel.vm_translate(cr3, rip + 1);
    if (p0 == 0 || p1 == 0) { sig_pend[s] = sig; return; };
    kernel.poke8(p0, 15);
    kernel.poke8(p1, 5);
    kernel.poke_va64(fr + 40, 128 + sig);
    kernel.task_complete(s, 231);
    kernel.sched_ready();
};

/** Terminate task `slot` (and the threads sharing its address space) as if by
 *  signal `sig`.  Used by tty for ^C (SIGINT to the foreground group), so it is
 *  safe from an IRQ handler.  0, or -ESRCH. */
def proc_signal_slot(slot: long, sig: long) -> long {
    if (slot <= 0 || slot >= kernel.task_count()) { return kconst.ESRCH; };
    let st = kernel.task_state(slot);
    if (st == kernel.TASK_DEAD) { return 0; };
    if (!proc_live(slot)) { return kconst.ESRCH; };
    if (sig == 0) { return 0; };
    if (sig < 0 || sig > 64) { return kconst.EINVAL; };
    if (proc_sig_ignored(slot, sig)) { return 0; };
    let cr3 = kernel.task_cr3(slot);
    let s = 1;
    while (s < kernel.task_count()) {
        if (proc_live(s) && (s == slot || kernel.task_cr3(s) == cr3)) { kill_task(s, sig); };
        s = s + 1;
    };
    0
};

/** Send `sig` to every task in process group `g`: 0, or -ESRCH when it is empty. */
def proc_signal_group(g: long, sig: long) -> long {
    let hit = 0;
    let s = 1;
    while (s < kernel.task_count()) {
        if (proc_live(s) && proc_pgid(s) == g) { proc_signal_slot(s, sig); hit = hit + 1; };
        s = s + 1;
    };
    if (hit == 0) { kconst.ESRCH } else { 0 }
};

/** If the running task was signalled while it could not be ended (see above), end
 *  it now and answer true: the caller returns at once.  Call at the top of a
 *  syscall that can run for long or block. */
def proc_check_pending() -> bool {
    let s = kernel.task_slot();
    if (s >= len(sig_pend) || sig_pend[s] == 0) { return false; };
    let sig = sig_pend[s];
    sig_pend[s] = 0;
    kernel.sys_exit_group(128 + sig);
    true
};

/** The running task wrote to a pipe nobody reads: SIGPIPE unless it is ignored. */
def proc_sigpipe() -> void {
    let s = kernel.task_slot();
    proc_ensure(s);
    if (((sig_ign[s] >> 13) & 1) != 0) { return; };
    kernel.sys_exit_group(141);
};

// ── lifecycle (sys.y) ───────────────────────────────────────────────────
def proc_on_fork(parent: long, child: long) -> void {
    proc_ensure(parent);
    proc_ensure(child);
    cwd_inos[child] = cwd_inos[parent];
    cwd_paths[child] = cwd_paths[parent];
    pgids[child] = proc_pgid(parent);
    sids[child] = proc_sid(parent);
    sig_ign[child] = sig_ign[parent];
    sig_pend[child] = 0;
    env_blobs[child] = env_blobs[parent];
};
def proc_on_exec(slot: long) -> void {
    proc_ensure(slot);
    sig_pend[slot] = 0;
};
def proc_on_exit(slot: long) -> void {
    proc_ensure(slot);
    env_blobs[slot] = "";
    sig_pend[slot] = 0;
    // orphans go to init (pid 1), which reaps them
    let init = kernel.task_slot_of_pid(1);
    if (init >= 0 && init != slot) {
        let s = 0;
        while (s < kernel.task_count()) {
            let st = kernel.task_state(s);
            if (s != slot && kernel.task_parent(s) == slot && st != kernel.TASK_FREE && st != kernel.TASK_REAPED) {
                kernel.task_set_parent(s, init);
            };
            s = s + 1;
        };
        kernel.wake_chan(fdt.fdt_chan(kconst.CH_CHILD, init));
    };
    // a parent in wait4 looks again
    let p = kernel.task_parent(slot);
    if (p >= 0) { kernel.wake_chan(fdt.fdt_chan(kconst.CH_CHILD, p)); };
};

// ── user memory helpers ─────────────────────────────────────────────────
/** The NUL-terminated string at user address `p` (at most 4096 bytes). */
def proc_ustr(p: long) -> str {
    let b: [byte] = [];
    let i = 0;
    while (i < 4096) {
        let c = kernel.peek_va8(p + i);
        if (c == 0) { i = 4096; } else { b += c; i = i + 1; };
    };
    from_bytes(b)
};

def put_str(addr: long, s: str) -> void {
    let i = 0;
    while (i < len(s)) { kernel.poke_va8(addr + i, byte_at(s, i)); i = i + 1; };
    kernel.poke_va8(addr + len(s), 0);
};

// ── process syscalls ────────────────────────────────────────────────────
def sys_getpid() -> long { kernel.task_pid(kernel.task_slot()) };
def sys_fork() -> long { kernel.SYS_FALLBACK };
def sys_vfork() -> long { kernel.sys_fork() };

/** The pointers of a NULL-terminated user vector as strs (at most 1024). */
def ustr_vec(vp: long) -> [str] {
    let out: [str] = [];
    if (vp == 0) { return out; };
    let i = 0;
    while (i < 1024) {
        let p = fdt.u_rd64(vp + i * 8);
        if (p == 0) { i = 1024; } else { out += proc_ustr(p); i = i + 1; };
    };
    out
};

def sys_execve(pathp: long, argvp: long, envp: long) -> long {
    if (check_dead()) { return 0; };
    if (!kernel.user_ok(pathp, 1)) { return kconst.EFAULT; };
    let slot = kernel.task_slot();
    let ino = vfs.vfs_resolve(slot, kconst.AT_FDCWD, pathp);
    if (ino < 0) { return ino; };
    let path = proc_ustr(pathp);
    let args = ustr_vec(argvp);
    if (len(args) == 0) { args += path; };
    let env = ustr_vec(envp);
    let total = 0;
    let blob = "";
    let i = 0;
    while (i < len(args)) { total = total + len(args[i]) + 9; i = i + 1; };
    i = 0;
    while (i < len(env)) { total = total + len(env[i]) + 9; blob += env[i] + chr(0); i = i + 1; };
    if (total > 40000) { return 0 - 7; };
    // kernel.sys_execve looks the path up itself: hand it an absolute one
    let upath = pathp;
    if (kernel.peek_va8(pathp) != 47) {
        let cwd = cwd_path(slot);
        let abs = cwd + "/" + path;
        if (cwd == "/") { abs = "/" + path; };
        let rsp = kernel.peek_va64(kernel.cur_frame() + 144);
        upath = (rsp - 512 - len(abs)) & (0 - 16);
        if (!kernel.user_ok(upath, len(abs) + 1)) { return kconst.EFAULT; };
        put_str(upath, abs);
    };
    let r = kernel.sys_execve(upath, 0);
    if (r < 0) {
        if (r == kconst.EFAULT) { return 0 - 8; };
        return r;
    };
    // the new image is current: its argv and envp go over the one-page stack
    let sp = elf.elf_restack(args, env);
    if (sp == 0) { kernel.sys_exit_group(137); return kconst.ENOMEM; };
    kernel.poke_va64(kernel.cur_frame() + 144, sp);
    proc_ensure(slot);
    env_blobs[slot] = blob;
    // the task is named for its program (the resource monitor lists it)
    let base = 0;
    let k = 0;
    while (k < len(path)) { if (path[k] == 47) { base = k + 1; }; k = k + 1; };
    kernel.task_set_name(slot, path[base:len(path)]);
    0
};

/** proc_check_pending, spelled for call sites that read better as a test. */
def check_dead() -> bool { proc_check_pending() };

def sys_wait4(pid: long, statusp: long, options: long, rusage: long) -> long {
    if (check_dead()) { return 0; };
    let me = kernel.task_slot();
    let any = false;
    let s = 0;
    while (s < kernel.task_count()) {
        if (kernel.task_parent(s) == me && s != me) {
            let st = kernel.task_state(s);
            if (st != kernel.TASK_FREE && st != kernel.TASK_REAPED && (pid <= 0 || kernel.task_pid(s) == pid)) { any = true; };
        };
        s = s + 1;
    };
    if (!any) { return kconst.ECHILD; };
    let r = kernel.sys_wait4(pid, statusp, options | 1, rusage);
    if (r != 0 || (options & 1) != 0) { return r; };
    kernel.block_restart(fdt.fdt_chan(kconst.CH_CHILD, me), 0)
};

def sys_exit_group(status: long) -> long { kernel.SYS_FALLBACK };
def sys_reboot(magic1: long, magic2: long, cmd: long, arg: long) -> long { kernel.SYS_FALLBACK };

def sys_kill(pid: long, sig: long) -> long {
    if (sig < 0 || sig > 64) { return kconst.EINVAL; };
    let me = kernel.task_slot();
    let r = 0;
    if (pid > 0) {
        let s = kernel.task_slot_of_pid(pid);
        if (s < 1) { r = kconst.ESRCH; } else { r = proc_signal_slot(s, sig); };
    } else if (pid == 0) {
        r = proc_signal_group(proc_pgid(me), sig);
    } else if (pid == 0 - 1) {
        let hit = 0;
        let s = 1;
        while (s < kernel.task_count()) {
            if (s != me && proc_live(s) && kernel.task_pid(s) != 1) { proc_signal_slot(s, sig); hit = hit + 1; };
            s = s + 1;
        };
        if (hit == 0) { r = kconst.ESRCH; };
    } else {
        r = proc_signal_group(0 - pid, sig);
    };
    check_dead();
    r
};

def sys_tkill(tid: long, sig: long) -> long { sys_kill(tid, sig) };
def sys_tgkill(tgid: long, tid: long, sig: long) -> long { sys_kill(tid, sig) };

def sys_rt_sigaction(sig: long, act: long, oact: long, size: long) -> long {
    if (sig < 1 || sig > 64) { return kconst.EINVAL; };
    if (act != 0 && (sig == 9 || sig == 19)) { return kconst.EINVAL; };
    let slot = kernel.task_slot();
    proc_ensure(slot);
    if (oact != 0) {
        if (!kernel.user_ok(oact, 32)) { return kconst.EFAULT; };
        kernel.kzero(oact, 32);
        if (sig < 64 && ((sig_ign[slot] >> sig) & 1) != 0) { fdt.u_wr64(oact, 1); };
    };
    if (act != 0 && sig < 64) {
        if (!kernel.user_ok(act, 32)) { return kconst.EFAULT; };
        if (fdt.u_rd64(act) == 1) { sig_ign[slot] = sig_ign[slot] | (1 << sig); } else { sig_ign[slot] = sig_ign[slot] & (0 - 1 - (1 << sig)); };
    };
    0
};

def sys_rt_sigprocmask(how: long, set: long, oset: long, size: long) -> long {
    if (oset != 0) {
        if (!kernel.user_ok(oset, 8)) { return kconst.EFAULT; };
        fdt.u_wr64(oset, 0);
    };
    0
};

def sys_rt_sigreturn() -> long { kconst.ENOSYS };

def sys_sigaltstack(ss: long, oss: long) -> long {
    if (oss != 0) {
        if (!kernel.user_ok(oss, 24)) { return kconst.EFAULT; };
        kernel.kzero(oss, 24);
        fdt.u_wr64(oss + 8, 2);          // SS_DISABLE
    };
    0
};

def sys_uname(buf: long) -> long {
    if (!kernel.user_ok(buf, 390)) { return kconst.EFAULT; };
    kernel.kzero(buf, 390);
    put_str(buf, "yunix");
    put_str(buf + 65, "yunix");
    put_str(buf + 130, "0.1");
    put_str(buf + 195, "yunix 0.1");
    put_str(buf + 260, "x86_64");
    0
};

def sys_umask(mask: long) -> long {
    let old = proc_umask_v;
    proc_umask_v = mask & 511;
    old
};

/** The limit of resource `res` (RLIMIT_*): stack 8 MB and 128 files are real,
 *  the rest unlimited. */
def rlim_cur(res: long) -> long {
    if (res == 3) { return 8388608; };
    if (res == 7) { return 128; };
    0 - 1
};

def sys_getrlimit(res: long, rlim: long) -> long {
    if (res < 0 || res > 15) { return kconst.EINVAL; };
    if (!kernel.user_ok(rlim, 16)) { return kconst.EFAULT; };
    fdt.u_wr64(rlim, rlim_cur(res));
    fdt.u_wr64(rlim + 8, if (res == 7) { 128 } else { 0 - 1 });
    0
};

def sys_setrlimit(res: long, rlim: long) -> long {
    if (res < 0 || res > 15) { return kconst.EINVAL; };
    0
};

def sys_prlimit64(pid: long, res: long, newp: long, oldp: long) -> long {
    if (pid != 0 && pid != sys_getpid()) { return kconst.EPERM; };
    if (oldp != 0) {
        let r = sys_getrlimit(res, oldp);
        if (r < 0) { return r; };
    };
    if (newp != 0) { return sys_setrlimit(res, newp); };
    0
};

def sys_sysinfo(info: long) -> long {
    if (!kernel.user_ok(info, 112)) { return kconst.EFAULT; };
    kernel.kzero(info, 112);
    fdt.u_wr64(info, time.now_us() / 1000000);
    fdt.u_wr64(info + 32, 536870912);
    fdt.u_wr64(info + 40, kernel.phys_free_bytes());
    kernel.poke_va8(info + 80, kernel.task_count() & 255);
    kernel.poke_va8(info + 104, 1);
    0
};

def sys_prctl(op: long, a2: long, a3: long, a4: long, a5: long) -> long { 0 };

def sys_getuid() -> long { 1000 };
def sys_getgid() -> long { 1000 };
def sys_geteuid() -> long { 1000 };
def sys_getegid() -> long { 1000 };

def sys_getppid() -> long {
    let p = kernel.task_parent(kernel.task_slot());
    if (p < 0) { 0 } else { kernel.task_pid(p) }
};

def sys_gettid() -> long { kernel.task_pid(kernel.task_slot()) };

/** The slot `pid` names (0 = the caller), or -1. */
def slot_of(pid: long) -> long {
    if (pid == 0) { return kernel.task_slot(); };
    kernel.task_slot_of_pid(pid)
};

def sys_setsid() -> long {
    let me = kernel.task_slot();
    if (proc_pgid(me) == kernel.task_pid(me)) { return kconst.EPERM; };
    pgids[me] = kernel.task_pid(me);
    sids[me] = kernel.task_pid(me);
    kernel.task_pid(me)
};

def sys_setpgid(pid: long, g: long) -> long {
    let s = slot_of(pid);
    if (s < 1) { return kconst.ESRCH; };
    if (g < 0) { return kconst.EINVAL; };
    if (g == 0) { g = kernel.task_pid(s); };
    proc_set_pgid(s, g);
    0
};

def sys_getpgid(pid: long) -> long {
    let s = slot_of(pid);
    if (s < 1) { return kconst.ESRCH; };
    proc_pgid(s)
};

def sys_getpgrp() -> long { proc_pgid(kernel.task_slot()) };

def sys_getsid(pid: long) -> long {
    let s = slot_of(pid);
    if (s < 1) { return kconst.ESRCH; };
    proc_sid(s)
};
