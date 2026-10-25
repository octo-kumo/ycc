// The raw-loop half of the foreach parity pair.
let a: [long] = [1, 2, 3, 4, 5, 6, 7, 8];
let s = 0;
for i in 0..a.length { s += a[i]; };
print(s);
