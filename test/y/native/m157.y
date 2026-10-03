// A module with type aliases of its own (t157_module_types.y).
type Pt = { x: long, y: long };
type Shape = Circle | Square;
type Circle = { c: Pt, r: long };
type Square = { c: Pt, side: long };
def origin() -> Pt { { x: 0, y: 0 } };
def area(s: Shape) -> long {
    match s { Circle c => 3 * c.r * c.r, Square q => q.side * q.side }
};
def unit() -> Shape { { c: origin(), r: 1 } };
export { origin, area, unit };
