// W4/S7: code addresses are tokens (2^40 + chunk * 2^20 + case), what a
// closure, a function value and a pushed return address hold.  Every indirect
// call here decodes one; the comparisons check that two spellings of the same
// def are the same token and that a different def is not.
def add1(x: long) -> long { x + 1 };
def add2(x: long) -> long { x + 2 };

let fns: [long -> long] = [];
fns += add1;
fns += add2;
print(fns[0](10), " ", fns[1](10), "\n");

// closures over a captured binding, stored in an array and called through it
def make(k: long) -> () -> long {
    let f = def() -> long { k * 3 };
    f
};
let cs: [() -> long] = [];
cs += make(2);
cs += make(5);
print(cs[0](), " ", cs[1](), "\n");

// the same def twice is the same token; another def is another token
let a = add1;
let b = add1;
print(a == b, " ", a == add2, "\n");

// a function value in a record, called and compared
let r = { f: add2, n: 7 };
print(r.f(r.n), " ", r.f == add2, " ", r.f == add1, "\n");

// a callback handed to a def that calls it
def apply(f: (long) -> long, v: long) -> long { f(v) };
print(apply(add1, 5), " ", apply(add2, 5), "\n");

// a closure capturing a mutable cell: every call sees the same cell
let count = 0;
let bump = def() -> long { count = count + 1; count };
print(bump(), " ", bump(), " ", count, "\n");
