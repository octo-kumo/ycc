// the thread syscalls the runtime does not reach by itself: futex timeouts,
// wake counts, set_tid_address, arch_prctl, sched_getaffinity, a raw clone.
def check(name: str, ok: bool) -> void {
    if (ok) { print(name + ": ok"); } else { print(name + ": FAIL"); };
};
let word: [long; 2] = [0, 0];
let ts: [long; 2] = [0, 0];

def mono_us() -> long {
    syscall(228, 1, &ts[0]);
    ts[0] * 1000000 + ts[1] / 1000
};

// futex wait with a value that no longer matches: EAGAIN at once
word[0] = 5;
check("futex EAGAIN", syscall(202, &word[0], 0, 4, 0, 0, 0) == 0 - 11);

// futex wait with a timeout: ETIMEDOUT after about that long
let to: [long; 2] = [0, 30000000];
let a = mono_us();
let r = syscall(202, &word[0], 128, 5, &to[0], 0, 0);
let b = mono_us();
check("futex timeout", r == 0 - 110 && b - a >= 30000 && b - a < 500000);

// nobody waits: wake wakes 0
check("futex wake none", syscall(202, &word[0], 129, 10, 0, 0, 0) == 0);

// arch_prctl: GET_FS returns what SET_FS put; the runtime's own TLS is restored
let fs0: [long; 1] = [0];
check("get fs", syscall(158, 4099, &fs0[0]) == 0);
check("set fs", syscall(158, 4098, fs0[0]) == 0);
let fs1: [long; 1] = [0];
syscall(158, 4099, &fs1[0]);
check("fs round trip", fs1[0] == fs0[0]);
check("bad arch_prctl", syscall(158, 77, 0) == 0 - 22);

// one cpu
let mask: [long; 2] = [0, 0];
check("affinity", syscall(204, 0, 16, &mask[0]) == 8 && mask[0] == 1);
check("affinity small", syscall(204, 0, 4, &mask[0]) == 0 - 22);

// set_tid_address answers the caller's tid, set_robust_list accepts
let tid = syscall(218, 0);
check("set_tid_address", tid == syscall(186));
check("getpid == gettid in a single thread", syscall(39) == tid);
check("set_robust_list", syscall(273, 0, 24) == 0);

// spawn / join through the runtime: the pids agree across threads
let main_pid = syscall(39);
let t = spawn { syscall(39) };
check("thread sees the group's pid", join t == main_pid);
let t2 = spawn { syscall(186) };
check("thread has its own tid", join t2 != syscall(186));
