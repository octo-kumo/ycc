// bench/y/maps.y — map reads and writes: counting (m[k] == none, then
// m[k] = m[k]! + 1), lookups whose option escapes into a variable, and
// misses. The key set is small (64 strings), so this is the scan; bigmap.y is the hash index.
def maps(n: long) -> long {
let keys: [str] = [];
let k = 0;
while (k < 64) {
    keys += "key" + tostring(k * 7919 % 1000);
    k = k + 1;
    0
};
let counts: {str => long} = {};
let i = 0;
let acc = 0;
while (i < n) {
    let w = keys[(i * 31 + i / 7) % 64];
    if (counts[w] == none) {
        counts[w] = 1;
        0
    } else {
        counts[w] = counts[w]! + 1;
        0
    };
    let o = counts[keys[i % 64]];
    if (is_some(o)) {
        acc = acc + o!;
        0
    } else { 0; };
    if (counts["missing"] != none) {
        acc = acc - 1;
        0
    } else { 0; };
    i = i + 1;
    0
};
acc + len(counts)
};

print(maps(60000));
