// `break` leaves the innermost enclosing loop; `continue` starts its next
// turn. Before these there was no way out of a loop but a flag tested in the
// condition, or a `return` (which cannot leave a value behind to go on with).
//
// The cases below are the ones where getting the jump target wrong is silent
// rather than loud: `continue` must run a C-style `for`'s step and a
// `foreach`/`for..in`'s increment, or the loop never ends; it must leave a
// nested loop alone; and a closure made over the loop variable must keep
// seeing its own turn's value after a `continue` has gone by.

// while: break leaves, and nothing after it in the body runs.
let i = 0;
while i < 10 {
    i = i + 1;
    if i == 4 { break; }
    print("w " + tostring(i));
}
print("w after " + tostring(i));

// while: continue re-tests the condition, and the counter it advanced stands.
let j = 0;
let odd = 0;
while j < 6 {
    j = j + 1;
    if j % 2 == 0 { continue; }
    odd = odd + j;
}
print("odd sum " + tostring(odd));

// for: continue MUST run the step. Were the target the head label, `i` would
// never advance past 0 and this would not terminate.
let n = 0;
let seen: [str] = [];
for (let k = 0; k < 5; k = k + 1) {
    if k == 2 { continue; }
    n = n + k;
    seen += tostring(k);
}
print("for sum " + tostring(n) + " of " + seen[0] + seen[1] + seen[2] + seen[3]);

// for: break leaves, and the step does not run on the way out.
let last = -1;
for (let k = 10; k > 0; k = k - 1) {
    if k == 7 { break; }
    last = k;
}
print("for break last " + tostring(last));

// for..in: break leaves.
let rlast = -1;
for x in 0..10 {
    if x == 5 { break; }
    rlast = x;
}
print("range last " + tostring(rlast));

// for..in: continue must advance the counter (it is incremented at the
// BOTTOM of the loop, after the body).
let cnt = 0;
for x in 0..10 {
    if x < 5 { continue; }
    cnt = cnt + 1;
}
print("range cont " + tostring(cnt));

// foreach: both.
let a = [10, 20, 30, 40];
let sum = 0;
foreach (v in a) {
    if v == 30 { break; }
    sum = sum + v;
}
print("each sum " + tostring(sum));
let sum2 = 0;
foreach (v in a) {
    if v == 20 { continue; }
    sum2 = sum2 + v;
}
print("each cont " + tostring(sum2));

// A body that appends to the array it walks keeps seeing what it appended,
// because `foreach` re-reads the length every turn rather than hoisting it,
// and `continue` goes through that same increment so it does not change the
// rule. Bounded here on purpose: `foreach (v in a) { a += v }` never ends,
// which is the documented behaviour, not something `break` should paper over.
let grow: [long] = [1, 2];
let adds = 0;
foreach (v in grow) {
    if adds >= 2 { break; }
    adds = adds + 1;
    grow += v;
    continue;
}
print("grew to " + tostring(len(grow)));

// Nested: break leaves only the INNERMOST loop. The outer one keeps going
// until its own break.
let out = "";
for x in 0..3 {
    for y in 0..3 {
        if y == 2 { break; }
        out = out + tostring(x) + tostring(y) + " ";
    }
    if x == 1 { break; }
}
print("nested " + out);

// continue in the inner loop of a nest leaves the outer one alone too.
let pairs = "";
for x in 0..3 {
    for y in 0..4 {
        if y == 1 { continue; }
        pairs = pairs + tostring(x * 10 + y) + " ";
    }
}
print("pairs " + pairs);

// Inside an `if` and inside a `match` arm -- neither is a loop, so the jump
// still belongs to the enclosing one.
let m = 0;
for x in 0..5 {
    match x {
        2 => { break; },
        _ => { if x % 2 == 0 { continue; }; m = m + 1; }
    }
}
print("match " + tostring(m));

// The `;` is optional before the block's `}`, exactly as after `return`.
let w = 0;
while w < 5 {
    w = w + 1;
    if w == 2 { break }
}
print("no semi " + tostring(w));

// A closure over the loop variable, kept past the loop: the cell a
// `for x in a..b` variable lives in is refreshed every turn, and `continue`
// and `break` must not reuse one turn's cell for the next.
def make() -> [(() -> long)] {
    let fs: [(() -> long)] = [];
    for x in 0..5 {
        def f() -> long { x * 10 };
        fs += f;
        if x == 2 { continue; }
        if x == 4 { break; }
    }
    fs
}
let got = make();
print("made " + tostring(len(got)));
foreach (g in got) { print("f " + tostring(g())); }

// A loop as a function body's last statement is still void, and a jump out
// of it does not make the function return anything.
def first_over(a: [long], lim: long) -> long {
    foreach (v in a) {
        if v > lim { return v; }
        if v < 0 { break; }
    };
    -1
}
print("first " + tostring(first_over([1, 2, 9, 3], 5)));
print("none " + tostring(first_over([1, 2, 3], 5)));
print("neg " + tostring(first_over([1, -1, 9], 5)));
