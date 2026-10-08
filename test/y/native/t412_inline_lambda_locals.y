// A name is boxed (moved to a shared heap cell) only when a nested function
// reads it from outside: a foreach lambda the emitter inlines keeps its own
// locals in the frame, but one that a closure inside the lambda captures is
// still shared, so the closure sees later writes.
let xs = [1, 2, 3];
let total = 0;
xs.foreach((x) => {
    let k = 0;
    for i in 0..x { k += i; };
    total += k;
});
print(total);
let fs: [() -> long] = [];
xs.foreach((x) => {
    let c = x * 10;
    fs += () => c;
    c += 1;
});
foreach (f in fs) { print(f()); };
let found = false;
["a", "b"].foreach((s) => {
    let hit = false;
    for j in 0..2 { if (s == "b" && j == 1) { hit = true; }; };
    if (hit) { found = true; };
});
print(found);
