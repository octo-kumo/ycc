// ndef: a declaration whose body is an assembly label
//
// There is no way to put assembly in a program, so these reach the runtime's
// own -- `y_str_cmp`, `y_str_eq` and `y_heap_used` take their arguments on the
// stack like any other function, which is the convention a ndef is
// called with. The declaration is a promise about the label: nothing here can
// check it, exactly as an `extern` declaration in C cannot.
ndef my_cmp(a: str, b: str) -> long = "y_str_cmp";
ndef my_eq(a: str, b: str) -> long = "y_str_eq";
ndef my_heap() -> long = "y_heap_used";

// called above its own declaration: a forward call resolves like a def's
print(early("a", "a"));
ndef early(a: str, b: str) -> long = "y_str_eq";

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
ndef str_eq(a: str, b: str) -> long;
print(str_eq("x", "x"));

// lint has nothing to say about any of them, and that is checked rather than
// assumed: there is no expect-warning marker in this file, and the native suite
// fails a fixture on any warning no marker claims -- at the default level or at
// `--warnings=extra`. A native has no body for the dropped-value, dead-code and
// unused-local rules to fire on, and the unused-binding rules exempt top-level
// names, which is what lets std/math.y declare twenty-odd natives that most
// programs calling one of them never mention.
//
// The unused parameter is here for the same reason: it is the case a
// body-walking rule would get wrong.
ndef spare(a: str, b: str, unused_param: str) -> long = "y_str_cmp";
ndef nobody_calls_this(a: str) -> long = "y_str_eq";
print(spare("a", "b", "third") < 0);