def fact(n: long) -> long {
    if (n <= 1) {
        1
    } else {
        n * self(n - 1)
    }
};
print(fact(10));
