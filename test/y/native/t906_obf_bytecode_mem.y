// flags: --ob=full --ob-seed=4
let g = 41;
type Cell = { v: long };
def load(p: *long) -> long { *p }
def store(p: *long, v: long) -> long { *p = v; *p }
def field(c: Cell) -> long { c.v }
def at(p: *long, i: long) -> long { *(p + i) }
def getg() -> long { g }
def mark() -> str { "VM-LABEL" }
def mk(start: long) -> long {
    let total = 0;
    let bump = def() -> long { total += start; total };
    bump();
    bump()
};
def main() -> long {
    let x = 5;
    print(tostring(load(&x)));
    print(tostring(store(&x, 9)));
    print(tostring(x));
    let c: Cell = { v: 7 };
    print(tostring(field(c)));
    let arr: [long; 3] = [11, 22, 33];
    print(tostring(at(&arr[0], 1)));
    print(tostring(getg()));
    print(mark());
    print(tostring(mk(3)));
    0
};
let r = main();
