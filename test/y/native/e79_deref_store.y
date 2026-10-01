// expect-error: 4:17: error: cannot dereference long (need *T)
// expect-error: 6:1: error: store target must be *T, got long
// expect-error: 9:1: error: store through pointer: expected long, got str
let bad_deref = *1;
let number = 1;
*number = 2;
let cell = 0;
let pointer = &cell;
*pointer = "wrong";
