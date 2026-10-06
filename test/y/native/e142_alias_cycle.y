// expect-error: 8:1: error: type 'T' refers to itself outside any record field, array, option, map or function type
// expect-error: 9:1: error: type 'U' refers to itself outside any record field, array, option, map or function type
// expect-error: 10:1: error: type 'A' refers to itself outside any record field, array, option, map or function type
// expect-error: 11:1: error: type 'B' refers to itself outside any record field, array, option, map or function type
// A recursive alias needs an indirection in its cycle: a record field, an
// array, an option, a map or a function type. `type W = [W];` used to live
// here and is legal now (t335_recursive_alias.y); what is left has none.
type T = T;
type U = U | { a: long };
type A = B;
type B = A;
let t: T = 1;
