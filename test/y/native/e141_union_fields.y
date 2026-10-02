// expect-error: member { name: long, y: long } of { name: str, x: long } | { name: long, y: long } has no field 'x' (match the member first)
// expect-error: field 'name' has a different type in each member of { name: str, x: long } | { name: long, y: long } (match the member first)
// expect-error: pattern type { x: long } can never match { name: str, x: long } | { name: long, y: long }
// expect-error: non-exhaustive match: nothing matches { name: long, y: long }
// A field read or written through a union must be in every member, with
// one type; a type pattern must be a member (membership is exact), and
// only a member's own type covers it.
type A = { name: str, x: long };
type B = { name: long, y: long };
type U = A | B;
type T = { x: long };
def f(u: U) -> long {
    let n = u.x;
    u.name = 3;
    n
}
def g(u: U) -> long {
    match u { T t => 1, A a => 2 }
}
print(f({ name: "a", x: 1 }), g({ name: "a", x: 1 }));
