// expect-error: 7:15: error: expected an expression, got ')'
// expect-error: 8:15: error: expected an expression, got ']'
// expect-error: 9:23: error: expected an expression, got ','
// A closer that closes nothing, right after an `if` in a block, is
// reported where it stands and the parse goes on (it once looped there
// forever).
{ if true { } ) };
{ if true { } ] };
def f() { if true { } , };
