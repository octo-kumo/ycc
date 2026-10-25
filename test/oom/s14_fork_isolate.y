// Coping strategy for a genuinely long-running program: do the allocating
// work in a child process, whose whole heap dies with it.  The parent's
// own cost is the fork block's closure record, ~64 bytes a task, no
// matter how much the task allocates.  Without the fork the same loop
// would retain every task's heap in the parent.
def task() -> long {
    let junk: [long] = [];
    for k in 0..200000 { junk += k; };
    junk.length
};
def arg_n(dflt: long) -> long {
    let a = argv();
    if (a.length > 1) {
        let v = a[1].tolong();
        if (v != none) { v! } else { dflt }
    } else { dflt }
};
def main() {
    let n = arg_n(200);
    let h0 = heap_used();
    let acc = 0;
    let i = 0;
    while (i < n) {
        let pid = fork { task(); exit(0); };
        if (pid > 0) { acc += wait_pid(pid); };
        i++;
    };
    let d = heap_used() - h0;
    print("s14_fork_isolate n=" + tostring(n) + " tasks=" + tostring(acc) +
        " heap=" + tostring(d) + " per_iter=" + tostring(d / n));
};
main();
