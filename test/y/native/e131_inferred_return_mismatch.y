// expect-error: 6:27: error: 'return': expected long, got float (the return type is inferred from the end of the body)
// expect-error: 8:27: error: 'return': expected void, got long (the return type is inferred from the end of the body)
// expect-error: 10:27: error: 'return': expected long, got void (the return type is inferred from the end of the body)
// expect-error: 12:61: error: 'return': expected str, got long
// expect-error: 14:39: error: 'return': expected long, got str (the return type is inferred from the end of the body)
def f(c: bool) { if (c) { return 1.5; }; 2 };
// a body that ends in a statement is void
def g(c: bool) { if (c) { return 5; }; print("x"); };
// a bare `return;` returns nothing
def h(c: bool) { if (c) { return; }; 7 };
// a def calling itself is checked again as if the type its first `return`
// gives were written
def r(n: long) { if (n == 0) { return "s"; }; if (n == 1) { return 1; }; self(n - 1) };
// function literals too
let lit = def(x: long) { if (x > 0) { return "s"; }; 2 };
