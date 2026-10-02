// type aliases, union types and match
type A = {
    field1: long;
    field2: float;
};

type B = {
    bfield: long;
};

type C = A | B;

let c: C = {
    field1: 1,
    field2: 2.0
};

let c2: C = {
    bfield: 10
};

def show(v: C) {
    match v {
        A { field1, field2 } => {
            print("Matched A: ", field1, ", ", field2);
        },
        B b => {
            print("Matched B: ", b.bfield);
        },
        _ => ()
    };
}
show(c);
show(c2);

// a match is an expression; record patterns compare fields
def code(v: C) -> long {
    match v { A a => 1, ({bfield: 10}) b => 2, _ => 3 } // expect-warning: unused variable 'a' // expect-warning: unused variable 'b'
}
print(code(c), code(c2), code({bfield: 11}));

// exhaustive without `_`: every member has an arm
def total(v: C) -> float {
    match v {
        A a => a.field2 + 1.0,
        B {bfield: x} => 0.5 * x
    }
}
print(total(c), " ", total(c2));

// unions print as the member they hold
print(c);
print(c2);
let cs: [C] = [];
cs += c;
cs += c2;
print(cs);
print(typeof(c));

// literal patterns on plain values
def name(n: long) -> str {
    match n { 0 => "zero", 1 => "one", -1 => "minus one", _ => "many" }
}
print(name(0), " ", name(1), " ", name(-1), " ", name(7));
def kind(s: str) -> str {
    match s { "a" => "letter a", _ => "other" }
}
print(kind("a"), " ", kind("b"));

// aliases work in any annotation
type Point = { x: long, y: long };
def add(p: Point, q: Point) -> Point { { x: p.x + q.x, y: p.y + q.y } }
print(add({x: 1, y: 2}, {x: 10, y: 20}));

// `type` and `match` stay ordinary names elsewhere
let type = 3;
let match = 4;
print(type + match);
