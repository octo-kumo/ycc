// Memory growth. The allocator is a bump that never frees, so every byte a
// loop allocates stays allocated: a loop over data that already exists
// must allocate nothing, and growing a container must cost memory linear
// in its size (capacity doubling), never quadratic. heap_used() is the
// number of bytes allocated so far; each check prints the bytes a region
// allocated, or whether that stayed within its bound.

def add(p: { x: long, y: long }, k: long) -> long { p.x + p.y + k }

let a: [long] = [1, 2, 3, 4, 5, 6, 7, 8];
let bs: [byte] = bytes("hello world");
let r = { x: 1, y: 2 };
let s = "hello world";
let t = "hello there";
let fl = 1.5;
let o: long? = some(3);
let base = 10;
let cl = def(z: long) -> long { z + base };
let acc = 0;

// 1. a million iterations over existing data allocate nothing at all
let h = heap_used();
let i = 0;
while (i < 1000000) {
    acc = acc + i * 3 % 7;
    a[i % 8] = a[(i + 1) % 8] + 1;
    bs[i % 11] = bs[(i + 3) % 11];
    r.x = r.y + i;
    if (s == t) { acc = acc + 1; };
    if (s < t) { acc = acc + 1; };
    acc = acc + len(s) + s.length + byte_at(s, i % 11);
    fl = fl * 1.0000001;
    acc = acc + add(r, i) + cl(i);
    if (is_some(o)) { acc = acc + unwrap(o); };
    i = i + 1;
};
for k in 0..1000000 { acc = acc + k; };
foreach (v in a) { acc = acc + v; };
print(heap_used() - h);

// 2. growing a container is linear: each outgrown buffer stays allocated,
// but with doubling they sum to less than the last one (8 + 16 + ... + c
// < 2c), and the last one is at most twice the payload — 4x in all
let n = 100000;
h = heap_used();
let xs: [long] = [];
for k in 0..n { xs += k; };
print(heap_used() - h <= 4 * 8 * n);
h = heap_used();
let ys: [long] = [];
for k in 0..10000 { ys *= k; };
print(heap_used() - h <= 4 * 8 * 10000);
h = heap_used();
let packed: [byte] = [];
for k in 0..n { packed += 'x'; };
print(heap_used() - h <= 4 * n);

// join sizes the result first and allocates it once
let parts: [str] = [];
for k in 0..n { parts += "x"; };
h = heap_used();
let joined = join(parts, "");
print(heap_used() - h <= n + 64);

// 3. what does allocate, by design: an option keeps its value in a box,
// so some(v) costs at most 16 bytes
h = heap_used();
for k in 0..1000 { let q: long? = some(k); acc = acc + 1; }; // expect-warning: unused variable 'q'
print(heap_used() - h <= 16 * 1000);
// a map read is an option too, but the map caches each entry's box: m[k]!
// never boxes, and a read that escapes boxes once per write of the entry
let m = { "a": 1 };
h = heap_used();
for k in 0..1000 { acc = acc + unwrap(m["a"]); };
print(heap_used() - h);
h = heap_used();
for k in 0..1000 { let q = m["a"]; acc = acc + q!; };
print(heap_used() - h <= 16);

print(len(xs) + len(ys) + len(packed) + len(joined));
print(acc > 0);
