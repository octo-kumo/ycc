// `a[lo:hi] = src` copies front to back in one runtime call (rt.y
// y_arr_setslice1/8 over prelude.s y_copy_fwd): eight bytes at a time when the
// destination starts eight or more bytes past the source, one at a time when
// closer, so a source that overlaps reads what an element loop would.
let a = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
a[2:5] = [30, 40, 50];
print(a);
let b: [byte] = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20];
b[1:4] = b[0:3];
print(b);
let big: [byte] = [];
for i in 0..40 { big += i; };
big[3:40] = big[0:37];
print(big[0:12]);
print(big[36:40]);
let w = [0, 1, 2, 3, 4];
w[1:5] = w[0:4];
print(w);
let s = ["x", "y", "z"];
s[0:2] = ["p", "q"];
print(s);
a[3:3] = [];
print(a.length);
