// flags: -W 2
// `0 - n` on literals is a negative literal.
def f() -> long {
    let a = 0 - 5; // expect-warning: '0 - n' is a negative literal; write it '-n'
    a * a + a
};
print(f());
