// Maps {K => V}: dynamic keys, one value type, reads always optional.
let m = {"a": 1, "b": 2};
print(m);
print(len(m));
print(m["a"]);
print(m["zz"]);
print(m["zz"] == none);

// set: overwrite keeps the position, a new key appends
m["a"] = 10;
m["c"] = 3;
print(m);
print(len(m));
print(m["a"]! + m["c"]!);

// duplicate literal keys: last value wins, first position stays
let d = {"x": 1, "y": 2, "x": 3}; // expect-warning: duplicate key 'x' in a map literal; the last one wins
print(d);

// keys built at run time compare by content
let k = "b" + "";
print(m[k]!);

// maps are references: an alias sees the write
let alias = m;
alias["d"] = 4;
print(m["d"]!);

// an empty map needs its type from an annotation
let e: {str => str} = {};
print(e);
e["hi"] = "there";
print(e["hi"]!);
print(tostring(e));

// other hashable key types
let n: {long => str} = {};
n[3] = "three";
n[3] = "THREE";
n[7] = "seven";
print(n);
print(n[3]!);

// maps cross function boundaries (by reference)
def bump(t: {str => long}, key: str) -> long {
    let cur = t[key];
    if (cur == none) { t[key] = 1; 1 } else { t[key] = cur! + 1; cur! + 1 }
};
let counts: {str => long} = {};
bump(counts, "w");
bump(counts, "w");
bump(counts, "v");
print(counts);

// function values are map values too
def twice(x: long) -> long { x * 2 };
def thrice(x: long) -> long { x * 3 };
let ops = {"two": twice, "three": thrice};
print(ops["three"]!(5));