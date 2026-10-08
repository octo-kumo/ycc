// `x in [c1, c2, ...]` with x a name or a literal and every element an
// integer or every element a string literal is compiled to compares
// (native.y in_chain): no array is built, so the loop warning stays quiet.
// A float list, or a computed left operand, still goes through the array.
let words = ["add", "mov", "ret", "push"];
let n = 0;
foreach (w in words) {
    if (w in ["add", "sub", "cmp"]) { n += 1; };
    if (!(w in ["ret"])) { n += 10; };
    let b = w in ["push", "pop"];
    if (b) { n += 100; };
};
print(n);
let c = 98;
print(c in [97, 98, 99]);
print(c in [1, 2]);
let x = 0.0;
print(x in [1.5, 0.0]);
let s = "hello";
for i in 0..s.length {
    if (s.byte_at(i) in [101, 111]) { n += 1000; }; // expect-warning: this array literal is built again on every iteration of the loop -- bind it once before the loop
};
print(n);
print(3 in [1, 2, 3] && !("z" in ["a"]));
