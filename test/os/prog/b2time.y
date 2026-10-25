// the clocks and sleeping.  Prints a verdict per check, never a time.
let ts: [long; 2] = [0, 0];
let tv: [long; 2] = [0, 0];

def mono_us() -> long {
    syscall(228, 1, &ts[0]);
    ts[0] * 1000000 + ts[1] / 1000
};

def check(name: str, ok: bool) -> void {
    if (ok) { print(name + ": ok"); } else { print(name + ": FAIL"); };
};

// monotonic and non-decreasing across many reads
let prev = mono_us();
let steady = true;
for i in 0..2000 {
    let now = mono_us();
    if (now < prev) { steady = false; };
    prev = now;
};
check("monotonic", steady);

// realtime is after 2020 and gettimeofday / time agree with it
syscall(228, 0, &ts[0]);
let real = ts[0];
check("realtime year", real > 1577836800 && real < 4102444800);
syscall(96, &tv[0], 0);
check("gettimeofday", tv[0] >= real && tv[0] <= real + 5 && tv[1] >= 0 && tv[1] < 1000000);
let t = syscall(201, 0);
check("time", t >= real && t <= real + 5);
check("bad clock", syscall(228, 99, &ts[0]) == 0 - 22);
syscall(229, 1, &ts[0]);
check("getres", ts[0] == 0 && ts[1] > 0 && ts[1] <= 10000000);

// nanosleep sleeps at least what it was asked, and not absurdly more
let req: [long; 2] = [0, 50000000];
let a = mono_us();
let r = syscall(35, &req[0], 0);
let b = mono_us();
check("nanosleep 50ms returns 0", r == 0);
check("nanosleep >= 50ms", b - a >= 50000);
check("nanosleep < 500ms", b - a < 500000);

// a sleep of one second takes a second of the machine's clock
req[0] = 1;
req[1] = 0;
a = mono_us();
syscall(35, &req[0], 0);
b = mono_us();
check("nanosleep 1s", b - a >= 1000000 && b - a < 1500000);

// clock_nanosleep: relative and absolute
req[0] = 0;
req[1] = 20000000;
a = mono_us();
r = syscall(230, 1, 0, &req[0], 0);
b = mono_us();
check("clock_nanosleep rel", r == 0 && b - a >= 20000 && b - a < 400000);
syscall(228, 1, &ts[0]);
req[0] = ts[0];
req[1] = ts[1] + 30000000;
if (req[1] >= 1000000000) { req[0] += 1; req[1] -= 1000000000; };
a = mono_us();
r = syscall(230, 1, 1, &req[0], 0);
b = mono_us();
check("clock_nanosleep abs", r == 0 && b - a >= 25000 && b - a < 400000);
req[1] = 5000000000;
check("bad nsec", syscall(35, &req[0], 0) == 0 - 22);

// sched_yield returns
check("sched_yield", syscall(24) == 0);
