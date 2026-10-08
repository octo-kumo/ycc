// A `def` is a statement, and a statement can live in a block, and a block is
// an expression -- so a `def` can sit anywhere an expression can. The
// emitter's def-collection walk descended only into statement positions
// (blocks, if arms, loop bodies, a function body), so a def that reached the
// assembler from anywhere else was never hoisted and never emitted:
//
//     if ({ def g() -> bool { true }; g() }) { print(1); } else { print(2); }
//     error: assemble: undefined label 'y_missing_g$3'
//
// Eight of the nine positions this fixture covers failed that way, one after
// another -- a call argument, an array element, a record value, an infix
// operand, an index, an `if` condition, a `while` condition and a
// `foreach` head -- while the ninth (a `let`'s value) worked, because a
// declaration's value happened to be descended into already. Every arm the
// complete walk (fv_walk, above it in native.y) has is here now.
def takes(v: long) -> long { v }
type Box = { v: long };

def via_return() -> long { return { def r1() -> long { 13 }; r1() }; }

def all_positions() -> long {
    let sum = 0;
    // a let value: the one position that already worked
    sum = sum + { def a1() -> long { 1 }; a1() };
    // a call argument
    sum = sum + takes({ def a2() -> long { 2 }; a2() });
    // an array element, a fixed-array element, an array repeat
    let arr = [{ def a4() -> long { 4 }; a4() }];
    let fix: [long; 1] = [{ def a5() -> long { 5 }; a5() }; 1];
    let rep = [{ def a6() -> long { 6 }; a6() }; 1];
    sum = sum + arr[0] + fix[0] + rep[0];
    // a record value and a map value
    let r: Box = { v: { def a7() -> long { 7 }; a7() } };
    let m: {str => long} = { "k": { def a8() -> long { 8 }; a8() } };
    sum = sum + r.v + m["k"]!;
    // operands: infix, unary, a return value
    sum = sum + ({ def a9() -> long { 9 }; a9() } + 0);
    sum = sum + -{ def a10() -> long { 10 }; a10() };
    sum = sum + via_return();
    // an address taken through a variable (only a variable has one)
    let addr = { def a12() -> long { 12 }; a12() };
    let p: *long = &addr;
    sum = sum + *p;
    // an assignment's right-hand side, and a field read through a block
    let w = 0;
    w = { def a14() -> long { 14 }; a14() };
    let inner = { w: { def a18() -> long { 18 }; a18() } };
    sum = sum + w + inner.w;
    // postfix bases: an index, a slice bound, and the value behind an index
    let base = [{ def a15() -> long { 15 }; a15() }];
    sum = sum + base[{ def a16() -> long { 0 }; a16() }];
    let text = "abcdef";
    let sub = text[{ def a17() -> long { 1 }; a17() }:4];
    sum = sum + sub.length;
    // a store through a pointer, a field store, an index store, a slice store
    let cell: *long = &w;
    *cell = { def a19() -> long { 19 }; a19() };
    let holder = { w: 0 };
    holder.w = { def a20() -> long { 20 }; a20() };
    let ia = [0];
    ia[{ def a21() -> long { 0 }; a21() }] = { def a22() -> long { 21 }; a22() };
    let sa = [0, 0, 0];
    sa[0:1] = [{ def a23() -> long { 22 }; a23() }];
    sum = sum + w + holder.w + ia[0] + sa[0];
    // a compound assignment, and the right-hand side of a plain one
    let op = 1;
    op += { def a24() -> long { 0 }; a24() } + 1;
    let inc = { def a26() -> long { 0 }; a26() } + 1;
    sum = sum + op + inc;
    // every kind of condition: if, while, a C-style for (init, cond, step),
    // a foreach head, and both bounds of a for-range head
    if ({ def b1() -> bool { true }; b1() }) { sum = sum + 1; };
    let n = 0;
    while ({ def b2() -> bool { n < 1 }; b2() }) { n = n + 1; };
    for (let i = { def b3() -> long { 0 }; b3() }; i < { def b4() -> long { 1 }; b4() }; i = i + { def b5() -> long { 1 }; b5() }) {
        sum = sum + 1;
    };
    foreach (x in { def b6() -> [long] { [1, 2] }; b6() }) { sum = sum + x; };
    for q in { def b8() -> long { 1 }; b8() }..{ def b9() -> long { 3 }; b9() } { sum = sum + 1; };
    // a def in a def in a def, all inside an expression block
    sum = sum + { def c1() -> long {
        def c2() -> long { def c3() -> long { 23 }; c3() };
        c2()
    }; c1() };
    // a let-bound closure inside an expression block, capture-free (hoisted
    // like a def) and capturing (built where it is written)
    sum = sum + { let c4 = def (x: long) -> long { x }; c4(24) };
    sum = sum + { let c5 = def (x: long) -> long { x + sum }; c5(0) };
    sum
}

// The two positions' worth of numbers spelled out, so a regression that
// breaks one of them says which: every arm contributes, so a wrong total is
// a wrong def somewhere.
print(all_positions());