let x = 1;
print(x);
let x = 2; // expect-warning: 'x' is declared more than once; the last declaration counts (the earlier one at line 1)
print(x);
let y = x + 10;
print(y);
def f(a: long) -> long {
    let a = a + 100;
    print(a);
    let b = 5;
    print(b);
    let b = 6;
    print(b);
    a + b
};
print(f(1));
print(x);
