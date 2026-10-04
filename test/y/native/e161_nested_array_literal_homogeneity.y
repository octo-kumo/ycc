// A nested array literal's element type is the inner literal's own type, so
// every later element is checked against it: arrays are homogeneous
// ("06-arrays.tex", `[[long]]`). `[[1], 2]` used to be accepted -- the
// checker returned as soon as it had the inner type and compared nothing --
// and the program then read element 1 as an array pointer and died on it.
// A poisoned inner (one that already reported its own error) still unifies
// quietly, so that error is reported once.
// expect-error: 9:9: error: array element: expected [long], got long
let a = [[1], 2];
// expect-error: 11:9: error: array element: expected [str], got long
let b = [["x"], 1];
// expect-error: 13:9: error: array element: expected [[long]], got long
let c = [[[1]], 2];
// expect-error: 15:9: error: array element: expected [long], got long
let d = [[1, 2], 3];
// expect-error: 17:9: error: array element: expected [long], got [str]
let e = [[1], ["x"]];
// expect-error: 19:11: error: undefined variable 'zzz'
let f = [[zzz], 2];
// expect-error: 21:16: error: undefined variable 'qqq'
let g = [[1], [qqq]];