// expect-error: pattern type { x: long } can never match { a: long } | { b: long }
type P = { x: long };
type U = { a: long } | { b: long };
let u: U = { a: 1 };
match u { P p => 1, _ => 0 };
