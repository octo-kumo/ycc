// expect-error: 'f' arg 0: expected { x: float }, got { x: long }
// expect-error: let 'rs': expected [{ x: float }], got [{ x: long }]
// A record is shared, never copied, so nothing converts the fields of an
// existing one: a {x: long} is not a {x: float} (a long stored INTO a
// float field is, t132, and so is one in a record literal written where
// a record type is declared, t145), nor is one inside an array literal.
def f(p: { x: float }) -> float { p.x };
let q = { x: 2 };
print(f(q));
let rs: [{ x: float }] = [{ x: 3 }];
