// expect-error: expected ';' after a native declaration, got '{'
// The whole point is that there is no body: the label is it.
native def my_cmp(a: str, b: str) -> long = "y_str_cmp" { 0 }
print(1);
