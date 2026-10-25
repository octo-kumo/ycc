// expect-error: 6:29: error: call takes 1 args, got 2
// expect-error: 7:29: error: call arg 0: expected long, got bool
// expect-error: 8:4: error: cannot call long (not a function)
// expect-error: 10:6: error: 'value' is not a function
// expect-error: 11:5: error: 'self' outside of a function
(def(x: long) -> long { x })(1, 2);
(def(x: long) -> long { x })(true);
(1)();
let value = 1;
value();
self();
