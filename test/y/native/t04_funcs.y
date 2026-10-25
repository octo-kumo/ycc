def add(a: long, b: long) -> long { a + b };
print(add(20, 22));
def sub(a: long, b: long) -> long { a - b };
print(sub(10, 4));
def outer() -> long {
    def helper(x: long) -> long { x * 2 };
    helper(21)
};
print(outer());
let f = def(x: long) -> long { x + 1 };
print(f(41));
