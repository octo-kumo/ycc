// flags: -W 1
// Level 1: a call whose value nobody reads. `give`, `fact` and `squares`
// hand a value back, so dropping it is a mistake; `nothing` returns void
// and `inferred` has no written return type, so neither is one -- and a
// builtin (len) is taken to return nothing. A recursive `self` is named
// for the def it is written in.
def give() -> long { 7 };
def nothing() -> void { puts("void\n") };
def inferred() { 3 };
def fact(n: long) -> long {
    if (n <= 1) { 1 } else { n * self(n - 1) }
};
def squares(n: long) -> long {
    // `self` here is `squares`, and it hands a value back
    if (n > 0) { self(n - 1); };  // expect-warning: the value of 'squares()' is not used
    n * n
};

def go() -> long {
    give();        // expect-warning: the value of 'give()' is not used
    nothing();
    inferred();
    len("abcd");
    fact(5);       // expect-warning: the value of 'fact()' is not used
    squares(4);    // expect-warning: the value of 'squares()' is not used
    // the same calls, read this time
    let a = give();
    let b = fact(5);
    a + b + squares(4)
};
print(tostring(go()));
