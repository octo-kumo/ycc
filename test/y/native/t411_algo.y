// std/algo.y against an independent reference: every function runs on inputs
// from a fixed generator, and the expected output was computed by a separate
// implementation in Python (math, bisect, itertools, heapq and plain dynamic
// programming), not by this code. The generator is a 31-bit LCG so both sides
// draw the same numbers.
import algo;

let seed = 12345;
def rnd(m: long) -> long {
    seed = (seed * 1103515245 + 12345) & 2147483647;
    (seed >> 8) % m
};
def rnd63() -> long {
    ((rnd(2147483648) << 31) | rnd(2147483648)) & 9223372036854775807
};
def rnd_arr(n: long, m: long) -> [long] {
    let a: [long] = [];
    let i = 0;
    while (i < n) { a += rnd(m); i = i + 1; };
    a
};
def sorted_asc(a: [long]) -> [long] {
    // an insertion sort: the test must not depend on the sort module
    let b: [long] = [];
    foreach (x in a) { b += x; };
    let i = 1;
    while (i < b.length) {
        let v = b[i];
        let j = i - 1;
        while (j >= 0 && b[j] > v) { b[j + 1] = b[j]; j = j - 1; };
        b[j + 1] = v;
        i = i + 1;
    };
    b
};
def is_sub(s: str, t: str) -> bool {
    let i = 0;
    let j = 0;
    while (i < s.length && j < t.length) {
        if (s[i] == t[j]) { i = i + 1; };
        j = j + 1;
    };
    i == s.length
};
def rnd_str(n: long, alphabet: long) -> str {
    let b: [byte] = [];
    let i = 0;
    while (i < n) { b += 97 + rnd(alphabet); i = i + 1; };
    from_bytes(b)
};

// ── numbers ──
print("gcd/lcm");
let i = 0;
while (i < 12) {
    let a = rnd(2001) - 1000;
    let b = rnd(2001) - 1000;
    print(algo.gcd(a, b), " ", algo.lcm(a, b));
    i = i + 1;
};
print(algo.gcd(0, 0), " ", algo.gcd(0, 7), " ", algo.lcm(0, 7), " ", algo.gcd(1 << 62, 1 << 40));

print("mulmod/powmod");
i = 0;
while (i < 8) {
    let m = rnd63() | 1;
    let a = rnd63() % m;
    let b = rnd63() % m;
    print(m, " ", algo.mulmod(a, b, m), " ", algo.powmod(a, b % 1000, m), " ", algo.powmod(a, 0, m));
    i = i + 1;
};
print(algo.powmod(5, 3, 1), " ", algo.powmod(-2, 3, 7), " ", algo.mulmod(9223372036854775806, 9223372036854775806, 9223372036854775807));

print("isqrt");
foreach (n in [0, 1, 2, 3, 4, 8, 9, 15, 16, 99, 100, 1000000, 999999999999, 4611686014132420609, 9223372036854775807, -5]) {
    print(n, " ", algo.isqrt(n));
};
i = 0;
while (i < 6) {
    let n = rnd63();
    print(n, " ", algo.isqrt(n));
    i = i + 1;
};

print("is_prime");
let bits = "";
i = 0;
while (i < 200) {
    if (algo.is_prime(i)) { bits += "1"; } else { bits += "0"; };
    i = i + 1;
};
print(bits);
foreach (n in [561, 1105, 1729, 1000000007, 998244353, 2305843009213693951, 3215031751, 3825123056546413051,
               9223372036854775783, 9223372036854775807, 4611686018427387847, 4611686018427387903, 1000000016000000063]) {
    print(n, " ", algo.is_prime(n));
};

print("primes");
let ps = algo.primes(100);
print(ps);
let big = algo.primes(100000);
let sum = 0;
foreach (p in big) { sum = sum + p; };
print(big.length, " ", sum, " ", big[big.length - 1]);
print(algo.primes(1), algo.primes(2), algo.primes(-3));

print("factorize");
foreach (n in [0, 1, 2, 12, 97, 360, 1024, 600851475143, 9223372036854775807, 6561000000, 1000000007 * 998244353,
               4611686014132420609, 3825123056546413051]) {
    print(n, " ", algo.factorize(n));
};
i = 0;
while (i < 6) {
    let n = rnd(1000000000000) + 2;
    let f = algo.factorize(n);
    let prod = 1;
    let allp = true;
    foreach (p in f) { prod = prod * p; if (!algo.is_prime(p)) { allp = false; }; };
    print(n, " ", f.length, " ", prod == n, " ", allp);
    i = i + 1;
};

print("choose");
foreach (nk in [[5, 2], [10, 0], [10, 10], [10, 11], [10, -1], [0, 0], [52, 5], [62, 31], [66, 33], [67, 33], [100, 3], [100, 50], [1000, 2], [3037000500, 2]]) {
    print(nk[0], " ", nk[1], " ", algo.choose(nk[0], nk[1]));
};

// ── searching ──
print("binary search");
let sa = sorted_asc(rnd_arr(60, 40));
print(sa);
let q = 0;
let bad = 0;
while (q < 45) {
    let x = q - 2;
    print(x, " ", algo.lower_bound(sa, x), " ", algo.upper_bound(sa, x), " ", algo.bsearch(sa, x));
    q = q + 1;
};
print(algo.partition_point(100, def (k: long) -> bool { k * k >= 2000 }));
print(algo.partition_point(0, def (k: long) -> bool { true }), " ", algo.partition_point(5, def (k: long) -> bool { false }));
print(algo.lower_bound([], 3), " ", algo.bsearch([], 3));
let words = ["apple", "banana", "banana", "cherry", "fig", "grape"];
foreach (w in ["", "apple", "b", "banana", "c", "fig", "zzz"]) {
    print(w, " ", algo.lower_bound_str(words, w));
};

// ── sequences ──
print("sequences");
print(algo.dedup([1, 1, 2, 2, 2, 3, 1, 1]), algo.dedup([]), algo.dedup([5]));
print(algo.rotate([1, 2, 3, 4, 5], 2), algo.rotate([1, 2, 3, 4, 5], -1), algo.rotate([1, 2, 3], 7), algo.rotate([], 3));
print(algo.prefix_sums([3, -1, 4, 1, -5, 9]), algo.prefix_sums([]));
let np = [1, 1, 2, 3];
let count = 1;
let first = np.length;
print(np);
while (algo.next_permutation(np)) { count = count + 1; };
print(count, " ", np);
let p3 = [1, 2, 3];
let chain = "";
let more = true;
while (more) { chain += tostring(p3) + ";"; more = algo.next_permutation(p3); };
print(chain);
print(algo.permutations([3, 1, 2]));
print(algo.permutations([]).length, " ", algo.permutations([7]));
print(algo.combinations([1, 2, 3, 4], 2));
print(algo.combinations([1, 2, 3], 0), algo.combinations([1, 2, 3], 3), algo.combinations([1, 2], 3), algo.combinations([1, 2], -1));
let kt = rnd_arr(50, 100);
let ks = sorted_asc(kt);
let kbad = 0;
i = 0;
while (i < 50) {
    if (algo.kth_smallest(kt, i)! != ks[i]) { kbad = kbad + 1; };
    i = i + 1;
};
print(kbad, " ", algo.kth_smallest(kt, 50), " ", algo.kth_smallest(kt, -1), " ", algo.kth_smallest([], 0), " ", kt.length);
print(algo.kth_smallest([5, 5, 5, 5], 2), " ", algo.kth_smallest([9, 1], 0), " ", algo.kth_smallest([9, 1], 1));

print("lis/lcs/edit/kmp/z/knapsack");
i = 0;
while (i < 8) {
    let a = rnd_arr(30, 50);
    print(algo.lis(a));
    i = i + 1;
};
print(algo.lis([]), " ", algo.lis([5]), " ", algo.lis([3, 3, 3]), " ", algo.lis([1, 2, 3, 4]), " ", algo.lis([4, 3, 2, 1]));
i = 0;
while (i < 8) {
    let a = rnd_str(14, 3);
    let b = rnd_str(12, 3);
    let c = algo.lcs(a, b);
    print(a, " ", b, " ", c.length, " ", is_sub(c, a) && is_sub(c, b), " ", algo.edit_distance(a, b));
    i = i + 1;
};
print(algo.lcs("", "abc") == "", " ", algo.lcs("abc", "abc"), " ", algo.lcs("abc", "xyz") == "", " ", algo.edit_distance("kitten", "sitting"), " ", algo.edit_distance("", "abc"), " ", algo.edit_distance("flaw", "lawn"));
i = 0;
while (i < 6) {
    let h = rnd_str(40, 2);
    let nd = rnd_str(3, 2);
    print(h, " ", nd, " ", algo.kmp(h, nd), " ", algo.z_function(nd));
    i = i + 1;
};
print(algo.kmp("aaaa", "aa"), algo.kmp("abc", ""), algo.kmp("", "a"), algo.z_function("aabxaab"), algo.z_function(""));
i = 0;
while (i < 6) {
    let n = 8;
    let w = rnd_arr(n, 20);
    let v = rnd_arr(n, 50);
    print(algo.knapsack(w, v, 30), " ", algo.knapsack(w, v, 0), " ", algo.knapsack(w, v, 100));
    i = i + 1;
};
print(algo.knapsack([], [], 10), " ", algo.knapsack([5], [9], 4), " ", algo.knapsack([5], [9], 5), " ", algo.knapsack([1], [1], -1));

// ── a heap ──
print("heap");
let h = algo.heap_new();
print(algo.heap_len(h), " ", algo.heap_peek(h), " ", algo.heap_pop(h));
let keys = rnd_arr(40, 30);
i = 0;
while (i < keys.length) { algo.heap_push(h, keys[i], i); i = i + 1; };
print(algo.heap_len(h), " ", algo.heap_peek(h)!.key);
let popped: [long] = [];
let valsok = true;
while (algo.heap_len(h) > 0) {
    let e = algo.heap_pop(h)!;
    popped += e.key;
    if (keys[e.val] != e.key) { valsok = false; };
};
print(popped, " ", valsok);
let h2 = algo.heap_new();
algo.heap_push(h2, 5, 50);
algo.heap_push(h2, 2, 20);
algo.heap_push(h2, 2, 21);
algo.heap_push(h2, 9, 90);
print(algo.heap_pop(h2)!.key, algo.heap_pop(h2)!.key, algo.heap_pop(h2)!.key, algo.heap_pop(h2)!.val, " ", algo.heap_len(h2));

// ── disjoint sets ──
print("dsu");
let d = algo.dsu_new(20);
print(algo.dsu_sets(d), " ", algo.dsu_size(d, 3), " ", algo.dsu_same(d, 1, 2));
i = 0;
while (i < 14) {
    let a = rnd(20);
    let b = rnd(20);
    print(a, " ", b, " ", algo.dsu_union(d, a, b), " ", algo.dsu_sets(d), " ", algo.dsu_same(d, a, b), " ", algo.dsu_size(d, a));
    i = i + 1;
};
let reps = "";
i = 0;
while (i < 20) { reps += tostring(algo.dsu_size(d, i)) + ","; i = i + 1; };
print(reps);
let roots: [long] = [];
i = 0;
while (i < 20) {
    let r = algo.dsu_find(d, i);
    if (!(r in roots)) { roots += r; };
    i = i + 1;
};
print(roots.length, " ", algo.dsu_sets(d), " ", algo.dsu_find(d, 3) == algo.dsu_find(d, algo.dsu_find(d, 3)));

// ── graphs ──
print("graphs");
def make_graph(n: long, m: long, directed: bool) -> [[long]] {
    let adj: [[long]] = [];
    let u = 0;
    while (u < n) { adj += [[]]; u = u + 1; };
    let e = 0;
    while (e < m) {
        let a = rnd(n);
        let b = rnd(n);
        if (a != b && !(b in adj[a])) {
            adj[a] += b;
            if (!directed) { adj[b] += a; };
        };
        e = e + 1;
    };
    adj
};
let g = make_graph(14, 16, false);
print(g);
print(algo.bfs(g, 0));
print(algo.bfs(g, 5), algo.bfs(g, -1), algo.bfs(g, 14));
print(algo.dfs(g, 0));
print(algo.dfs(g, 9), algo.dfs(g, 14));
print(algo.components(g));
// weights
let wts: [[long]] = [];
foreach (row in g) {
    let wr: [long] = [];
    foreach (v in row) { wr += 1 + rnd(9); };
    wts += wr;
};
print(wts);
print(algo.dijkstra(g, wts, 0));
print(algo.dijkstra(g, wts, 7));
let sp = algo.shortest_path(g, wts, 0, 11);
print(sp[0], " ", sp[sp.length - 1]);
let plen = 0;
i = 0;
while (i + 1 < sp.length) {
    let ui = sp[i];
    let k = 0;
    while (g[ui][k] != sp[i + 1]) { k = k + 1; };
    plen = plen + wts[ui][k];
    i = i + 1;
};
print(plen == algo.dijkstra(g, wts, 0)[11], " ", algo.shortest_path(g, wts, 3, 3), " ", algo.shortest_path(g, wts, 0, 99));
let dag = make_graph(10, 14, true);
print(dag);
let ts = algo.toposort(dag);
print(ts);
if (ts != none) {
    let pos: [long] = [];
    foreach (x in ts!) { pos += 0; };
    i = 0;
    while (i < ts!.length) { pos[ts![i]] = i; i = i + 1; };
    let okorder = true;
    i = 0;
    while (i < dag.length) {
        foreach (v in dag[i]) { if (pos[v] <= pos[i]) { okorder = false; }; };
        i = i + 1;
    };
    print(okorder);
};
print(algo.toposort([[1], [2], [0]]), algo.toposort([[1], [2], []]), algo.toposort([]));
let edges: [[long]] = [[0, 1, 4], [0, 2, 3], [1, 2, 1], [1, 3, 2], [2, 3, 4], [3, 4, 2], [4, 5, 6], [5, 3, 3], [6, 7, 1]];
let mst = algo.kruskal(8, edges);
print(mst);
let total = 0;
foreach (e in mst) { total = total + e[2]; };
print(total, " ", mst.length, " ", algo.kruskal(3, []));
