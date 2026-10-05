// A value-used `+=` on a string is `s = s + t`: the ownership cell is
// dropped, so the buffer comes back exactly as long as the result and
// nothing can extend it in place again. That is what keeps a string read
// out of `s` before the append stable (the value semantics strings have to
// keep), but it also means the whole string is copied here -- so a loop of
// them copies it once per iteration, and the amortised growth every other
// append in that loop had is gone with it. An append *statement* is O(1)
// amortised (gen_sappend), so the difference is one `;`.
//
// The check follows the emitter's own rule for which of the two a site is:
// `gen` (a value is produced, so the append copies) against `gen_stmt`
// (nothing reads one, so gen_sappend extends in place) -- and it wants a
// loop, since one copy costs what any `+` costs. Every line below that is
// not marked must stay silent: an append statement, an append to an array of
// strings, an append to a number, a loop body's own last statement (which
// the emitter drops even without a `;`), and the same value-used append
// outside a loop.
//
// A global, and the ledger's shape: the append is the value of an if arm
// inside a loop, where one missing `;` turns 120 KB of output into 1.2 GB.
let out = "";
let i = 0;
while (i < 3) { out += "abcdefgh"; if (i % 2 == 0) { out += "ijklmnop" }; i = i + 1 }; // expect-warning: this `+=` on a string copies the whole string, so a loop of them is quadratic -- add a `;` if nothing reads the value
print(len(out));

// a local inside a def, with the value wanted, in a loop of its own
def wanted(n: long) -> str {
    let s = "";
    let i = 0;
    while (i < n) {
        let u = { s += "ab" }; // expect-warning: this `+=` on a string copies the whole string, so a loop of them is quadratic -- add a `;` if nothing reads the value
        if (n > 1 && u == "") { s += "!" }; // expect-warning: this `+=` on a string copies the whole string, so a loop of them is quadratic -- add a `;` if nothing reads the value
        i = i + 1
    };
    s
};
print(wanted(2));

// an append statement: the amortised form, silent
let good = "";
good += "x";
good += "yz";
print(good);

// an array of strings is not a string: `+=` pushes an element
let arr: [str] = [];
arr += "q";
print(arr.length);

// a number, likewise
let n = 0;
n += 1;
print(n);

// a loop body's own last statement is dropped by the emitter, `;` or not
let body = "";
let j = 0;
while (j < 3) { j = j + 1; body += "y" }
print(len(body));

// the same value-used append outside a loop: one copy, which is what any `+`
// costs, so nothing is said
let once = "";
once += "p" ;
if (once == "") { once += "q" };
print(once);

// and the check knows a binding's string-ness from its annotation or its
// initialiser (lint never runs the checker), so a *parameter* is silent
// even where its append copies -- the limit of a syntactic check, kept
// visible so it does not look like an oversight.
def through_param(s: str, t: str) -> str {
    let u = { s += t };
    u
};
print(through_param("ab", "cd"));