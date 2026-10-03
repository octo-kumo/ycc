// A union value holds its member with the union's shared fields (every
// member has them, with one type) first, then the member's own: a shared
// field is one load at one place, whatever the member. A standalone record
// has all its fields sorted by name. A value going from one layout to the
// other -- a member into the union, the union into a member, one union
// into another -- is a cast: the record is copied where the layouts
// differ, wherever the value goes.
type Leaf = { id: long, tag: str, v: long };
type Add = { a: Expr, b: Expr, id: long, tag: str };
type Mul = { a: Expr, b: Expr, id: long, scale: long, tag: str };
type Neg = { e: Expr, id: long, tag: str };
type Expr = Leaf | Add | Mul | Neg;
type Bin = Add | Mul;

def leaf(n: long, v: long) -> Expr { { id: n, tag: "leaf", v: v } };

def eval(x: Expr) -> long {
    match x {
        Leaf l => l.v,
        Add { a, b } => self(a) + self(b),
        Mul m => self(m.a) * self(m.b) * m.scale,
        Neg { e: inner } => 0 - self(inner)
    }
};

let one = leaf(1, 1);
let two = leaf(2, 2);
// standalone members, laid out sorted
let s: Add = { a: one, b: two, id: 3, tag: "add" };
let m: Mul = { a: one, b: two, id: 5, scale: 10, tag: "mul" };
print(s.id, " ", s.tag, " ", m.scale);

// into the union: shared fields read through it
let e: Expr = s;
print(e.id, " ", e.tag, " ", eval(e));
let xs: [Expr] = [];
xs += s;
xs += one;
xs += { e: e, id: 4, tag: "neg" };
xs += m;
foreach (x in xs) { print(x.id, " ", x.tag, " ", eval(x)); };

// out of the union: a checked cast
let back: Add = xs[0];
print(back.a.id, " ", back.b.id, " ", back.id, " ", back.tag);
let mb: Mul = xs[3];
print(mb.scale, " ", mb.tag);

// one union into another: Bin shares a, b, id and tag
let bins: [Bin] = [];
bins += s;
bins += m;
foreach (b in bins) { print(b.a.id, " ", b.b.id, " ", b.id, " ", b.tag); };
let wide: Expr = bins[1];
print(wide.tag, " ", eval(wide));
let narrow: Bin = xs[3];
print(narrow.a.id, " ", narrow.tag);
let mm: Mul = narrow;
print(mm.scale);

// arguments, returns, fields, element stores, literals, options
def ident(x: Expr) -> Expr { x };
def pick(first: bool) -> Expr {
    if (first) { return s; };
    m
};
print(ident(s).tag, " ", eval(pick(true)), " ", eval(pick(false)));
type Box = { inner: Expr, n: long };
let bx: Box = { inner: s, n: 1 };
print(bx.inner.tag, " ", eval(bx.inner));
bx.inner = m;
print(bx.inner.tag, " ", eval(bx.inner));
xs[1] = s;
print(xs[1].tag, " ", eval(xs[1]));
let arr: [Expr] = [one, s, m];
foreach (x in arr) { print(x.tag); };
let o: Expr? = some(ident(s));
print(o!.tag);
e = m;
print(e.tag, " ", eval(e));

// printing: the fields in the type's order, whatever the layout
print(e);
print(s);
print(bins[0]);

// a shared field written through the union, read back through the union
let fresh: Expr = { e: one, id: 7, tag: "neg" };
fresh.id = 42;
print(fresh.id, " ", eval(fresh));

// record patterns read in place
match xs[2] {
    { tag: "neg" } n => print("neg ", n.id),
    _ => print("other")
};
def bin_ids(b: Bin) -> long {
    match b {
        Add { id } => id,
        Mul { id: i, scale } => i * scale
    }
};
print(bin_ids(bins[0]), " ", bin_ids(bins[1]));
