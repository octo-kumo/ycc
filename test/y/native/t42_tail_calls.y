// Tail calls recycle the frame: a self-call in tail position overwrites
// the parameter slots and jumps back to the prologue, so tail recursion
// runs in constant stack. `return self(...)` and if-arm tails are tail
// positions too; anything else (e.g. self(x) + self(y)) is a plain call.

def sum_to(n: long, acc: long) -> long {
    if (n == 0) { acc } else { self(n - 1, acc + n) }
};
print(sum_to(1000000, 0));

def fact(n: long, acc: long) -> long {
    if (n <= 1) { acc } else { self(n - 1, acc * n) }
};
print(fact(10, 1));

def deep(n: long) -> long {
    if (n == 0) { 42 } else { return self(n - 1) }
};
print(deep(500000));

def parity(n: long) -> str {
    if (n == 0) { "even" } else {
        if (n == 1) { "odd" } else { self(n - 2) }
    }
};
print(parity(1000001));

def fib(n: long) -> long {
    if (n < 2) { n } else { self(n - 1) + self(n - 2) }
};
print(fib(10));
