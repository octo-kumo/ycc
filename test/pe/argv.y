// argv() on Windows: the process has a single UTF-16 command line, and y_argv_win
// cuts it the way the C runtime does. pe-gate runs this with a handful of
// arguments and compares what it prints with argv.expected.
let a = argv();
print(len(a));
let i = 1;
while (i < len(a)) {
    print(i, " [", a[i], "] ", len(a[i]));
    i = i + 1;
};
