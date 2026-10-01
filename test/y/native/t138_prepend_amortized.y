// a *= v inserts at the front, in place, in amortized O(1): the header's
// fourth word counts the free slots before data, a prepend steps data
// back one slot, and when there is no room the elements move to a block
// with max(len, 8) free slots in front and the same room behind.

// a random mix of prepends and pushes agrees with a model: the prepended
// values in reverse, then the pushed ones
let seed = 12345;
def rnd(n: long) -> long {
    seed = (seed * 1103515245 + 12345) % 2147483648;
    seed % n
};
def check(a: [long], fr: [long], bk: [long]) -> bool {
    let n = len(fr);
    let ok = len(a) == n + len(bk);
    for j in 0..n { if (a[j] != fr[n - 1 - j]) { ok = false; }; };
    for k in 0..len(bk) { if (a[n + k] != bk[k]) { ok = false; }; };
    ok
};
let a: [long] = [];
let fr: [long] = [];
let bk: [long] = [];
let ok = true;
for i in 0..3000 {
    if (rnd(3) == 0) { a += i; bk += i; } else { a *= i; fr += i; };
    if (i % 101 == 0) { ok = ok && check(a, fr, bk); };
};
print(ok && check(a, fr, bk));
print(len(a));

// packed bytes, the same way
let b: [byte] = [];
let bf: [long] = [];
let bb: [long] = [];
let bok = true;
for i in 0..3000 {
    let v = i % 251;
    if (rnd(2) == 0) { b += v; bb += v; } else { b *= v; bf += v; };
};
let wide: [long] = [];
foreach (x in b) { wide += x; };
print(check(wide, bf, bb));

// the header never moves: an alias sees every prepend and push
let al = a;
al *= -1;
al += -2;
print(a[0]);
print(a[len(a) - 1]);
print(len(al) == len(a));

// copies and slices own their elements
let cp = a[0:4];
cp *= 99;
print(cp);
print(a[0:4]);

// a literal has no room in front; strings and nested arrays prepend too
let lit = [3, 4];
lit *= 2;
lit *= 1;
print(lit);
let ss = ["c"];
ss *= "b";
ss *= "a";
print(ss);
let nn = [[3]];
nn *= [2];
nn += [4];
nn *= [1];
print(nn);

// many prepends: linear time, and memory within a small factor of the data
let h = heap_used();
let big: [long] = [];
for i in 0..20000 { big *= i; };
print(heap_used() - h <= 5 * 8 * 20000);
print(big[0] + big[19999]);
