// expect-error: 3:7: error: expected a parameter name, got '{'
// expect-error: 4:19: error: expected '=', got '1'
def f({ };
let missing_equal 1;
