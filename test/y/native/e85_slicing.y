// expect-error: 6:6: error: slice start: expected long, got bool
// expect-error: 7:6: error: slice end: expected long, got bool
// expect-error: 8:4: error: slice start: expected long, got bool
// expect-error: 10:7: error: cannot slice long (only arrays)
let array = [1];
array[true:1];
array[0:false];
"x"[true:1];
let number = 1;
number[0:1];
