// expect-error: ndef 'my_cmp' must be at the top level (an assembly label has no place inside a function)
// An assembly label has no place inside a function body.
def outer() -> long {
    ndef my_cmp(a: str, b: str) -> long = "y_str_cmp";
    0
};
print(outer());
