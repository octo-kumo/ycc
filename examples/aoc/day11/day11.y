// day11.y -- Advent of Code 2025, day 11 ("Reactor"), in Y.
//
// Below the floor of the factory there is a big toroidal reactor and a new
// server rack, and a tangle of cables between them.  The input lists devices
// and, for each, the devices its outputs are attached to; data flows along
// those outputs and never backwards.  Four devices matter by name: `you`,
// next to you, and `out`, the reactor's main output; and for part 2 `svr`,
// the server rack, plus `fft` and `dac`.
//
//   part 1  how many distinct directed paths lead from `you` to `out`
//   part 2  how many distinct directed paths lead from `svr` to `out`
//           through BOTH `fft` and `dac`
//
// Device names are opaque identifiers, so nothing here may depend on where a
// name sits in the file, on how long it is, or on what letters it uses: the
// whole solver sees names exactly once, when a name is interned into an
// integer id by an open-addressed table, and every later step works on
// integers.  `--check` proves that by re-running the same entry point on
// three permutations of the input -- lines reversed, each output list
// reversed, and every device renamed to an opaque `q<id>z` -- and demanding
// the same answers.
//
// Nothing here needs an ordered traversal, so there is none: the counts are
// sums over a device's outputs, and integer addition does not care in which
// order the outputs are visited.  The one place an order IS visible is the
// "top devices" table, and that order is produced by a merge sort written
// here (Y has no `sort`) over two parallel arrays, ordered by count
// descending and then by name ascending.
//
// Part 1 is counted three ways -- a memoised pull DP, a push DP over a
// topological order, and an exhaustive enumeration that materialises every
// path -- and part 2 two ways -- the three-segment product and a single walk
// carrying two "have I been here" flags.  `--check` runs all five plus the
// anchors, the micro-cases and the permutation oracle; see README.md.
//
// build: ../../../refs/ycc.ref day11.y -o day11
// run:   ./day11            (input.txt -> both answers)
//        ./day11 --check    (property battery, no reference file)
//        ./day11 --help
import fs;

// ── constants ────────────────────────────────────────────────────────────────

const HASH_CAP = 16384;          // interner slots; a power of two
const HASH_MASK = 16383;
const NODE_LIMIT = 4000;         // 4x headroom; past this the parser refuses
const SPACE = 32;                // every byte <= this separates device names
const FNV_OFFSET = 2166136261;   // FNV-1a, 32-bit
const FNV_PRIME = 16777619;
const MOD32 = 4294967291;        // largest 32-bit prime, keeps the hash small
const NO_NODE = -1;              // a device that is not in the input
const NO_PATH = -1;              // count_paths: the input is not a DAG
const FL_FFT = 1;                // the "already visited fft" flag
const FL_DAC = 2;                // the "already visited dac" flag

// ── types ────────────────────────────────────────────────────────────────────

// The name -> id table.  A record, so it is a reference: `interner_add` fills
// it in and the caller sees the result without returning anything.
type Interner = {
    slot: [long],                // hash slot -> id + 1 (0 means empty)
    names: [str],                // id -> the name it was interned under
    n: long
};

// The parsed device graph, in CSR form.  `out` is a device that is a target
// with no line of its own, so it gets an id like any other and an empty
// output list; that is what the statement's data looks like.
type Graph = {
    n: long,
    names: [str],
    start: [long],               // outputs of v are adj[start[v] .. start[v + 1])
    adj: [long],
    edges: long,
    lines: long,
    you: long, svr: long, fft: long, dac: long, out: long,
    tok_mismatch: long,          // lines where tokenize() and split() disagree
    err: str
};

// What the exhaustive enumeration of every path found.
type Walk = { count: long, maxlen: long, dup: long, rev: long };

// ── the check harness's tallies (globals, so every assert_* can add to them)
let checks_run = 0;
let checks_failed = 0;
let first_failure = "";

// ── small string helpers ─────────────────────────────────────────────────────

// The device names on the right of a line, in order.  Byte level, so a line
// that ends in a space, or has two spaces in a row, reads the same: every
// byte <= 32 is a separator and a run of separators collapses.
//
// The obvious `rest.split(" ")` gets both of those wrong -- it drops exactly
// one trailing empty field and keeps the empties in the middle -- which is
// why the parser counts the two against each other per line instead of
// trusting either one.
def tokenize(rest: str) -> [str] {
    let out: [str] = [];
    let n = len(rest);
    let lo = 0;
    let i = 0;
    while (i < n) {
        if ((rest[i] & 255) <= SPACE) {
            if (i > lo) { out += rest[lo:i] };
            lo = i + 1;
        };
        i = i + 1;
    };
    if (n > lo) { out += rest[lo:n] };
    out
}

// "a b c" for ["a","b","c"].  `sep.join(xs)` puts the separator FIRST, which
// is not what a graph line wants, so this walks the array instead.
def space_join(xs: [str]) -> str {
    let s = "";
    for i in 0..len(xs) { s += " " + xs[i] };
    s
}

// str `<`, by hand: fewer paths first is decided by the caller, this is only
// the tie-break, and comparing bytes needs no library.
def str_lt(a: str, b: str) -> bool {
    let n = len(a);
    if (len(b) < n) { n = len(b) };
    let i = 0;
    let less = false;
    let undecided = true;
    while (i < n && undecided) {
        if (a[i] != b[i]) {
            less = a[i] < b[i];
            undecided = false;
        } else {
            i = i + 1;
        };
    };
    if (undecided) { len(a) < len(b) } else { less }
}

// ── interning names into integer ids ─────────────────────────────────────────

def new_interner() -> Interner {
    let slot: [long] = [];
    let i = 0;
    while (i < HASH_CAP) { slot += 0; i = i + 1 };
    { slot: slot, names: [], n: 0 }
}

def hash_name(s: str) -> long {
    let h = FNV_OFFSET;
    for i in 0..len(s) {
        h = (h ^ (s[i] & 255)) * FNV_PRIME % MOD32;
    };
    h
}

// The id of `name`, or NO_NODE if it was never interned.  Open addressing,
// linear probing: the name itself is the stored key, so a lookup is exact
// whatever the hash does.
def interner_lookup(t: Interner, name: str) -> long {
    let h = hash_name(name) & HASH_MASK;
    let probes = 0;
    let found = NO_NODE;
    while (probes < HASH_CAP && found == NO_NODE) {
        let at = t.slot[h];
        if (at == 0) {
            probes = HASH_CAP;                // empty slot: it is not here
        } else {
            if (t.names[at - 1] == name) { found = at - 1 };
            h = (h + 1) & HASH_MASK;
            probes = probes + 1;
        };
    };
    found
}

// The id of `name`, interning it if it is new.  NO_NODE only when the input
// holds more than NODE_LIMIT devices -- a refusal, never a truncation.
def interner_add(t: Interner, name: str) -> long {
    let h = hash_name(name) & HASH_MASK;
    let probes = 0;
    let id = NO_NODE;
    while (probes < HASH_CAP && id == NO_NODE) {
        let at = t.slot[h];
        if (at == 0) {
            if (t.n >= NODE_LIMIT) {
                probes = HASH_CAP;
            } else {
                t.names += name;
                t.n = t.n + 1;
                t.slot[h] = t.n;               // id + 1, so 0 can mean empty
                id = t.n - 1;
            };
        } else {
            if (t.names[at - 1] == name) { id = at - 1 };
            h = (h + 1) & HASH_MASK;
            probes = probes + 1;
        };
    };
    id
}

// ── parsing ──────────────────────────────────────────────────────────────────

// Read the device graph.  One pass interns every name and records, per line,
// its source and its outputs; then a prefix sum turns that into CSR.
//
// Every line is tokenized twice, once by tokenize() and once by the builtin
// split(), and the counts must agree -- `tok_mismatch` is the number of lines
// where they do not.  Nothing downstream looks at it: it is the parser
// auditing itself, so a change in how either reader treats whitespace shows
// up as a disagreement rather than as a quietly different graph.
def parse_graph(lines: [str]) -> Graph {
    let t = new_interner();
    let srcs: [long] = [];                     // source id, per line
    let off: [long] = [];                      // offset into dsts, per line
    let dsts: [long] = [];                     // output ids, lines concatenated
    let err = "";
    let mismatch = 0;
    let nlines = 0;
    let i = 0;
    while (i < len(lines) && err == "") {
        let line = lines[i].trim_end();
        if (line != "") {
            let ci = line.index_of(":");
            let src = "";
            let rest = "";
            if (ci < 0) {
                err = "line " + tostring(i + 1) + ": no ':' separator";
            } else {
                src = line[0:ci].trim();
                rest = line[ci + 1:];
                if (src == "") {
                    err = "line " + tostring(i + 1) + ": no device name before ':'";
                };
            };
            if (err == "") {
                let sid = interner_add(t, src);
                if (sid == NO_NODE) {
                    err = "line " + tostring(i + 1) + ": more than "
                          + tostring(NODE_LIMIT) + " devices";
                } else {
                    let toks = tokenize(rest);
                    let sp = rest.split(" ");
                    let spn = 0;
                    for k in 0..len(sp) { if (sp[k] != "") { spn = spn + 1 } };
                    if (spn != len(toks)) { mismatch = mismatch + 1 };
                    srcs += sid;
                    off += len(dsts);
                    for k in 0..len(toks) {
                        let did = interner_add(t, toks[k]);
                        if (did == NO_NODE) {
                            err = "line " + tostring(i + 1) + ": more than "
                                  + tostring(NODE_LIMIT) + " devices";
                        } else {
                            dsts += did;
                        };
                    };
                    if (err == "") { nlines = nlines + 1 };
                };
            };
        };
        i = i + 1;
    };
    off += len(dsts);

    if (err == "" && nlines == 0) { err = "no device lines" };
    if (err != "") {
        return { n: 0, names: [], start: [], adj: [], edges: 0, lines: 0,
                 you: NO_NODE, svr: NO_NODE, fft: NO_NODE, dac: NO_NODE,
                 out: NO_NODE, tok_mismatch: mismatch, err: err };
    };

    let nn = t.n;
    let start: [long] = [];
    let i2 = 0;
    while (i2 <= nn) { start += 0; i2 = i2 + 1 };
    for k in 0..len(srcs) {
        // A device's degree is how many OUTPUTS its line names, which is how
        // many entries this line added to dsts -- not one per line.  Getting
        // that wrong gives a CSR whose last offset is the line count, and a
        // graph that is quietly not the file's; check_csr() exists to catch
        // exactly that.
        start[srcs[k] + 1] = start[srcs[k] + 1] + (off[k + 1] - off[k]);
    };
    for k in 1..(nn + 1) { start[k] = start[k] + start[k - 1] };

    let cur: [long] = [];
    for k in 0..(nn + 1) { cur += start[k] };
    let adj: [long] = [];
    for k in 0..len(dsts) { adj += 0 };
    for k in 0..len(srcs) {
        let s = srcs[k];
        let p = off[k];
        while (p < off[k + 1]) {
            adj[cur[s]] = dsts[p];
            cur[s] = cur[s] + 1;
            p = p + 1;
        };
    };

    { n: nn, names: t.names, start: start, adj: adj, edges: len(dsts),
      lines: nlines,
      you: interner_lookup(t, "you"), svr: interner_lookup(t, "svr"),
      fft: interner_lookup(t, "fft"), dac: interner_lookup(t, "dac"),
      out: interner_lookup(t, "out"),
      tok_mismatch: mismatch, err: "" }
}

// ── the counting ─────────────────────────────────────────────────────────────

// How many distinct directed paths lead from `from` to `to`?  A device's
// value is the sum of its outputs' values, `to` itself is worth 1 (the path
// that has arrived), and a device with no outputs is worth 0.  Memoised, so
// each device is resolved once instead of once per path -- without it the
// walk is exponential, which is what makes part 2's answer take a while.
//
// An explicit stack, not recursion, and `on[]` marks what is on it: a step
// onto a device already on the stack is a cycle, and the walk answers
// NO_PATH rather than counting paths it could never finish.
def count_paths(g: Graph, from: long, to: long) -> long {
    if (g.n == 0 || from == NO_NODE || to == NO_NODE) { return 0 };
    if (from == to) { return 1 };
    let n = g.n;
    let memo: [long] = [];
    let on: [long] = [];
    let st: [long] = [];
    let pos: [long] = [];
    let i = 0;
    // st[]/pos[] are FIXED size and written at the current depth: a path in a
    // DAG visits each device at most once, so n frames is always enough, and a
    // frame that lives at its own depth is what makes "the frame below me"
    // mean the device that stepped into this one.
    while (i < n) { memo += -1; on += 0; st += 0; pos += 0; i = i + 1 };
    memo[to] = 1;
    memo[from] = 0;
    on[from] = 1;
    st[0] = from;
    pos[0] = g.start[from];
    let d = 1;
    let cyc = false;
    while (d > 0 && !cyc) {
        let top = d - 1;
        let u = st[top];
        let p = pos[top];
        if (p >= g.start[u + 1]) {
            on[u] = 2;                          // every output is resolved
            d = d - 1;
            // u's value is now final, so hand it up to the frame that stepped
            // into u.  `to` is never pushed -- it is worth 1 on sight -- so
            // every other output arrives through here, exactly once.
            if (d > 0) { memo[st[d - 1]] = memo[st[d - 1]] + memo[u] };
        } else {
            pos[top] = p + 1;
            let v = g.adj[p];
            if (v == to) {
                memo[u] = memo[u] + 1;
            } else if (on[v] == 1) {
                cyc = true;
            } else if (on[v] == 0) {
                memo[v] = 0;
                on[v] = 1;
                st[d] = v;
                pos[d] = g.start[v];
                d = d + 1;
            } else {
                memo[u] = memo[u] + memo[v];   // already resolved: reuse it
            };
        };
    };
    if (cyc) { NO_PATH } else { memo[from] }
}

// Kahn's algorithm, FIFO queue in a growing array.  Returns an order in
// which every device may be resolved; the order's LENGTH is the acyclicity
// certificate, because a DAG's order covers every device and a cycle's does
// not.
//
// The counter is IN-degree: start from the devices nothing feeds, and when a
// device is resolved, one of its outputs' predecessors is gone.  `you` and
// `svr` are both such sources in this data, and `out` is the single sink.
def topo_order(g: Graph) -> [long] {
    let n = g.n;
    let indeg: [long] = [];
    let i = 0;
    while (i < n) { indeg += 0; i = i + 1 };
    for v in 0..n {
        let p = g.start[v];
        while (p < g.start[v + 1]) {
            indeg[g.adj[p]] = indeg[g.adj[p]] + 1;
            p = p + 1;
        };
    };
    let q: [long] = [];
    for v in 0..n { if (indeg[v] == 0) { q += v } };
    let order: [long] = [];
    let head = 0;
    while (head < len(q)) {
        let u = q[head];
        head = head + 1;
        order += u;
        let p = g.start[u];
        while (p < g.start[u + 1]) {
            let v = g.adj[p];
            indeg[v] = indeg[v] - 1;
            if (indeg[v] == 0) { q += v };
            p = p + 1;
        };
    };
    order
}

// The same count by the other direction: instead of pulling each device's
// value up from its outputs, push a running total forward along every edge in
// a topological order.  Same recurrence, opposite data flow, which is what
// makes it worth comparing against count_paths.  `out` is not expanded, so a
// path stops there exactly as it does in count_paths.
def push_counts(g: Graph, src: long, order: [long]) -> [long] {
    let n = g.n;
    let ways: [long] = [];
    let i = 0;
    while (i < n) { ways += 0; i = i + 1 };
    if (src == NO_NODE) { return ways };
    ways[src] = 1;
    for k in 0..len(order) {
        let u = order[k];
        if (u != g.out && ways[u] > 0) {
            let p = g.start[u];
            while (p < g.start[u + 1]) {
                ways[g.adj[p]] = ways[g.adj[p]] + ways[u];
                p = p + 1;
            };
        };
    };
    ways
}

// The most devices on any path from `src` to `out`, in devices not hops.
// The same forward pass with a different value type: the max over outputs
// instead of the sum, +1 instead of +.
def longest_path(g: Graph, src: long, order: [long]) -> long {
    let n = g.n;
    let len_to: [long] = [];
    let i = 0;
    while (i < n) { len_to += 0; i = i + 1 };
    if (src == NO_NODE) { return 0 };
    len_to[src] = 1;
    let best = 1;
    for k in 0..len(order) {
        let u = order[k];
        if (len_to[u] > 0) {
            if (u != g.out) {
                let p = g.start[u];
                while (p < g.start[u + 1]) {
                    let v = g.adj[p];
                    if (len_to[v] < len_to[u] + 1) { len_to[v] = len_to[u] + 1 };
                    p = p + 1;
                };
            };
            if (len_to[u] > best) { best = len_to[u] };
        };
    };
    best
}

// Every path from `from` to `to`, one at a time, with each one materialised
// and checked.  Exponential in the worst case; it is here because `you` is
// only a few hops from `out` and the count is small, which is exactly why the
// counting methods exist at all for part 2.
//
// `dup` counts paths seen twice (each is keyed by its device NAMES, so this
// does not trust the ids), and `rev` counts attempted steps onto a device
// already on the path being built -- zero in a DAG.
def enumerate_paths(g: Graph, from: long, to: long) -> Walk {
    if (g.n == 0 || from == NO_NODE || to == NO_NODE) {
        return { count: 0, maxlen: 0, dup: 0, rev: 0 };
    };
    let n = g.n;
    let on: [long] = [];
    let hits: [long] = [];
    let st: [long] = [];
    let pos: [long] = [];
    let i = 0;
    while (i < n) { on += 0; hits += 0; st += 0; pos += 0; i = i + 1 };
    let pathnames: [str] = [];
    let keys = new_interner();
    let count = 0;
    let maxlen = 0;
    let dup = 0;
    let rev = 0;
    let i = 0;
    // pathnames is hoisted out of the walk and refilled per path, so the only
    // thing a completed path allocates is the key string itself (and the slice
    // join takes).  No literal array is created inside this loop.
    while (i < n) { pathnames += ""; i = i + 1 };
    on[from] = 1;
    hits[from] = 1;
    st[0] = from;
    pos[0] = g.start[from];
    let d = 1;
    while (d > 0) {
        let top = d - 1;
        let u = st[top];
        let p = pos[top];
        if (u == to) {
            count = count + 1;
            if (d > maxlen) { maxlen = d };
            for j in 0..d { pathnames[j] = g.names[st[j]] };
            let key = "|".join(pathnames[0:d]);
            if (interner_lookup(keys, key) >= 0) { dup = dup + 1 };
            interner_add(keys, key);
            on[u] = 0;
            hits[u] = hits[u] - 1;
            d = d - 1;
        } else if (p >= g.start[u + 1]) {
            on[u] = 0;
            hits[u] = hits[u] - 1;
            d = d - 1;
        } else {
            pos[top] = p + 1;
            let v = g.adj[p];
            if (hits[v] > 0) { rev = rev + 1 };
            if (on[v] == 0) {
                on[v] = 1;
                hits[v] = hits[v] + 1;
                st[d] = v;
                pos[d] = g.start[v];
                d = d + 1;
            };
        };
    };
    { count: count, maxlen: maxlen, dup: dup, rev: rev }
}

// Part 2 as the write-ups do it.  The graph is acyclic, so a path that visits
// both `fft` and `dac` visits them in ONE order -- both orders at once would
// be a cycle -- and the two orders are disjoint sets of paths, so their
// counts add.  Within one order the count is the PRODUCT of the three
// segment counts: every path of one segment combines with every path of the
// next, so 1 x 1 x 2 choices is 2 paths.
//
// Returns [answer, svr>fft, fft>dac, dac>out, svr>dac, dac>fft, fft>out].
def part2_segments(g: Graph) -> [long] {
    if (g.svr == NO_NODE || g.fft == NO_NODE || g.dac == NO_NODE
        || g.out == NO_NODE) {
        return [0, 0, 0, 0, 0, 0, 0];
    };
    let a = count_paths(g, g.svr, g.fft);
    let b = count_paths(g, g.fft, g.dac);
    let c = count_paths(g, g.dac, g.out);
    let d = count_paths(g, g.svr, g.dac);
    let e = count_paths(g, g.dac, g.fft);
    let f = count_paths(g, g.fft, g.out);
    [a * b * c + d * e * f, a, b, c, d, e, f]
}

// Part 2 the other way round: ONE walk from `svr` to `out` carrying two
// flags, "already visited fft" and "already visited dac", counting a path
// only when both are set on arrival.  Nothing is multiplied here, and the
// state is four per device instead of one -- a different computation from the
// segment product, which is the point of having both.
def walk_both(g: Graph, memo: [long], u: long, fl: long) -> long {
    let key = u * 4 + fl;
    let hit = memo[key];
    if (hit >= 0) {
        hit
    } else {
        let v = 0;
        if (u == g.out) {
            if (fl == (FL_FFT | FL_DAC)) { v = 1 };
        } else {
            let nf = fl;
            if (u == g.fft) { nf = nf | FL_FFT };
            if (u == g.dac) { nf = nf | FL_DAC };
            let p = g.start[u];
            while (p < g.start[u + 1]) {
                v = v + walk_both(g, memo, g.adj[p], nf);
                p = p + 1;
            };
        };
        memo[key] = v;
        v
    }
}

// The flag walk, from scratch: allocate the 4-states-per-device memo and go.
// The acyclicity test is not decoration -- a walk that carries its own state
// cannot detect a cycle the way count_paths does (the same state arrives
// again only after the answer for it is wanted), so it refuses a graph that
// is not a DAG rather than recursing until the stack runs out.
def part2_flags(g: Graph) -> long {
    if (g.svr == NO_NODE || g.out == NO_NODE || g.n == 0) { return 0 };
    if (len(topo_order(g)) != g.n) { return 0 };
    let memo: [long] = [];
    let i = 0;
    while (i < 4 * g.n) { memo += -1; i = i + 1 };
    walk_both(g, memo, g.svr, 0)
}

// ── an order of my own (Y has no `sort`) ─────────────────────────────────────

// Counts descending, then names ascending.  One comparison, used by the merge.
def before(k1: long, n1: str, k2: long, n2: str) -> bool {
    if (k1 != k2) { k1 > k2 } else { str_lt(n1, n2) }
}

// Merge sort on TWO PARALLEL ARRAYS -- never one array of (count, name) rows.
// A merge that compared one row's count against another row's name is not a
// mistake this code is able to express; see README.md, the day05 note.
def msort(keys: [long], names: [str], lo: long, hi: long, k: [long], s: [str]) -> long {
    if (hi - lo < 2) { return 0 };
    let mid = (lo + hi) / 2;
    msort(keys, names, lo, mid, k, s);
    msort(keys, names, mid, hi, k, s);
    let i = lo;
    let j = mid;
    let w = lo;
    while (i < mid && j < hi) {
        if (before(keys[i], names[i], keys[j], names[j])) {
            k[w] = keys[i];
            s[w] = names[i];
            i = i + 1;
        } else {
            k[w] = keys[j];
            s[w] = names[j];
            j = j + 1;
        };
        w = w + 1;
    };
    while (i < mid) { k[w] = keys[i]; s[w] = names[i]; i = i + 1; w = w + 1 };
    while (j < hi) { k[w] = keys[j]; s[w] = names[j]; j = j + 1; w = w + 1 };
    let q = lo;
    while (q < hi) { keys[q] = k[q]; names[q] = s[q]; q = q + 1 };
    0
}

// Sort `keys`/`names` in place, ascending by `before`.  The scratch pair is
// allocated once, here, and handed down -- never inside the recursion.
def sort_pairs(keys: [long], names: [str]) -> long {
    let n = len(keys);
    if (n < 2) { return n };
    let k: [long] = [];
    let s: [str] = [];
    let i = 0;
    while (i < n) { k += 0; s += ""; i = i + 1 };
    msort(keys, names, 0, n, k, s);
    n
}

// ── the permutations the oracle uses ─────────────────────────────────────────

// The device lines, back to front.  Ids are handed out in first-seen order,
// so reversing the lines renumbers the whole graph.
def perm_lines(lines: [str]) -> [str] {
    let out: [str] = [];
    let i = len(lines);
    while (i > 0) {
        i = i - 1;
        out += lines[i];
    };
    out
}

// Each line's outputs, back to front.  The same graph with every adjacency
// list in the other order.
def perm_rhs(lines: [str]) -> [str] {
    let out: [str] = [];
    for i in 0..len(lines) {
        let line = lines[i].trim_end();
        let ci = line.index_of(":");
        if (ci < 0) {
            out += line;
        } else {
            let toks = tokenize(line[ci + 1:]);
            let rev: [str] = [];
            let k = len(toks);
            while (k > 0) {
                k = k - 1;
                rev += toks[k];
            };
            out += line[0:ci].trim() + ":" + space_join(rev);
        };
    };
    out
}

// The five devices the statement names by hand.  Everything else in the
// input is an opaque name; these five are not, because the puzzle DEFINES
// them by name -- perm_relabel() has to leave them alone or the question
// changes.
def is_special(name: str) -> bool {
    name == "you" || name == "out" || name == "svr" || name == "fft"
    || name == "dac"
}

// Every device EXCEPT the five named ones gets a new, opaque name: built
// from the id the device was given on its first appearance, so the names
// change, change length, and acquire digits, which the real ones never have.
// Because the id is a bijection this is the same graph under a different
// naming, and because the ids come from the line order the caller hands in,
// reversing the lines renumbers it as well.
def perm_relabel(lines: [str]) -> [str] {
    let t = new_interner();
    let out: [str] = [];
    for i in 0..len(lines) {
        let line = lines[i].trim_end();
        let ci = line.index_of(":");
        if (ci < 0) {
            out += line;
        } else {
            let sname = line[0:ci].trim();
            let sid = interner_add(t, sname);
            let toks = tokenize(line[ci + 1:]);
            let parts: [str] = [];
            if (is_special(sname)) { parts += sname }
            else { parts += "q" + tostring(sid) + "z" };
            for k in 0..len(toks) {
                let id = interner_add(t, toks[k]);
                if (is_special(toks[k])) { parts += toks[k] }
                else { parts += "q" + tostring(id) + "z" };
            };
            out += parts[0] + ":" + space_join(parts[1:len(parts)]);
        };
    };
    out
}

// All three at once.
def perm_all(lines: [str]) -> [str] { perm_relabel(perm_rhs(perm_lines(lines))) }

// ── one entry point, shared by the answers and by every check ────────────────

// Everything the two answers are made of, so that the permutation oracle can
// compare whole records rather than one field at a time.
type Res = {
    p1: long, p2: long,          // the two answers, by the production methods
    p1b: long, p2b: long,        // the same answers by the other methods
    n: long, edges: long, lines: long, cyc: long,
    all_svr: long, longest: long,
    seg: [long],                 // part2_segments' seven numbers
    err: str
};

// The solver.  `lines` in, both answers out.  Every check in --check goes
// through here too, so a defect injected into the solver is injected into the
// checks as well -- the thing day02's battery got wrong.
def solve_graph(lines: [str]) -> Res {
    let g = parse_graph(lines);
    if (g.err != "") {
        return { p1: 0, p2: 0, p1b: 0, p2b: 0, n: 0, edges: 0, lines: 0,
                 cyc: 0, all_svr: 0, longest: 0, seg: [0, 0, 0, 0, 0, 0, 0],
                 err: g.err };
    };
    let order = topo_order(g);
    let cyc = g.n - len(order);           // != 0 exactly when there is a cycle
    let seg = part2_segments(g);
    let ways_you = push_counts(g, g.you, order);
    let p1 = count_paths(g, g.you, g.out);
    // `out` may not be in the input at all, and -1 is not an index.
    let p1b = 0;
    if (g.out != NO_NODE) { p1b = ways_you[g.out] };
    let p2 = seg[0];
    let p2b = part2_flags(g);
    let all_svr = count_paths(g, g.svr, g.out);
    let longest = longest_path(g, g.you, order);
    { p1: p1, p2: p2, p1b: p1b, p2b: p2b, n: g.n, edges: g.edges, lines: g.lines,
      cyc: cyc, all_svr: all_svr, longest: longest, seg: seg, err: "" }
}

// The id of a device by name, scanning `g.names`.  The graph does not keep
// the interner it was built from -- ids are all the solver ever needs -- so
// this is a plain scan, used only by the checks and only to prove that a
// sorted row still names a device that carries the count printed beside it.
def name_id(g: Graph, name: str) -> long {
    let found = NO_NODE;
    let v = 0;
    while (v < g.n && found == NO_NODE) {
        if (g.names[v] == name) { found = v };
        v = v + 1;
    };
    found
}

// ── the "top devices" table ──────────────────────────────────────────────────

// The `want` devices carrying the most paths from `svr`, `out` itself left
// out (it is every path's endpoint, so it would always be first and say
// nothing).  Sorted by count descending then name ascending, which is a total
// order, so the table is reproducible without any tie-break of last resort.
def top_devices(g: Graph, ways: [long], want: long) -> [str] {
    let keys: [long] = [];
    let names: [str] = [];
    for v in 0..g.n {
        if (v != g.out && ways[v] > 0) {
            keys += ways[v];
            names += g.names[v];
        };
    };
    sort_pairs(keys, names);
    let out: [str] = [];
    let n = len(keys);
    if (want > n) { want = n };
    for i in 0..want { out += tostring(keys[i]) + "  " + names[i] };
    out
}

// ── the check harness ────────────────────────────────────────────────────────

def expect(name: str, ok: bool, detail: str) -> long {
    checks_run = checks_run + 1;
    let bad = 0;
    if (ok) {
        print("ok   " + name + "   " + detail);
    } else {
        checks_failed = checks_failed + 1;
        bad = 1;
        if (first_failure == "") { first_failure = name };
        print("FAIL " + name + "   " + detail);
    };
    bad
}

// One hand-worked micro-case, run through the real parser and every method.
// The arithmetic is in README.md so a reader can check it by eye.
def micro(label: str, lines: [str], want1: long, want2: long) -> long {
    let r = solve_graph(lines);
    if (r.err != "") {
        return expect("micro " + label, false, "parse failed: " + r.err);
    };
    let seg = part2_segments(parse_graph(lines));
    let d = f"part1={r.p1}/{want1} (push {r.p1b}, "
            + f"flags p2={r.p2b}/{want2}, route {seg[1]}x{seg[2]}x{seg[3]}"
            + f" + {seg[4]}x{seg[5]}x{seg[6]})";
    let f = 0;
    f = f + expect("micro " + label + " part 1", r.p1 == want1, d);
    f = f + expect("micro " + label + " part 1 methods agree",
                   r.p1 == r.p1b, f"{r.p1} vs push {r.p1b}");
    f = f + expect("micro " + label + " part 2", r.p2 == want2, d);
    f = f + expect("micro " + label + " part 2 methods agree",
                   r.p2 == r.p2b, f"product {r.p2} vs flags {r.p2b}");
    f
}

// The anchors.  Part 1's is the statement's own worked example and its own
// answer; part 2's is a public write-up's worked example and its own answer
// (README.md names both and links the write-up).  A third case is the
// statement's example again with `svr`, `fft` and `dac` absent, which is the
// edge case the statement's data cannot show: part 2 is then 0 because a
// named device that is not in the graph is on no path at all.
def check_anchors() -> long {
    let f = 0;
    let ls: [str]? = fs.read_lines("example.txt");
    if (ls == none) {
        f = f + expect("example.txt present", false, "cannot read example.txt");
    } else {
        f = f + expect("example.txt present", true, f"{len(ls!)} lines");
        f = f + micro("statement example", ls!, 5, 0);
    };
    let l2: [str]? = fs.read_lines("example2.txt");
    if (l2 == none) {
        f = f + expect("example2.txt present", false, "cannot read example2.txt");
    } else {
        f = f + expect("example2.txt present", true, f"{len(l2!)} lines");
        // The write-up lists the paths of its example one by one: exactly one
        // svr>fft (svr-aaa-fft), exactly one fft>dac (fft-ccc-eee-dac), and
        // exactly two dac>out (via ggg and via hhh).  The multiplication
        // principle then makes part 2 = 1 x 1 x 2 = 2, which is the number the
        // write-up states -- that is the anchor.
        //
        // It also says "svr>dac: 0", which cannot be right: its own traced
        // svr-aaa-fft-ccc-eee-dac is one such path.  So seg[4] is printed and
        // NOT asserted, and the route-2 product is 0 for a reason that holds
        // either way: dac cannot reach fft in a DAG (asserted below).
        let seg = part2_segments(parse_graph(l2!));
        let r = solve_graph(l2!);
        f = f + expect("write-up example segment counts (traced)",
                       seg[1] == 1 && seg[2] == 1 && seg[3] == 2,
                       f"svr>fft={seg[1]} fft>dac={seg[2]} dac>out={seg[3]} "
                       + f"(traced 1 1 2; the write-up's svr>dac={seg[4]} "
                       + f"contradicts its own trace, so it is not asserted)");
        f = f + expect("write-up example: dac cannot reach fft",
                       seg[5] == 0, f"dac>fft={seg[5]}, fft>out={seg[6]}");
        f = f + expect("write-up example part 1", r.p1 == 0,
                       f"{r.p1} (that graph has no `you` at all)");
        f = f + micro("write-up example", l2!, 0, 2);
    };
    f
}

// Every micro-case the README works out by hand, plus the whitespace hazards
// the statement's format allows.
def check_micro() -> long {
    let f = 0;
    // A two-device network: you -> a -> out, one path.
    f = f + micro("two-device chain", ["you: a", "a: out"], 1, 0);
    // One hop: `out` as a direct output of `you`.  The statement's sink has
    // no line of its own, and this is the smallest input that shows it.
    f = f + micro("you straight to out", ["you: out"], 1, 0);
    // Two outputs, both reaching out: 2 paths, and nothing multiplies.
    f = f + micro("fan out", ["you: a b", "a: out", "b: out"], 2, 0);
    // A diamond: you -> {a,b} -> c -> out.  Two DIFFERENT paths (a>c and
    // b>c), which is the case a solver that dedupes device sets gets wrong.
    f = f + micro("diamond", ["you: a b", "a: c", "b: c", "c: out"], 2, 0);
    // A dead end: `b` reaches nothing, so only a's path counts.
    f = f + micro("dead end", ["you: a b", "a: out", "b: c"], 1, 0);
    // A repeated output is a second cable to the same device, and the
    // statement counts paths, so it is a second path: 2.  No line in the real
    // input repeats an output, which is why this is a micro-case and not an
    // observation -- but the oracle canary in --check does use the case.
    f = f + micro("repeated output", ["you: a a", "a: out"], 2, 0);
    // Nothing reaches `out` at all.
    f = f + micro("out unreachable", ["you: a", "a: b", "b: c"], 0, 0);
    // `you` itself is a sink: no path leaves it.
    f = f + micro("you is a sink", ["you: a"], 0, 0);
    // Whitespace hazards.  A trailing space and a doubled space must read
    // exactly like the clean line: split() drops one trailing empty field and
    // keeps interior ones, so a parser that trusted it would see 4 outputs.
    f = f + micro("trailing space", ["you: a b ", "a: out", "b: out "], 2, 0);
    f = f + micro("double space", ["you: a  b", "a: out", " b: out"], 2, 0);
    // The part-2 chain of one: svr -> fft -> dac -> out is 1 path, and the
    // other order has no paths because dac cannot reach fft.
    f = f + micro("part2 chain",
                  ["svr: fft", "fft: dac", "dac: out"], 0, 1);
    // 1 x 2 x 2: two ways into dac, two ways out of it.
    f = f + micro("part2 1x2x2",
                  ["svr: fft", "fft: x y", "x: dac", "y: dac",
                   "dac: p q", "p: out", "q: out"], 0, 4);
    // Both waypoints, but `out` is not reachable from dac: 0.
    f = f + micro("part2 out cut off",
                  ["svr: fft", "fft: dac", "dac: p", "p: q"], 0, 0);
    // Both waypoints reached, but not on a path from svr at all: 0.
    f = f + micro("part2 svr cut off",
                  ["svr: p", "p: out", "fft: dac", "dac: out"], 0, 0);
    // `fft` present, `dac` absent: the second device is on no path, so 0.
    f = f + micro("part2 dac missing",
                  ["svr: fft", "fft: out"], 0, 0);
    // The order really does matter: dac -> fft gives 2 here, so a solver that
    // always counted the paths in one fixed order would get this wrong.
    f = f + micro("part2 reverse order",
                  ["svr: dac", "dac: p q", "p: fft", "q: fft",
                   "fft: out"], 0, 2);
    f
}

// Every path, materialised, counted and checked against the DPs.  This is the
// oracle that differs in KIND from the solver: no memo, no order, no
// recurrence -- just a walk that writes down each path it finds.
def check_enumeration(lines: [str]) -> long {
    let f = 0;
    let g = parse_graph(lines);
    if (g.err != "") {
        return expect("real input parses for the enumeration", false, g.err);
    };
    let w = enumerate_paths(g, g.you, g.out);
    let dp = count_paths(g, g.you, g.out);
    f = f + expect("enumeration present", w.count > 0, f"{w.count} paths, longest {w.maxlen}");
    f = f + expect("enumerated paths are distinct", w.dup == 0,
                   f"{w.dup} duplicate(s) of {w.count}");
    f = f + expect("enumeration never revisits a device", w.rev == 0,
                   f"{w.rev} attempted step(s) onto a device already on the path");
    f = f + expect("part 1 == enumeration", dp == w.count,
                   f"dp {dp} vs {w.count} enumerated, longest path {w.maxlen} devices");
    let order = topo_order(g);
    let lp = longest_path(g, g.you, order);
    f = f + expect("longest path == enumeration maxlen", lp == w.maxlen,
                   f"topological {lp} vs enumeration {w.maxlen}");
    f
}

// The sort, checked on the real input's "top devices" table: the order is
// total, the result is an exact permutation of the rows that went in, and
// every name still carries its own count.  The last of those three is what a
// merge that compares one row's key against another row's name cannot pass.
def check_sort(lines: [str]) -> long {
    let f = 0;
    let g = parse_graph(lines);
    if (g.err != "") {
        return expect("real input parses for the sort check", false, g.err);
    };
    let order = topo_order(g);
    let ways = push_counts(g, g.svr, order);
    let keys: [long] = [];
    let names: [str] = [];
    for v in 0..g.n {
        if (v != g.out && ways[v] > 0) {
            keys += ways[v];
            names += g.names[v];
        };
    };
    let rows = len(keys);
    sort_pairs(keys, names);

    let misordered = 0;
    for i in 1..rows {
        if (!before(keys[i - 1], names[i - 1], keys[i], names[i])) {
            misordered = misordered + 1;
        };
    };
    f = f + expect("sort order is total and ascending", misordered == 0,
                   f"{misordered} of {rows - 1} adjacent pairs out of order");

    // An exact permutation of the ROWS that went in: every name appears once, and
    // once is all of them.  (`out` is not a row -- it is excluded on purpose
    // -- so "every DEVICE appears" is the wrong question to ask here.)
    let mark: [long] = [];
    let i = 0;
    while (i < g.n) { mark += 0; i = i + 1 };
    let twice = 0;
    let foreign = 0;
    let skewed = 0;
    for i in 0..rows {
        let id = name_id(g, names[i]);
        if (id == NO_NODE) {
            foreign = foreign + 1;
        } else {
            mark[id] = mark[id] + 1;
            if (mark[id] > 1) { twice = twice + 1 };
            if (keys[i] != ways[id]) { skewed = skewed + 1 };
        };
    };
    let once = 0;
    for v in 0..g.n { if (mark[v] == 1) { once = once + 1 } };
    f = f + expect("sort is an exact permutation", once == rows && twice == 0
                   && foreign == 0 && rows > 1,
                   f"{rows} rows in, {once} device(s) once, {twice} repeated, "
                   + f"{foreign} foreign");
    f = f + expect("sort keeps every name with its own count", skewed == 0,
                   f"{skewed} of {rows} rows have a count that is not their device's");
    f
}

// Two graphs that are the same graph must report the same things.
def same_answers(a: Res, b: Res) -> bool {
    a.err == "" && b.err == "" && a.p1 == b.p1 && a.p2 == b.p2
    && a.n == b.n && a.edges == b.edges && a.lines == b.lines
}

// `lines` with one more output on the line of `name`.  A repeated output is a
// second cable to the same device, which counts as a second path -- the real
// input never does it, but it moves ONE answer and leaves the other alone,
// which is what a canary needs.
def bump_output(lines: [str], name: str, extra: str) -> [str] {
    let out: [str] = [];
    for i in 0..len(lines) {
        let line = lines[i].trim_end();
        let ci = line.index_of(":");
        if (ci > 0 && line[0:ci].trim() == name) { out += line + " " + extra }
        else { out += line };
    };
    out
}

// `lines` with the first output of `name`'s line removed.
def drop_first_output(lines: [str], name: str) -> [str] {
    let out: [str] = [];
    for i in 0..len(lines) {
        let line = lines[i].trim_end();
        let ci = line.index_of(":");
        if (ci > 0 && line[0:ci].trim() == name) {
            let toks = tokenize(line[ci + 1:]);
            out += line[0:ci].trim() + ":" + space_join(toks[1:len(toks)]);
        } else {
            out += line;
        };
    };
    out
}

// `lines` plus a brand new device that nothing leads to: a new device and a
// new connection, and not one path.
def add_isolated(lines: [str], name: str, target: str) -> [str] {
    let out: [str] = [];
    for i in 0..len(lines) { out += lines[i] };
    out += name + ": " + target;
    out
}

// A Res record built by hand, for testing the comparison itself rather than
// the solver.
def mk_res(p1: long, p2: long, n: long, edges: long, lines: long, err: str) -> Res {
    { p1: p1, p2: p2, p1b: p1, p2b: p2, n: n, edges: edges, lines: lines,
      cyc: 0, all_svr: 0, longest: 0, seg: [0, 0, 0, 0, 0, 0, 0], err: err }
}

// Canaries for the oracle below.  A permutation must look the same and
// anything else must not, so each canary is a graph that differs from the real
// one in exactly ONE of the things same_answers() compares.  Drop a comparison
// from same_answers() and the canary that depends on it starts passing --
// which is the point: an oracle nobody has tried to fool is an oracle nobody
// knows is awake.  (Injection 18 in inject.sh removes the part-2 comparison
// and is caught by the first graph canary; injection 22 inverts what an
// absent device means and is caught by the anchors.)
//
// The comparison is ALSO unit-tested field by field, because a graph canary
// can only move the fields the graph happens to be able to move: dropping an
// output of `you`, for instance, moves BOTH answers, because `you` is itself
// reachable from `svr` in this input.
def check_oracle_canaries(lines: [str], base: Res) -> long {
    let f = 0;
    let c1 = solve_graph(bump_output(lines, "svr", "fft"));
    f = f + expect("canary: part 2 must be compared",
                   !same_answers(base, c1) && c1.p2 != base.p2 && c1.p1 == base.p1,
                   f"a repeated svr output gives part1 {c1.p1} (== {base.p1}) "
                   + f"and part2 {c1.p2} (was {base.p2}): the graphs differ");
    let c3 = solve_graph(add_isolated(lines, "zqx", "you"));
    f = f + expect("canary: the device and connection counts must be compared",
                   !same_answers(base, c3) && c3.n == base.n + 1
                   && c3.p1 == base.p1 && c3.p2 == base.p2,
                   f"an unreachable device gives {c3.n} devices (was {base.n}), "
                   + f"part1 {c3.p1}, part2 {c3.p2}");
    let c4 = solve_graph(drop_first_output(lines, "you"));
    f = f + expect("canary: a dropped connection is not a permutation",
                   !same_answers(base, c4) && c4.p1 != base.p1,
                   f"dropping an output of you moves BOTH answers (part1 "
                   + f"{c4.p1}, part2 {c4.p2}), which is why the field-by-field "
                   + f"unit test below exists");

    // Field by field, with hand-made records: every comparison the oracle
    // makes has to be able to fail on its own.
    let a = mk_res(11, 22, 3, 4, 5, "");
    let eq = same_answers(a, mk_res(11, 22, 3, 4, 5, ""));
    let d1 = !same_answers(a, mk_res(12, 22, 3, 4, 5, ""));
    let d2 = !same_answers(a, mk_res(11, 23, 3, 4, 5, ""));
    let dn = !same_answers(a, mk_res(11, 22, 4, 4, 5, ""));
    let de = !same_answers(a, mk_res(11, 22, 3, 5, 5, ""));
    let dl = !same_answers(a, mk_res(11, 22, 3, 4, 6, ""));
    let dr = !same_answers(a, mk_res(11, 22, 3, 4, 5, "x"));
    f = f + expect("same_answers: equal on equal, different on any one field moved",
                   eq && d1 && d2 && dn && de && dl && dr,
                   f"equal={eq} p1={d1} p2={d2} n={dn} edges={de} lines={dl} "
                   + f"err={dr}");
    f
}

// The permutation oracle.  Three permutations of the same input, all through
// the one entry point, and the answers must not move.  This is the check
// that varies the input's ORDER rather than re-deriving the answer the same
// way twice -- the one that caught day05's pair-sorting bug, which every
// part-2 method there agreed with.
def check_permutations(lines: [str]) -> long {
    let f = 0;
    let base = solve_graph(lines);
    if (base.err != "") {
        return expect("real input parses for the oracle", false, base.err);
    };
    f = f + expect("oracle needs a non-trivial answer", base.p1 > 0 && base.p2 > 0,
                   f"part1={base.p1} part2={base.p2}");
    f = f + check_oracle_canaries(lines, base);
    let variants: [str] = ["lines reversed", "outputs reversed", "renamed + both"];
    let v = 0;
    while (v < 3) {
        let pl: [str] = [];
        if (v == 0) { pl = perm_lines(lines) }
        else if (v == 1) { pl = perm_rhs(lines) }
        else { pl = perm_all(lines) };
        let r = solve_graph(pl);
        let same = same_answers(base, r);
        f = f + expect("permutation: " + variants[v], same,
                       f"{r.p1}/{r.p2} vs {base.p1}/{base.p2}, "
                       + f"{r.n} devices/{r.edges} connections vs "
                       + f"{base.n}/{base.edges}"
                       + if (r.err != "") { "  parse: " + r.err } else { "" });
        v = v + 1;
    };
    f
}

// The real input, every way.  Presence guards first: a comparison of two
// values that are both absent passes trivially, so every observed quantity
// is shown present before anything is compared with it.
def check_real(lines: [str]) -> long {
    let f = 0;
    let g = parse_graph(lines);
    if (g.err != "") {
        return expect("input well formed", false, g.err);
    };
    f = f + expect("input well formed", true,
                   f"{g.lines} device lines, {g.n} devices, {g.edges} connections");
    f = f + expect("the two tokenizers agree on every line", g.tok_mismatch == 0,
                   f"{g.tok_mismatch} line(s) where tokenize() and split() disagree");
    f = f + expect("every named device is in the graph",
                   g.you != NO_NODE && g.out != NO_NODE && g.svr != NO_NODE
                   && g.fft != NO_NODE && g.dac != NO_NODE,
                   f"you={g.you} out={g.out} svr={g.svr} fft={g.fft} dac={g.dac}");
    let order = topo_order(g);
    let cyc = g.n - len(order);
    f = f + expect("the graph is a DAG", cyc == 0,
                   f"a topological order covered {g.n - cyc} of {g.n} devices");

    // Re-derive the CSR straight from the file and demand it row for row.
    // This is the parser checking its own output against its input, and it is
    // what catches a build that reads the same lines and produces a different
    // graph -- a degree counted per LINE instead of per CONNECTION lands
    // here, not in the answers.
    let bad_rows = 0;
    let total_deg = 0;
    let li = 0;
    while (li < len(lines) && bad_rows == 0) {
        let line = lines[li].trim_end();
        if (line != "") {
            let ci = line.index_of(":");
            if (ci > 0) {
                let src = line[0:ci].trim();
                let sid = name_id(g, src);
                let toks = tokenize(line[ci + 1:]);
                let deg = g.start[sid + 1] - g.start[sid];
                total_deg = total_deg + deg;
                if (deg != len(toks)) {
                    bad_rows = bad_rows + 1;
                } else {
                    for k in 0..len(toks) {
                        if (g.names[g.adj[g.start[sid] + k]] != toks[k]) {
                            bad_rows = bad_rows + 1;
                        };
                    };
                };
            };
        };
        li = li + 1;
    };
    f = f + expect("the CSR is the file, row for row", bad_rows == 0,
                   f"{bad_rows} row(s) of {g.lines} disagree with their line");
    f = f + expect("the CSR degrees add up to the connections",
                   total_deg == g.edges && g.edges > 0,
                   f"{total_deg} vs {g.edges}");

    // Every connection is one way.  Nothing in the solver assumes it -- the
    // counts are directed either way -- but a mutual pair would be a 2-cycle,
    // so this is also an independent read on the acyclicity verdict above.
    let mutual = 0;
    for v in 0..g.n {
        let p = g.start[v];
        while (p < g.start[v + 1]) {
            let u = g.adj[p];
            let q = g.start[u];
            let found = false;
            while (q < g.start[u + 1]) {
                if (g.adj[q] == v) { found = true };
                q = q + 1;
            };
            if (found) { mutual = mutual + 1 };
            p = p + 1;
        };
    };
    f = f + expect("no connection is mutual (that would be a 2-cycle)",
                   mutual == 0, f"{mutual} of {g.edges} connections go both ways");

    let r = solve_graph(lines);
    let seg = r.seg;

    f = f + expect("part 1 present", r.p1 > 0, f"part1={r.p1}");
    f = f + expect("part 2 present", r.p2 > 0, f"part2={r.p2}");

    // Part 1, three ways.
    f = f + expect("part 1: pull DP == push DP", r.p1 == r.p1b,
                   f"{r.p1} vs {r.p1b}");
    // Part 2, two ways.
    f = f + expect("part 2: segment product == flag walk", r.p2 == r.p2b,
                   f"{r.p2} vs {r.p2b}");
    f = f + expect("part 2 == the two routes added",
                   r.p2 == seg[1] * seg[2] * seg[3] + seg[4] * seg[5] * seg[6],
                   f"{seg[1]}x{seg[2]}x{seg[3]} + {seg[4]}x{seg[5]}x{seg[6]}");

    // Invariants the answers must satisfy, all from outside the counting.
    f = f + expect("part 2 <= all svr>out paths", r.p2 > 0 && r.p2 <= r.all_svr,
                   f"{r.p2} <= {r.all_svr}");
    f = f + expect("part 2 > 0 needs every segment of its route",
                   r.p2 > 0 && seg[1] > 0 && seg[2] > 0 && seg[3] > 0,
                   f"segments {seg[1]} {seg[2]} {seg[3]}");
    // A DAG cannot have both fft->dac and dac->fft: that would be a cycle.
    f = f + expect("at most one order of fft and dac is reachable",
                   !((seg[2] > 0) && (seg[5] > 0)),
                   f"fft>dac={seg[2]} dac>fft={seg[5]}");
    f = f + expect("a path is at least two devices long", r.longest >= 2,
                   f"{r.longest} devices");
    f = f + expect("part 1 >= 1 path, part 2 >= 1 path",
                   r.p1 >= 1 && r.p2 >= 1, f"{r.p1} {r.p2}");
    // `you` and `svr` are both sources in this data, so the push DP's totals
    // must equal the pull DP's -- which they do, checked above; here: the two
    // pushes must also agree with each other on `out`.
    let ways_you = push_counts(g, g.you, order);
    let ways_svr = push_counts(g, g.svr, order);
    f = f + expect("push: ways[out] == pull: count_paths",
                   ways_you[g.out] == r.p1 && ways_svr[g.out] == r.all_svr,
                   f"you {ways_you[g.out]} == {r.p1}, svr {ways_svr[g.out]} == {r.all_svr}");
    // Every device the two pushes touched must be a real device.
    let touched_you = 0;
    let touched_svr = 0;
    for v in 0..g.n {
        if (ways_you[v] > 0) { touched_you = touched_you + 1 };
        if (ways_svr[v] > 0) { touched_svr = touched_svr + 1 };
    };
    f = f + expect("pushes reach something", touched_you > 0 && touched_svr > 0,
                   f"{touched_you} devices carry a path from you, "
                   + f"{touched_svr} from svr");

    print(f"real input: part 1 = {r.p1}, part 2 = {r.p2}, "
          + f"{g.n} devices, {g.edges} connections");
    f
}

def run_check() -> long {
    checks_run = 0;
    checks_failed = 0;
    first_failure = "";

    let f = check_anchors();
    f = f + check_micro();
    let lines: [str]? = fs.read_lines("input.txt");
    if (lines == none) {
        f = f + expect("input.txt present", false, "cannot read input.txt");
    } else {
        f = f + expect("input.txt present", true,
                       f"{len(lines!)} lines");
        f = f + check_real(lines!);
        f = f + check_enumeration(lines!);
        f = f + check_sort(lines!);
        f = f + check_permutations(lines!);
    };

    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed");
        return 0;
    };
    print(f"property check: {checks_failed} of {checks_run} FAILED (first: {first_failure})");
    f
}

// ── the answer ────────────────────────────────────────────────────────────────

def solve(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day11: cannot read " + path + "\n");
        return 1;
    };
    let g = parse_graph(lines!);
    if (g.err != "") {
        eputs("day11: " + path + ": " + g.err + "\n");
        return 1;
    };
    let order = topo_order(g);
    let cyc = g.n - len(order);
    if (cyc != 0) {
        eputs("day11: " + path + " is not acyclic: a topological order covered "
              + tostring(g.n - cyc) + " of " + tostring(g.n)
              + " devices, so paths through it are not finite\n");
        return 1;
    };
    let r = solve_graph(lines!);
    let seg = r.seg;
    let ways_svr = push_counts(g, g.svr, order);
    let top = top_devices(g, ways_svr, 5);

    print("day11: Advent of Code 2025 day 11 -- Reactor");
    print(f"input: {path}");
    print(f"devices: {g.n} ({g.lines} device lines, {g.edges} connections)");
    print(f"topological order covered all {g.n} devices, so the graph is a DAG");
    print(f"part 1 (paths from you to out): {r.p1}");
    print(f"part 2 (paths from svr to out through both fft and dac): {r.p2}");
    print(f"  route svr -> fft -> dac -> out: {seg[1]} * {seg[2]} * {seg[3]}"
          + f" = {seg[1] * seg[2] * seg[3]}");
    print(f"  route svr -> dac -> fft -> out: {seg[4]} * {seg[5]} * {seg[6]}"
          + f" = {seg[4] * seg[5] * seg[6]}");
    print(f"all paths svr -> out, unfiltered: {r.all_svr}");
    print(f"longest path you -> out: {r.longest} devices");
    print("the 5 devices carrying the most paths from svr (out excluded):");
    for i in 0..len(top) { print(f"  {i + 1}. {top[i]}") };
    0
}

const HELP = "day11 -- Advent of Code 2025 day 11 (Reactor), in Y

usage:
  ./day11 [FILE]        solve FILE (default input.txt) and print both answers
  ./day11 --check       run the property battery and print every assertion
  ./day11 --permute N   solve a permutation of FILE: 1 lines reversed,
                        2 outputs reversed, 3 renamed and both reversed
  ./day11 --help        this text

part 1: how many distinct directed paths lead from you to out
part 2: how many distinct directed paths lead from svr to out through both
        fft and dac

The input is a list of devices, one per line, 'name: output output ...'.
Device names are opaque; nothing depends on their order, length or letters.
";

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let have_path = false;
    let perm = -1;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--check") {
            want_check = true;
        } else if (a == "--help" || a == "-h") {
            print(HELP);
            return 0;
        } else if (a == "--permute") {
            if (i + 1 >= len(args)) {
                eputs("day11: --permute needs 1, 2 or 3\n");
                return 1;
            };
            i = i + 1;
            perm = tolong(args[i]);
            if (perm < 1 || perm > 3) {
                eputs("day11: --permute takes 1, 2 or 3, not " + args[i] + "\n");
                return 1;
            };
        } else if (a == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day11: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day11: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day11: more than one input file given (try --help)\n");
            return 1;
        } else {
            path = a;
            have_path = true;
        };
        i = i + 1;
    };

    if (want_check) {
        run_check();
        if (checks_failed != 0) { return 1 };
        return 0;
    };
    if (perm > 0) {
        let lines: [str]? = fs.read_lines(path);
        if (lines == none) {
            eputs("day11: cannot read " + path + "\n");
            return 1;
        };
        let pl: [str] = [];
        if (perm == 1) { pl = perm_lines(lines!) }
        else if (perm == 2) { pl = perm_rhs(lines!) }
        else { pl = perm_all(lines!) };
        let g = parse_graph(pl);
        if (g.err != "") {
            eputs("day11: permuted " + path + ": " + g.err + "\n");
            return 1;
        };
        let r = solve_graph(pl);
        print(f"permutation {perm}: part 1 = {r.p1}, part 2 = {r.p2}, "
              + f"{g.n} devices, {g.edges} connections");
        return 0;
    };
    solve(path)
};
exit(main())
