// a record pattern on an option tests the payload: it must be that record
// expect-error: 5:8: error: pattern type { n: long } can never match { a: long }
type P = { n: long };
let q: { a: long }? = some({ a: 1 });
if let P c = q { print("bad") };
