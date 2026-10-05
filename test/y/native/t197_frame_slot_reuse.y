// Frame slots are reused as blocks end (E2): a block's slots are released when
// it ends, and a statement's temporaries when it does. So the fixture pins the
// three ways that can go wrong -- a temporary outliving a block inside its own
// statement, a place binding whose slot a nested block would take out of scope,
// and a name read after a sibling block released it. Every value here is the
// same under the old monotonic counter, which is what makes it a regression
// test rather than a record of today's code.

// a temporary holds its slot across the blocks inside its statement
def f2() -> long { let inner = 0; inner };
def g2f() -> long { let inner = 2; inner };
let mm: [[long]] = [[0, 0, 0, 0], [0, 0, 0, 0]];
mm[f2()][g2f()] += 5;
print(mm[0][2]);              // 5

// the same, through a field target and a `+=` whose right side calls
type Cell = { v: long };
def bump(c: Cell) -> Cell { let d = 3; { let e = 4; c.v = c.v + d + e }; c };
let c = bump({ v: 1 });
print(c.v);                   // 8

// a captured variable: its heap cell outlives the block that declared the name
def mk(start: long) -> long {
    let total = 0;
    let bump = def() -> long {
        let step = start * 2;
        total += step;
        total
    };
    bump();
    { let scratch = 99; scratch = scratch - 99 };
    bump()
};
print(mk(3));                 // 12

// `x++` and `++x` on a name, in statement position and in value position
def count(n: long) -> long {
    let i = 0;
    while (i < n) { i++; i += 0 };
    let j = i++;
    let k = ++j;
    k + i
};
print(count(4));              // 10

// an array `+=` element by element, with blocks in the element and the target
let xs: [long] = [1, 2];
def pick(n: long) -> long { let q = n * 10; q };
xs += { let t = 3; t };
let ys: [[long]] = [[1], [2]];
ys += [[pick(4)]];
let zs: [long] = [7];
zs += [8, 9];
print(join(xs, ","));         // 1,2,3
print(join(ys[2], ","));      // 40
print(join(zs, ","));         // 7,8,9

// a string `+=` on a name whose right side builds in blocks
let s = "a";
s += { let t = "b"; t } + { let u = "c"; u };
print(s);                     // abc

// a name declared in a loop body, read after: the body releases its slots, so
// the next iteration must not land on the previous one's
let acc = "";
foreach (w in ["p", "q", "r"]) {
    let doubled = w + w;
    acc += doubled;
}
print(acc);                   // ppqqrr

// two sibling blocks, each keeping its own name while the other runs
let first = 0;
let second = 0;
{ let only_here = 7; first = only_here; }
{ let only_here = 8; second = only_here; }
print(first + second);        // 15