// The thread and process builtins check what they are given.
let t = spawn { 1 };
let n = 5;
let a = join n;
let b = spawn(n);
let c = fork(n);
let d = spawn();
let e = wait_pid();
let f = wait_pid("x");
let m = mutex(1);
let s = sem();
let g = sem("two");
let h = lock(m);
let i = lock n { 1 };
let j = try_lock m;
let k = lock(m, n);
post n;
wait(s, s);
let l = lock m 5;
// expect-error: 4:9: error: join takes a thread (a spawn's value), got long
// expect-error: 5:14: error: spawn takes a block (a function of no parameters), got long
// expect-error: 6:13: error: fork takes a block (a function of no parameters), got long
// expect-error: 7:14: error: spawn takes a block
// expect-error: 8:17: error: wait_pid takes exactly 1 argument (a pid)
// expect-error: 9:17: error: wait_pid's pid: expected long, got str
// expect-error: 10:14: error: mutex takes no arguments
// expect-error: 11:12: error: sem takes exactly 1 argument (its count)
// expect-error: 12:12: error: sem's count: expected long, got str
// expect-error: 13:13: error: lock takes a mutex and a block
// expect-error: 14:9: error: lock's mutex: expected mutex, got long
// expect-error: 15:19: error: expected '{' (the block try_lock runs), got ';'
// expect-error: 16:13: error: lock takes a block (a function of no parameters), got long
// expect-error: 17:1: error: post's semaphore: expected sem, got long
// expect-error: 18:5: error: wait takes exactly 1 argument (a sem)
// expect-error: 19:16: error: expected '{' (the block lock runs), got '5'
