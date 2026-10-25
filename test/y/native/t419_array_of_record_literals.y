// An array literal of record literals takes the element type from the annotation:
// long -> float and long -> byte fields, a union element, [R; N], [[R]], an argument, a return.
type R = { x: float, b: byte };
type A = { l: long };
type B = { s: str };
type U = A | B;
def sum(rs: [R]) -> float { let t = 0.0; foreach (r in rs) { t += r.x + r.b; }; t };
def mk() -> [R] { return [{ x: 2, b: 3 }]; };
let rs: [R] = [{ x: 1.5, b: 1 }, { x: 2, b: 7 }];
let fx: [R; 2] = [{ x: 1, b: 2 }, { x: 3, b: 4 }];
let us: [U] = [{ l: 1 }, { s: "a" }];
let nn: [[R]] = [[{ x: 1, b: 2 }], [{ x: 3, b: 4 }, { x: 5, b: 6 }]];
rs += { x: 9, b: 9 };
print(sum(rs), " ", sum([{ x: 1, b: 1 }]), " ", sum(mk()), " ", fx[1].b, " ", len(us), " ", nn[1][1].x);
