// a process with live threads ends when the process ends, whoever ends it;
// and a task spinning in user mode is preempted (time slicing).
def check(name: str, ok: bool) -> void {
    if (ok) { print(name + ": ok"); } else { print(name + ": FAIL"); };
};
let ts: [long; 2] = [0, 0];
def mono_us() -> long {
    syscall(228, 1, &ts[0]);
    ts[0] * 1000000 + ts[1] / 1000
};
let st: [long; 1] = [0];
def nap(sec: long, ns: long) -> void {
    let q: [long; 2] = [sec, ns];
    syscall(35, &q[0], 0);
};

// 1. main returns while a worker spins forever in user mode
let pid = syscall(57);
if (pid == 0) {
    let t = spawn { let n = 0; while (true) { n += 1; }; n };
    nap(0, 10000000);
    syscall(231, 3);
};
syscall(61, pid, &st[0], 0, 0);
check("leader exit with a spinning worker", st[0] == 3 << 8);

// 2. a worker calls exit_group while main sleeps for ten seconds
pid = syscall(57);
if (pid == 0) {
    let t = spawn { nap(0, 30000000); syscall(231, 7); 0 };
    nap(10, 0);
    syscall(231, 99);
};
let a = mono_us();
syscall(61, pid, &st[0], 0, 0);
let b = mono_us();
check("worker exit_group status", st[0] == 7 << 8);
check("worker exit_group is prompt", b - a < 3000000);

// 3. two tasks, one of them spinning without a syscall: the other still runs
pid = syscall(57);
if (pid == 0) {
    let flag: [long; 1] = [0];
    let t = spawn { nap(0, 20000000); flag[0] = 1; 0 };
    let n = 0;
    while (flag[0] == 0) { n += 1; };
    syscall(231, 5);
};
a = mono_us();
syscall(61, pid, &st[0], 0, 0);
b = mono_us();
check("preempted spin", st[0] == 5 << 8 && b - a < 3000000);

// 4. exit(60) of a worker ends only the worker
pid = syscall(57);
if (pid == 0) {
    let t = spawn { syscall(60, 0); 0 };
    nap(0, 50000000);
    syscall(231, 4);
};
syscall(61, pid, &st[0], 0, 0);
check("worker exit(60) leaves the process", st[0] == 4 << 8);
