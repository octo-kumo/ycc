// expect-error: 'my_cmp' is a native def and is declared again at the top level (a native def cannot share a name)
// One name cannot be two declarations, and both would claim the label.
native def my_cmp(a: str, b: str) -> long = "y_str_cmp";
def my_cmp(a: str, b: str) -> long { 0 };
print(my_cmp("a", "b"));
