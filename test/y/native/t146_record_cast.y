// A value the checker cannot type going where a record type is declared
// is checked at run time: a record of other fields traps rather than be
// read at the wrong offsets.
type P = { x: long, y: long };
def sum(p: P) -> long { p.x + p.y };
def pass(v) -> long { sum(v) };
print(pass({ x: 1, y: 2 }));
print(pass({ x: 1, z: 2 }));
print("not reached");
