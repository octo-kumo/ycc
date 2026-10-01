// expect-error: let 'r': expected { x: float }, got { x: long }
// expect-error: 'f' arg 0: expected { x: float }, got { x: long }
// expect-error: let 'rs': expected [{ x: float }], got [{ x: long }]
// expect-error: let 'bb': expected { b: byte }, got { b: long }
// A record is shared, never copied, so nothing converts its fields:
// {x: long} is not a {x: float} (a long stored INTO a float field is,
// t132), nor is one inside an array literal or under a byte field.
let r: { x: float } = { x: 1 };
def f(p: { x: float }) -> float { p.x };
let q = { x: 2 };
print(f(q));
let rs: [{ x: float }] = [{ x: 3 }];
let bb: { b: byte } = { b: 4 };
print(r.x);
