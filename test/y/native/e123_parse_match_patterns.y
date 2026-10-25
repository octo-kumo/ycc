// expect-error: 5:11: error: expected '}' to close the field list, got '=>'
// expect-error: 9:5: error: '...' is not allowed in a match pattern
type R = { x: long };
match { x: 1 } {
    R { x => 1,
    _ => 2
};
match { x: 1 } {
    { x: 1, ... } => 3,
    _ => 4
};
