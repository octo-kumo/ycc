// Two threads that allocate hard. Before the stop-the-world collector a cycle
// was refused once a thread existed (y_heap+24), so every byte either thread
// allocated stayed: src/tools/ytest/su_gc.y runs this under a small cap, where the
// committed runtime runs out of memory and this one does not.
def work(n: long) -> long {
    let i = 0;
    let acc = 0;
    while (i < n) {
        let s = "x" + tostring(i) + "-abcdefghijklmnop";
        acc = acc + s.length;
        i = i + 1;
    };
    acc
};
let t1 = spawn { work(300000) };
let t2 = spawn { work(300000) };
print(join t1);
print(join t2);
