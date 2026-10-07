// flags: -W 2
def a(c: bool) -> long {
    if (c) { // expect-warning: the 'if' branch is empty; invert the condition and drop the arm
    } else {
        print(1);
    };
    if (c) { // expect-warning: the 'if' branch is empty; invert the condition and drop the arm
    };
    0
};
def both(c: bool) -> long {
    if (c) { // expect-warning: both branches of this 'if' are empty; it does nothing // expect-warning: the 'else' branch is empty
    } else {
    };
    0
};
def b(raw: str, hasesc: bool) -> str {
    let buf = raw; // expect-warning: 'buf' is set once under a condition; write 'let buf = <cond> ? <then> : <initial>'
    if (hasesc) {
        buf = "x";
    };
    buf
};
def cc(c: bool, x: long) -> long {
    if (c) { x = 1; } else { x = 2; }; // expect-warning: 'x' is chosen by a condition in both arms; write one conditional assignment
    x
};
def d(c: bool) -> long {
    if (c) { return 1; } else { return 2; }; // expect-warning: an 'if' returning a value from both arms can return a conditional
};
def d2(c: bool) -> bool {
    if (c) { return true; } else { return false; }; // expect-warning: an 'if' returning true and false can return the condition
};
def e(c: bool) -> long {
    if (c) { return 1; }; // expect-warning: an 'if' returning a value and a following return can be one conditional return
    return 2;
};
def e2(c: bool) -> bool {
    if (c) { // expect-warning: an 'if' returning true and then false can return the condition
        return true;
    };
    return false;
};
def g(c: bool, x: long) -> long {
    while (true) {
        if (!c) { break; }; // expect-warning: 'while (true)' with a leading 'break' guard can test the guard instead
        print(x);
        break;
    };
    x
};
def main() -> long {
    print(a(true));
    print(both(true));
    print(len(b("a", true)));
    print(cc(true, 0));
    print(d(true));
    print(d2(true));
    print(e(true));
    print(e2(true));
    print(g(true, 0));
    0
};
exit(main());
