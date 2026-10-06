// Data parallelism: eight threads each own a DISJOINT slice of one shared
// array, write it, and the main thread reads the whole thing after joining.
// Nothing is locked because nothing is shared, and `join` is the barrier that
// makes the writes visible -- so this is the test that would fail if a
// thread's stores went to a private copy of the array, or if the join
// returned before the thread's writes landed.
let n = 8;
let per = 2000;
let total = n * per;
let data: [long] = [];
for i in 0..total { data += 0; };
let ts: [() -> long] = [];
for w in 0..n {
    ts += spawn {
        let base = w * per;
        let i = 0;
        while (i < per) { data[base + i] = base + i; i = i + 1; };
        data[base]
    };
};
let firsts: [long] = [];
foreach (t in ts) { firsts += join t; };
let ok = true;
let i = 0;
while (i < total) {
    if (data[i] != i) { ok = false; };
    i = i + 1;
};
print(ok);
print(len(data));
print(firsts);
// The same shape the other way round: one thread writes, then spawns ten
// readers from inside itself -- a thread's own spawns see its writes.
let src: [long] = [];
for i in 0..100 { src += i * 3; };
let t = spawn {
    let kids: [() -> long] = [];
    for k in 0..10 {
        kids += spawn {
            let s = 0;
            for i in 0..100 { s = s + src[i]; };
            s
        };
    };
    let sum = 0;
    foreach (k in kids) { sum = sum + join k; };
    sum
};
print(join t);
