// One image, two behaviours: the spinner never makes a system call, so the
// only thing that can take the CPU away from it is the timer.
let a = argv();
if (a[0] == "spin") {
    let i = 0;
    while (i < 60000000) { i = i + 1; };
    puts("spin done\n");
} else {
    puts("print ran\n");
};
