#!/usr/bin/env python3
# The reference for t411_algo.y: the same generator, the same sections, and
# every answer from a different implementation (math, bisect, itertools,
# heapq, plain dynamic programming). `python3 t411_algo.ref.py > t411_algo.expected`
# rebuilds the expected output; the Y test must reproduce it byte for byte.
import bisect
import heapq
import itertools
import math

M63 = (1 << 63) - 1
seed = 12345
out = []


def say(*a):
    out.append("".join(fmt(x) for x in a))


def fmt(v):
    if v is None:
        return "none"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, list):
        return "[" + ", ".join(fmt(x) for x in v) + "]"
    return str(v)


def rnd(m):
    global seed
    seed = (seed * 1103515245 + 12345) & 2147483647
    return (seed >> 8) % m


def rnd63():
    return ((rnd(2147483648) << 31) | rnd(2147483648)) & M63


def rnd_arr(n, m):
    return [rnd(m) for _ in range(n)]


def rnd_str(n, alphabet):
    return "".join(chr(97 + rnd(alphabet)) for _ in range(n))


def trunc_div(a, b):
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


# ── numbers ──
say("gcd/lcm")
for _ in range(12):
    a = rnd(2001) - 1000
    b = rnd(2001) - 1000
    g = math.gcd(a, b)
    say(g, " ", 0 if a == 0 or b == 0 else abs(a * b) // g)
say(math.gcd(0, 0), " ", math.gcd(0, 7), " ", 0, " ", math.gcd(1 << 62, 1 << 40))

say("mulmod/powmod")
for _ in range(8):
    m = rnd63() | 1
    a = rnd63() % m
    b = rnd63() % m
    say(m, " ", (a * b) % m, " ", pow(a, b % 1000, m), " ", pow(a, 0, m))
say(pow(5, 3, 1), " ", pow(-2, 3, 7), " ", (9223372036854775806 * 9223372036854775806) % 9223372036854775807)

say("isqrt")
for n in [0, 1, 2, 3, 4, 8, 9, 15, 16, 99, 100, 1000000, 999999999999, 4611686014132420609, 9223372036854775807, -5]:
    say(n, " ", math.isqrt(n) if n >= 0 else -1)
for _ in range(6):
    n = rnd63()
    say(n, " ", math.isqrt(n))


def is_prime(n):
    if n < 2:
        return False
    if n < 10**7:
        if n % 2 == 0:
            return n == 2
        f = 3
        while f * f <= n:
            if n % f == 0:
                return False
            f += 2
        return True
    # Miller-Rabin with sixteen bases: a proof below 3.3e24 with the first twelve
    d, s = n - 1, 0
    while d % 2 == 0:
        d //= 2
        s += 1
    for a in [2, 3, 5, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53]:
        if a % n == 0:
            continue
        x = pow(a, d, n)
        if x in (1, n - 1):
            continue
        for _ in range(s - 1):
            x = x * x % n
            if x == n - 1:
                break
        else:
            return False
    return True


say("is_prime")
say("".join("1" if is_prime(i) else "0" for i in range(200)))
for n in [561, 1105, 1729, 1000000007, 998244353, 2305843009213693951, 3215031751, 3825123056546413051,
          9223372036854775783, 9223372036854775807, 4611686018427387847, 4611686018427387903, 1000000016000000063]:
    say(n, " ", is_prime(n))

say("primes")


def sieve(n):
    if n < 2:
        return []
    s = bytearray([1]) * (n + 1)
    s[0] = s[1] = 0
    for i in range(2, int(n ** 0.5) + 1):
        if s[i]:
            s[i * i::i] = bytearray(len(s[i * i::i]))
    return [i for i in range(n + 1) if s[i]]


say(sieve(100))
big = sieve(100000)
say(len(big), " ", sum(big), " ", big[-1])
say(sieve(1), sieve(2), sieve(-3))

say("factorize")
KNOWN = {
    # too large for trial division in Python: the factors are known, and are checked prime below
    1000000007 * 998244353: [998244353, 1000000007],
    4611686014132420609: [2147483647, 2147483647],
    3825123056546413051: [149491, 747451, 34233211],
}


def factorize(n):
    if n < 2:
        return []
    if n in KNOWN:
        f = KNOWN[n]
        assert math.prod(f) == n and all(is_prime(p) for p in f)
        return f
    f = []
    p = 2
    while p * p <= n:
        while n % p == 0:
            f.append(p)
            n //= p
        p += 1 if p == 2 else 2
    if n > 1:
        f.append(n)
    return f


for n in [0, 1, 2, 12, 97, 360, 1024, 600851475143, 9223372036854775807, 6561000000, 1000000007 * 998244353,
          4611686014132420609, 3825123056546413051]:
    say(n, " ", factorize(n))
for _ in range(6):
    n = rnd(1000000000000) + 2
    f = factorize(n)
    say(n, " ", len(f), " ", math.prod(f) == n, " ", all(is_prime(p) for p in f))

say("choose")
for n, k in [[5, 2], [10, 0], [10, 10], [10, 11], [10, -1], [0, 0], [52, 5], [62, 31], [66, 33], [67, 33], [100, 3],
             [100, 50], [1000, 2], [3037000500, 2]]:
    if k < 0 or k > n:
        r = None
    else:
        r = math.comb(n, k)
        if r > M63:
            r = None
    say(n, " ", k, " ", r)

# ── searching ──
say("binary search")
sa = sorted(rnd_arr(60, 40))
say(sa)
for q in range(45):
    x = q - 2
    lo = bisect.bisect_left(sa, x)
    hi = bisect.bisect_right(sa, x)
    say(x, " ", lo, " ", hi, " ", lo if lo < len(sa) and sa[lo] == x else -1)
say(next(k for k in range(0, 101) if k * k >= 2000))
say(0, " ", 5)
say(0, " ", -1)
words = ["apple", "banana", "banana", "cherry", "fig", "grape"]
for w in ["", "apple", "b", "banana", "c", "fig", "zzz"]:
    say(w, " ", bisect.bisect_left(words, w))

# ── sequences ──
say("sequences")
say([k for k, _ in itertools.groupby([1, 1, 2, 2, 2, 3, 1, 1])], [], [5])


def rot(a, k):
    if not a:
        return []
    k %= len(a)
    return a[k:] + a[:k]


say(rot([1, 2, 3, 4, 5], 2), rot([1, 2, 3, 4, 5], -1), rot([1, 2, 3], 7), rot([], 3))
say(list(itertools.accumulate([3, -1, 4, 1, -5, 9], initial=0)), [0])
np_ = [1, 1, 2, 3]
say(np_)
perms = sorted(set(itertools.permutations(np_)))
say(len(perms), " ", np_)
say("".join(str(list(p)) + ";" for p in itertools.permutations([1, 2, 3])))
say([[[3, 1, 2][i] for i in p] for p in itertools.permutations(range(3))])
say(1, " ", [[7]])
say([list(c) for c in itertools.combinations([1, 2, 3, 4], 2)])
say([[]], [list(c) for c in itertools.combinations([1, 2, 3], 3)], [], [])
kt = rnd_arr(50, 100)
say(0, " ", None, " ", None, " ", None, " ", len(kt))
say(5, " ", 1, " ", 9)

say("lis/lcs/edit/kmp/z/knapsack")
for _ in range(8):
    a = rnd_arr(30, 50)
    best = [1] * len(a)
    for i in range(len(a)):
        for j in range(i):
            if a[j] < a[i]:
                best[i] = max(best[i], best[j] + 1)
    say(max(best))
say(0, " ", 1, " ", 1, " ", 4, " ", 1)


def lcs_len(a, b):
    t = [[0] * (len(b) + 1) for _ in range(len(a) + 1)]
    for i in range(len(a)):
        for j in range(len(b)):
            t[i + 1][j + 1] = t[i][j] + 1 if a[i] == b[j] else max(t[i][j + 1], t[i + 1][j])
    return t[len(a)][len(b)]


def edit(a, b):
    d = list(range(len(b) + 1))
    for i in range(1, len(a) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(b) + 1):
            cur = d[j]
            d[j] = min(d[j] + 1, d[j - 1] + 1, prev + (a[i - 1] != b[j - 1]))
            prev = cur
    return d[len(b)]


for _ in range(8):
    a = rnd_str(14, 3)
    b = rnd_str(12, 3)
    say(a, " ", b, " ", lcs_len(a, b), " ", True, " ", edit(a, b))
say(True, " ", "abc", " ", True, " ", edit("kitten", "sitting"), " ", 3, " ", edit("flaw", "lawn"))


def find_all(h, n):
    return [i for i in range(len(h) - len(n) + 1) if h[i:i + len(n)] == n] if n else []


def zf(s):
    z = []
    for i in range(len(s)):
        k = 0
        while i + k < len(s) and s[k] == s[i + k]:
            k += 1
        z.append(k)
    return z


for _ in range(6):
    h = rnd_str(40, 2)
    nd = rnd_str(3, 2)
    say(h, " ", nd, " ", find_all(h, nd), " ", zf(nd))
say(find_all("aaaa", "aa"), find_all("abc", ""), find_all("", "a"), zf("aabxaab"), zf(""))


def knap(w, v, cap):
    if cap < 0:
        return 0
    best = [0] * (cap + 1)
    for wi, vi in zip(w, v):
        for c in range(cap, wi - 1, -1):
            best[c] = max(best[c], best[c - wi] + vi)
    return best[cap]


for _ in range(6):
    w = rnd_arr(8, 20)
    v = rnd_arr(8, 50)
    say(knap(w, v, 30), " ", knap(w, v, 0), " ", knap(w, v, 100))
say(knap([], [], 10), " ", knap([5], [9], 4), " ", knap([5], [9], 5), " ", knap([1], [1], -1))

# ── a heap ──
say("heap")
say(0, " ", None, " ", None)
keys = rnd_arr(40, 30)
say(len(keys), " ", min(keys))
say(sorted(keys), " ", True)
say(2, 2, 5, 90, " ", 0)

# ── disjoint sets ──
say("dsu")
parent = list(range(20))


def find(x):
    while parent[x] != x:
        x = parent[x]
    return x


def size_of(x):
    r = find(x)
    return sum(1 for i in range(20) if find(i) == r)


say(20, " ", 1, " ", False)
sets = 20
for _ in range(14):
    a = rnd(20)
    b = rnd(20)
    ra, rb = find(a), find(b)
    if ra != rb:
        parent[rb] = ra
        sets -= 1
        ch = True
    else:
        ch = False
    say(a, " ", b, " ", ch, " ", sets, " ", find(a) == find(b), " ", size_of(a))
say("".join(str(size_of(i)) + "," for i in range(20)))
say(len({find(i) for i in range(20)}), " ", sets, " ", True)

# ── graphs ──
say("graphs")


def make_graph(n, m, directed):
    adj = [[] for _ in range(n)]
    for _ in range(m):
        a = rnd(n)
        b = rnd(n)
        if a != b and b not in adj[a]:
            adj[a].append(b)
            if not directed:
                adj[b].append(a)
    return adj


def bfs(adj, s):
    dist = [-1] * len(adj)
    if s < 0 or s >= len(adj):
        return dist
    dist[s] = 0
    q = [s]
    for u in q:
        for v in adj[u]:
            if dist[v] < 0:
                dist[v] = dist[u] + 1
                q.append(v)
    return dist


def dfs(adj, s):
    order = []
    if s < 0 or s >= len(adj):
        return order
    seen = set()

    def go(u):
        seen.add(u)
        order.append(u)
        for v in adj[u]:
            if v not in seen:
                go(v)

    go(s)
    return order


def components(adj):
    n = len(adj)
    comp = [-1] * n
    nxt = 0
    for s in range(n):
        if comp[s] < 0:
            comp[s] = nxt
            stack = [s]
            while stack:
                u = stack.pop()
                for v in adj[u]:
                    if comp[v] < 0:
                        comp[v] = nxt
                        stack.append(v)
            nxt += 1
    return comp


def dijkstra(adj, w, s):
    dist = [-1] * len(adj)
    best = {s: 0}
    pq = [(0, s)]
    while pq:
        d, u = heapq.heappop(pq)
        if d > best[u]:
            continue
        dist[u] = d
        for v, wt in zip(adj[u], w[u]):
            if v not in best or d + wt < best[v]:
                best[v] = d + wt
                heapq.heappush(pq, (d + wt, v))
    return dist


g = make_graph(14, 16, False)
say(g)
say(bfs(g, 0))
say(bfs(g, 5), bfs(g, -1), bfs(g, 14))
say(dfs(g, 0))
say(dfs(g, 9), dfs(g, 14))
say(components(g))
wts = [[1 + rnd(9) for _ in row] for row in g]
say(wts)
say(dijkstra(g, wts, 0))
say(dijkstra(g, wts, 7))
say(0, " ", 11)
say(True, " ", [3], " ", [])
dag = make_graph(10, 14, True)
say(dag)


def toposort(adj):
    n = len(adj)
    indeg = [0] * n
    for row in adj:
        for v in row:
            indeg[v] += 1
    order = [u for u in range(n) if indeg[u] == 0]
    for x in order:
        for v in adj[x]:
            indeg[v] -= 1
            if indeg[v] == 0:
                order.append(v)
    return order if len(order) == n else None


ts = toposort(dag)
say(ts)
if ts is not None:
    pos = {x: i for i, x in enumerate(ts)}
    say(all(pos[v] > pos[u] for u in range(len(dag)) for v in dag[u]))
say(toposort([[1], [2], [0]]), toposort([[1], [2], []]), toposort([]))
edges = [[0, 1, 4], [0, 2, 3], [1, 2, 1], [1, 3, 2], [2, 3, 4], [3, 4, 2], [4, 5, 6], [5, 3, 3], [6, 7, 1]]
parent = list(range(8))
mst = []
for e in sorted(edges, key=lambda e: e[2]):
    ra, rb = find(e[0]), find(e[1])
    if ra != rb:
        parent[rb] = ra
        mst.append(e)
say(mst)
say(sum(e[2] for e in mst), " ", len(mst), " ", [])

print("\n".join(out))
