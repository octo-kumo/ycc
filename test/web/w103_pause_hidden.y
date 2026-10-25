// W5 pause_hidden: CLOCK_MONOTONIC must not advance while the page is hidden.
def sleep_ms(ms: long) -> void {
    let ts: [long; 2] = [0; 2];
    ts[0] = ms / 1000;
    ts[1] = (ms % 1000) * 1000000;
    os_call("y_os_nanosleep", &ts[0]);
};
let a = clock_us();
puts("A " + tostring(a) + "\n");
sleep_ms(150);
let b = clock_us();
puts("B " + tostring(b) + "\n");
sleep_ms(1200);
let c = clock_us();
puts("C " + tostring(c) + "\n");
puts("D " + tostring(c - b) + "\n");
