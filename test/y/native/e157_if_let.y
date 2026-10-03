// `if let` wants a pattern, an `=`, and a subject the pattern can match.
// Each error lands on the token that broke it.
// expect-error: 11:16: error: expected '=' after the pattern of 'if let', got 'o'
// expect-error: 12:14: error: 'some' binds exactly one name
// expect-error: 13:13: error: expected a name to bind in 'some(', got '3'
// expect-error: 14:15: error: expected ')' to close 'some(', got '='
// expect-error: 15:8: error: cannot match a record pattern against long
// expect-error: 16:46: error: undefined variable 'v'
type Leaf = { tag: str, n: long };
let o: long? = some(7);
if let some(x) o { print(x) };
if let some(x, y) = o { print(x) };
if let some(3) = o { print(1) };
if let some(x = o { print(x) };
if let Leaf { n: k } = 5 { print(k) };
if let some(v) = o { print(v) } else { print(v) };