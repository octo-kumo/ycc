// flags: -W 1
// Level 1: an `else` branch that does nothing. `if (c) { A } else { }` is
// what the void redesign made unnecessary -- the branch can go. An `else`
// that runs anything, and an `if` with no `else` at all, are fine.
def go(c: bool, n: long) -> long {
    let acc = 0;
    if (c) { acc = acc + 1; } else { }        // expect-warning: the 'else' branch is empty
    if (c) { acc = acc + 2; }
    if (c) { acc = acc + 4; } else { ; }
    if (c) { acc = acc + 8; } else { acc = acc + 16; }
    while (n > 0) {
        n = n - 1;
        if (c) { acc = acc + 32; } else { }    // expect-warning: the 'else' branch is empty
    }
    acc
};
print(go(true, 2), " ", go(false, 1));