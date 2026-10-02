// Only k is assigned through an open record type.
// expect-error: 3:29: error: cannot assign field 'a' through an open record type (only its k)
def bad(r: {a: long, ..}) { r.a = 5; };
bad({ a: 1 });
