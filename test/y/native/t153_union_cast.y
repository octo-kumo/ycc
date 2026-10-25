// A union value goes where one of its members is declared -- or a union
// of some of its members -- through a cast the program checks: the
// member's own fields then read directly. A value holding another member
// stops the program.
type Circle = { name: str, r: float };
type Rect = { name: str, w: float, h: float };
type Tri = { name: str, a: float, b: float, c: float };
type Shape = Circle | Rect | Tri;
type Flat = Rect | Tri;
def radius(c: Circle) -> float { c.r };
def width(s: Shape) -> float { let r: Rect = s; r.w };
def flat_name(f: Flat) -> str { f.name };
let shapes: [Shape] = [];
shapes += { name: "disc", r: 1.5 };
shapes += { name: "box", w: 2.0, h: 3.0 };
shapes += { name: "wedge", a: 3.0, b: 4.0, c: 5.0 };
print(radius(shapes[0]));
print(width(shapes[1]));
let f: Flat = shapes[2];
print(flat_name(f), " ", f);
let back: Shape = f;
print(back.name);
print(width(shapes[0]));
print("not reached");
