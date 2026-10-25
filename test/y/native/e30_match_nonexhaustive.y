// expect-error: non-exhaustive match: nothing matches { bfield: long }
type A = { field1: long };
type B = { bfield: long };
type C = A | B;
let c: C = { bfield: 10 };
print(match c { A a => 1, ({bfield: 10}) b => 2 });
