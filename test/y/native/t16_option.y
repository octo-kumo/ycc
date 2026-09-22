let a: int? = some(1);
print(is_some(a));
print(unwrap(a) + 41);
let b: int? = none;
print(is_some(b));
print(b == none);
let c = some(7);
print(unwrap(c) * 2);
