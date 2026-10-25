// A record type says which fields a value has: reading another is a
// compile error, whatever the record's width (it used to compile and trap
// at run time for any record that had other than one field).
// expect-error: 7:8: error: record has no field 'c'
// expect-error: 9:30: error: record has no field 'z'
let r = { a: 1, b: 2 };
print(r.c);
type P = { x: long, y: long };
def f(p: P) -> long { p.x + p.z };
print(f({ x: 1, y: 2 }));
