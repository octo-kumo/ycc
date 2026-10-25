// Shared scalar/aggregate formatting preserves left-to-right evaluation.
let trace = "";
def text(mark: str) -> str { trace += mark; "x" };
def number(mark: str) -> long { trace += mark; 12 };
print(text("a") + number("b"));
print(number("c") + text("d"));
print(trace);

let b: byte = 'A';
print("x" + b, " ", b + "x", " ", tostring(b));
print("x" + 12345678901234567890n);
print(12345678901234567890n + "x");

let m: {str => [long]} = { "one": [1], "two": [2, 3] };
print(tostring(m));
print(tostring(m) == tostring([m][0]));
print(tostring({ values: m, count: 2, ready: true }));
let empty: {str => [long]} = {};
print(tostring(empty));

// A zero byte is still a character when concatenated, including at either end.
let zero: byte = 0;
let a = "x" + zero;
let z = zero + "x";
print(len(a), " ", a[1] + 0, " ", len(z), " ", z[0] + 0);
