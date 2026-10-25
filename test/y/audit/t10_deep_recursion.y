def f(x: long) -> long {
    if (x == 0) { 1 } else { x * self(x - 1) }
};
print(f(100000))