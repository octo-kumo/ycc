// Fixed arrays are first-class heap values (a {len, cap, data} header on the
// arena, exactly like [T]), so binding one to a second name shares it and a
// write through either name is visible through both. This replaces the old
// e06_arrfirst rejection test: the "not first-class" restriction existed
// while [v; n] lived in stack slots.
let a = [0; 4];
let b = a;
b[1] = 9;
print(a[1]);
print(len(b));
a[3] = 4;
print(b[3]);
