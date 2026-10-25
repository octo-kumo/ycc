// Map reads and the box cache. A read m[k] is V?, an option is a heap
// box, and a map caches the box of each entry: the first read after a
// write boxes the value, later reads share that box, and a write clears
// it (a reader still holding the old box keeps the old value). m[k]!,
// unwrap(m[k]), is_some(m[k]) and m[k] ==/!= none take or test the value
// without a box at all.

// a read is a snapshot of the entry: a later write never changes it
let m = {"a": 1, "b": 2};
let o = m["a"];
m["a"] = 5;
print(o!);
print(m["a"]!);
let o2 = m["a"];
let o3 = m["a"];
print(o2! + o3!);
m["a"] = 7;
print(o2!);
print(m["a"]);
print(m);
// ... through an alias too
let al = m;
let held = m["b"];
al["b"] = 20;
print(held!);
print(m["b"]!);

// every boxless form, on a hit and on a miss
print(is_some(m["a"]));
print(is_some(m["zz"]));
print(m["a"] == none);
print(m["zz"] == none);
print(m["a"] != none);
print(m["zz"] != none);
print(none == m["zz"]);
print(none != m["a"]);
print(unwrap(m["a"]));

// the map and the key run exactly once in every form
let calls = 0;
def key(s: str) -> str { calls = calls + 1; s };
def mp(t: {str => long}) -> {str => long} { calls = calls + 10; t };
print(mp(m)[key("a")]!);
print(is_some(mp(m)[key("b")]));
print(mp(m)[key("q")] == none);
print(none != mp(m)[key("q")]);
print(unwrap(mp(m)[key("b")]));
let e = mp(m)[key("a")];
print(e!);
print(calls);

// option values: the entry holds an option, so m[k]! is one
let mo: {str => long?} = {};
mo["x"] = some(3);
mo["y"] = none;
print(mo["x"]!!);
print(mo["y"] == none);
print(mo["y"]! == none);
print(is_some(mo["y"]));
print(mo["z"] == none);

// the cache in numbers: heap_used() deltas over 1000 iterations
let acc = 0;
let h = heap_used();
for k in 0..1000 { acc = acc + m["a"]! + unwrap(m["b"]); };
print(heap_used() - h);
h = heap_used();
for k in 0..1000 {
    if (is_some(m["a"]) && m["zz"] == none && m["b"] != none) { acc = acc + 1; };
};
print(heap_used() - h);
// a read that escapes boxes once; every later read shares the box
h = heap_used();
for k in 0..1000 { let q = m["a"]; acc = acc + q!; };
print(heap_used() - h <= 16);
// a write clears the box, so the next escaping read makes a new one
h = heap_used();
for k in 0..1000 { m["a"] = k; let q = m["a"]; acc = acc + q!; };
print(heap_used() - h <= 16 * 1000);
// the counting idiom allocates nothing once the keys exist
let words = ["x", "y", "x", "z", "x"];
let counts: {str => long} = {};
foreach (w in words) { counts[w] = 0; };
h = heap_used();
for k in 0..200 {
    foreach (w in words) {
        if (counts[w] == none) { counts[w] = 1; } else { counts[w] = counts[w]! + 1; };
    };
};
print(heap_used() - h);
print(counts);
print(acc);

// an array value is one entry, an empty one too
let am: {str => [long]} = {};
am["x"] = [1, 2];
am["y"] = [];
am["z"] = [3];
print(am);
print(len(am));
print(len(am["y"]!));
let nm: {str => [[long]]} = {};
nm["a"] = [[]];
nm["b"] = [];
print(nm);
print(len(nm["a"]!));

// the value runs before the scan, so a key it adds is found, not doubled
let w: {str => long} = {};
def side() -> long { w["k"] = 7; 8 };
w["k"] = side();
print(w);

// unwrapping a miss traps like unwrap(none)
print(m["nope"]!);
print("unreachable");
