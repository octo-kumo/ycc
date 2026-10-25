// Option propagation is for an option: `?.` on anything else is a type
// error, and a `?.` with neither a field name nor `[` after it is a syntax
// error. The diagnostic names the operator, not the test the parser
// lowers it to, and sits on the `?.` itself.
// expect-error: 11:8: error: '?.' needs an option, got long
// expect-error: 13:8: error: '?.' needs an option, got str
// expect-error: 14:8: error: '?.' needs an option, got long
// expect-error: 16:8: error: '?.' needs an option, got [long]
// expect-error: 17:10: error: expected a field name or '[' after '?.', got ')'
let n = 5;
print(n?.field);
let s: str = "a";
print(s?.length);
print(n?.[0]);
let a: [long] = [1];
print(a?.[0]);
print(n?.);