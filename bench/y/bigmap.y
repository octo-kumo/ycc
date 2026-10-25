// bench/y/bigmap.y — large maps: 40k long keys and 20k str keys inserted, read
// back, missed and overwritten (the hash index; a scan would take seconds).
def run() -> long {
    let m: { long => long } = {};
    let s: { str => long } = {};
    let ks: [str] = [];
    for i in 0..100000 { ks += "k" + tostring(i * 13); };
    for i in 0..1000000 { m[i * 7919 % 100003] = i; };
    for i in 0..100000 { s[ks[i]] = i; };
    let acc = 0;
    for i in 0..1000000 { if (m[i * 7919 % 100003] != none) { acc = acc + m[i * 7919 % 100003]!; }; };
    for i in 0..100000 { acc = acc + s[ks[i]]!; };
    for i in 0..100000 { if (s["x" + tostring(i)] == none) { acc++; }; };
    for i in 0..100000 { s[ks[i]] = s[ks[i]]! + 1; };
    acc + len(m) + len(s)
};
print(run());
