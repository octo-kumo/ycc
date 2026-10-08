// `none =>` in a match on an option: with `some(x)` or a type arm that covers
// the payload it makes the match exhaustive (no `_` arm needed).
type T = { v: long };
def rec(o: T?) -> long { match o { T c => c.v, none => 0 - 1 } };
def sm(o: long?) -> long { match o { some(x) => x + 1, none => 0 } };
def first(o: long?) -> long { match o { none => 0 - 7, long n => n } };
print(rec(some({ v: 5 })));
print(rec(none));
print(sm(some(41)));
print(sm(none));
print(first(none));
print(first(some(9)));
