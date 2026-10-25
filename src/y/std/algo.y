// std/algo.y -- algorithms and the small data structures they want.
//
//     import algo;
//     print(algo.gcd(84, 36));                              // 12
//     print(algo.is_prime(1000000007));                     // true
//     print(algo.lower_bound([1, 3, 3, 7], 3));             // 1
//     let h = algo.heap_new();
//     algo.heap_push(h, 5, 50); algo.heap_push(h, 2, 20);
//     print(algo.heap_pop(h)!.val);                         // 20
//
// Y has no generics, so what is about numbers takes a `[long]`, what is about
// text takes a `str`, and what is about positions in any array takes a size
// and a question about an index (`partition_point`). Everything here is
// plain Y over the language's own arrays and records: no system calls, no
// state between calls, nothing that cares which target it runs on.
//
// `long` arithmetic wraps on overflow (two's complement), as everywhere in Y.
// The number-theory functions below are written so that no intermediate value
// overflows for any argument they accept; where an answer cannot fit, the
// function says so (`choose` answers `none`).
export {
    gcd, lcm, mulmod, powmod, isqrt, is_prime, primes, factorize, choose,
    partition_point, lower_bound, upper_bound, bsearch, lower_bound_str,
    dedup, rotate, prefix_sums, next_permutation, permutations, combinations,
    kth_smallest, lis, lcs, edit_distance, kmp, z_function, knapsack,
    Heap, Entry, heap_new, heap_push, heap_pop, heap_peek, heap_len,
    DSU, dsu_new, dsu_find, dsu_union, dsu_same, dsu_size, dsu_sets,
    bfs, dfs, toposort, dijkstra, shortest_path, components, kruskal
};

// ── helpers ─────────────────────────────────────────────────────────────

// `[v; n]` for a size that is not a literal
def filled(n: long, v: long) -> [long] {
    let a: [long] = [];
    let i = 0;
    while (i < n) {
        a += v;
        i = i + 1;
    };
    a
};

def zero_bytes(n: long) -> [byte] {
    let a: [byte] = [];
    let i = 0;
    while (i < n) {
        a += 0;
        i = i + 1;
    };
    a
};

// ── numbers ─────────────────────────────────────────────────────────────

/** The greatest common divisor, never negative; `gcd(0, 0)` is 0. */
def gcd(a: long, b: long) -> long {
    let x = if (a < 0) { -a } else { a };
    let y = if (b < 0) { -b } else { b };
    while (y != 0) {
        let t = x % y;
        x = y;
        y = t;
    };
    x
};

/** The least common multiple, never negative; 0 if either argument is 0. The
result wraps if it does not fit a `long`, like `*` does. */
def lcm(a: long, b: long) -> long {
    if (a == 0 || b == 0) { return 0; };
    let g = gcd(a, b);
    let r = (a / g) * b;
    if (r < 0) { -r } else { r }
};

// a + b mod m for 0 <= a, b < m, without ever forming a sum that overflows
def addmod(a: long, b: long, m: long) -> long {
    if (a >= m - b) { a - (m - b) } else { a + b }
};

/** `a * b mod m` for `0 <= a, b` and `m >= 1`, exact for every `m` a `long`
holds: a double-and-add over the bits of `b`, so no product is ever formed. */
def mulmod(a: long, b: long, m: long) -> long {
    let r = 0;
    let x = a % m;
    let y = b;
    while (y > 0) {
        if (y & 1 == 1) { r = addmod(r, x, m); };
        x = addmod(x, x, m);
        y = y >> 1;
    };
    r
};

/** `b ** e mod m` for `e >= 0` and `m >= 1`. */
def powmod(b: long, e: long, m: long) -> long {
    if (m == 1) { return 0; };
    let r = 1;
    let x = b % m;
    if (x < 0) { x = x + m; };
    let k = e;
    while (k > 0) {
        if (k & 1 == 1) { r = mulmod(r, x, m); };
        x = mulmod(x, x, m);
        k = k >> 1;
    };
    r
};

/** The integer square root: the largest `r` with `r * r <= n`, or -1 for a
negative `n`. */
def isqrt(n: long) -> long {
    if (n < 0) { return -1; };
    if (n < 2) { return n; };
    let x = n / 2 + 1;
    let y = (x + n / x) / 2;
    while (y < x) {
        x = y;
        y = (x + n / x) / 2;
    };
    x
};

/** Whether `n` is prime. Exact for every `long`: trial division by the small
primes, then Miller-Rabin with the first twelve primes as bases, which is a
proof (not a probability) below 3.3e24. */
def is_prime(n: long) -> bool {
    if (n < 2) { return false; };
    let bases = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37];
    foreach (p in bases) {
        if (n == p) { return true; };
        if (n % p == 0) { return false; };
    };
    let d = n - 1;
    let s = 0;
    while (d & 1 == 0) {
        d = d >> 1;
        s = s + 1;
    };
    foreach (a in bases) {
        let x = powmod(a, d, n);
        if (x != 1 && x != n - 1) {
            let composite = true;
            let r = 1;
            while (r < s && composite) {
                x = mulmod(x, x, n);
                if (x == n - 1) { composite = false; };
                r = r + 1;
            };
            if (composite) { return false; };
        };
    };
    true
};

/** Every prime up to and including `n`, ascending (a sieve of Eratosthenes). */
def primes(n: long) -> [long] {
    let out: [long] = [];
    if (n < 2) { return out; };
    let composite: [byte] = zero_bytes(n + 1);
    let i = 2;
    while (i <= n) {
        if (composite[i] == 0) {
            out += i;
            let j = i * i;
            if (i <= n / i) {
                while (j <= n) {
                    composite[j] = 1;
                    j = j + i;
                };
            };
        };
        i = i + 1;
    };
    out
};

// a factor of the odd composite n (Pollard-Brent over mulmod)
def rho(n: long) -> long {
    let c = 1;
    while (true) {
        let x = 2;
        let y = 2;
        let d = 1;
        while (d == 1) {
            x = addmod(mulmod(x, x, n), c, n);
            y = addmod(mulmod(y, y, n), c, n);
            y = addmod(mulmod(y, y, n), c, n);
            d = gcd(if (x > y) { x - y } else { y - x }, n);
        };
        if (d != n) { return d; };
        c = c + 1;
    };
    n
};

def split_into(n: long, out: [long]) -> long {
    if (n == 1) { return 0; };
    if (is_prime(n)) {
        out += n;
        return 0;
    };
    let f = rho(n);
    split_into(f, out);
    split_into(n / f, out);
    0
};

/** The prime factors of `n >= 2` with multiplicity, ascending (`[2, 2, 3]` for
12); `[]` for anything below 2. Trial division by the small primes, then
Pollard's rho for what is left, so a product of two 31-bit primes is as quick
as a small number. */
def factorize(n: long) -> [long] {
    let out: [long] = [];
    if (n < 2) { return out; };
    let m = n;
    let p = 2;
    while (p < 100 && p * p <= m) {
        while (m % p == 0) {
            out += p;
            m = m / p;
        };
        p = p + 1;
    };
    if (m > 1) { split_into(m, out); };
    // rho finds factors in no order: insertion sort puts them in ascending order
    let i = 1;
    while (i < out.length) {
        let v = out[i];
        let j = i - 1;
        while (j >= 0 && out[j] > v) {
            out[j + 1] = out[j];
            j = j - 1;
        };
        out[j + 1] = v;
        i = i + 1;
    };
    out
};

/** The binomial coefficient `n` choose `k`, or `none` when `k` is out of
range (`k < 0` or `k > n`) or the answer does not fit a `long`. */
def choose(n: long, k: long) -> long? {
    if (k < 0 || k > n) { return none; };
    let kk = if (k > n - k) { n - k } else { k };
    let r = 1;
    let i = 1;
    while (i <= kk) {
        // r = r * (n - kk + i) / i, with the division exact at every step and
        // the multiplication checked: divide the common factor out first
        let m = n - kk + i;
        let g = gcd(r, i);
        let r1 = r / g;
        let i1 = i / g;
        let m1 = m / i1;
        if (m1 != 0 && r1 > 9223372036854775807 / m1) { return none; };
        r = r1 * m1;
        i = i + 1;
    };
    some(r)
};

// ── searching ───────────────────────────────────────────────────────────

/** The smallest `i` in `[0, n]` for which `pred(i)` is true, given that `pred`
is false up to some point and true from there on; `n` if it is never true.
This is binary search over any sorted structure: `pred` is the question asked
of position `i`. */
def partition_point(n: long, pred: (long) -> bool) -> long {
    let lo = 0;
    let hi = n;
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        if (pred(mid)) { hi = mid; } else { lo = mid + 1; };
    };
    lo
};

/** The first index of the ascending `a` whose element is `>= x`; `a.length`
if there is none. */
def lower_bound(a: [long], x: long) -> long {
    let lo = 0;
    let hi = a.length;
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        if (a[mid] < x) { lo = mid + 1; } else { hi = mid; };
    };
    lo
};

/** The first index of the ascending `a` whose element is `> x`; `a.length`
if there is none. `upper_bound(a, x) - lower_bound(a, x)` counts the `x`s. */
def upper_bound(a: [long], x: long) -> long {
    let lo = 0;
    let hi = a.length;
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        if (a[mid] <= x) { lo = mid + 1; } else { hi = mid; };
    };
    lo
};

/** The index of the first `x` in the ascending `a`, or -1. */
def bsearch(a: [long], x: long) -> long {
    let i = lower_bound(a, x);
    if (i < a.length && a[i] == x) { i } else { -1 }
};

/** `lower_bound` for an ascending `[str]`, compared by bytes. */
def lower_bound_str(a: [str], x: str) -> long {
    let lo = 0;
    let hi = a.length;
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        if (a[mid] < x) { lo = mid + 1; } else { hi = mid; };
    };
    lo
};

// ── sequences ───────────────────────────────────────────────────────────

/** `a` with each run of equal neighbours collapsed to one element: the set of
a sorted array. A new array. */
def dedup(a: [long]) -> [long] {
    let out: [long] = [];
    foreach (x in a) {
        if (out.length == 0 || out[out.length - 1] != x) { out += x; };
    };
    out
};

/** `a` rotated left by `k` positions (right if `k` is negative); a new array.
`rotate([1, 2, 3, 4], 1)` is `[2, 3, 4, 1]`. */
def rotate(a: [long], k: long) -> [long] {
    let n = a.length;
    let out: [long] = [];
    if (n == 0) { return out; };
    let s = k % n;
    if (s < 0) { s = s + n; };
    let i = 0;
    while (i < n) {
        out += a[(i + s) % n];
        i = i + 1;
    };
    out
};

/** `[0, a[0], a[0] + a[1], ...]`: `n + 1` running sums, so the sum of
`a[i..j)` is `p[j] - p[i]`. */
def prefix_sums(a: [long]) -> [long] {
    let out: [long] = [0];
    let s = 0;
    foreach (x in a) {
        s = s + x;
        out += s;
    };
    out
};

/** Rearranges `a`, in place, into the next permutation in lexicographic order
and answers true; at the last one (descending) it leaves `a` as the first
(ascending) and answers false. Looping `while (next_permutation(a))` from a
sorted array visits every distinct ordering once. */
def next_permutation(a: [long]) -> bool {
    let n = a.length;
    let i = n - 2;
    while (i >= 0 && a[i] >= a[i + 1]) { i = i - 1; };
    if (i < 0) {
        let lo = 0;
        let hi = n - 1;
        while (lo < hi) {
            let t = a[lo];
            a[lo] = a[hi];
            a[hi] = t;
            lo = lo + 1;
            hi = hi - 1;
        };
        return false;
    };
    let j = n - 1;
    while (a[j] <= a[i]) { j = j - 1; };
    let t = a[i];
    a[i] = a[j];
    a[j] = t;
    let lo = i + 1;
    let hi = n - 1;
    while (lo < hi) {
        let u = a[lo];
        a[lo] = a[hi];
        a[hi] = u;
        lo = lo + 1;
        hi = hi - 1;
    };
    true
};

/** Every ordering of the elements of `a`, as arrays, in the order of their
positions (`[1, 2, 3]` gives `[1,2,3] [1,3,2] [2,1,3] ...`). Equal elements are
distinct positions, so `a.length!` arrays come back. Only for small `a`. */
def permutations(a: [long]) -> [[long]] {
    let out: [[long]] = [];
    let idx: [long] = [];
    let i = 0;
    while (i < a.length) {
        idx += i;
        i = i + 1;
    };
    let more = true;
    while (more) {
        let p: [long] = [];
        foreach (k in idx) { p += a[k]; };
        out += p;
        more = next_permutation(idx);
    };
    out
};

/** Every way to choose `k` of the elements of `a`, keeping their order, as
arrays: `combinations([1, 2, 3], 2)` is `[[1, 2], [1, 3], [2, 3]]`. `[[]]` for
`k = 0`; `[]` if `k` is negative or more than `a.length`. */
def combinations(a: [long], k: long) -> [[long]] {
    let out: [[long]] = [];
    let n = a.length;
    if (k < 0 || k > n) { return out; };
    let idx: [long] = [];
    let i = 0;
    while (i < k) {
        idx += i;
        i = i + 1;
    };
    while (true) {
        let c: [long] = [];
        foreach (j in idx) { c += a[j]; };
        out += c;
        // advance the rightmost index that has room
        let p = k - 1;
        while (p >= 0 && idx[p] == n - k + p) { p = p - 1; };
        if (p < 0) { return out; };
        idx[p] = idx[p] + 1;
        let q = p + 1;
        while (q < k) {
            idx[q] = idx[q - 1] + 1;
            q = q + 1;
        };
    };
    out
};

/** The `k`th smallest element of `a` (0 is the smallest), or `none` if `k` is
out of range. Quickselect on a copy: `a` is not changed, and the expected time
is linear. */
def kth_smallest(a: [long], k: long) -> long? {
    if (k < 0 || k >= a.length) { return none; };
    let b: [long] = [];
    foreach (x in a) { b += x; };
    let lo = 0;
    let hi = b.length - 1;
    while (lo < hi) {
        // median of three pivot, so sorted input is not the worst case
        let mid = lo + (hi - lo) / 2;
        let x = b[lo];
        let y = b[mid];
        let z = b[hi];
        let pivot = if (x < y) { if (y < z) { y } else if (x < z) { z } else { x } }
                    else { if (x < z) { x } else if (y < z) { z } else { y } };
        let i = lo;
        let j = hi;
        while (i <= j) {
            while (b[i] < pivot) { i = i + 1; };
            while (b[j] > pivot) { j = j - 1; };
            if (i <= j) {
                let t = b[i];
                b[i] = b[j];
                b[j] = t;
                i = i + 1;
                j = j - 1;
            };
        };
        if (k <= j) { hi = j; } else if (k >= i) { lo = i; } else { return some(b[k]); };
    };
    some(b[k])
};

/** The length of the longest strictly increasing subsequence of `a`, in
O(n log n). */
def lis(a: [long]) -> long {
    let tails: [long] = [];
    foreach (x in a) {
        let i = lower_bound(tails, x);
        if (i == tails.length) { tails += x; } else { tails[i] = x; };
    };
    tails.length
};

/** A longest common subsequence of `a` and `b`, by bytes (the first one in the
usual traceback, preferring `a`'s earlier characters). */
def lcs(a: str, b: str) -> str {
    let n = a.length;
    let m = b.length;
    let w = m + 1;
    let t: [long] = filled((n + 1) * w, 0);
    let i = n - 1;
    while (i >= 0) {
        let j = m - 1;
        while (j >= 0) {
            if (a[i] == b[j]) {
                t[i * w + j] = t[(i + 1) * w + j + 1] + 1;
            } else {
                let down = t[(i + 1) * w + j];
                let right = t[i * w + j + 1];
                t[i * w + j] = if (down > right) { down } else { right };
            };
            j = j - 1;
        };
        i = i - 1;
    };
    let out: [byte] = [];
    let x = 0;
    let y = 0;
    while (x < n && y < m) {
        if (a[x] == b[y]) {
            out += a[x];
            x = x + 1;
            y = y + 1;
        } else if (t[(x + 1) * w + y] >= t[x * w + y + 1]) {
            x = x + 1;
        } else {
            y = y + 1;
        };
    };
    from_bytes(out)
};

/** The Levenshtein distance between `a` and `b`, by bytes: the fewest single
byte insertions, deletions and substitutions that turn one into the other. */
def edit_distance(a: str, b: str) -> long {
    let n = a.length;
    let m = b.length;
    let prev: [long] = [];
    let j = 0;
    while (j <= m) {
        prev += j;
        j = j + 1;
    };
    let i = 1;
    while (i <= n) {
        let cur: [long] = [i];
        let k = 1;
        while (k <= m) {
            let cost = if (a[i - 1] == b[k - 1]) { 0 } else { 1 };
            let best = prev[k - 1] + cost;
            if (prev[k] + 1 < best) { best = prev[k] + 1; };
            if (cur[k - 1] + 1 < best) { best = cur[k - 1] + 1; };
            cur += best;
            k = k + 1;
        };
        prev = cur;
        i = i + 1;
    };
    prev[m]
};

/** Every position where `needle` occurs in `hay` (overlapping ones included),
ascending, by Knuth-Morris-Pratt in O(n + m). An empty `needle` matches
nowhere. */
def kmp(hay: str, needle: str) -> [long] {
    let out: [long] = [];
    let m = needle.length;
    if (m == 0) { return out; };
    let fail: [long] = filled(m, 0);
    let k = 0;
    let i = 1;
    while (i < m) {
        while (k > 0 && needle[i] != needle[k]) { k = fail[k - 1]; };
        if (needle[i] == needle[k]) { k = k + 1; };
        fail[i] = k;
        i = i + 1;
    };
    k = 0;
    i = 0;
    while (i < hay.length) {
        while (k > 0 && hay[i] != needle[k]) { k = fail[k - 1]; };
        if (hay[i] == needle[k]) { k = k + 1; };
        if (k == m) {
            out += i - m + 1;
            k = fail[k - 1];
        };
        i = i + 1;
    };
    out
};

/** The Z-function of `s`: element `i` is the length of the longest common
prefix of `s` and `s[i:]` (element 0 is `s.length`). */
def z_function(s: str) -> [long] {
    let n = s.length;
    let z: [long] = filled(n, 0);
    if (n == 0) { return z; };
    z[0] = n;
    let l = 0;
    let r = 0;
    let i = 1;
    while (i < n) {
        if (i < r) {
            z[i] = if (z[i - l] < r - i) { z[i - l] } else { r - i };
        };
        while (i + z[i] < n && s[z[i]] == s[i + z[i]]) { z[i] = z[i] + 1; };
        if (i + z[i] > r) {
            l = i;
            r = i + z[i];
        };
        i = i + 1;
    };
    z
};

/** The best total value of items taken at most once each (0/1 knapsack) whose
weights fit `cap`: `weights[i]` and `values[i]` are item `i`. Weights and
`cap` are non-negative; the arrays must be the same length. */
def knapsack(weights: [long], values: [long], cap: long) -> long {
    if (cap < 0) { return 0; };
    let best: [long] = filled(cap + 1, 0);
    let i = 0;
    while (i < weights.length) {
        let w = weights[i];
        let v = values[i];
        let c = cap;
        while (c >= w) {
            if (best[c - w] + v > best[c]) { best[c] = best[c - w] + v; };
            c = c - 1;
        };
        i = i + 1;
    };
    best[cap]
};

// ── a heap ──────────────────────────────────────────────────────────────

/** A binary min-heap of `(key, val)` pairs, smallest key first: the priority
queue under Dijkstra's algorithm. `keys` and `vals` are parallel arrays kept in
heap order; make one with `heap_new` and use only the `heap_` functions on it.
Pairs with equal keys come out in no particular order. */
type Heap = { keys: [long], vals: [long] };

/** A pair a heap returns: the smallest key and the value stored with it. */
type Entry = { key: long, val: long };

/** An empty heap. */
def heap_new() -> Heap {
    let h: Heap = { keys: [], vals: [] };
    h
};

/** How many pairs the heap holds. */
def heap_len(h: Heap) -> long { h.keys.length };

def heap_swap(h: Heap, i: long, j: long) -> long {
    let k = h.keys[i];
    h.keys[i] = h.keys[j];
    h.keys[j] = k;
    let v = h.vals[i];
    h.vals[i] = h.vals[j];
    h.vals[j] = v;
    0
};

/** Adds the pair `(key, val)`. O(log n). */
def heap_push(h: Heap, key: long, val: long) -> void {
    h.keys += key;
    h.vals += val;
    let i = h.keys.length - 1;
    while (i > 0) {
        let p = (i - 1) / 2;
        if (h.keys[p] <= h.keys[i]) { break; };
        heap_swap(h, p, i);
        i = p;
    };
};

/** The pair with the smallest key, left in the heap; `none` if it is empty. */
def heap_peek(h: Heap) -> Entry? {
    if (h.keys.length == 0) { return none; };
    some({ key: h.keys[0], val: h.vals[0] })
};

/** Removes and returns the pair with the smallest key; `none` if the heap is
empty. O(log n). */
def heap_pop(h: Heap) -> Entry? {
    let n = h.keys.length;
    if (n == 0) { return none; };
    let top = { key: h.keys[0], val: h.vals[0] };
    heap_swap(h, 0, n - 1);
    h.keys.pop();
    h.vals.pop();
    n = n - 1;
    let i = 0;
    while (true) {
        let l = 2 * i + 1;
        let r = l + 1;
        let m = i;
        if (l < n && h.keys[l] < h.keys[m]) { m = l; };
        if (r < n && h.keys[r] < h.keys[m]) { m = r; };
        if (m == i) { break; };
        heap_swap(h, i, m);
        i = m;
    };
    some(top)
};

// ── disjoint sets ───────────────────────────────────────────────────────

/** Disjoint sets over `0 .. n - 1` (union-find), with path halving and union
by size, so both operations are effectively constant time. Make one with
`dsu_new`; every element starts alone. */
type DSU = { parent: [long], size: [long], sets: long };

/** `n` singleton sets. */
def dsu_new(n: long) -> DSU {
    let d: DSU = { parent: [], size: [], sets: n };
    let i = 0;
    while (i < n) {
        d.parent += i;
        d.size += 1;
        i = i + 1;
    };
    d
};

/** The representative of the set holding `x`: two elements are in one set
exactly when their representatives are equal. */
def dsu_find(d: DSU, x: long) -> long {
    let v = x;
    while (d.parent[v] != v) {
        d.parent[v] = d.parent[d.parent[v]];
        v = d.parent[v];
    };
    v
};

/** Merges the sets of `a` and `b`; true if they were different, false if they
were already one. */
def dsu_union(d: DSU, a: long, b: long) -> bool {
    let x = dsu_find(d, a);
    let y = dsu_find(d, b);
    if (x == y) { return false; };
    if (d.size[x] < d.size[y]) {
        let t = x;
        x = y;
        y = t;
    };
    d.parent[y] = x;
    d.size[x] = d.size[x] + d.size[y];
    d.sets = d.sets - 1;
    true
};

/** Whether `a` and `b` are in the same set. */
def dsu_same(d: DSU, a: long, b: long) -> bool { dsu_find(d, a) == dsu_find(d, b) };

/** How many elements are in the set holding `x`. */
def dsu_size(d: DSU, x: long) -> long { d.size[dsu_find(d, x)] };

/** How many separate sets there are. */
def dsu_sets(d: DSU) -> long { d.sets };

// ── graphs ──────────────────────────────────────────────────────────────
//
// A graph of `n` nodes numbered `0 .. n - 1` is its adjacency lists: `adj[u]`
// holds the nodes `u` has an edge to, in the order the algorithms walk them.
// Weighted graphs carry a parallel `w` with `w[u][i]` the weight of the edge
// to `adj[u][i]`. An undirected edge is listed in both directions.

/** The fewest edges from `s` to every node (breadth-first search); -1 for
a node `s` cannot reach. */
def bfs(adj: [[long]], s: long) -> [long] {
    let dist: [long] = filled(adj.length, -1);
    if (s < 0 || s >= adj.length) { return dist; };
    let queue: [long] = [s];
    dist[s] = 0;
    let head = 0;
    while (head < queue.length) {
        let u = queue[head];
        head = head + 1;
        foreach (v in adj[u]) {
            if (dist[v] < 0) {
                dist[v] = dist[u] + 1;
                queue += v;
            };
        };
    };
    dist
};

/** The nodes reachable from `s`, in depth-first preorder: each node's
neighbours are tried in adjacency order, and a node is listed when first
reached. */
def dfs(adj: [[long]], s: long) -> [long] {
    let order: [long] = [];
    if (s < 0 || s >= adj.length) { return order; };
    let seen: [byte] = zero_bytes(adj.length);
    let stack: [long] = [s];
    while (stack.length > 0) {
        let u = stack.pop();
        if (seen[u] == 0) {
            seen[u] = 1;
            order += u;
            // pushed last-first, so the first neighbour is the next one popped
            let i = adj[u].length - 1;
            while (i >= 0) {
                if (seen[adj[u][i]] == 0) { stack += adj[u][i]; };
                i = i - 1;
            };
        };
    };
    order
};

/** The nodes of a directed graph in an order where every edge goes from an
earlier node to a later one (Kahn's algorithm: the nodes with nothing pointing
at them first, lowest number first among those, then as they free up); `none`
if the graph has a cycle. */
def toposort(adj: [[long]]) -> [long]? {
    let n = adj.length;
    let indeg: [long] = filled(n, 0);
    foreach (edges in adj) {
        foreach (v in edges) { indeg[v] = indeg[v] + 1; };
    };
    let order: [long] = [];
    let u = 0;
    while (u < n) {
        if (indeg[u] == 0) { order += u; };
        u = u + 1;
    };
    let head = 0;
    while (head < order.length) {
        let x = order[head];
        head = head + 1;
        foreach (v in adj[x]) {
            indeg[v] = indeg[v] - 1;
            if (indeg[v] == 0) { order += v; };
        };
    };
    if (order.length == n) { some(order) } else { none }
};

// Dijkstra over the heap: the distances, and the node each one was reached from
def dijkstra_run(adj: [[long]], w: [[long]], s: long, parent: [long]) -> [long] {
    let dist: [long] = filled(adj.length, -1);
    if (s < 0 || s >= adj.length) { return dist; };
    let h = heap_new();
    dist[s] = 0;
    heap_push(h, 0, s);
    while (heap_len(h) > 0) {
        let top = heap_pop(h)!;
        let u = top.val;
        // a stale entry: a shorter way to u was found after this one was pushed
        if (top.key == dist[u]) {
            let i = 0;
            while (i < adj[u].length) {
                let v = adj[u][i];
                let nd = top.key + w[u][i];
                if (dist[v] < 0 || nd < dist[v]) {
                    dist[v] = nd;
                    parent[v] = u;
                    heap_push(h, nd, v);
                };
                i = i + 1;
            };
        };
    };
    dist
};

/** The least total weight from `s` to every node (Dijkstra's algorithm); -1
for a node `s` cannot reach. Weights must be non-negative. */
def dijkstra(adj: [[long]], w: [[long]], s: long) -> [long] {
    let parent: [long] = filled(adj.length, -1);
    dijkstra_run(adj, w, s, parent)
};

/** The nodes on a lightest path from `s` to `t`, both included; `[]` if there
is none. Weights must be non-negative. */
def shortest_path(adj: [[long]], w: [[long]], s: long, t: long) -> [long] {
    let path: [long] = [];
    let parent: [long] = filled(adj.length, -1);
    let dist = dijkstra_run(adj, w, s, parent);
    if (t < 0 || t >= adj.length || dist[t] < 0) { return path; };
    let v = t;
    while (v != s) {
        path += v;
        v = parent[v];
    };
    path += s;
    let i = 0;
    let j = path.length - 1;
    while (i < j) {
        let x = path[i];
        path[i] = path[j];
        path[j] = x;
        i = i + 1;
        j = j - 1;
    };
    path
};

/** A label for every node such that two nodes share one exactly when they are
joined by edges (read as undirected); labels are `0, 1, 2 ...` in the order of
each component's lowest-numbered node. */
def components(adj: [[long]]) -> [long] {
    let n = adj.length;
    let d = dsu_new(n);
    let u = 0;
    while (u < n) {
        foreach (v in adj[u]) { dsu_union(d, u, v); };
        u = u + 1;
    };
    let label: [long] = filled(n, -1);
    let next = 0;
    u = 0;
    while (u < n) {
        let r = dsu_find(d, u);
        if (label[r] < 0) {
            label[r] = next;
            next = next + 1;
        };
        label[u] = label[r];
        u = u + 1;
    };
    label
};

// `idx` (indices into `edges`) ordered by edge weight, stable: a bottom-up
// merge sort, kept here rather than borrowed from `sort` because a unit that
// hands a closure to another unit's function does not link in a std pack.
def sort_by_weight(idx: [long], edges: [[long]]) -> [long] {
    let n = idx.length;
    let src: [long] = [];
    foreach (k in idx) { src += k; };
    let width = 1;
    while (width < n) {
        let dst: [long] = [];
        let lo = 0;
        while (lo < n) {
            let mid = if (lo + width < n) { lo + width } else { n };
            let hi = if (lo + 2 * width < n) { lo + 2 * width } else { n };
            let i = lo;
            let j = mid;
            while (i < mid || j < hi) {
                if (j >= hi || (i < mid && edges[src[j]][2] >= edges[src[i]][2])) {
                    dst += src[i];
                    i = i + 1;
                } else {
                    dst += src[j];
                    j = j + 1;
                };
            };
            lo = hi;
        };
        src = dst;
        width = width * 2;
    };
    src
};

/** A minimum spanning forest by Kruskal's algorithm: of the `edges` (each
`[u, v, weight]`, undirected) over nodes `0 .. n - 1`, the ones chosen, in the
order they were taken (lightest first, input order among equals). */
def kruskal(n: long, edges: [[long]]) -> [[long]] {
    let idx: [long] = [];
    let i = 0;
    while (i < edges.length) {
        idx += i;
        i = i + 1;
    };
    let order = sort_by_weight(idx, edges);
    let d = dsu_new(n);
    let out: [[long]] = [];
    foreach (k in order) {
        if (dsu_union(d, edges[k][0], edges[k][1])) { out += edges[k]; };
    };
    out
};
