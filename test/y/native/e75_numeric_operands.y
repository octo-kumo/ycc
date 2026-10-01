// expect-error: 3:6: error: '*' left operand: expected long, got bool
// expect-error: 4:3: error: '*' right operand: expected long, got bool
true * 1;
1 * true;
