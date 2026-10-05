// expect-error: native label 'str_cmp' must start with 'y_' (generated code calls it by that prefix)
// A label without the prefix is not one generated code calls.
native def my_cmp(a: str, b: str) -> long = "str_cmp";
print(my_cmp("a", "b"));
