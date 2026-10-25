// `{ k: str }` is a record type like any other: exactly one field, k. It
// takes no record of other fields, and reads no field but k.
// expect-error: 13:10: error: 'key' arg 0: expected { k: str }, got { k: str, extra: long }
// expect-error: 14:10: error: 'key' arg 0: expected { k: str }, got { k: str, extra: long }
// expect-error: 15:39: error: record has no field 'missing'
// expect-error: 17:1: error: let 'w': expected { k: str, v: long }, got { k: str }
// expect-error: 18:1: error: 'wrap' body: expected { k: str }, got { k: str, v: long }
// expect-error: 20:4: error: '+=' element: expected { k: str }, got { k: str, extra: long }
// expect-error: 21:1: error: 'back' body: expected { k: str, v: long }, got { k: str }
// expect-error: 22:1: error: cannot bind a void value to 'both'
def key(r: { k: str }) -> str { r.k };
let extended = { k: "value", extra: 1 };
print(key(extended));
print(key({ k: "lit", extra: 2 }));
def missing(r: { k: str }) -> long { r.missing };
let n: { k: str } = { k: "a" };
let w: { k: str, v: long } = n;
def wrap(r: { k: str, v: long }) -> { k: str } { r };
let xs: [{ k: str }] = [];
xs += extended;
def back(r: { k: str }) -> { k: str, v: long } { r };
let both = if (true) { { k: "a" } } else { { k: "b", v: 1 } };
print(both.k);
