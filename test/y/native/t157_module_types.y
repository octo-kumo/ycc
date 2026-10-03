// A module imported by name keeps its type aliases too: the program names
// them m157.Pt; its own Pt is another type, and the module's code still
// finds its own.
import m157;
type Pt = { a: long };
let mine: Pt = { a: 5 };
let theirs: m157.Pt = m157.origin();
def shift(p: m157.Pt, d: long) -> m157.Pt { { x: p.x + d, y: p.y + d } };
let s: m157.Shape = { c: shift(theirs, 2), side: 3 };
print(mine.a, " ", theirs.x, " ", shift(theirs, 1).y, " ", m157.area(s), " ", m157.area(m157.unit()));
match s { m157.Square q => print("square ", q.side, " at ", q.c.x), _ => print("other") };
let shapes: [m157.Shape] = [s, m157.unit()];
print(len(shapes));
