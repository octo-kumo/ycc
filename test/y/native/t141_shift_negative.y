// A negative shift count stops the program: x86 would quietly shift by
// the count's low 6 bits.
let n = 3 - 4;
print(1 << 2);
print(1 << n);
print("unreachable");
