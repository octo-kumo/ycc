// flags: --warnings=all
// Fresh accumulators with no other loop effects: preserve empty identities.
def total(xs: [long]) -> long {
    let n = 10; // expect-warning: this numeric accumulator loop can be one array '.reduce((acc, item) => acc + <expr>, initial)' -- preserve the accumulator type
    foreach (x in xs) { n += x * 2; };
    n
};
def reduced(xs: [long]) -> long { xs.reduce((acc, x) => acc + x * 2, 10) };
def any_positive(xs: [long]) -> bool {
    let found = false; // expect-warning: this false flag and early-exit search can be one array '.some(item => <condition>)'
    foreach (x in xs) { if (x > 0) { found = true; break; }; };
    found
};
def every_positive(xs: [long]) -> bool {
    let valid = true; // expect-warning: this true flag and early-exit search can be one array '.all(item => !(<condition>))'
    foreach (x in xs) { if (x <= 0) { valid = false; break; }; };
    valid
};
// An explicitly float accumulator needs a float reduce seed, even if its
// original initializer was written as an integer literal.
def fractional(xs: [float]) -> float {
    let n: float = 0; // expect-warning: this numeric accumulator loop can be one array '.reduce((acc, item) => acc + <expr>, initial)' -- preserve the accumulator type
    foreach (x in xs) { n += x; };
    n
};
def fractional_reduced(xs: [float]) -> float { xs.reduce((acc, x) => acc + x, 0.0) };
// A read of the accumulator changes the recurrence, not a plain sum.
def recurrence(xs: [long]) -> long {
    let n = 1;
    foreach (x in xs) { n += n * x; };
    n
};
// No break: replacing this body with some would stop observing later items.
def no_break(xs: [long]) -> bool {
    let found = false;
    foreach (x in xs) { if (x > 0) { found = true; }; };
    found
};
// The predicate observes the flag, so it is not an independent predicate.
def dependent(xs: [long]) -> bool {
    let found = false;
    foreach (x in xs) { if (!found && x > 0) { found = true; break; }; };
    found
};
// An extra write is real state and cannot disappear into a predicate.
def extra(xs: [long]) -> long {
    let hits = 0;
    let found = false;
    foreach (x in xs) { if (x > 0) { hits++; found = true; break; }; };
    if (found) { hits } else { 0 }
};
// Byte truncation on each iteration must not become long accumulation.
def narrow(xs: [long]) -> byte {
    let n: byte = 0;
    foreach (x in xs) { n += x; };
    n
};
// Strings are iterable but do not provide array methods.
def chars(s: str) -> long {
    let n = 0;
    foreach (c in s) { n += c; };
    n
};
// Calls may mutate captured state; this first rule set does not recommend them.
def add(x: long) -> long { x + 1 };
def calling(xs: [long]) -> long {
    let n = 0;
    foreach (x in xs) { n += add(x); };
    n
};
foreach (xs in [[], [-2, 0], [1, 2, 3]]) {
    if (total(xs) != reduced(xs)) { exit(1); };
    if (any_positive(xs) != xs.some(x => x > 0)) { exit(1); };
    if (every_positive(xs) != xs.all(x => x > 0)) { exit(1); };
};
foreach (xs in [[], [0.5, -0.25], [1e16, -1e16, 1.0]]) {
    if (fractional(xs) != fractional_reduced(xs)) { exit(1); };
};
print(recurrence([1, 2]), no_break([0, 1]), dependent([0, 1]), extra([0, 1]), narrow([255, 2]), chars("A"), calling([1]));
