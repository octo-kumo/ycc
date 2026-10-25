// expect-error: 8:6: error: array index: expected long, got bool
// expect-error: 9:4: error: array index: expected long, got bool
// expect-error: 11:5: error: string index: expected long, got bool
// expect-error: 12:4: error: string index: expected long, got bool
// expect-error: 13:1: error: array index: expected long, got bool
// expect-error: 14:1: error: array index: expected long, got bool
let array = [1];
array[true];
[1][false];
let text = "x";
text[true];
"x"[false];
array[true] = 2;
[1][false] = 2;
