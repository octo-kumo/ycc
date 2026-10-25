// expect-error: 3:25: error: default value of parameter 'x' must be a literal
// expect-error: 4:15: error: expected ',' or ')', got '{'
def f(x: long = len("x")) { 1 };
def g(x: long { 1 };
