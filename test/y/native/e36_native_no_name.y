// expect-error: expected a name after 'native def', got '('
// A native def is always named -- there is no anonymous form.
native def (a: str, b: str) -> long = "y_str_cmp";
print(1);
