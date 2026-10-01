// expect-error: 6:1: error: slice assignment: cannot store [str] into [long]
// expect-error: 7:1: error: slice assignment needs an array on the right, got long
// expect-error: 9:1: error: cannot assign to a slice of str (strings are immutable)
// expect-error: 11:1: error: cannot slice-assign long (only arrays)
let array = [1];
array[0:1] = ["wrong"];
array[0:1] = 1;
let text = "x";
text[0:1] = "y";
let number = 1;
number[0:1] = [1];
