// Hoisting, captures and append ownership share the emitter's AST traversal.
def make(seed: long) -> (long) -> str {
    let text = "";
    let calls = 0;
    def next(n: long) -> str {
        calls += 1;
        let values = [{ def twice(x: long) -> long { x * 2 }; twice(seed + n) }];
        let value = { item: values[0] };
        text += tostring(value.item);
        text += ":";
        text += tostring(calls);
        text
    };
    next
};
let f = make(10);
let first = f(1);
print(first);
print(f(2));
print(first);
// Taking an address prevents ownership of an append buffer being assumed.
def address_append() -> str {
    let text = "a";
    let p = &text;
    text += "b";
    let kept = *p;
    text += "c";
    kept + "/" + text
};
print(address_append());
// Argument defaults and function-local shadowing keep their binding order.
def defaults(a: long, b: long = 3) -> long {
    let inner = def(a: long) -> long { a + b };
    inner(a)
};
print(defaults(7), defaults(7, 5));
