// W4: sleeps order wakeups -- three sleepers with different delays wake in
// deadline order, and the main thread sees them in that order.  The host's
// timer queue drives the blocking nanosleep.
def sleep_us(us: long) -> void {
    let ts: [long; 2] = [0; 2];
    ts[0] = us / 1000000;
    ts[1] = (us % 1000000) * 1000;
    os_call("y_os_nanosleep", &ts[0]);
};
def sleeper(ms: long, tag: str) -> long {
    sleep_us(ms * 1000);
    print(tag);
    ms
};
let order: [str] = [];
// 100 ms apart, so a host that resumes a thread a little late (the suite runs
// four at a time) cannot swap two wakeups.
let a = spawn { sleeper(300, "a") };
let b = spawn { sleeper(100, "b") };
let c = spawn { sleeper(200, "c") };
// join in spawn order: the sleepers still wake by deadline, so the tags come
// out b, c, a while the join values are 100, 200, 300.
let ra = join a;
let rb = join b;
let rc = join c;
print(rb, " ", rc, " ", ra);
