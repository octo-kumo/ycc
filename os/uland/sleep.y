// sleep SECONDS -- wait (fractions work: sleep 0.5).
import ulib;
let a = argv();
if (len(a) != 2) { puts("usage: sleep <seconds>\n"); exit(1); };
let t = a[1];
let whole = 0;
let frac = 0;
let digits = 0;
let seen_dot = false;
let i = 0;
while (i < len(t)) {
    let c = t[i];
    if (c == 46 && !seen_dot) { seen_dot = true; }
    else if (c >= 48 && c <= 57) {
        if (!seen_dot) { whole = whole * 10 + (c - 48); }
        else if (digits < 3) {
            digits = digits + 1;
            frac = frac * 10 + (c - 48);
        };
    } else {
        puts("sleep: bad time " + t + "\n");
        exit(1);
    };
    i = i + 1;
};
while (digits < 3) { frac = frac * 10; digits = digits + 1; };
ulib.sleep_ms(whole * 1000 + frac);
