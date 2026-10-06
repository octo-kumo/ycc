// `native` was a KEYWORD until `native def` became the one-word `ndef`. It is
// an ordinary identifier now, in every position a name can appear: a record
// type and a field, a function, a local, and a loop variable.
type native = { native: long, other: str };
def native(x: long) -> long { x + 1 };
let n = native(7);
let r: native = { native: n, other: "s" };
print(n);
print(r.native);
print(r.other);
let count = 0;
foreach (native in [1, 2, 3]) { count = count + native; };
print(count);
