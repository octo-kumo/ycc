// expect-error: 7:24: error: non-exhaustive match on { v: long }? (add a '_' arm)
// expect-error: 8:24: error: non-exhaustive match on { v: long }? (add a '_' arm)
// expect-error: 9:27: error: non-exhaustive match on long? (add a '_' arm)
// A match on an option is exhaustive with a `none` arm plus `some(x)` or a type
// arm for the payload; either half alone is not.
type T = { v: long };
def a(o: T?) -> long { match o { none => 0 } };
def b(o: T?) -> long { match o { T c => c.v } };
def c(o: long?) -> long { match o { some(x) => x } };
