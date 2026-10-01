// .length on arrays and strings; .ptr on arrays: a *T to the first element
// (a *byte reads and writes exactly one byte).
let a = [1, 2, 3];
print(a.length);
let s = "hello";
print(s.length);
print("".length);
let b: [byte] = [c'a', c'b', c'c', c'd'];
let p = b.ptr;
print(*p);
*p = c'z';
print(b[0]);
print(b[1]);
print(b[2]);
let q = a.ptr;
print(*q);
*q = 9;
print(a);
let e: [long] = [];
print(e.length);
let rs = [{x: 1}, {x: 2}];
print(rs.length);
print(a.length + s.length);