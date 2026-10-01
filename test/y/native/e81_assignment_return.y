// expect-error: 6:1: error: cannot assign to function 'sample'
// expect-error: 8:1: error: assignment to 'value': expected long, got str
// expect-error: 10:1: error: assignment to 'fixed': expected [long; 1], got [bool; 1]
// expect-error: 11:1: error: 'return' outside of a function
def sample() -> long { 1 };
sample = 2;
let value: long = 1;
value = "wrong";
let fixed: [long; 1] = [0; 1];
fixed = [true; 1];
return 1;
