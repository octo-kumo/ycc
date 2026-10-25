// Function equality includes its result type, including inside arrays.
// expect-error: 8:1: error: assignment to 'handlers': expected [(long) -> long], got [(long) -> str]
// expect-error: 9:1: error: cannot bind a void value to 'chosen'
// expect-error: 10:13: error: 'chosen' is not a function
let numeric = def(n: long) -> long { n };
let textual = def(n: long) -> str { "x" };
let handlers = [numeric];
handlers = [textual];
let chosen = if (true) { numeric } else { textual };
print(chosen(1));
