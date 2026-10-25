// expect-error: non-exhaustive match: nothing matches { bfield: long } (add an arm or '_'; value patterns match only the values they name and cover no type)
type A = {afield: long};
type B = {bfield: long};
type C = A | B;
def f(c: C) -> long {
    match c { A a => 1, ({bfield: 10}) b => 2 }
};
print(f({afield: 1}));
