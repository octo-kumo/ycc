// `foreach` over a map or a string, not just an array. The audit called
// this the cheap half of its P1-5 (204 hand-written index loops, and
// `foreach` covering neither maps nor strings); a map yields its KEYS (the
// pairs want two names, and the manual's answer for that is keys(m)) and a
// string yields its BYTES.
//
// The length is re-read on every iteration, as it always was for an array, so
// a body that grows the thing it walks goes on seeing what it added.
let m = { "b": 2, "a": 1, "c": 3 };
foreach (k in m) { print(k, "=", m[k]!, " "); };
print("| ");

// insertion order, not hash order and not sorted
foreach (k in m) { print(k, " "); };
print("| ");

// a non-string key type works the same
let n: {long => str} = {};
n[2] = "two";
n[10] = "ten";
foreach (k in n) { print(k, "=", n[k]!, " "); };
print("| ");

// a string yields bytes, zero-extended
foreach (c in "hi!") { print(c, " "); };
print("| ");
foreach (c in "") { print("never"); };
foreach (c in "\n\t") { print(c, " "); };
print("| ");

// empty is empty, and not an error
let e: {str => long} = {};
let seen = 0;
foreach (k in e) { seen = seen + 1; };
foreach (c in "") { seen = seen + 100; };
print(seen, " ");

// break and continue work here as they do in an array loop
let sum = 0;
foreach (k in m) {
    if (k == "b") { continue; };
    if (k == "c") { break; };
    sum = sum + m[k]!;
};
print(sum, " ");

let cs = 0;
foreach (c in "abcdef") {
    if (c == 98) { continue; };   // 'b'
    if (c == 101) { break; };     // 'e'
    cs = cs + c;
};
print(cs, " ");

// the loop variable is per-iteration fresh, so a closure captures its own
let fs: [(long) -> long] = [];
foreach (k in n) { let j = k; fs += def (x: long) -> long { j * 10 + x }; };
print(fs[0](1), " ", fs[1](1), " ");

// and a body that grows what it walks sees the new entries, exactly as
// `foreach (x in a) { a += x }` does
let grow: {str => long} = { "1": 1 };
let count = 0;
foreach (k in grow) {
    count = count + 1;
    if (count < 4) { grow[k + count] = count; };
};
print(count, " ");
let arr: [long] = [1];
let rounds = 0;
foreach (x in arr) {
    rounds = rounds + 1;
    if (rounds < 4) { arr += x; };
};
print(rounds, " ");

// a map's keys also come out of keys(m), and the two agree
let same = len(m);
foreach (k in keys(m)) { if (m[k] == none) { same = same - 1; }; };
// and a string's bytes out of bytes(), the same values
let csame = 0;
foreach (c in "abc") { csame = csame + c; };
let bybytes = 0;
foreach (c in bytes("abc")) { bybytes = bybytes + c; };
print(same, " ", csame, " ", bybytes);
