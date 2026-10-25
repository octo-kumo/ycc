// Threads spawning threads, all at once. The collector's registry of live
// threads (y_gc_threads) is a linked list that spawn pushes on and an exiting
// thread takes itself off; two of those at the same moment used to lose one
// update and drop a live thread from the list, so its stack was never scanned
// and its start closure was freed before it ran (a crash in y_thread_start, or
// a "thread belongs to another process" trap). Run under --gc=stress by
// test/sh/test_gc.sh, where every allocation can collect.
let outer: [() -> long] = [];
for w in 0..6 {
    outer += spawn {
        let mine = 0;
        for k in 0..30 {
            let t = spawn { let a: [long] = []; a += k * w; a += 1; len(a) };
            mine = mine + join t;
        };
        mine
    };
};
let all = 0;
foreach (t in outer) { all = all + join t; };
print(all);
