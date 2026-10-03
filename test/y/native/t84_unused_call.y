// flags: -W 1
// Level 1: a call whose value nobody reads. `give` and `fact` hand a
// value back, so dropping it is a mistake; `nothing` returns void and is
// called for its effect, so it is not one. `self` resolves to the def it
// is written in, so a recursive call is named for it.
def give() -> long { 7 };
def fact(n: long) -> long {
    if (n <= 1) { 1 } else { n * self(n - 1) }
};
def nothing() -> void { puts("void\n") };

def go() -> long {
    give();    // expect-warning: the value of 'give()' is not used
    nothing();
    fact(5);   // expect-warning: the value of 'fact()' is not used
    // the same two calls, read this time
    let a = give();
    let b = fact(5);
    a + b
};
print(tostring(go()));
