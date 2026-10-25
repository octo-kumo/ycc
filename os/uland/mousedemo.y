// mousedemo [legacy] -- asks the terminal for mouse reports (xterm modes 1000 and 1006; `legacy`
// leaves out 1006, so the reports are the old ESC [ M bytes) and prints each one as a line:
//   mouse press|release|wheel button=B col=C row=R      q quits.
import ulib;

let esc = chr(27);
let a = argv();
let sgr = !(len(a) >= 2 && a[1] == "legacy");

let saved = ulib.tty_get(0);
let t = ulib.tty_get(0);
if (len(t) > 0) {
    let lf = ulib.le(t, 12, 4) & ~(1 | 2 | 8 | 16 | 32 | 64 | 512 | 2048 | 32768);
    t[12] = lf & 255;
    t[13] = (lf >> 8) & 255;
    t[14] = (lf >> 16) & 255;
    t[15] = (lf >> 24) & 255;
    t[22] = 0;
    t[23] = 1;
    ulib.tty_set(0, t);
};
puts(esc + "[?1000h");
if (sgr) { puts(esc + "[?1006h"); };
puts("mousedemo: move, click or scroll over the terminal; q quits\n");

def next() -> long {
    let b = ulib.read(0, 1);
    if (len(b) == 0) { return 0 - 1; };
    b[0] + 0
};

def report(b: long, col: long, row: long, press: bool) -> void {
    let kind = if (b >= 64) { "wheel" } else if (press) { "press" } else { "release" };
    puts("mouse " + kind + " button=" + tostring(b) + " col=" + tostring(col) + " row=" + tostring(row) + "\n");
};

let go = true;
while (go) {
    let c = next();
    if (c < 0 || c == 113) {
        go = false;
    } else if (c == 27) {
        let c2 = next();
        if (c2 == 91) {
            let c3 = next();
            if (c3 == 60) {
                // ESC [ < b ; x ; y M|m
                let nums: [long] = [0, 0, 0];
                let k = 0;
                let end = 0;
                while (end == 0) {
                    let d = next();
                    if (d >= 48 && d <= 57) { nums[k] = nums[k] * 10 + d - 48; }
                    else if (d == 59) { if (k < 2) { k = k + 1; }; }
                    else { end = d; if (d < 0) { end = 77; }; };
                };
                report(nums[0], nums[1], nums[2], end == 77);
            } else if (c3 == 77) {
                let b = next() - 32;
                let col = next() - 32;
                let row = next() - 32;
                let press = (b & 3) != 3;
                report(b & 67, col, row, press);
            };
        };
    };
};
puts(esc + "[?1000l" + esc + "[?1006l");
if (len(saved) > 0) { ulib.tty_set(0, saved); };
