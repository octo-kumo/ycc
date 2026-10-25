// Allocates once, outside any loop: the default --gc=auto must not link the
// collector at all (src/tools/ytest/su_treeshake.y gates that), and --gc=always
// must. The program prints the same thing either way.
let a: [long] = [1, 2, 3];
print(a[0] + a[1] + a[2]);
