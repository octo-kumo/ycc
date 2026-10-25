// A forked child must not wait for a thread that started in its parent (M21).
// The child's copy of the thread's control block names the parent's tid, and
// that thread cannot end as far as the child's address space is concerned: it
// would wait on a word nobody will ever clear, and the parent waits in
// wait_pid, so both stopped with no diagnostic at all. It traps instead.
//
// Only the child writes the trap line and the parent waits for it, so the
// order below is fixed.
let t = spawn { sleep(200); 40 + 2 };

let pid = fork(def () -> long {
    let v = join(t);
    print("child: joined -> ", v, " (should not happen)");
    0
});
if (pid > 0) { wait_pid(pid); print("parent: reaped"); };

// The parent's own join is unaffected, and a thread the child starts itself is
// its own.
print("parent: join gives ", join(t));
let pid2 = fork(def () -> long {
    let mine = spawn { 7 };
    print("child: my own thread gives ", join(mine));
    0
});
if (pid2 > 0) { wait_pid(pid2); };
print("done");