// expect-error: undefined label 'y_nothing_here'
// A native whose label has no assembly is not found at link time -- the same
// error a call to a missing symbol would give.
native def nothing() -> long = "y_nothing_here";
print(nothing());
