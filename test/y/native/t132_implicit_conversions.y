// The implicit numeric conversions happen wherever a value is stored under
// a declared type: long/byte -> float converts, long -> byte keeps the low
// 8 bits. Every store path, with the expected value alongside.
let b: byte = 258;
print(b);                           // 2
let f: float = c'A';
print(f);                           // 65.000000
let g: float = 3;
print(g);                           // 3.000000
def h(x: float) -> float { x };
print(h(2));                        // 2.000000
print(h(c'A'));                     // 65.000000
def hb(x: byte) -> long { x + 0 };
print(hb(300));                     // 44
let arr: [byte] = [c'a', c'b'];
arr[0] = 300;
print(arr[0]);                      // 44 (packed store)
let fb: [byte; 2] = [c'a'; 2];
fb[1] = 258;
print(fb[1]);                       // 2
let bb: byte = c'A';
let lf: float = bb;
print(lf);                          // 65.000000
let ll: long = bb;
print(ll);                          // 65
let fx: float = 0.5;
fx = c'B';
print(fx);                          // 66.000000
let by: byte = c'z';
by = 513;
print(by);                          // 1
def tsum(n: long, s: float) -> float { if (n == 0) { s } else { self(n - 1, n) } };
print(tsum(3, 0.5));                // 1.000000 (tail self call)
def depth(n: long) -> float { if (n == 0) { return 0; }; 1.5 + self(n - 1) };
print(depth(2));                    // 3.000000
let cf = def(x: float) -> float { x * 2.0 };
print(cf(3));                       // 6.000000 (closure value call)
let rec = { f: def(x: float) -> float { x } };
print(rec.f(4));                    // 4.000000 (call through a field)
let lit = [1.5, 2];
print(lit[1]);                      // 2.000000 (unannotated literal)
let ml = { "a": 1.5, "b": 2 };
print(unwrap(ml["b"]));             // 2.000000 (map literal value)
let pa: [float] = [];
pa += 1;
pa *= 2;
print(pa[0]);                       // 2.000000 (prepend)
print(pa[1]);                       // 1.000000 (push)
let fl: [float] = [0.5];
let lo = [7, 8];
let cat = fl + lo;
print(cat[2]);                      // 8.000000 ([float] + [long])
let lb: [long] = [1];
let bs1: [byte] = [c'a'];
let cat2 = lb + bs1;
print(cat2[1]);                     // 97 ([long] + [byte])
let cat3 = bs1 + lo;
print(cat3[2]);                     // 8 ([byte] + [long] packs)
print(len(cat3));                   // 3
let cons = 3 :: fl;
print(cons[0]);                     // 3.000000
let fa: [float] = [0.5];
fa += lo;
print(fa[2]);                       // 8.000000 ([float] += [long])
let bt: byte = 255;
bt++;
print(bt);                          // 0
let pre = ++bt;
print(pre);                         // 1
let bv = { bt += 300 };
print(bv);                          // 45 (the value stored)
print(bt);                          // 45
def r1() -> float { return 3; };
print(r1());                        // 3.000000
def r2(c: bool) -> float { if (c) { 1 } else { 2 } };
print(r2(false));                   // 2.000000
def rb() -> byte { 300 };
print(rb());                        // 44
let nb: byte = -1;
print(nb);                          // 255
let ub: byte = c'a';
let ng: byte = -ub;
print(ng);                          // 159
print(-ub);                         // -97 (negation is long arithmetic)
print(1 < 2.5);                     // true
print(2.5 > 2);                     // true
print(1 == 1.0);                    // true
print(2 != 2.0);                    // false
let gf: float = 0.0;
def setg() { gf = 7; };
setg();
print(gf);                          // 7.000000 (global store)
let cv = 0.5;
let setc = def() { cv = 9; };
setc();
print(cv);                          // 9.000000 (captured store)
let o2 = { p: { x: 1.5 } };
o2.p.x = 3;
print(o2.p.x);                      // 3.000000 (nested field)
let g2: [[float]] = [[0.5]];
g2[0][0] = 4;
print(g2[0][0]);                    // 4.000000 (nested element)
let rx = { x: 1.5 };
rx.x += 1;
print(rx.x);                        // 2.500000
let fe: [float] = [1.0];
fe[0] += 1;
print(fe[0]);                       // 2.000000
let fx2: [float; 2] = [1, 2];
print(fx2[1]);                      // 2.000000 (fixed literal adopts)
let fr: [float] = [5; 3];
print(fr[2]);                       // 5.000000 ([v; n] adopts)
let bs: [byte] = [];
bs += [104, 300];
print(bs[1]);                       // 44 (+= packs)
let m: { str => float } = {};
m["a"] = 3;
print(unwrap(m["a"]));              // 3.000000
let pf = 0.0;
let pp = &pf;
*pp = 3;
print(pf);                          // 3.000000
