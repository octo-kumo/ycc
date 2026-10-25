// W4/S5: idiv/div.  Y's / and % widen with cqo and then idiv, so this
// exercises the fast path (and the MIN/-1 guard the emitter puts in front of
// it) at both signs; the 128-bit helpers are reached only from asm that
// leaves a wide rdx, and the web-forms probe is what lowers that path.  The
// last line divides by zero: the runtime reports it and exits 1, exactly as
// it does natively.
def dv(a: long, b: long) -> long { a / b };
def md(a: long, b: long) -> long { a % b };

print(dv(7, 2), " ", dv(-7, 2), " ", dv(7, -2), " ", dv(-7, -2), "\n");
print(md(7, 2), " ", md(-7, 2), " ", md(7, -2), " ", md(-7, -2), "\n");
let min = -9223372036854775807 - 1;
print(dv(min, 1), " ", md(min, 1), "\n");
print(dv(min, -1), " ", md(min, -1), "\n");
print(dv(1000000000000, 7), " ", md(1000000000000, 7), "\n");
print(dv(0, 5), " ", md(0, 5), "\n");
let i = 1;
let bad = 0;
while (i < 1000) {
    if (md(i * 1000, 7) != (i * 1000) % 7) { bad = bad + 1; };
    i = i + 1;
};
print("div ok ", bad, "\n");
print(dv(1, 0), "\n");
