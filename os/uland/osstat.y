// osstat -- the kernel's counters in the terminal (the numbers the GUI's F3 monitor draws).
//
//   osstat          one snapshot: uptime, CPU, memory, activity and the tasks
//   osstat check    verify the snapshot is self-consistent; prints "osstat: ok" (what the tests run)
//
// Needs a display: the counters are read through /dev/fb0 (FB_STATS, kernel/fbdev.y).
import ulib;
import kmon;

def snap(fd: long) -> bool {
    kmon.init(fd) && kmon.sample()
};

def check() -> long {
    let c = kmon.cur;
    let bad = "";
    if (c[0] != 1) { bad = "version"; };
    if (c[1] <= 0) { bad = "uptime"; };
    if (c[7] <= 0 || c[8] + c[9] > c[7]) { bad = "memory"; };
    // every byte of RAM is in exactly one bucket: the tagged ones cannot exceed what was carved, and
    // the buckets together cannot exceed RAM
    let sum = 0;
    let k = 0;
    while (k < kmon.NSEG) { sum = sum + kmon.seg[k]; k = k + 1; };
    if (sum + c[8] != c[7]) { bad = "memory buckets"; };
    if (c[47] < c[43] + c[44] + c[45] + c[46]) { bad = "page region"; };
    if (c[30] <= 0 || c[31] <= 0) { bad = "image"; };
    if (c[4] <= 0) { bad = "syscalls"; };
    if (c[12] < 2) { bad = "tasks"; };
    if (c[26] != c[12]) { bad = "rows"; };
    let me = false;
    let i = 0;
    while (i < kmon.ntask) {
        if (kmon.t_name[i] == "osstat" && kmon.t_state[i] == 1 && kmon.t_pid[i] == ulib.getpid()) { me = true; };
        i = i + 1;
    };
    if (!me) { bad = "own row"; };
    if (bad != "") {
        puts("osstat: bad " + bad + "\n");
        return 1;
    };
    puts("osstat: ok\n");
    0
};

def show() -> void {
    let c = kmon.cur;
    puts("uptime " + kmon.uptime_str(c[1]) + "  ticks " + tostring(c[2]) + "  syscalls " + tostring(c[4]) + "  switches " + tostring(c[5]) + "  faults " + tostring(c[6]) + "\n");
    puts("RAM " + kmon.bytes_str(c[7]) + " = never used " + kmon.bytes_str(c[8]) + " + " + kmon.bytes_str(c[7] - c[8]) + " in use:\n");
    let names = ["user pages", "page tables", "kernel heap (used)", "kernel heap (reserved, unused)", "framebuffers", "kernel stacks", "pipes, devices", "other kernel", "image + fs", "low memory + gaps", "recycled pages"];
    let k = 0;
    while (k < kmon.NSEG) {
        puts("  " + kmon.pad_r(names[k], 32) + kmon.pad_l(kmon.bytes_str(kmon.seg[k]), 11) + "\n");
        k = k + 1;
    };
    puts("page region carved " + kmon.bytes_str(c[47]) + ": fb " + kmon.bytes_str(c[43]) + " stacks " + kmon.bytes_str(c[44]) + " pipes " + kmon.bytes_str(c[45]) + " dev " + kmon.bytes_str(c[46]) + " user " + kmon.bytes_str(c[29] * 4096) + " ptab " + kmon.bytes_str(c[42] * 4096) + " recycled " + kmon.bytes_str(c[9]) + "\n");
    puts("forks " + tostring(c[18]) + "  execs " + tostring(c[19]) + "  exits " + tostring(c[20]) + "  tasks " + tostring(c[12]) + "  input events " + tostring(c[17]) + "\n");
    puts(" PID PPID ST    TICKS     RES  NAME\n");
    let i = 0;
    while (i < kmon.ntask) {
        let res = if (kmon.t_thread[i] != 0) { "       -" } else { kmon.pad_l(tostring(kmon.t_pages[i] * 4) + "K", 8) };
        puts(kmon.pad_l(tostring(kmon.t_pid[i]), 4) + kmon.pad_l(tostring(kmon.t_ppid[i]), 5) + " " + kmon.pad_r(kmon.state_str(kmon.t_state[i]), 4) + kmon.pad_l(tostring(kmon.t_ticks[i]), 8) + res + "  " + kmon.t_name[i] + "\n");
        i = i + 1;
    };
};

let fd = ulib.open("/dev/fb0", 2);
if (fd < 0) {
    puts("osstat: no display (the counters are read through /dev/fb0)\n");
    exit(1);
};
if (!snap(fd)) {
    puts("osstat: the kernel gave no snapshot\n");
    exit(1);
};
let args = argv();
if (len(args) > 0 && args[len(args) - 1] == "check") { exit(check()); };
show();
