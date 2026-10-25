// expect-error: expected ')', got '='
// expect-error: expected ')', got '+='
// Assignment and compound assignment are statement forms: neither can
// nest inside an expression (++/-- can).
let x = 0;
let y = (x = 7);
let z = (x += 2);
print(y);
