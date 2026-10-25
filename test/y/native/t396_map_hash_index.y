// Maps with str and long keys switch from a scan to a hash index past 8
// entries; every observable behaviour stays that of the scan: insertion order,
// overwrite in place, absent keys, a literal bigger than the threshold, maps
// that are values of maps, and the key types that never get an index.
let big = {"a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7, "h": 8, "i": 9, "j": 10, "k": 11};
big["l"] = 12;
big["a"] = 100;
print(big["a"]! + big["l"]! + big["k"]!);
print(big["zz"]);
print(len(big));
print(keys(big)[0] + keys(big)[11]);

let m: { long => long } = {};
let bad = 0;
for i in 0..3000 { m[i * 31 - 500] = i; };
for i in 0..3000 { if (m[i * 31 - 500]! != i) { bad += 1; } };
for i in 0..300 { if (m[i * 31 - 499] != none) { bad += 1; } };
for i in 0..3000 { m[i * 31 - 500] = i + 1; };
for i in 0..3000 { if (m[i * 31 - 500]! != i + 1) { bad += 1; } };
print(bad); print(len(m)); print(keys(m)[2999]); print(values(m)[0]);

let s: { str => long } = {};
for i in 0..2000 { s["key" + tostring(i)] = i; };
s["key7"] = -7;
let sbad = 0;
for i in 0..2000 { if (s["key" + tostring(i)]! != i && i != 7) { sbad += 1; } };
print(sbad); print(s["key7"]); print(s["nokey"]); print(len(s));
print(keys(s)[1999]);

let nest: { str => { long => long } } = {};
for i in 0..20 { let inner: { long => long } = {}; inner[i] = i * i; nest["n" + tostring(i)] = inner; };
print(nest["n19"]![19]);
print(len(nest));

let b: { byte => long } = {};
for i in 0..40 { b['a' + i] = i; };
print(b['a' + 39]); print(len(b));
let f: { float => long } = {};
for i in 0..20 { f[i * 0.5] = i; };
print(f[9.5]); print(len(f));
let small: { long => str } = {};
small[3] = "x"; small[4] = "y"; small[3] = "z";
print(small);
