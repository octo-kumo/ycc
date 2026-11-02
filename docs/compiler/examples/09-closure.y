// A nested def captures `n`. The closure does not escape, so the checked
// lifetime pass can place its allocation in the enclosing call.
def outer(n: long) -> long {
    def inner() -> long { n + 1 };
    inner()
};
print(outer(2));
