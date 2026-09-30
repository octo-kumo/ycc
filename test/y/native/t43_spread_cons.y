// Record spread is a STATIC shape union: first appearance keeps the
// position, later entries win the value. Cons (x :: a) prepends exactly
// ONE element -- even an array-typed one -- and chains to the right.

// spread overlaps
let base = { x: 1, y: 2 };
print({ a: 0, ...base });
print({ ...base, ...{ y: 9, z: 3 } });
print({ ...base, y: 100 });
print({ x: 7, ...base, x: 8 });
let copy = { ...base };
print(copy.x + copy.y);

// spread of a computed record
def make() { { p: 1, q: 2 } };
print({ ...make(), r: 3 });

// cons: exactly one element
print(0 :: [1, 2, 3]);
print(1 :: 2 :: [3]);
print([8] :: [[9]]);
let a = [2, 3];
print(1 :: a);
print(len(a));

// + splices the two sides' elements; :: takes one element whole
print([8] + [9]);
print([8] :: [[9]]);

// options round trip
let o: long? = some(5);
print(o);
let n: long? = none;
print(n);
print(unwrap(o));
print(is_some(n));
