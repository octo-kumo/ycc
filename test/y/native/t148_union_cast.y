// A value the checker cannot type going where a union is declared must be
// a record of one of its members' fields; any other record traps.
type A = { a: long };
type B = { b: long };
type U = A | B;
def wrap(v) -> U { v };
print(wrap({ b: 2 }));
print(wrap({ c: 3 }));
print("not reached");
