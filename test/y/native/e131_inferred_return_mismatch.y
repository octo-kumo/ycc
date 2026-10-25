// expect-error: 6:27: error: 'return': expected long, got float (the return type is inferred from the end of the body)
// expect-error: 8:27: error: 'return': expected void, got long (the return type is inferred from the end of the body)
// expect-error: 11:27: error: 'return': expected long, got void (the return type is inferred from the end of the body; write '-> void' on the def to return nothing)
// expect-error: 14:61: error: 'return': expected str, got long (the return type is inferred from the first 'return')
// expect-error: 16:39: error: 'return': expected long, got str (the return type is inferred from the end of the body)
def f(c: bool) { if (c) { return 1.5; }; 2 };
// a body that ends in a statement is void
def g(c: bool) { if (c) { return 5; }; print("x"); };
// a bare `return;` returns nothing, and the message says which word to
// write: the `long` in it comes from the tail, not from the source
def h(c: bool) { if (c) { return; }; 7 };
// a def calling itself is checked again as if the type its first `return`
// gives were written
def r(n: long) { if (n == 0) { return "s"; }; if (n == 1) { return 1; }; self(n - 1) };
// function literals too
let lit = def(x: long) { if (x > 0) { return "s"; }; 2 };
