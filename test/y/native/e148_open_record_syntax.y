// There is no record type that takes any record with some fields: a
// record type lists all of its fields, and `..` is not a field.
// expect-error: 4:29: error: expected a field name in a type, got '..'
def name_of(r: { name: str, .. }) -> str { r.name };
print(name_of({ name: "a" }));
