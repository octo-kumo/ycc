// typeof, printing records and function values, and def shadowing
let m = { a: 1, b: "hi", c: true, d: 2.5 };
print(m);
print(typeof(m));

def add(a: long, b: long) -> long { a + b };
print(add);
print(typeof(add));

print(typeof(1));
print(typeof(2.5));
print(typeof(true));
print(typeof("x"));
print(typeof([1, 2, 3]));

// a record holding a function (annotated so the VM prints the same type:
// the VM has no return-type inference and would print `<inferred>`)
let rec = { n: 7, f: def(x: long, y: long) -> long { x * y } };
print(rec);
let g = rec.f;
print(g(6, 7));
print("via field = " + ((rec.f)(3, 4)));

// a later definition shadows an earlier one, exactly as in the VM
def dup(x: long) -> long { x + 1 };
def dup(x: long) -> long { x + 100 };
print(dup(1));
