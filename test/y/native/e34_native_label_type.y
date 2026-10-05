// expect-error: the label after '=' must be a string
// The label names an assembly symbol, so it is written as one.
native def my_cmp(a: str, b: str) -> long = 42;
print(my_cmp("a", "b"));
