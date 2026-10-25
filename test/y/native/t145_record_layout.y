// A record is laid out by field name: a literal may write its fields in
// one order and the record type in another, and every read, write and
// print still finds the right field.
type AB = { alpha: long, beta: long };

def rd(p: AB) -> long { p.alpha * 10 + p.beta };
print(rd({ beta: 2, alpha: 1 }));

def wa(p: AB) { p.alpha = 5; };
let r = { beta: 2, alpha: 1 };
wa(r);
print(r.alpha, " ", r.beta);

let q: AB = { beta: 2, alpha: 1 };
print(q.alpha);

def mk() -> AB { { beta: 2, alpha: 1 } };
print(mk().alpha);

let xs: [AB] = [];
xs += { beta: 2, alpha: 1 };
print(xs[0].alpha);

def sp(p: AB) -> long {
    let c = { ...p, gamma: 3 };
    c.alpha * 100 + c.beta * 10 + c.gamma
};
print(sp({ beta: 2, alpha: 1 }));

let r2: AB = { alpha: 1, beta: 2 };
r2 = { beta: 4, alpha: 3 };
print(r2.alpha);

let o: { inner: AB } = { inner: { beta: 2, alpha: 1 } };
print(o.inner.alpha);

// a record prints its fields in the order its type writes them
print(q);
let ba: { beta: long, alpha: long } = q;
print(ba);

// if arms agree on a record type in any order
def pick(c: bool) -> AB {
    if (c) { { alpha: 1, beta: 2 } } else { { beta: 20, alpha: 10 } }
};
print(pick(true).beta, " ", pick(false).beta);

// a union member written in another order
type A = { field1: long; field2: long; };
type B = { bfield: long; };
type U = A | B;
let cu: U = { field2: 2, field1: 1 };
match cu {
    A { field1, field2 } => { print(field1, " ", field2); },
    _ => ()
};

// a record literal written where a record type is declared is created as
// that type: its values convert as they would stored into its fields
let fl: { x: float, n: { y: float } } = { x: 2, n: { y: 3 } };
print(fl.x + fl.n.y);
let by: { b: byte } = { b: 300 };
print(by.b);
