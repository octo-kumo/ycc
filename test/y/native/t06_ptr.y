let x: long = 41;
let p: *long = &x;
print(*p);
*p = *p + 1;
print(x);
let q = &x;
print(*q);
print(p == q);
