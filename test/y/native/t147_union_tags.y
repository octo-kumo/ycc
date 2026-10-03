// A union value is exactly one of its members: its record's descriptor
// says which, so a match compares that, printing shows that member, and
// a field every member has (with one type) reads and writes straight
// through the union -- one move, as a union value holds its member with
// those fields first.
type A = { name: str, x: long };
type B = { name: str, y: long, z: long };
type C = { id: long, name: str };
type U = A | B;
type V = A | B | C;

let us: [U] = [];
us += { name: "a", x: 1 };
us += { y: 2, name: "b", z: 3 };
foreach (u in us) {
    print(u.name);
    match u {
        A a => print("A ", a.x),
        B b => print("B ", b.y + b.z)
    };
    print(u);
};

// name sorts first in A and B, second in C; held in V, it is first in all
// three
let vs: [V] = [];
vs += { name: "a", x: 1 };
vs += { y: 2, name: "b", z: 3 };
vs += { id: 7, name: "c" };
foreach (v in vs) {
    v.name = v.name + "!";
    print(v.name, " ", v);
};

// a record pattern narrows to the member with its fields, or to the
// union of the members that have them
match vs[2] {
    { id: 7 } c => print("id 7: ", c.name),
    _ => print("other")
};
match vs[0] {
    { name: "a!" } n => print("named: ", n.name),
    _ => print("other")
};
