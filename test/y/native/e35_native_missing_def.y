// expect-error: expected 'def' after 'native', got 'my_cmp'
// `native` alone is not a declaration: it says how the next one is written.
native my_cmp(a: str, b: str) -> long = "y_str_cmp";
print(1);
