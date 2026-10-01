// expect-error: 3:16: error: character literal must be exactly one byte, got 2
// expect-error: 4:15: error: expected an expression, got ';'
let bad_char = c'ab';
let missing = ;
