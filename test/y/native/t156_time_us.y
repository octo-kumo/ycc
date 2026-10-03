// time_us() is the wall clock: microseconds since the Unix epoch (UTC,
// CLOCK_REALTIME), which can jump when the clock is set. clock_us() is
// the monotonic clock, for intervals.
let t = time_us();
// after 2020-01-01 and before 2100-01-01
print(t > 1577836800000000, " ", t < 4102444800000000);
// whole days since the epoch: past 2020-01-01's
print(t / 1000000 / 86400 >= 18262);
let m0 = clock_us();
sleep(2);
print(clock_us() - m0 >= 2000);
