// The first userland program: an ordinary ycc program, built with the normal
// Linux target, that runs in ring 3 here because the kernel implements the
// ABI its runtime already speaks.
puts("hello from userland\n");
let xs: [long] = [];
let i = 0;
while (i < 5) { xs += i * i; i = i + 1; };
print("sum: " + tostring(xs[0] + xs[1] + xs[2] + xs[3] + xs[4]));
