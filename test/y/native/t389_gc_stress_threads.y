// The threaded collector under --gc=stress: a cycle at every allocating slow
// path, with two threads. The collector is correct at any trigger frequency,
// so this is what turns "it worked when it ran" into "it was checked while it
// ran" -- src/tools/ytest/su_gc.y builds exactly this program with --gc=stress.
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
let t1 = spawn { work(20000) };
let t2 = spawn { work(20000) };
print(join t1);
print(join t2);
