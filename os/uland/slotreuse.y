// slotreuse -- a task slot is reused once its task is reaped; nothing may leak from the old
// task into the new one. A child killed in the middle of a 30 s nanosleep leaves a pending
// sleep behind; the next child, which lands in the same slot and sleeps through the same
// address (the parent allocates nothing in between, so the heap lines up), must sleep its
// own 100 ms and not take over the dead one's deadline.
import ulib;

let st: [long; 1] = [0; 1];
let a = ulib.fork();
if (a == 0) { ulib.sleep_ms(30000); exit(0); };
let until = clock_us() + 50000;
while (clock_us() < until) { }
ulib.kill(a, 9);
ulib.wait_pid(a, st, 0);
let t0 = clock_us();
let b = ulib.fork();
if (b == 0) { ulib.sleep_ms(100); exit(0); };
ulib.wait_pid(b, st, 0);
let ms = (clock_us() - t0) / 1000;
if (ms >= 90 && ms < 5000) { puts("slotreuse ok\n"); } else { puts("slotreuse: the second sleep took " + tostring(ms) + " ms\n"); exit(1); };
