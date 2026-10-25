// expect-error: 'f' arg 0: expected { x: float }, got { x: long }
// A record is shared, never copied, so nothing converts the fields of an
// existing one: a {x: long} is not a {x: float} (a long stored INTO a
// float field is, t132, and so is one in a record literal written where
// a record type is declared, t145, or in an array literal there, t419).
def f(p: { x: float }) -> float { p.x };
let q = { x: 2 };
print(f(q));
