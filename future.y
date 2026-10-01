// this file contains some ideas for future.
// planned but not yet decided on how exactly i want them to look like.
// locks, semaphores, and other concurrency primitives

let thread1 = spawn {
    // thread body goes here
};

let thread2 = spawn {
    // another thread body goes here
};

let m = mutex();
lock m {
    // critical section code goes here
}

let s = sem(0);
s.wait();
s.post();