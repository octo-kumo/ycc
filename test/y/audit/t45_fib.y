def f(x: long) -> long {
    if (x <= 1) { 1 } else { self(x - 1) + self(x - 2) }
};
print(f(30))