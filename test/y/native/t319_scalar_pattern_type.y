// TODO.md item 13: a pattern's type position accepts the language's own names.
// `if let long n = v` was `unknown type 'long'`, because parse_type_pattern
// built a raw `tname` there where the annotation path (parse_type_atom2) builds
// a `tlong`. It now goes through that path, so a pattern and an annotation of
// the same type cannot disagree about what a name means -- which is the half
// item 2 needs, since a primitive union member has no other spelling.
//
// What a scalar pattern means today: "is the subject one of these". The one
// subject it can be on, while a union cannot hold a primitive (item 2), is an
// option -- so the test is the option's own and the binding is its payload,
// exactly what `if let some(m) = s` lowers to.

// every scalar, both ways
let some_long: long? = some(7);
if let long n = some_long { print("long ", n); } else { print("no long"); };
let no_long: long? = none;
if let long n = no_long { print("long ", n); } else { print("no long"); };

let some_str: str? = some("hi");
if let str s = some_str { print("str ", s); } else { print("no str"); };

let some_bool: bool? = some(true);
if let bool b = some_bool { print("bool ", b); } else { print("no bool"); };

let some_float: float? = some(1.5);
if let float f = some_float { print("float ", f); } else { print("no float"); };

// a byte has no literal yet (TODO.md item 7), so it comes from an annotation
let raw: byte = 65;
let some_byte: byte? = some(raw);
if let byte y = some_byte { print("byte ", y); } else { print("no byte"); };

// `int` is `long`, as everywhere
let int_opt: long? = some(3);
if let int i = int_opt { print("int ", i); } else { print("no int"); };

// the binding is the payload: arithmetic and calls on it work as they would on
// the value itself
if let long n = some_long { print("plus one ", n + 1, " sq ", n * n); };
if let str s = some_str { print("len ", s.length, " upper ", s.upper()); };

// a match arm. A `match` over an OPTION has always needed a `_` arm -- the
// exhaustiveness rule counts a union's members and a record's fields, and an
// option is neither -- so that is unchanged by the scalar spelling: `some(v)`
// and `none` arms alone are rejected the same way they always were.
match some_str { str t => print("m str ", t), _ => print("m none") };
match no_long { long u => print("m long ", u), _ => print("m none") };

// and the else is optional, like any other `if let`
if let str s = some_str { print("no else ", s); };

// a subject that IS the pattern's type: always matches, since the checker
// proved the two types are the same one. So the spelling is legal for any of
// the language's own names, not only the five scalars -- a mutex is a record
// under the type, and `if let mutex held = m` is true and binds it.
if let long n = 5 { print("plain ", n); };
let m = mutex();
if let mutex held = m { print("held"); }; // expect-warning: unused variable 'held'

// `some()` with no name and the scalar spelling agree on the test
if let some(v) = some_long { print("some(v) ", v); };
if let long w = some_long { print("long w ", w); };

// a record alias is still a type pattern -- the renamer resolves it, and the
// pattern binds the record
type P = { x: long, y: str };
let p: P = { x: 2, y: "two" };
if let P q = p { print("P ", q.x, q.y); };
match p { P r => print("m P ", r.x, r.y) };

// and the value pattern beside it, on the same record
match p { { x: 1 } => print("x is 1"), _ => print("x is not 1") };