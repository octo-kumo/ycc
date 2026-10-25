// Captures remain visible after empty loops, callbacks and nested closures.
def leak() -> long {
    let a: [long] = [];
    let t = 5;
    a.foreach((x) => { t += x; });
    t
};
print(leak());
def f() -> long {
    let t = 0;
    let a: [long] = [1, 2, 3];
    a.foreach((x) => { t += x; });
    t
};
let g: [long] = [1, 2, 3];
let out = 0;
g.foreach((x) => { let h = () => x + 1; out += h(); });
print(f());
print(out);
