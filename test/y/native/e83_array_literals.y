// expect-error: 4:19: error: array element type void is unsupported in native mode
// expect-error: 5:17: error: array element type void is unsupported in native mode
// expect-error: 6:20: error: expected an array size (an integer literal from 0 to 2147483647), got '-'
let bad_dynamic = [print(1)];
let bad_fixed = [print(1); 1];
let bad_size = [1; -1];
