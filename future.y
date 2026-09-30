// this file contains some ideas for future.
// planned but not yet decided on how exactly i want them to look like.
// locks, semaphores, and other concurrency primitives

lock(long); // pass in a long to use as lock id, should be reentrant, so the same thread can acquire it multiple times without deadlocking

let thread1 = spawn {
    // thread body goes here
};

let thread2 = spawn {
    // another thread body goes here
};

