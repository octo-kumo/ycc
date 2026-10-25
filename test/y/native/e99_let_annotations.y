// expect-error: 8:1: error: let 'fn_bad': expected (str) -> long, got (long) -> long
// expect-error: 9:1: error: let 'repeat_bad': expected [str; 2], got [long; 2]
// expect-error: 10:1: error: annotation 'void' is not a native value type
// expect-error: 11:1: error: let 'array_bad': expected [str], got [long]
// expect-error: 12:1: error: let 'scalar_bad': expected str, got long
// expect-error: 13:1: error: parameter 'bad_map' has unpassable type {void => long} (a void value has no representation, and a type pattern cannot be passed by value)
// expect-error: 14:5: error: '{void => long}' cannot be bound to a variable
let fn_bad: (str) -> long = def(x: long) -> long { x };
let repeat_bad: [str; 2] = [1; 2];
let invalid_annotation: void = 1;
let array_bad: [str] = [1];
let scalar_bad: str = 1;
def invalid_map(bad_map: {void => long}) {
    let copied_map = bad_map;
    0
};
