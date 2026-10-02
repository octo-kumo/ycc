// An open record type, `{f: T, ..}`, is any record with those fields:
// they read through the record's own descriptor, wherever its type puts
// them, so records of different types go through one parameter.
def name_of(r: {name: str, ..}) -> str { r.name };
print(name_of({ name: "a", x: 1 }), " ", name_of({ id: 2, name: "b" }));
type P = { id: long, name: str, tags: [str] };
let p: P = { id: 7, name: "seven", tags: ["x"] };
print(name_of(p));
def kind(n: {k: str, ..}) -> str { n.k };
print(kind({ k: "num", v: 1 }), " ", kind({ col: 3, k: "bin", line: 2 }));
// only k is assigned through one (its offset is in every descriptor)
def retag(n: {k: str, ..}) { n.k = "tag"; };
let q = { k: "a", v: 5 };
retag(q);
print(q);
// a value seen through an open type prints the fields the type lists
let v: {a: long, ..} = { b: 2, a: 1 };
print(v.a, " ", v);
// the declared fields keep their types
def total(r: {a: long, b: long, ..}) -> long { r.a + r.b };
print(total({ a: 3, b: 4, c: "x" }));
