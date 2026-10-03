// A number ending the source: 1e with no digit after it is the number
// 1 followed by the name e, not an exponent and not a trap.
// expect-error: undefined variable 'n'
// expect-error: expected ';', got 'e'
n = 1e