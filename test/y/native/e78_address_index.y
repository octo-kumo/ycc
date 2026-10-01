// expect-error: 5:17: error: array index: expected long, got bool
// expect-error: 7:23: error: cannot index long (only arrays)
// expect-error: 9:28: error: cannot index long (only arrays)
let array = [1];
let bad_index = &array[true];
let number = 1;
let bad_array_index = &number[0];
def scalar() -> long { 1 };
let bad_expression_index = &scalar()[0];
