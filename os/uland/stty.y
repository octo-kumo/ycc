// stty [-a] [size] [rows N] [cols N] [columns N] [sane] [raw] [cooked]
//      [min N] [time N] [echo|-echo] [icanon|-icanon] [isig|-isig] [icrnl|-icrnl]
//      [opost|-opost] [onlcr|-onlcr] -- show or set the console's termios.
import ulib;

const TCGETS = 21505;
const TCSETS = 21506;
const TIOCGWINSZ = 21523;
const TIOCSWINSZ = 21524;

let tm: [byte; 40] = [0; 40];
let ws: [byte; 8] = [0; 8];

def u32(off: long) -> long {
    tm[off] | (tm[off + 1] << 8) | (tm[off + 2] << 16) | (tm[off + 3] << 24)
};

def put32(off: long, v: long) -> void {
    tm[off] = v & 255;
    tm[off + 1] = (v >> 8) & 255;
    tm[off + 2] = (v >> 16) & 255;
    tm[off + 3] = (v >> 24) & 255;
};

/** Set (on) or clear the bits `mask` of the flag word at `off`. */
def flag(off: long, mask: long, on: bool) -> void {
    let v = u32(off);
    if (on) { v = v | mask; } else { v = v & (0 - 1 - mask); };
    put32(off, v);
};

def rows() -> long { ws[0] | (ws[1] << 8) };
def cols() -> long { ws[2] | (ws[3] << 8) };

def put_size(r: long, c: long) -> void {
    ws[0] = r & 255;
    ws[1] = (r >> 8) & 255;
    ws[2] = c & 255;
    ws[3] = (c >> 8) & 255;
    ws[4] = 0;
    ws[5] = 0;
    ws[6] = 0;
    ws[7] = 0;
};

def sane() -> void {
    put32(0, 1280);
    put32(4, 5);
    put32(12, 35387);
    tm[17 + 0] = 3;
    tm[17 + 1] = 28;
    tm[17 + 2] = 127;
    tm[17 + 3] = 21;
    tm[17 + 4] = 4;
    tm[17 + 5] = 0;
    tm[17 + 6] = 1;
};

def raw() -> void {
    flag(0, 1 | 32 | 64 | 128 | 256 | 1024, false);
    flag(4, 1, false);
    flag(12, 1 | 2 | 8 | 16 | 32 | 64 | 512 | 2048 | 32768, false);
    tm[17 + 5] = 0;
    tm[17 + 6] = 1;
};

def cooked() -> void {
    flag(0, 256 | 1024, true);
    flag(4, 1 | 4, true);
    flag(12, 1 | 2 | 8 | 16 | 32 | 512 | 2048 | 32768, true);
};

def yes(w: long, mask: long, name: str) -> str {
    if ((u32(w) & mask) != 0) { name + " " } else { "-" + name + " " }
};

def show() -> void {
    puts("speed 38400 baud; rows " + tostring(rows()) + "; columns " + tostring(cols()) + ";\n");
    puts("min = " + tostring(tm[17 + 6]) + "; time = " + tostring(tm[17 + 5]) + ";\n");
    let s = yes(12, 1, "isig") + yes(12, 2, "icanon") + yes(12, 8, "echo") + yes(12, 16, "echoe") + yes(12, 32, "echok");
    s += yes(0, 256, "icrnl") + yes(0, 1024, "ixon") + yes(4, 1, "opost") + yes(4, 4, "onlcr");
    puts(s + "\n");
};

def num(a: [str], i: long) -> long {
    if (i >= len(a)) {
        puts("stty: missing number\n");
        exit(1);
    };
    let v = tolong(a[i]);
    if (v == none) {
        puts("stty: bad number: " + a[i] + "\n");
        exit(1);
    };
    v!
};

let a = argv();
if (syscall(16, 0, TCGETS, ptr_addr(&tm[0])) < 0) {
    puts("stty: not a terminal\n");
    exit(1);
};
syscall(16, 0, TIOCGWINSZ, ptr_addr(&ws[0]));
let i = 1;
let size_changed = false;
let shown = len(a) == 1;
while (i < len(a)) {
    let w = a[i];
    if (w == "-a") { shown = true; }
    else if (w == "size") { puts(tostring(rows()) + " " + tostring(cols()) + "\n"); }
    else if (w == "rows") { i = i + 1; put_size(num(a, i), cols()); size_changed = true; }
    else if (w == "cols" || w == "columns") { i = i + 1; put_size(rows(), num(a, i)); size_changed = true; }
    else if (w == "min") { i = i + 1; tm[17 + 6] = num(a, i) & 255; }
    else if (w == "time") { i = i + 1; tm[17 + 5] = num(a, i) & 255; }
    else if (w == "sane") { sane(); }
    else if (w == "raw") { raw(); }
    else if (w == "cooked") { cooked(); }
    else if (w == "echo") { flag(12, 8, true); }
    else if (w == "-echo") { flag(12, 8, false); }
    else if (w == "icanon") { flag(12, 2, true); }
    else if (w == "-icanon") { flag(12, 2, false); }
    else if (w == "isig") { flag(12, 1, true); }
    else if (w == "-isig") { flag(12, 1, false); }
    else if (w == "icrnl") { flag(0, 256, true); }
    else if (w == "-icrnl") { flag(0, 256, false); }
    else if (w == "opost") { flag(4, 1, true); }
    else if (w == "-opost") { flag(4, 1, false); }
    else if (w == "onlcr") { flag(4, 4, true); }
    else if (w == "-onlcr") { flag(4, 4, false); }
    else {
        puts("stty: unknown argument: " + w + "\n");
        exit(1);
    };
    i = i + 1;
};
if (len(a) > 1 && !(len(a) == 2 && (a[1] == "-a" || a[1] == "size"))) {
    syscall(16, 0, TCSETS, ptr_addr(&tm[0]));
    if (size_changed) { syscall(16, 0, TIOCSWINSZ, ptr_addr(&ws[0])); };
};
if (shown) { show(); };
