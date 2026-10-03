// Threads and processes (CHOICES_MADE.md 33): spawn { } runs a block on
// a thread of its own, its value -- `join t`, or t() -- once it ends; a
// mutex guards what threads share (lock m { }, try_lock m { }); a
// semaphore counts (post s; wait s;); fork { } runs a block in a child
// process, wait_pid its exit code. Each thread allocates from a heap of
// its own.
def work(n: long) -> long {
    let i = 0;
    let sum = 0;
    while (i < n) {
        sum = sum + i;
        i = i + 1;
    };
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
        while (i < 10000) {
            lock m { counter = counter + 1; };
            i = i + 1;
        };
        0
    };
    k = k + 1;
};
foreach (t in ts) { join t; };
print(counter);

let items: [long] = [];
let full = sem(0);
let guard = mutex();
let producer = spawn {
    let i = 0;
    while (i < 5) {
        lock guard { items += i * i; };
        post full;
        i = i + 1;
    };
    0
};
let j = 0;
while (j < 5) {
    wait full;
    j = j + 1;
};
join producer;
print(items);

let tl = mutex();
let r = lock tl {
    let probe = spawn { try_lock tl { 1 } };
    join probe
};
print(r, " ", try_lock tl { 2 });

let pid = fork { exit(7); };
print(wait_pid(pid));
let pid2 = fork { print("in child"); };
print(wait_pid(pid2), " ", wait_pid(99999999));
let strs = spawn { let acc = ""; let i = 0; while (i < 1000) { acc += "ab"; i = i + 1; }; acc };
print(len(join strs));

// mutex and sem are types: fields, parameters and arrays hold them.
type Account = {guard: mutex, balance: long};
def deposit(a: Account, n: long) -> void {
    lock a.guard { a.balance = a.balance + n; };
}
let acct: Account = {guard: mutex(), balance: 0};
let done = sem(0);
let sems: [sem] = [done];
let ds: [() -> long] = [];
let q = 0;
while (q < 3) {
    ds += spawn { deposit(acct, 10); post sems[0]; 0 };
    q = q + 1;
};
let w = 0;
while (w < 3) { wait done; w = w + 1; };
foreach (t in ds) { join t; };
print(acct.balance);
let quiet = spawn { print("void thread"); };
join quiet;
