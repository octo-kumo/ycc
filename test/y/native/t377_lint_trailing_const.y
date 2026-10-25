// flags: --warnings=all
// A block whose value is dropped, ending in a bare constant (rule 2.13): the
// constant is the block's value and nothing reads it.
def f(n: long) -> void {
    print(n + 1);
    0 // expect-warning: the value of this block is not used; this constant does nothing
};

def g(ok: bool) -> void {
    if (ok) {
        print("yes");
        false // expect-warning: the value of this block is not used; this constant does nothing
    };
};

f(2);
g(true);
