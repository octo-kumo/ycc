// Inferred return types: every `return` converts to the type the checker
// infers, and the emitter types calls, `self` and literals by that same
// type (the value each line prints is in its comment).

// a `return` converts to the trailing value's type
def half(c: bool) { if (c) { return 1; }; 2.5 };
print(half(true));          // 1.000000
print(half(false));         // 2.500000

// a byte trailing value: the long a `return` gives is masked
def low(c: bool) { let z: byte = 7; if (c) { return 300; }; z };
print(low(true));           // 44
print(low(false));          // 7

// a trailing local: calls are typed as the checker types them
def quarter() { let y = 0.25; y };
print(quarter());           // 0.250000
let q = quarter();
print(q + 1.0);             // 1.250000
def word() { let t = "ab"; t };
print(word() + "c");        // abc
print(1 + word());          // 1ab
def pair() { let r = { a: 1.5, b: "x" }; r };
print(pair().a);            // 1.500000
print(pair().b + "y");      // xy
def floats() { let xs = [1.5, 2.5]; xs };
print(floats()[1]);         // 2.500000

// `self` has the inferred type inside the body
def grow(n: long) { if (n == 0) { 0.5 } else { self(n - 1) + 1.0 } };
print(grow(2));             // 2.500000

// a trailing self call leaves the type to the `return`s
def acc(n: long, a: float) { if (n == 0) { return a; }; self(n - 1, a + 1.0) };
print(acc(3, 0.5));         // 3.500000
def rep(n: long, s: str) { if (n == 0) { return s; }; self(n - 1, s + "a") };
print(1 + rep(2, ""));      // 1aa

// an if-arm that is a self call takes the other arm's type
def dbl(n: long, a: float) { if (n > 0) { self(n - 1, a * 2.0) } else { a } };
print(dbl(2, 0.5));         // 2.000000

// calls between inferred defs, either way round
def a1(n: long) { if (n == 0) { let z = 0.25; z } else { b1(n - 1) } };
def b1(n: long) { a1(n) * 2.0 };
print(b1(2));               // 2.000000

// a function literal, and a closure capturing a float
let lit = def(x: long) { let r = x * 0.5; r };
print(lit(3));              // 1.500000
def outer() {
    let k = 2.0;
    def inner(c: bool) { if (c) { return 1; }; k };
    inner(true) + inner(false)
};
print(outer());             // 3.000000

// a bare `return;` in a def that ends in a statement: void
def note(c: bool) { if (c) { return; }; print("noted"); };
note(true);
note(false);                // noted
