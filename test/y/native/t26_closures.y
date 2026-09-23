// Closures: a nested function may read bindings of the enclosing function.
// Each is closure-converted into a heap record [code, cap0, cap1, ...];
// captured values are copied when the closure is created. This replaces the
// old e04_capture rejection test ("cannot capture 'x'").

// 1. capture a local, called in place
def outer() -> long { let x = 41; def inner() -> long { x + 1 }; inner() };
print(outer());

// 2. capture a parameter, called more than once
def counter(start: long) -> long {
    let n = start;
    def bump(d: long) -> long { n + d };
    bump(1) + bump(2)
};
print(counter(10));

// 3. return a closure; each one keeps its own captured value
def make_adder(n: long) -> (long) -> long {
    let add = def(x: long) -> long { x + n };
    add
};
let a5 = make_adder(5);
let a100 = make_adder(100);
print(a5(3));
print(a100(3));
print(a5(1));

// 4. several captures, including a string
def mk(a: long, b: long, s: str) -> (long) -> long {
    let f = def(x: long) -> long { puts(s); x + a * b };
    f
};
let g = mk(3, 4, "tagged ");
print(g(1));
print(g(2));

// 5. functions as arguments, and composition
def apply2(f: (long) -> long, v: long) -> long { f(v) };
def inc(x: long) -> long { x + 1 };
def dbl(x: long) -> long { x * 2 };
print(apply2(inc, 41));

def compose(f: (long) -> long, g2: (long) -> long) -> (long) -> long {
    let h = def(x: long) -> long { f(g2(x)) };
    h
};
let c = compose(inc, dbl);
print(c(5));

// 6. arrays of functions
let fs: [(long) -> long] = [inc, dbl];
let f0 = fs[0];
let f1 = fs[1];
print(f0(10));
print(f1(10));
