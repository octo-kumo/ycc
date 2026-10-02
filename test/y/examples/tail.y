def factorial(n: long, acc: long, mod: long) {
    if n == 0 {
        return acc;
    } else {
        return factorial(n - 1, (n * acc) % mod, mod);
    }
}
// without tail recursion, this would cause a stack overflow for large n
print(factorial(100000000, 1, 1000000007));