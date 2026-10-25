// sys -- yunix's system call table and lifecycle hooks .
//
// std/kernel.y's y_sys_dispatch calls y_os_sys FIRST for every syscall.  This
// def replaces kernel.y's default (a program's `y_` def wins at link time).  Each
// number calls its owning module; an answer of kernel.SYS_FALLBACK hands the
// call to kernel.y's own handler (read, write, openat ... -- what worked before
// yunix), so a module that returns SYS_FALLBACK keeps the default behaviour.
import kernel;
import kconst from "./kconst.y";
import vfs from "./vfs.y";
import fdt from "./fdt.y";
import pipe from "./pipe.y";
import proc from "./proc.y";
import time from "./time.y";
import thread from "./thread.y";
import mm from "./mm.y";
import tty from "./tty.y";
import kbd from "./kbd.y";
import dsp from "./dsp.y";
import unix from "./unix.y";
import kstat from "./kstat.y";

let sys_reported: [long] = [];

/** Report an unimplemented call once per number on the console; -ENOSYS. */
def sys_unimplemented(nr: long) -> long {
    let i = 0;
    let seen = false;
    while (i < len(sys_reported)) {
        if (sys_reported[i] == nr) { seen = true; };
        i = i + 1;
    };
    if (!seen) {
        sys_reported += nr;
        puts("yunix: unimplemented syscall " + tostring(nr) + " (" + kernel.task_name(kernel.task_slot()) + ")\n");
    };
    kconst.ENOSYS
};

def y_os_sys(nr: long, a1: long, a2: long, a3: long, a4: long, a5: long, a6: long) -> long {
    // the kernel's own IPC calls (1024..) and anything negative
    if (nr < 0 || nr >= 1024) { return kernel.SYS_FALLBACK; };
    kstat.kstat_syscall(nr);
    if (proc.proc_check_pending()) { return 0; };
    // ── early routes: getpid is the thread group's pid, gettid the slot's own;
    //    these two win over the proc lines below ──
    if (nr == 39) { return thread.thread_sys_getpid(); };
    if (nr == 186) { return thread.thread_sys_gettid(); };
    // ── fd I/O (fdt) ──
    if (nr == 0) { return fdt.sys_read(a1, a2, a3); };
    if (nr == 1) { return fdt.sys_write(a1, a2, a3); };
    if (nr == 3) { return fdt.sys_close(a1); };
    if (nr == 7) { return fdt.sys_poll(a1, a2, a3); };
    if (nr == 8) { return fdt.sys_lseek(a1, a2, a3); };
    if (nr == 16) { return fdt.sys_ioctl(a1, a2, a3); };
    if (nr == 17) { return fdt.sys_pread64(a1, a2, a3, a4); };
    if (nr == 18) { return fdt.sys_pwrite64(a1, a2, a3, a4); };
    if (nr == 19) { return fdt.sys_readv(a1, a2, a3); };
    if (nr == 20) { return fdt.sys_writev(a1, a2, a3); };
    if (nr == 23) { return fdt.sys_select(a1, a2, a3, a4, a5); };
    if (nr == 32) { return fdt.sys_dup(a1); };
    if (nr == 33) { return fdt.sys_dup2(a1, a2); };
    if (nr == 72) { return fdt.sys_fcntl(a1, a2, a3); };
    if (nr == 270) { return fdt.sys_pselect6(a1, a2, a3, a4, a5, a6); };
    if (nr == 271) { return fdt.sys_ppoll(a1, a2, a3, a4, a5); };
    if (nr == 292) { return fdt.sys_dup3(a1, a2, a3); };
    // ── pipes (pipe) ──
    if (nr == 22) { return pipe.sys_pipe(a1); };
    if (nr == 293) { return pipe.sys_pipe2(a1, a2); };
    // ── processes, ids, signals (proc) ──
    if (nr == 13) { return proc.sys_rt_sigaction(a1, a2, a3, a4); };
    if (nr == 14) { return proc.sys_rt_sigprocmask(a1, a2, a3, a4); };
    if (nr == 15) { return proc.sys_rt_sigreturn(); };
    if (nr == 39) { return proc.sys_getpid(); };
    if (nr == 57) { return proc.sys_fork(); };
    if (nr == 58) { return proc.sys_vfork(); };
    if (nr == 59) { return proc.sys_execve(a1, a2, a3); };
    if (nr == 61) { return proc.sys_wait4(a1, a2, a3, a4); };
    if (nr == 62) { return proc.sys_kill(a1, a2); };
    if (nr == 63) { return proc.sys_uname(a1); };
    if (nr == 95) { return proc.sys_umask(a1); };
    if (nr == 97) { return proc.sys_getrlimit(a1, a2); };
    if (nr == 99) { return proc.sys_sysinfo(a1); };
    if (nr == 102) { return proc.sys_getuid(); };
    if (nr == 104) { return proc.sys_getgid(); };
    if (nr == 107) { return proc.sys_geteuid(); };
    if (nr == 108) { return proc.sys_getegid(); };
    if (nr == 109) { return proc.sys_setpgid(a1, a2); };
    if (nr == 110) { return proc.sys_getppid(); };
    if (nr == 111) { return proc.sys_getpgrp(); };
    if (nr == 112) { return proc.sys_setsid(); };
    if (nr == 121) { return proc.sys_getpgid(a1); };
    if (nr == 124) { return proc.sys_getsid(a1); };
    if (nr == 131) { return proc.sys_sigaltstack(a1, a2); };
    if (nr == 157) { return proc.sys_prctl(a1, a2, a3, a4, a5); };
    if (nr == 160) { return proc.sys_setrlimit(a1, a2); };
    if (nr == 169) { return proc.sys_reboot(a1, a2, a3, a4); };
    if (nr == 186) { return proc.sys_gettid(); };
    if (nr == 200) { return proc.sys_tkill(a1, a2); };
    if (nr == 231) { return proc.sys_exit_group(a1); };
    if (nr == 234) { return proc.sys_tgkill(a1, a2, a3); };
    if (nr == 302) { return proc.sys_prlimit64(a1, a2, a3, a4); };
    // ── time (time) ──
    if (nr == 24) { return time.sys_sched_yield(); };
    if (nr == 35) { return time.sys_nanosleep(a1, a2); };
    if (nr == 96) { return time.sys_gettimeofday(a1, a2); };
    if (nr == 201) { return time.sys_time(a1); };
    if (nr == 228) { return time.sys_clock_gettime(a1, a2); };
    if (nr == 229) { return time.sys_clock_getres(a1, a2); };
    if (nr == 230) { return time.sys_clock_nanosleep(a1, a2, a3, a4); };
    // ── threads (thread) ──
    if (nr == 56) { return thread.sys_clone(a1, a2, a3, a4, a5); };
    if (nr == 60) { return thread.sys_exit(a1); };
    if (nr == 158) { return thread.sys_arch_prctl(a1, a2); };
    if (nr == 202) { return thread.sys_futex(a1, a2, a3, a4, a5, a6); };
    if (nr == 204) { return thread.sys_sched_getaffinity(a1, a2, a3); };
    if (nr == 218) { return thread.sys_set_tid_address(a1); };
    if (nr == 273) { return thread.sys_set_robust_list(a1, a2); };
    if (nr == 435) { return thread.sys_clone3(a1, a2); };
    // ── memory (mm) ──
    if (nr == 9) { return mm.sys_mmap(a1, a2, a3, a4, a5, a6); };
    if (nr == 10) { return mm.sys_mprotect(a1, a2, a3); };
    if (nr == 11) { return mm.sys_munmap(a1, a2); };
    if (nr == 12) { return mm.sys_brk(a1); };
    if (nr == 25) { return mm.sys_mremap(a1, a2, a3, a4, a5); };
    if (nr == 28) { return mm.sys_madvise(a1, a2, a3); };
    if (nr == 318) { return mm.sys_getrandom(a1, a2, a3); };
    // ── files and directories (A: vfs) ──
    if (nr == 2) { return vfs.sys_open(a1, a2, a3); };
    if (nr == 4) { return vfs.sys_stat(a1, a2); };
    if (nr == 5) { return vfs.sys_fstat(a1, a2); };
    if (nr == 6) { return vfs.sys_lstat(a1, a2); };
    if (nr == 21) { return vfs.sys_access(a1, a2); };
    if (nr == 76) { return vfs.sys_truncate(a1, a2); };
    if (nr == 77) { return vfs.sys_ftruncate(a1, a2); };
    if (nr == 79) { return vfs.sys_getcwd(a1, a2); };
    if (nr == 80) { return vfs.sys_chdir(a1); };
    if (nr == 81) { return vfs.sys_fchdir(a1); };
    if (nr == 82) { return vfs.sys_rename(a1, a2); };
    if (nr == 83) { return vfs.sys_mkdir(a1, a2); };
    if (nr == 84) { return vfs.sys_rmdir(a1); };
    if (nr == 87) { return vfs.sys_unlink(a1); };
    if (nr == 89) { return vfs.sys_readlink(a1, a2, a3); };
    if (nr == 90) { return vfs.sys_chmod(a1, a2); };
    if (nr == 217) { return vfs.sys_getdents64(a1, a2, a3); };
    if (nr == 257) { return vfs.sys_openat(a1, a2, a3, a4); };
    if (nr == 258) { return vfs.sys_mkdirat(a1, a2, a3); };
    if (nr == 262) { return vfs.sys_newfstatat(a1, a2, a3, a4); };
    if (nr == 263) { return vfs.sys_unlinkat(a1, a2, a3); };
    if (nr == 264) { return vfs.sys_renameat(a1, a2, a3, a4); };
    if (nr == 268) { return vfs.sys_fchmodat(a1, a2, a3, a4); };
    if (nr == 269) { return vfs.sys_faccessat(a1, a2, a3, a4); };
    if (nr == 280) { return vfs.sys_utimensat(a1, a2, a3, a4); };
    if (nr == 316) { return vfs.sys_renameat2(a1, a2, a3, a4, a5); };
    if (nr == 332) { return vfs.sys_statx(a1, a2, a3, a4, a5); };
    if (nr == 439) { return vfs.sys_faccessat2(a1, a2, a3, a4); };
    // ── AF_UNIX sockets (E: unix) ──
    if (nr == 41) { return unix.sys_socket(a1, a2, a3); };
    if (nr == 42) { return unix.sys_connect(a1, a2, a3); };
    if (nr == 43) { return unix.sys_accept(a1, a2, a3); };
    if (nr == 44) { return unix.sys_sendto(a1, a2, a3, a4, a5, a6); };
    if (nr == 45) { return unix.sys_recvfrom(a1, a2, a3, a4, a5, a6); };
    if (nr == 46) { return unix.sys_sendmsg(a1, a2, a3); };
    if (nr == 47) { return unix.sys_recvmsg(a1, a2, a3); };
    if (nr == 48) { return unix.sys_shutdown(a1, a2); };
    if (nr == 49) { return unix.sys_bind(a1, a2, a3); };
    if (nr == 50) { return unix.sys_listen(a1, a2); };
    if (nr == 51) { return unix.sys_getsockname(a1, a2, a3); };
    if (nr == 52) { return unix.sys_getpeername(a1, a2, a3); };
    if (nr == 53) { return unix.sys_socketpair(a1, a2, a3, a4); };
    if (nr == 54) { return unix.sys_setsockopt(a1, a2, a3, a4, a5); };
    if (nr == 55) { return unix.sys_getsockopt(a1, a2, a3, a4, a5); };
    if (nr == 288) { return unix.sys_accept4(a1, a2, a3, a4); };
    sys_unimplemented(nr)
};

// ── lifecycle (kernel.y calls these; every module with per-slot state hooks in) ──
def y_os_task_forked(parent: long, child: long) -> void {
    kstat.kstat_fork(child);
    proc.proc_on_fork(parent, child);
    if (thread.thread_shares_mm(child)) { fdt.fdt_share(parent, child); } else { fdt.fdt_on_fork(parent, child); };
    mm.mm_on_fork(parent, child);
    thread.thread_on_fork(parent, child);
    time.time_on_task(child);
    tty.tty_on_task(child);
    pipe.pipe_on_task(child);
};

def y_os_task_exec(i: long) -> void {
    kstat.kstat_exec();
    fdt.fdt_on_exec(i);
    proc.proc_on_exec(i);
    mm.mm_on_exec(i);
    thread.thread_on_exec(i);
};

def y_os_task_exited(i: long) -> void {
    kstat.kstat_exit();
    fdt.fdt_on_exit(i);
    thread.thread_on_exit(i);
    mm.mm_on_exit(i);
    proc.proc_on_exit(i);
    time.time_on_task(i);
    tty.tty_on_task(i);
    pipe.pipe_on_task(i);
};

def y_os_task_switch(prev_slot: long, next_slot: long) -> void {
    kstat.kstat_switch();
    thread.thread_on_switch(prev_slot, next_slot);
};

/** Bring the OS modules up (boot.y, after kernel.init and the fs mount). */
def sys_boot_init(rows: long, cols: long) -> void {
    time.time_init();
    tty.tty_init(rows, cols);
    dsp.dsp_init();
    kbd.kbd_init();
};

