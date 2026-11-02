// The body hint belongs to the def it is written in, not to the enclosing
// def; the nested def's parameter is still inferred from its own body.
def outer(a) -> long {
    def inner(b) -> long { b * 2 };
    inner(a) + 1
};
print(outer(4));
