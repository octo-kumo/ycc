// A forked child must not wait for a lock its parent holds (M21). The child
// inherits the mutex's word and nobody in the child will ever release it, so
// before the fix this blocked forever -- and the parent blocked in wait_pid,
// so the program stopped with no diagnostic at all. It traps instead.
//
// try_lock is not a trap: the mutex is held, so false is the honest answer.
// Only the child writes the trap line and the parent waits for it, so the
// order below is fixed.
let held = mutex();

def child() -> long {
    lock held { print("child: got the lock (should not happen)"); 0 };
    0
};

lock held {
    let free = try_lock held { print("child: not it"); 0 };
    print("parent: try_lock while holding gives ", free);
    let pid = fork(child);
    if (pid > 0) { wait_pid(pid); }
};
print("parent: released");

// The child's own mutex works as usual, and one it took and released is free
// again.
let mine = mutex();
let pid2 = fork(def () -> long {
    lock mine { print("child: my own lock works"); 0 };
    let again = try_lock mine { print("child: took it again"); 0 };
    print("child: after my lock, try_lock gives ", again);
    0
});
if (pid2 > 0) { wait_pid(pid2); };
print("done");