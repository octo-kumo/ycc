// A module whose type aliases and defs are used from another file, under the
// module's own name. The module is imported BY PATH, so its names are flat
// (ORIGIN MAP, "mods" in native.y) and `m.T` and `T` are the same thing.
type Pair = { a: long, b: long };
type Alt = Pair;
type Maybe2 = Pair?;

def mk(a: long, b: long) -> Pair { { a: a, b: b } };
def sum(p: Pair) -> long { p.a + p.b };
def give() -> Pair { mk(7, 7) };

export { Pair, Alt, Maybe2, mk, sum, give };
