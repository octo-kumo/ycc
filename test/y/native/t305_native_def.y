// native def: a declaration whose body is an assembly label
//
// There is no way to put assembly in a program, so these reach the runtime's
// own -- `y_str_cmp`, `y_str_eq` and `y_heap_used` take their arguments on the
// stack like any other function, which is the convention a native def is
// called with. The declaration is a promise about the label: nothing here can
// check it, exactly as an `extern` declaration in C cannot.
native def my_cmp(a: str, b: str) -> long = "y_str_cmp";
native def my_eq(a: str, b: str) -> long = "y_str_eq";
native def my_heap() -> long = "y_heap_used";

// called above its own declaration: a forward call resolves like a def's
print(early("a", "a"));
native def early(a: str, b: str) -> long = "y_str_eq";

print(my_cmp("apple", "banana") < 0);
print(my_cmp("banana", "apple") > 0);
print(my_cmp("same", "same"));
print(my_eq("abc", "abc"));
print(my_eq("abc", "abd"));
print(my_heap() >= 0);

// a native may be used as a value, like any other function
let f = my_cmp;
print(f("a", "b") < 0);

// and with no `=`, the label is `y_<name>`
native def str_eq(a: str, b: str) -> long;
print(str_eq("x", "x"));