// Optional parameters `b?: T`: the body sees a T?; a call may leave the
// argument out (none) or pass a plain T (some), and they mix with defaults.
def show(a: long, b?: long) -> str {
    if (is_some(b)) { tostring(a) + "+" + tostring(unwrap(b)) } else { tostring(a) }
};
print(show(1));
print(show(1, 2));
def greet(name: str, greeting?: str, punct = "!") -> str {
    let g = "hello";
    if (is_some(greeting)) { g = unwrap(greeting); 0 };
    g + " " + name + punct
};
print(greet("bob"));
print(greet("bob", "hi"));
print(greet("bob", "hi", "?"));
def opts(a?: long, b?: [long]) -> long {
    let n = 0;
    if (is_some(a)) { n = n + unwrap(a); 0 };
    if (is_some(b)) { n = n + len(unwrap(b)); 0 };
    n
};
print(opts());
print(opts(5));
print(opts(5, [1, 2, 3]));