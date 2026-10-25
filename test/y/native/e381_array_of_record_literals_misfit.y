// expect-error: 5:34: error: array element: expected { x: float, b: byte }, got { x: float }
// An element of an array literal that does not fit the annotated record type is
// an error at that element, not a silent mismatch.
type R = { x: float, b: byte };
let rs: [R] = [{ x: 1.5, b: 1 }, { x: 2.5 }];
