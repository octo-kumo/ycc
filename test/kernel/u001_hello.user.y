// A userland program: the ordinary Linux target, unchanged.
puts("hello from userland\n");
let xs: [long] = [];
let i = 0;
while (i < 5) { xs += i * i; i = i + 1; };
print("sum: " + tostring(xs[0] + xs[1] + xs[2] + xs[3] + xs[4]));
