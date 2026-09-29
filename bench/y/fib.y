// bench/y/fib.y — call-heavy recursion. The cleanest measure of raw call
// overhead: no allocation, no strings, just calls and arithmetic.
def fib(n: long) -> long {
    if (n < 2) {
        n
    } else {
        fib(n - 1) + fib(n - 2)
    }
};

print(fib(35));
