// expect-error: 6:1: error: type 'T' refers to itself outside any record field or function type
// expect-error: 7:1: error: type 'W' refers to itself outside any record field or function type
// expect-error: 8:1: error: type 'U' refers to itself outside any record field or function type
// expect-error: 9:1: error: type 'A' refers to itself outside any record field or function type
// A recursive alias needs a record field or a function type in its cycle.
type T = T;
type W = [W];
type U = U | { a: long };
type A = B;
type B = A;
let t: T = 1;
