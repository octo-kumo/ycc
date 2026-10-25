// W4: threads on the web -- spawn/join, a mutex and a semaphore, four threads.
// The same shape as the native t160_threads (which also forks, so it stays
// skipped); the host's clone/futex implement the rest.
def work(n: long) -> long {
    let i = 0;
    let sum = 0;
    while (i < n) { sum = sum + i; i = i + 1; };
    sum
};
let t1 = spawn { work(1000) };
let t2 = spawn { work(2000) };
print(join t1, " ", join t2, " ", t1());
let counter = 0;
let m = mutex();
let ts: [() -> long] = [];
let k = 0;
while (k < 4) {
    ts += spawn {
        let i = 0;
        while (i < 10000) { lock m { counter = counter + 1; }; i = i + 1; };
        0
    };
    k = k + 1;
};
foreach (t in ts) { join t; };
print(counter);
let items: [long] = [];
let full = sem(0);
let guard = mutex();
let p = spawn {
    let i = 0;
    while (i < 8) { lock guard { items += i; }; post full; i = i + 1; };
    0
};
let j = 0;
while (j < 8) { wait full; j = j + 1; };
join p;
lock guard { print(join(items, ",")); };
