// bench/y/sorting.y — a hand-written quicksort and insertion sort over
// [long], the builtin sort, and a check pass: array indexing, swaps, calls.
def qsort(a: [long], lo: long, hi: long) -> long {
    if (lo >= hi) { return 0; };
    let p = a[(lo + hi) / 2];
    let i = lo;
    let j = hi;
    while (i <= j) {
        while (a[i] < p) { i++; };
        while (a[j] > p) { j--; };
        if (i <= j) { let t = a[i]; a[i] = a[j]; a[j] = t; i++; j--; };
    };
    qsort(a, lo, j);
    qsort(a, i, hi);
    0
};
def fill(n: long, seed: long) -> [long] {
    let a: [long] = [];
    let s = seed;
    for i in 0..n { s = (s * 1103515245 + 12345) % 2147483648; a += s % 100000; };
    a
};
def run() -> long {
    let a = fill(400000, 7);
    qsort(a, 0, len(a) - 1);
    let ok = 0;
    for i in 1..len(a) { if (a[i - 1] <= a[i]) { ok++; }; };
    let b = fill(4000, 3);
    for i in 1..len(b) {
        let k = b[i];
        let j = i - 1;
        while (j >= 0 && b[j] > k) { b[j + 1] = b[j]; j--; };
        b[j + 1] = k;
    };
    ok + b[0] + b[len(b) - 1]
};
print(run());
