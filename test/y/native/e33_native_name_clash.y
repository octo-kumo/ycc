// expect-error: 'my_cmp' is a ndef and is declared again at the top level (a ndef cannot share a name)
// One name cannot be two declarations, and both would claim the label.
ndef my_cmp(a: str, b: str) -> long = "y_str_cmp";
def my_cmp(a: str, b: str) -> long { 0 };
print(my_cmp("a", "b"));
