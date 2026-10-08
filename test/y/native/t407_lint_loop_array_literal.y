// A constant array literal searched inside a loop is a new array on every
// iteration: `[35, 34, 39].index(c)` in meta.y's scanner allocated one for every
// byte of every file with a '#' in it. The warning names it wherever a loop
// evaluates one -- the body, a while's condition, a for's condition and step --
// and stays quiet for a literal bound once, one that is not constant, and one
// outside any loop.
let s = "a(b)c";
let n = 0;
for i in 0..s.length {
    if ([40, 41].index(s.byte_at(i)) >= 0) { n += 1; }; // expect-warning: this array literal is built again on every iteration of the loop -- bind it once before the loop
    if (s.byte_at(i) in [97, 98]) { n += 10; }; // expect-warning: this array literal is built again on every iteration of the loop -- bind it once before the loop
};
let i = 0;
while ([3, 4].index(i) < 0 && i < 9) { i += 1; }; // expect-warning: this array literal is built again on every iteration of the loop -- bind it once before the loop
let opens = [40, 41];
let words = ["x", "y"];
for j in 0..s.length {
    if (opens.index(s.byte_at(j)) >= 0) { n += 100; };
    if ([s.byte_at(j), 99].index(99) >= 0) { n += 1000; };
    if (words.index("y") == 1 && j == 0) { n += 10000; };
};
print([1, 2].index(2));
print(n, " ", i);
