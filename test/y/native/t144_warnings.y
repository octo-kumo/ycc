// Warnings (src/y/lint.y; `ycc -w` turns them off). Each line marked
// `expect-warning` draws the warning it quotes, and no other line draws
// one (test_native.sh). A warning never stops the build: this runs.

// types, as written
type Point = { x: long, y: long };
type Spot = { x: long, y: long }; // expect-warning: type 'Spot' is the same type as 'Point'
type Tag = { name: str };
type Tag = { name: str, id: long }; // expect-warning: type 'Tag' is declared more than once; the last declaration counts

def norm(p: { x: long, y: long }) -> long { p.x * p.x + p.y * p.y }; // expect-warning: the type { x: long, y: long } is already declared as 'Point'; use the alias
def left(a: { lo: long, hi: long }) -> long { a.lo }; // expect-warning: the type { lo: long, hi: long } is written out 2 times; name it with `type`
def right(a: { lo: long, hi: long }) -> long { a.hi };

// a value computed and dropped
def dropped(x: long) -> long {
    x; // expect-warning: the value of 'x' is not used
    x + 1; // expect-warning: the result of '+' is not used
    x == 2; // expect-warning: the result of '==' is not used; did you mean '='?
    -x; // expect-warning: the result of '-' is not used
    x
};

// code after a return
def early(x: long) -> long {
    if (x > 0) { return 1; } else { return 2; };
    print("never"); // expect-warning: unreachable code
    0
};

// a comparison that is always false; a division by a literal zero
def odd(x: long) -> bool {
    if (x < x || x > x) { print("never"); }; // expect-warning: 'x < x' is always false // expect-warning: 'x > x' is always false
    x % 2 == 1
};
def zero(x: long) -> long {
    let y = x;
    if (x > 100) {
        y /= 0; // expect-warning: division by zero
        y = x % 0; // expect-warning: division by zero
    };
    if (x > 100) { x / 0 } else { y } // expect-warning: division by zero
};

// no warning: a call's value dropped, `ok && f()`, `f != f` (the NaN
// test), a division by a float zero
def side(n: long) -> long { n + 1 };
def quiet(x: long, f: float) -> float {
    side(x);
    x > 0 && side(x);
    if (f != f) { f / 0.0 } else { f }
};

// x = x
def same(x: long) -> long {
    let y = x;
    y = y; // expect-warning: 'y' is assigned to itself
    y
};

// a key given twice
def keys() -> long {
    let r = { a: 1, a: 2 }; // expect-warning: duplicate field 'a' in a record literal; the last one wins
    let m = {"k": 1, "k": 2}; // expect-warning: duplicate key 'k' in a map literal; the last one wins
    r.a + m["k"]!
};

// bindings nothing reads
def locals(x: long) -> long {
    let unread = x; // expect-warning: unused variable 'unread'
    const limit = 10; // expect-warning: unused constant 'limit'
    def helper() -> long { 1 }; // expect-warning: unused function 'helper'
    let written = 0; // expect-warning: variable 'written' is assigned but never read
    written = x;
    let _quiet = x;
    x
};

// exempt: parameters, loop variables, top-level bindings, `_` names --
// and an unused IMPORT, which is not exempt by design but because the lint
// pass cannot see the import list (it is handed a spliced AST and, per line,
// the module that line came from). It costs binary space rather than being
// free -- 6705 bytes for `import math;`, TODO.md #9 -- and
// test/sh/test_treeshake.sh is what measures that. When the warning lands it
// has to keep `// For its alias X.` modules quiet: a module imported only for
// a type alias has no identifier to see.
import math;
def exempt(p: long) -> long {
    for i in 0..3 { };
    foreach (j in [1, 2]) { };
    0
};
let top = 1;

print(norm({ x: 3, y: 4 }));
print(left({ lo: 1, hi: 2 }) + right({ lo: 1, hi: 2 }));
print(dropped(5));
print(early(1));
print(odd(3));
print(zero(7));
print(quiet(1, 2.5));
print(same(4));
print(keys());
print(locals(6));
print(exempt(0));
let t: Tag = { name: "t", id: 2 };
print(t.id + top);
