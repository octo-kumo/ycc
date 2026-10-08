// A capturing literal is inlined for the loop, but the statements AFTER it
// must still read the enclosing binding: the capture entries are shadowed
// back when the body is done. The nested function literal keeps the separate
// body path, and the empty first loop proves the leak is gone.
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
// A nested function literal inside the body also keeps the separate body path.
let g: [long] = [1, 2, 3];
let out = 0;
g.foreach((x) => { let h = () => x + 1; out += h(); });
print(f());
print(out);
