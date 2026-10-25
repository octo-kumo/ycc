// flags: --warnings=all
// Suggestions preserve short-circuit order, values and lexical scopes.
def nested(a: bool, b: bool) -> long {
    let n = 0;
    if (a) { // expect-warning: these nested 'if' guards can be one 'if (outer && inner)' -- keep the body and short-circuit order
        if (b) { n++; };
    };
    n
};
def merged(a: bool, b: bool) -> long {
    let n = 0;
    if (a && b) { n++; };
    n
};
def guarded(n: long) -> long {
    let out = 0;
    if (n < 0) { return -1; } else { out = n + 1; }; // expect-warning: the 'then' branch always returns; use a guard clause and move the 'else' body after it, keeping its block scope
    out
};
def flat(n: long) -> long {
    if (n < 0) { return -1; };
    n + 1
};
def positive(n: long) -> bool {
    if (n > 0) { true } else { false } // expect-warning: this boolean-valued 'if' can be its condition, or its negation when the true arm is false
};
def inverted(n: long) -> bool {
    if (n > 0) { false } else { true } // expect-warning: this boolean-valued 'if' can be its condition, or its negation when the true arm is false
};
// Combining the guards must not evaluate division on the skipped path.
def division_guard(n: long) -> long {
    let result = 0;
    if (n != 0) { // expect-warning: these nested 'if' guards can be one 'if (outer && inner)' -- keep the body and short-circuit order
        if (10 / n > 1) { result = 1; };
    };
    result
};
// Extra work in the outer arm means the guards cannot simply be merged.
def extra(a: bool, b: bool) -> long {
    let n = 0;
    if (a) { n += 2; if (b) { n++; }; };
    n
};
// A source-name condition is known bool because lint runs after checking.
def identity(n: bool) -> bool { if (n) { true } else { false } }; // expect-warning: this boolean-valued 'if' can be its condition, or its negation when the true arm is false
// Calls in a condition are deliberately outside the initial advice subset.
def effect(n: long) -> bool { positive(n) };
def calling(n: long) -> bool { if (effect(n)) { true } else { false } };
// A then arm that only sometimes returns is not a guard clause.
def partial(a: bool, b: bool) -> long {
    let n = 0;
    if (a) { if (b) { return 1; }; n += 2; } else { n += 3; };
    n
};
// The branches' values are needed, so do not flatten the else.
def valued(n: long) -> long { if (n < 0) { return -1; } else { n + 1 } };
for i in 0..2 {
    for j in 0..2 {
        if (nested(i != 0, j != 0) != merged(i != 0, j != 0)) { exit(1); };
    };
};
for n in -2..3 {
    if (guarded(n) != flat(n) || positive(n) != (n > 0) || inverted(n) != (n <= 0)) { exit(1); };
};
if (division_guard(0) != 0 || division_guard(2) != 1) { exit(1); };
print(extra(true, true), identity(true), calling(1), partial(false, true), valued(2));
