// expect-error: 19:12: error: packed record has no field 'y'
// expect-error: 20:13: error: field 'x' is given twice
// expect-error: 21:13: error: a packed record literal cannot spread
// expect-error: 22:13: error: packed field 'x': expected byte, got bool
// expect-error: 23:1: error: packed record has no field 'zzz'
// expect-error: 24:10: error: packed record has no field 'nope'
// expect-error: 25:15: error: sizeof needs a packed record or bitmap type, got long
// expect-error: 26:17: error: packed record has no field 'q'
// expect-error: 27:12: error: field 'in' is a packed record: give it a literal { .. }
// expect-error: 28:1: error: cannot assign the whole of field 'in' (packed { x: byte }): write its parts
// expect-error: 29:12: error: packed record: field 'name' of type str cannot live in a packed record (integers, bool, float, pointers, fixed arrays of those, and other packed records can)
// expect-error: 30:11: error: packed record: field 'name' of type str cannot live in a packed record (integers, bool, float, pointers, fixed arrays of those, and other packed records can)
// Using a packed record: unknown fields, a field twice, a spread, a wrong value type,
// whole-field assignment of a nested record, a non-literal for a nested record, a field type
// that cannot live in raw memory, and sizeof/offsetof of the wrong thing.
type A = packed { name: str, n: u8 };
type C = packed { x: u8 };
type F = packed { in: C };
let c: C = { y: 1 };
let c2: C = { x: 1, x: 2 };
let c3: C = { ...c };
let c4: C = { x: true };
c.zzz = 1;
let n = c.nope;
let s = sizeof(long);
let o = offsetof(C, q);
let f: F = { in: 3 };
f.in = c;
let a: A = {};
let n2 = a.n;
