// Pointer arithmetic: p +/- n moves by whole elements (the pointee's
// width), n + p is the mirror, p - q counts elements, and +=/-=/++/-- work
// through the same scaling. Comparison stays the raw address order.
let a = [10, 20, 30, 40];
let p = a.ptr;
print(*(p + 1));
print(*(1 + p));
print(*(p + 3));
print(p - a.ptr);
let q = p + 2;
print(q - p);
print(q > p, q == p + 2);
q -= 1;
print(*q);
q++;
print(*q);
q = q - 2;
print(*q);

let bytes: [byte; 4] = [65, 66, 67, 68];
let b: *byte = &bytes[0];
print(*(b + 1));
print(*(3 + b));
print(b + 3 - b);
b += 2;
print(*b);
b--;
print(*b);

let fixed: [long; 3] = [7, 8, 9];
let f = fixed.ptr;
print(*(f + 2));
print((f + 2) - f);
print(*(f + 2));
