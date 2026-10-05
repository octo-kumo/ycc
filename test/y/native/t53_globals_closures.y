// Top-level variables are globals; named functions that capture are
// closures everywhere they are named (regression: a capturing def called
// by name from another function used to run without its record).

// globals read and written from functions, called from functions
let counter = 0;
def bump() -> long { counter += 1; counter };
def bump_twice() -> long { bump(); bump() };
print(bump_twice());
print(counter);

// forward calls between top-level defs that read a global
let y = 5;
def fa() -> long { fb() + 1 };
def fb() -> long { y };
print(fa());
y = 10;
print(fa());

// every value kind as a global
let names: [str] = [];
def add_name(n: str) -> long { names += n; len(names) };
add_name("a");
add_name("b");
puts(join(names, ",") + "\n");
let msg = "hi";
def greet() -> str { msg + "!" };
puts(greet() + "\n");
let rec = { a: 1, b: "x" };
def geta() -> long { rec.a };
rec.a = 9;
print(geta());
let fl = 1.5;
def half() -> float { fl / 2.0 };
print(half());
let M = { "k": 3 };
def getk(k: str) -> long { let v = M[k]; if (v == none) { 0 } else { v! } };
def getk2(k: str) -> long { getk(k) + 1 };
print(getk2("k"));

// a global's address, and a function value held in a global
let p = &counter;
*p = 41;
print(counter);
let fnv = bump;
print(fnv());
def call_fnv() -> long { fnv() };
print(call_fnv());

// re-declared (shadowed) globals
let x = 1;
let x = x + 1; // expect-warning: 'x' is declared more than once; the last declaration counts (the earlier one at line 51)
def getx() -> long { x };
print(getx());

// a nested def that captures, called by name from a sibling
def outer() -> long {
    let v = 3;
    def inner() -> long { v };
    def caller() -> long { inner() + 1 };
    caller()
};
print(outer());

// ... recursing by its own name, in and out of tail position
def fact_scaled(n: long) -> long {
    let base = 100;
    def fact(k: long) -> long { if (k <= 1) { base } else { k * fact(k - 1) } };
    fact(n)
};
print(fact_scaled(5));
def count(n: long) -> long {
    let step = 1;
    def go(k: long, acc: long) -> long { if (k == 0) { acc } else { go(k - step, acc + 1) } };
    go(n, 0)
};
print(count(200000));

// ... naming itself as a value
def self_value() -> long {
    let z = 7;
    def me(k: long) -> long { if (k == 0) { z } else { let g = me; g(k - 1) } };
    me(3)
};
print(self_value());

// ... reached through another closure and through a literal
def chain() -> long {
    let w = 3;
    def inner() -> long { w };
    def mid() -> long { inner() * 2 };
    let lam = def() -> long { mid() + inner() };
    lam()
};
print(chain());

// ... escaping, and sharing the captured variable with its scope
def make_counter() -> () -> long {
    let n = 0;
    def next() -> long { n += 1; n };
    def twice() -> long { next(); next() };
    twice
};
let c1 = make_counter();
print(c1());
print(c1());

// closures made in a top-level loop: a C-style `for` variable is one
// variable, so they all share it (no global: it is scoped to the loop)
let fs: [() -> long] = [];
for (let i = 0; i < 3; i++) {
    fs += def() -> long { i * 10 };
};
print(fs[0]() + fs[1]() + fs[2]());
