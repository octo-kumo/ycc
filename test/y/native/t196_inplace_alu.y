// Every `x op= v` and `x++` a plain long local takes in place, with the value
// printed at each step (B2, and the `*` that has no immediate form).
def f(n: long) -> long {
  let x: long = 3;
  x += 4;
  print(x);
  x -= 2;
  print(x);
  x *= 5;          // no `imul $imm, mem`: the register form, not a broken one
  print(x);
  x *= n;          // and a non-literal right-hand side
  print(x);
  x |= 8;
  print(x);
  x &= 12;
  print(x);
  x ^= 1;
  print(x);
  x++;
  print(x);
  x--;
  x--;
  print(x);
  // the same operators as an expression keep the desugar (the value is read)
  let y: long = 2;
  let z: long = { y *= 3; y };
  print(z);
  print(y);
  print(y++);
  print(y);
  return x
};
print(f(2));
// a byte target is not a plain long: the desugar stays
def g(b: byte) -> byte {
  b += 1;
  print(b);
  b++;
  b
};
print(g(3));
// a global is a .bss cell, not a frame slot: the desugar stays
let g1: long = 6;
g1 += 1;
g1 *= 3;
print(g1);