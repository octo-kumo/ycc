def fact(n: long) -> long {
    if (n <= 1) { 1 } else { n * self(n - 1) }
};
print(fact(5));
def fib(n: long) -> long {
    if (n < 2) { n } else { self(n - 1) + self(n - 2) }
};
print(fib(10));
