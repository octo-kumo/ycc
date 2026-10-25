// flags: --warnings=extra
// Conditions that decide nothing: a constant one, one that repeats an earlier
// condition of its else-if chain, a loop that cannot run, and an operator
// whose two operands are the same expression.
def f(x: long, y: long) -> long {
    let a = 0;
    if (x == 1) { a = 2; } else if (x == 1) { a = 3; }; // expect-warning: this condition repeats an earlier one of the chain, so this branch never runs
    if (true) { a = a + 1; }; // expect-warning: the condition is always true
    if (x > 0) { a = a + 1; } else if (false) { a = a + 2; }; // expect-warning: the condition is always false
    while (false) { a = a + 4; }; // expect-warning: the condition is always false, so the loop never runs
    let b = x ^ x; // expect-warning: both operands of '^' are the same expression
    let c = x == y && x == y; // expect-warning: both operands of '&&' are the same expression
    a + b + (if (c) { 1 } else { 0 })
};
print(f(1, 2));
