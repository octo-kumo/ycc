// expect-error: native def 'my_cmp' needs a return type (there is no body to infer it from)
// There is no body to infer the return type from, so it must be written.
native def my_cmp(a: str, b: str) = "y_str_cmp";
print(my_cmp("a", "b"));
