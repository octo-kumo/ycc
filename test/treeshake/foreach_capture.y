// A capturing literal cannot be inlined (its binding lives in a cell the
// record carries): the body must still run once per element and see updates.
def f() -> long {
    let t = 0;
    let a: [long] = [1, 2, 3];
    a.foreach((x) => { t += x; });
    t
};
// A nested function literal inside the body also keeps the separate body path.
let g: [long] = [1, 2, 3];
let out = 0;
g.foreach((x) => { let h = () => x + 1; out += h(); });
print(f());
print(out);
