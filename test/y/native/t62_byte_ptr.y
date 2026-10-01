// *p through a *byte loads and stores one byte (it used to move 8, so the
// load read the neighbours too and the store clobbered them).
let b: [byte] = [c'a', c'b', c'c', c'd'];
let p = &b[0];
print(*p);
*p = c'z';
print(b[0]);
print(b[1]);