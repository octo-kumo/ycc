// expect-error: 4:19: error: array element type void is unsupported in native mode
// expect-error: 5:17: error: array element type void is unsupported in native mode
// expect-error: 6:16: error: array size must be a non-negative integer literal ([v; n])
let bad_dynamic = [print(1)];
let bad_fixed = [print(1); 1];
let bad_size = [1; -1];
