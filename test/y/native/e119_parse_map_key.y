// expect-error: 4:25: error: expected a key, got '['
// expect-error: 4:28: error: expected ';', got ':'
// expect-error: 4:32: error: expected an expression, got '}'
let broken = { good: 1, [0]: 2 };
