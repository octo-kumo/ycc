// A missing parameter type is inferred from a literal in the body (`i + 10`)
// or from a literal actual at a call site (`g(7)` and `h(true)`).
def f(i) { i + 10 };
def g(x) { x };
def h(flag) { if flag { 1 } else { 0 } };

def main() -> long {
    print(f(5));
    print(g(7));
    print(h(true));
    0
};

exit(main());
