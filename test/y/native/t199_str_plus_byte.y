// `+` on a string auto-stringifies the non-string side, and a `byte` is a
// number like any other: `s[i]` yields one, so building a string from a
// glyph ramp or a digit table is the shape this file is. The emitter had
// arms for `long`, `float` and `bool` and none for `byte`, which fell
// through to the unknown-operand arm and pushed the byte's *value* where
// `y_str_cat` wants a pointer -- a dereference of 65, and SIGSEGV, with no
// diagnostic anywhere (the checker types the expression as `str`).

// an annotated byte, and the mirror with the byte on the left
let b: byte = 'A';
print("x" + b);
print(b + "x");

// the shape that found it: a lookup table indexed per iteration
let digits = "0123456789";
print("d=" + digits[3]);

let out = "";
let i = 0;
while (i < 5) { out = out + digits[i]; i = i + 1 };
print(out);

// the other sources of a byte the entry lists
let fixed: [byte; 4] = [65; 4];
print("f=" + fixed[1]);
let bs: [byte] = ['Z'];
print("a=" + bs[0]);

// a byte from a call, not a load: the value is the same either way
def pick(n: long) -> byte { digits[n] };
print("c=" + pick(7));

// and the types that already worked, so the whole family is pinned
let n: long = 65;
let f: float = 1.5;
let t: bool = true;
print("n" + n);
print("f" + f);
print("b" + t);
print(n + "n");
print(f + "f");
print(t + "t");