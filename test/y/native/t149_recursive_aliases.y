// A type alias may refer to itself, or to aliases that refer back to it,
// through a record's field or a function type: lists, trees, unions of
// mutually recursive records, functions returning themselves. A record
// nested in a record prints as its type.
type L = { head: long, tail: L? };
def sum(l: L) -> long {
    let t = l.tail;
    if (t == none) { l.head } else { l.head + sum(t!) }
};
let l: L = { head: 1, tail: some({ head: 2, tail: some({ head: 3, tail: none }) }) };
print(sum(l));
print(l);
print(typeof(l));

type Tree = { v: long, kids: [Tree] };
def total(t: Tree) -> long {
    let s = t.v;
    foreach (k in t.kids) { s = s + total(k); };
    s
};
let kids: [Tree] = [];
kids += { v: 2, kids: [] };
kids += { v: 3, kids: [] };
print(total({ v: 1, kids: kids }));

// mutual recursion through a union; the literals are its members
type Expr = Num | Add;
type Num = { n: long };
type Add = { l: Expr, r: Expr };
def ev(e: Expr) -> long {
    match e {
        Num x => x.n,
        Add a => ev(a.l) + ev(a.r)
    }
};
let e: Expr = { l: { n: 1 }, r: { l: { n: 2 }, r: { n: 3 } } };
print(ev(e));
print(e);

// two aliases of one structure are one type
type M = { head: long, tail: M? };
let m: M = l;
print(sum(m));

// a function type that returns itself
type F = (long) -> F;
def f(x: long) -> F { print(x); f };
f(1)(2)(3);
