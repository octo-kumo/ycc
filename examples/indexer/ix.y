// ix.y -- the indexing engine.
//
// Four things live here and nothing else:
//
//   1. cmp_path  -- a STRICT TOTAL order on path strings (see the header).
//   2. Two open-addressed hash tables: extensions (str -> bucket) and
//      visited directories (int64 -> present).  Maps in Y are a linear
//      scan and there is no map_get/map_set, so an index keyed by
//      extension written naively is O(n) per file.  These are fixed
//      capacity, linear probing, FNV-1a, with the probe count kept as a
//      first-class number so a property check can read it.
//   3. walk      -- a bounded, explicit-stack directory walk.  It does
//      NOT use fs.list_dir: that allocates a 32768-byte getdents buffer
//      per call, i.e. 32 KB of arena per directory in a heap that never
//      frees anything.  read_dirs below uses one module-level buffer,
//      so the walk's own heap cost is constant in the size of the tree.
//   4. the sorting, hand-rolled, allocating nothing per pass.
//
// NOTHING HERE TRAPS on a hostile input.  Every filesystem refusal --
// ENOENT, ENOTDIR, EACCES, ELOOP, ENAMETOOLONG -- becomes a count, a
// line in DIAG, or a non-zero return.  Runtime traps print to STDOUT, so
// a trap would corrupt the golden instead of announcing itself.

import fs;

// ─────────────────────────────────────────────────────────────────────────
// cmp_path is a STRICT TOTAL order, and that is the whole point
// ─────────────────────────────────────────────────────────────────────────
//
// "There is no sort in Y" (examples/SUGGESTIONS.md #17), so this is
// hand-rolled, and a hand-rolled sort's real property is not "it sorts" --
// any list can be sorted badly once by luck.  The real property is that the
// order is TOTAL and DETERMINISTIC, which is three properties a bare
// `s < t` does not give you for free:
//
//   * antisymmetry    cmp(a,b) == -cmp(b,a)
//   * irreflexivity   cmp(a,a) == 0
//   * strictness      cmp(a,b) != 0 whenever a != b
//
// The last is the trap.  A comparator that lowercases both sides and then
// returns 0 when the shared prefix runs out treats "B" and "a" as equal and
// leaves their order to whatever the sort does with equal elements: stable
// for merge sort, so DETERMINISTIC, and still wrong -- two distinct files
// can swap places between one walk and the next and the golden will
// faithfully record the swap.  So cmp_path has three stages and stage 3
// exists only to break case ties:
//
//   1. byte-by-byte with both sides lowercased, so README and readme sit
//      together instead of at opposite ends of the list;
//   2. if the shared prefix runs out, the SHORTER path first;
//   3. same length and case-folded equal -- the RAW bytes decide, so "B"
//      precedes "b" and nothing distinct ever ties.
//
// A pair that agrees on all three is the same string, the only thing
// allowed to compare 0.
//
// Note on `>>>`: hex16 uses `>>> 4` on a value that is routinely negative
// (FNV-1a of a short file is), which is normally this campaign's most
// expensive silent-wrong-answer trap.  It is correct HERE and only because
// the loop runs exactly 16 times and masks with `& 15` each pass, so the
// sign-extension bits leave the window before they can reach a digit.
// --check asserts hex16 against externally supplied vectors, negatives
// included, so this is measured rather than reasoned about.

// ── record and function types ───────────────────────────────────────────

// One indexed file. `head` is "" unless --head asked for a snippet.
// `flags` bit 0 = looked binary, bit 1 = the first line had no newline.
type Entry = { path: str, ext: str, size: long, hash: long, head: str, flags: long };

// One extension's aggregate. `biggest`/`bpath` name its largest file, so
// the summary needs no second scan.
type Bucket = { ext: str, nfiles: long, nbytes: long, biggest: long, bpath: str };

// A comparison as a first-class value.  ORCHESTRATOR.md 2.15: "A def IS a
// first-class value, typed (parameter type) -> return type" -- the parens
// are the parameter LIST.  So a comparator is an ordinary argument and is
// dispatched through an array of them (CMPS below), with no closure: the
// wave-2 briefing assumed a comparator could not be passed as a value, and
// it can.
type Cmp = (str, str) -> long;

// A comparison over INDICES into the entry array: one sort serves three
// orderings over the same records, with the ordering chosen by the
// module-level SORT_KEY (a `def` is a value but a closure is not).
type ICmp = (long, long) -> long;

// ── limits and stat constants ───────────────────────────────────────────

const XT_CAP = 4096;       // extension table slots (power of two)
const VD_CAP = 65536;      // visited-directory slots (power of two)
const SORT_CAP = 65536;    // sort scratch; >= MAX_FILES
const MAX_FILES = 65536;
const MAX_DEPTH = 64;
const READ_BUF = 32768;    // ONE getdents64 buffer for the whole process

const S_IFMT = 61440;
const S_IFDIR = 16384;
const S_IFREG = 32768;
const S_IFLNK = 40960;

// ── index state (module globals: .bss, allocated once, never freed) ────

let ENT: [Entry] = [];
let BKT: [Bucket] = [];
let NAMES: [str] = [];     // one directory's names, refilled per call
let DIAG: [str] = [];      // human-readable lines (DIAG), and the CLI
let WARNED: [str] = [];    // paths already warned about, so not twice
let N_DIR: long = 0;
let N_FILE: long = 0;
let N_LINK: long = 0;
let N_OTHER: long = 0;
let N_UNREAD: long = 0;
let N_BYTES: long = 0;
let N_CYCLE: long = 0;
let N_CAP: long = 0;       // a cap was hit (files, dirs, stack or depth)
let HEAD_FLAGS: long = 0;  // head_of's verdict for the file just read

// Options.  They live here, not in the CLI, for one reason: the property
// check has to be able to build a report and compare two of them
// byte-for-byte, and it must go through the SAME renderer the CLI uses --
// a check that renders its own copy of the output checks nothing.
let ROOT: str = ".";
let OPT_EXT: str = "";
let OPT_FIND: str = "";
let OPT_LARGEST: long = -1;
let FOLLOW: bool = false;
let WANT_HASH: bool = true;
let HEAD_COLS: long = 0;
let DEPTH_CAP: long = 64;
let STRICT: bool = false;
let COLOR: long = 0;
// true until --color / --no-color / --no-tty settles it, so the CLI can
// tell "off because --no-tty" from "not decided yet".
let COLOR_AUTO: bool = true;

// SGR sequences.  Module-level constants, so painting a line costs no
// allocation; and nothing is emitted at all when COLOR is 0, which is what
// makes EXPECTED plain ASCII and byte-identical on every terminal.
const C_OFF = "\x1b[0m";
const C_BOLD = "\x1b[1m";
const C_DIM = "\x1b[2m";
const C_CYAN = "\x1b[36m";

def paint(code: str, s: str) -> str {
    if (COLOR != 0) { code + s + C_OFF } else { s }
};

// s padded to at least n columns.  A fixed-width column is what makes the
// golden readable; pad_right alone would truncate a long name.
def padl(s: str, n: long) -> str {
    if (s.length >= n) { s } else { s.pad_right(n, " ") }
};

def yn(b: bool) -> str { if (b) { "on" } else { "off" } };

// Linux x86-64 struct stat: dev at byte 0, ino at 8, mode at 24, size at
// 48 -- which is st[6] of a [long; 18].  Module-level so a walk never
// allocates one per directory.
let ST: [long; 18] = [0; 18];
let RBUF: [byte; 32768] = [0; 32768];
let HBUF: [byte; 17] = [0; 17];

// Explicit walk stack, and the sort's ping-pong scratch.  A bottom-up
// merge sort in these buffers allocates NOTHING: a recursive merge sort
// cannot say that, because every xs[0:mid] is a fresh slice in an arena
// that never frees.
let STK: [str; 8192] = [""; 8192];
let SKD: [long; 8192] = [0; 8192];
let SP: long = 0;
let SA: [str; 65536] = [""; 65536];
let SB: [str; 65536] = [""; 65536];
let IA: [long; 65536] = [0; 65536];
let IB: [long; 65536] = [0; 65536];

// ── FNV-1a, 64-bit ──────────────────────────────────────────────────────

// 0xcbf29ce484222325 as a signed long, and 0x100000001b3.
const FNV_BASIS = -3750763034362895579;
const FNV_PRIME = 1099511628211;

def fnv_step(h: long, b: long) -> long { (h ^ b) * FNV_PRIME };

def fnv_str(s: str) -> long {
    let h = FNV_BASIS;
    let i = 0;
    while (i < s.length) { h = fnv_step(h, byte_at(s, i)); i = i + 1; };
    h
};

// 16 lowercase hex digits, no prefix and no sign, into one module-level
// buffer.  --check compares this against the published FNV vectors as
// STRINGS, so the buffer's width is part of the contract.
def hex16(v: long) -> str {
    let x = v;
    let i = 15;
    while (i >= 0) {
        let d = x & 15;
        if (d < 10) { HBUF[i] = 48 + d; } else { HBUF[i] = 87 + d; };
        x = x >>> 4;
        i = i - 1;
    };
    from_bytes(HBUF[0:16])
};

def lower_byte(c: long) -> long {
    if (c >= 65 && c <= 90) { c + 32 } else { c }
};

// ── the two comparators ─────────────────────────────────────────────────

// Raw byte order. Also cmp_bytes' three-way result: byte_at gives a long,
// and the difference of two bytes is 0 exactly when they are equal.
def cmp_bytes(a: str, b: str) -> long {
    let la = a.length;
    let lb = b.length;
    let m = la;
    if (lb < m) { m = lb };
    let i = 0;
    while (i < m) {
        let ca = byte_at(a, i);
        let cb = byte_at(b, i);
        if (ca != cb) { return ca - cb };
        i = i + 1;
    };
    la - lb
};

// The path order. See the header for why it has three stages.
def cmp_path(a: str, b: str) -> long {
    let la = a.length;
    let lb = b.length;
    let m = la;
    if (lb < m) { m = lb };
    let i = 0;
    while (i < m) {
        let ca = lower_byte(byte_at(a, i));
        let cb = lower_byte(byte_at(b, i));
        if (ca != cb) { return ca - cb };
        i = i + 1;
    };
    if (la != lb) { return la - lb };
    let k = 0;
    while (k < la) {
        let ra = byte_at(a, k);
        let rb = byte_at(b, k);
        if (ra != rb) { return ra - rb };
        k = k + 1;
    };
    0
};

let CMPS: [Cmp] = [cmp_path, cmp_bytes];

// ── the sorts: bottom-up merge, zero allocation ─────────────────────────

// xs in cmp order. One allocation (the result); the merge runs in SA/SB.
def sort_str(xs: [str], cmp: Cmp) -> [str] {
    let n = len(xs);
    if (n < 2) { return xs };
    let i = 0;
    while (i < n) { SA[i] = xs[i]; i = i + 1; };
    let src = SA;
    let dst = SB;
    let width = 1;
    while (width < n) {
        let lo = 0;
        while (lo < n) {
            let mid = lo + width;
            if (mid > n) { mid = n };
            let hi = mid + width;
            if (hi > n) { hi = n };
            let a = lo;
            let b = mid;
            let k = lo;
            while (k < hi) {
                if (a < mid && (b >= hi || cmp(src[a], src[b]) <= 0)) {
                    dst[k] = src[a];
                    a = a + 1;
                } else {
                    dst[k] = src[b];
                    b = b + 1;
                };
                k = k + 1;
            };
            lo = hi;
        };
        let t = src;
        src = dst;
        dst = t;
        width = width * 2;
    };
    let out: [str] = [];
    let j = 0;
    while (j < n) { out += src[j]; j = j + 1; };
    out
};

// A permutation of 0..n-1 sorted by cmp over indices.  SORT_KEY picks the
// ordering, so one comparator serves all three views.
let SORT_KEY: long = 0;

def ent_cmp(i: long, j: long) -> long {
    let a: Entry = ENT[i];
    let b: Entry = ENT[j];
    let r = 0;
    if (SORT_KEY == 1) {
        r = b.size - a.size;
        if (r == 0) { r = cmp_path(a.path, b.path) };
    } else if (SORT_KEY == 2) {
        r = cmp_path(a.ext, b.ext);
        if (r == 0) { r = cmp_path(a.path, b.path) };
    } else {
        r = cmp_path(a.path, b.path);
    };
    r
};

// The bucket ordering needs its own comparator: ent_cmp reads ENT[i], and
// the extension table is BKT.  Pointing one at the other produces an order
// that is deterministic and meaningless -- which is exactly what a golden
// file would have recorded.
def bkt_cmp(i: long, j: long) -> long {
    let a: Bucket = BKT[i];
    let b: Bucket = BKT[j];
    cmp_path(a.ext, b.ext)
};

let ECMPS: [ICmp] = [ent_cmp];
let BCMPS: [ICmp] = [bkt_cmp];

// The two orderings the report uses, in one place each, so that listing()
// and selftest.y cannot drift apart: a check that re-derived the selection
// would be testing its own copy of it.
def order_paths() -> [long] {
    // --largest switches to size descending with the path order as the
    // tiebreak, so EQUAL SIZES still have one defined order.
    if (OPT_LARGEST > 0) { SORT_KEY = 1 } else { SORT_KEY = 0 };
    sort_idx(N_FILE, ECMPS[0])
};

def order_buckets() -> [long] {
    sort_idx(len(BKT), BCMPS[0])
};

// sort_idx(n, cmp) is sort_perm(0..n-1, cmp): the order the index was
// FOUND in never reaches the comparator, so re-sorting a shuffled
// permutation of an already-sorted set must give the identical answer.
// selftest.y asserts exactly that, because a sort that leaks input order
// still sorts.
def sort_idx(n: long, cmp: ICmp) -> [long] {
    if (n < 1) { return [] };
    let ids: [long] = [];
    let i = 0;
    while (i < n) {
        ids += i;
        i = i + 1;
    };
    sort_perm(ids, cmp)
};

// xs, a permutation of indices, sorted by cmp over indices.  One allocation
// for the copy into IA plus one for the result; the merge itself runs in
// IA/IB, so a sort costs the arena nothing per pass.
def sort_perm(xs: [long], cmp: ICmp) -> [long] {
    let n = len(xs);
    if (n < 1) { return [] };
    let i = 0;
    while (i < n) { IA[i] = xs[i]; i = i + 1; };
    if (n < 2) { return [0] };
    let src = IA;
    let dst = IB;
    let width = 1;
    while (width < n) {
        let lo = 0;
        while (lo < n) {
            let mid = lo + width;
            if (mid > n) { mid = n };
            let hi = mid + width;
            if (hi > n) { hi = n };
            let a = lo;
            let b = mid;
            let k = lo;
            while (k < hi) {
                if (a < mid && (b >= hi || cmp(src[a], src[b]) <= 0)) {
                    dst[k] = src[a];
                    a = a + 1;
                } else {
                    dst[k] = src[b];
                    b = b + 1;
                };
                k = k + 1;
            };
            lo = hi;
        };
        let t = src;
        src = dst;
        dst = t;
        width = width * 2;
    };
    src[0:n]
};

// ── extension table: open addressing, linear probing ────────────────────
//
// Maps in Y are a linear scan (no map_get / map_set), so a per-extension
// index written the obvious way is O(n) per file and O(n^2) per tree.
// 4096 slots, FNV-1a, linear probe, real str comparison in the slot, and
// the probe count exposed so a check can read it instead of trusting it.

let XT_KEY: [str; 4096] = [""; 4096];
let XT_VAL: [long; 4096] = [0; 4096];
let XT_USED: [bool; 4096] = [false; 4096];
let XT_PROBES: long = 0;    // cumulative slots examined, every lookup
let XT_LOOKUPS: long = 0;
let XT_INSERTS: long = 0;
let XT_WASNEW: bool = false;  // the last xt_put created its slot
let XT_FULL: bool = false;    // an insert found no free slot

// The slot holding k, or -1.  Terminates on an empty slot or a full lap,
// which is what makes a saturated table a report instead of a hang.
def xt_find(k: str) -> long {
    let i = fnv_str(k) & 4095;
    let n = 0;
    let found = -1;
    let go = true;
    while (go && n < 4096) {
        XT_PROBES = XT_PROBES + 1;
        if (XT_USED[i]) {
            if (XT_KEY[i] == k) { found = i; go = false; }
            else { i = (i + 1) & 4095; n = n + 1; };
        } else {
            go = false;
        };
    };
    XT_LOOKUPS = XT_LOOKUPS + 1;
    found
};

// The slot for k, inserting if absent.  -1 means FULL.
def xt_put(k: str) -> long {
    let s = xt_find(k);
    XT_WASNEW = false;
    if (s >= 0) { return s };
    let i = fnv_str(k) & 4095;
    let n = 0;
    let placed = -1;
    let go = true;
    while (go && n < 4096) {
        if (XT_USED[i]) { i = (i + 1) & 4095; n = n + 1; }
        else {
            XT_USED[i] = true;
            XT_KEY[i] = k;
            XT_VAL[i] = 0;
            placed = i;
            XT_WASNEW = true;
            XT_INSERTS = XT_INSERTS + 1;
            go = false;
        };
    };
    if (placed < 0) { XT_FULL = true };
    placed
};

def xt_reset() -> long {
    let i = 0;
    while (i < 4096) { XT_USED[i] = false; XT_KEY[i] = ""; XT_VAL[i] = 0; i = i + 1; };
    XT_PROBES = 0;
    XT_LOOKUPS = 0;
    XT_INSERTS = 0;
    XT_FULL = false;
    0
};

def xt_used() -> long {
    let n = 0;
    let i = 0;
    while (i < 4096) { if (XT_USED[i]) { n = n + 1 }; i = i + 1; };
    n
};

// ── visited-directory set: open addressing over int64 keys ──────────────
//
// Keyed on (dev, ino), NOT on the path, which is the point: a symlink loop
// is /a/link -> /a, and the two NAMES differ while the inode does not.  A
// path-keyed set walks straight into it.  The key is compared as a real
// int64 in the slot, so this can never report a false repeat -- a
// hash-only set would, and a false repeat silently drops a whole directory.

let VD_KEY: [long; 65536] = [0; 65536];
let VD_USED: [bool; 65536] = [false; 65536];
let VD_COUNT: long = 0;

def vd_key(dev: long, ino: long) -> long { dev * 1000003 + ino };

// An 8-byte FNV-1a over the key, so all 64 bits of the key take part.
// `>>` (arithmetic) is correct here and `>>>` would be wrong-ish: the mask
// `& 255` runs every pass, so the sign-extension bits never reach a byte.
def vd_hash(k: long) -> long {
    let h = FNV_BASIS;
    let x = k;
    let i = 0;
    while (i < 8) {
        h = fnv_step(h, x & 255);
        x = x >> 8;
        i = i + 1;
    };
    h
};

// true when (dev, ino) was NOT present before and is now.  false means
// either a repeat or a full table; visit_dir distinguishes them by count.
def vd_claim(dev: long, ino: long) -> bool {
    if (VD_COUNT >= 65536) { return false };
    let k = vd_key(dev, ino);
    let i = vd_hash(k) & 65535;
    let n = 0;
    let claimed = false;
    let go = true;
    while (go && n < 65536) {
        if (VD_USED[i]) {
            if (VD_KEY[i] == k) { go = false; }
            else { i = (i + 1) & 65535; n = n + 1; };
        } else {
            VD_USED[i] = true;
            VD_KEY[i] = k;
            VD_COUNT = VD_COUNT + 1;
            claimed = true;
            go = false;
        };
    };
    claimed
};

def vd_reset() -> long {
    let i = 0;
    while (i < 65536) { VD_USED[i] = false; VD_KEY[i] = 0; i = i + 1; };
    VD_COUNT = 0;
    0
};

// ── path helpers ────────────────────────────────────────────────────────

def base_of(p: str) -> str {
    let c = p.last_index_of("/");
    if (c < 0) { p } else { p[c + 1:p.length] }
};

// The extension, lowercased, or "(none)".  A dot at the start of the base
// name (.gitignore) and a trailing dot (README.) are both NOT an extension;
// otherwise everything from the LAST dot is.
//
// The base name is taken HERE rather than left to the caller.  The walk does
// pass base_of()'s result, but this function is exported, and a caller who
// passes a path got ".d/file" for "dir.d/file" -- a defect that S1's rule
// table found, because the rule is stated for names, not for paths.
def ext_of(path: str) -> str {
    let name = base_of(path);
    let dot = -1;
    let i = 0;
    while (i < name.length) {
        if (byte_at(name, i) == 46) { dot = i };
        i = i + 1;
    };
    if (dot > 0 && dot + 1 < name.length) { name[dot + 1:name.length].lower() } else { "(none)" }
};

// A path relative to root, with '/' separators.  "." and "/" are passed
// through: stripping them would name the file by its bare basename, which
// is not what a caller reading a report wants.
def rel_of(full: str, root: str) -> str {
    if (root == "/" || root == "." || root == "") { full }
    else {
        let cut = root.length;
        if (cut > 0 && full[0:cut] == root) { full[cut + 1:full.length] } else { full }
    }
};

def errno_name(e: long) -> str {
    let r = "";
    if (e == 1) { r = "EPERM" }
    else if (e == 2) { r = "ENOENT" }
    else if (e == 13) { r = "EACCES" }
    else if (e == 17) { r = "EEXIST" }
    else if (e == 20) { r = "ENOTDIR" }
    else if (e == 28) { r = "ENOSPC" }
    else if (e == 36) { r = "ENAMETOOLONG" }
    else if (e == 40) { r = "ELOOP" }
    else { r = "errno " + tostring(e) };
    r
};

// ── readdir, without fs.list_dir's 32 KB-per-call buffer ────────────────

// The number of names read into NAMES, or -errno on failure.  One shared
// RBUF: 32 KB of arena for the whole process instead of 32 KB per
// directory.
def read_dirs(path: str) -> long {
    NAMES = [];
    let fd = syscall(257, -100, path, 65536 + 524288, 0);
    if (fd < 0) { return fd };        // already -errno
    let err = 0;
    let go = true;
    while (go) {
        let k = syscall(217, fd, &RBUF[0], 32768);
        if (k < 0) { err = 0 - k; go = false; }
        else if (k == 0) { go = false; }
        else {
            let off = 0;
            while (off + 19 <= k) {
                let reclen = RBUF[off + 16] + 256 * RBUF[off + 17];
                // A reclen that cannot be right (the kernel never writes
                // one, but a zero here would spin for ever) ends the pass.
                if (reclen < 19 || off + reclen > k) { off = k } else {
                    let e = off + 19;
                    while (e < off + reclen && RBUF[e] != 0) { e = e + 1; };
                    let name = from_bytes(RBUF[off + 19:e]);
                    if (name != "." && name != "..") { NAMES += name; };
                    off = off + reclen;
                };
            };
        };
    };
    syscall(3, fd);
    if (err != 0) { return 0 - err };
    len(NAMES)
};

def n_names() -> long { len(NAMES) };

// ── content hashing and first lines ─────────────────────────────────────

// FNV-1a over a file's bytes, streamed through RBUF: hashing a 40 MB file
// costs READ_BUF of arena rather than 40 MB.  0 means unreadable, which
// the walk has already counted.
def hash_file(path: str) -> long {
    let fd = syscall(257, -100, path, 0, 0);
    if (fd < 0) { return 0 };
    let h = FNV_BASIS;
    let go = true;
    while (go) {
        let k = syscall(0, fd, &RBUF[0], 32768);
        if (k <= 0) { go = false; }
        else {
            let i = 0;
            while (i < k) { h = fnv_step(h, RBUF[i]); i = i + 1; };
        };
    };
    syscall(3, fd);
    h
};

// The first line of path, cut to `cols` columns, tabs and non-printables
// shown as '.'.  Sets HEAD_FLAGS: bit 0 = binary (a NUL in the first 256
// bytes), bit 1 = the first line had no newline.  A binary file and a file
// whose only line has no newline are both ORDINARY cases here: a marker
// and a flag bit, never an error and never a trap.
def head_of(path: str, cols: long) -> str {
    HEAD_FLAGS = 0;
    let fd = syscall(257, -100, path, 0, 0);
    if (fd < 0) { HEAD_FLAGS = 4; return "<unreadable>" };
    let got = syscall(0, fd, &RBUF[0], 256);
    syscall(3, fd);
    if (got < 0) { HEAD_FLAGS = 4; return "<unreadable>" };
    if (got == 0) { HEAD_FLAGS = 8; return "<empty>" };
    let n = got;
    let flags = 0;
    let stop = n;
    let bin = false;
    let i = 0;
    while (i < n) {
        if (RBUF[i] == 0) { bin = true };
        if (RBUF[i] == 10) { stop = i; i = n; } else { i = i + 1; };
    };
    if (bin) { flags = flags + 1 };
    if (stop == n) { flags = flags + 2 };
    HEAD_FLAGS = flags;
    if (bin) { return "<binary>" };
    let cut = stop;
    if (cols > 0 && cut > cols) { cut = cols };
    let out: str = "";
    let j = 0;
    while (j < cut) {
        let c = RBUF[j];
        if (c == 9) { out += " " } else if (c < 32 || c > 126) { out += "." } else { out += from_bytes(RBUF[j:j + 1]) };
        j = j + 1;
    };
    if (cut > 0 && RBUF[cut - 1] == 13) { out = out[0:out.length - 1] };
    out
};

// ── the walk ────────────────────────────────────────────────────────────

def note(s: str) -> long { DIAG += s; len(DIAG) };

def warn_once(p: str, why: str) -> long {
    let dup = false;
    let i = 0;
    while (i < len(WARNED)) {
        if (WARNED[i] == p) { dup = true; i = len(WARNED) } else { i = i + 1; };
    };
    if (!dup) {
        WARNED += p;
        note(p + ": " + why);
    };
    0
};

def clear() -> long {
    ENT = [];
    BKT = [];
    NAMES = [];
    DIAG = [];
    WARNED = [];
    N_DIR = 0;
    N_FILE = 0;
    N_LINK = 0;
    N_OTHER = 0;
    N_UNREAD = 0;
    N_BYTES = 0;
    N_CYCLE = 0;
    N_CAP = 0;
    HEAD_FLAGS = 0;
    xt_reset();
    vd_reset();
    0
};

def add_entry(full: str, rel: str, size: long) -> long {
    if (N_FILE >= 65536) {
        N_CAP = N_CAP + 1;
        if (N_CAP == 1) { note("file cap of " + tostring(65536) + " reached; the rest of the tree was not indexed") };
        return 0;
    };
    let ex = ext_of(base_of(rel));
    let hv = 0;
    if (WANT_HASH) { hv = hash_file(full) };
    let hd = "";
    let fl = 0;
    if (HEAD_COLS > 0) {
        hd = head_of(full, HEAD_COLS);
        fl = HEAD_FLAGS;
    };
    ENT += { path: rel, ext: ex, size: size, hash: hv, head: hd, flags: fl };
    N_FILE = N_FILE + 1;
    N_BYTES = N_BYTES + size;
    let slot = xt_put(ex);
    if (slot >= 0 && XT_WASNEW) {
        BKT += { ext: ex, nfiles: 0, nbytes: 0, biggest: -1, bpath: "" };
        XT_VAL[slot] = len(BKT) - 1;
    };
    if (slot >= 0) {
        let bi = XT_VAL[slot];
        let b: Bucket = BKT[bi];
        b.nfiles = b.nfiles + 1;
        b.nbytes = b.nbytes + size;
        if (size > b.biggest) {
            b.biggest = size;
            b.bpath = rel;
        };
    };
    0
};

def push(d: str, depth: long) -> long {
    if (SP >= 8192) {
        N_CAP = N_CAP + 1;
        if (N_CAP == 1) { note("directory stack cap of 8192 reached; the rest of the tree was not walked") };
        return 0;
    };
    STK[SP] = d;
    SKD[SP] = depth;
    SP = SP + 1;
    0
};

def lmode(path: str) -> long {
    if (syscall(262, -100, path, &ST[0], 256) != 0) { -1 } else { ST[3] & 4294967295 }
};

def smode(path: str) -> long {
    if (syscall(262, -100, path, &ST[0], 0) != 0) { -1 } else { ST[3] & 4294967295 }
};

def ssize(path: str) -> long {
    if (syscall(262, -100, path, &ST[0], 0) != 0) { 0 } else { ST[6] }
};

// One child name.  lstat FIRST, so a symlink is a symlink and is never
// mistaken for its target; FOLLOW then decides what to do with it.
def visit_child(child: str, rel: str, depth: long) -> long {
    let m = lmode(child);
    if (m < 0) {
        N_UNREAD = N_UNREAD + 1;
        warn_once(child, "cannot stat");
        return 0;
    };
    let ty = m & S_IFMT;
    if (ty == S_IFLNK) {
        N_LINK = N_LINK + 1;
        if (!FOLLOW) { return 0 };
        let t = smode(child);
        if (t < 0) {
            N_UNREAD = N_UNREAD + 1;
            warn_once(child, "dangling symlink");
        } else if ((t & S_IFMT) == S_IFDIR) {
            push(child, depth + 1);
        } else if ((t & S_IFMT) == S_IFREG) {
            add_entry(child, rel, ssize(child));
        } else {
            N_OTHER = N_OTHER + 1;
            warn_once(child, "symlink to a non-regular file");
        };
        0
    } else if (ty == S_IFDIR) {
        push(child, depth + 1);
        0
    } else if (ty == S_IFREG) {
        add_entry(child, rel, ssize(child));
        0
    } else {
        N_OTHER = N_OTHER + 1;
        warn_once(child, "not a regular file");
        0
    }
};

def visit_dir(d: str, depth: long) -> long {
    N_DIR = N_DIR + 1;
    if (syscall(262, -100, d, &ST[0], 0) != 0) {
        N_UNREAD = N_UNREAD + 1;
        warn_once(d, "cannot stat");
        return 0;
    };
    let dev = ST[0];
    let ino = ST[1];
    if (VD_COUNT < 65536 && !vd_claim(dev, ino)) {
        N_CYCLE = N_CYCLE + 1;
        if (N_CYCLE <= 4) { note(d + ": already visited (dev " + tostring(dev) + " ino " + tostring(ino) + "); not descended") };
        return 0;
    };
    let n = read_dirs(d);
    if (n < 0) {
        N_UNREAD = N_UNREAD + 1;
        warn_once(d, "cannot list (" + errno_name(0 - n) + ")");
        return 0;
    };
    // Sorted with OUR comparator, not fs.list_dir's bare `s <= t`: the
    // order the walk visits in is an order --check has properties for.
    let names = sort_str(NAMES, CMPS[0]);
    let i = 0;
    while (i < n) {
        let child = d + "/" + names[i];
        visit_child(child, rel_of(child, ROOT), depth + 1);
        i = i + 1;
    };
    0
};

// Walk root.  0 = indexed (possibly with warnings), 2 = no such path,
// 3 = not a directory.
def walk(root: str) -> long {
    clear();
    ROOT = root;
    let m = smode(root);
    if (m < 0) { return 2 };
    if ((m & S_IFMT) != S_IFDIR) { return 3 };
    push(root, 0);
    while (SP > 0) {
        SP = SP - 1;
        let d = STK[SP];
        let dep = SKD[SP];
        if (dep > DEPTH_CAP) {
            N_CAP = N_CAP + 1;
            if (N_CAP == 1) { note("depth cap of " + tostring(DEPTH_CAP) + " reached at " + d) };
        } else {
            visit_dir(d, dep);
        };
    };
    0
};

// ── the report ──────────────────────────────────────────────────────────
//
// Every line is appended to one `str` and printed once.  Every `+=` below is
// in DISCARDED position -- inside braces, with the `;` INSIDE them -- which is
// what keeps `s += t` amortised O(1).  The `;` has to be inside the block: a
// `;` after the closing brace discards the block's value without making its
// last statement discarded, and the append turns quadratic with byte-identical
// output.  See the `str +=` heading in examples/BUGS.md; the -S audit that
// checks it is in README.md under "the quadratic audit".

def hdr(out: str, k: str, v: str) -> str {
    // padl the LABEL, not the accumulator: padl(out, 12) pads the whole
    // report-so-far to 12 columns, which is a no-op once the report is longer
    // than twelve characters -- and that is how the first draft of this
    // printed every header label glued to its value.
    out += paint(C_BOLD, padl(k, 11));
    out += v;
    out += "\n";
    out
};

// The per-extension aggregate table.  The buckets are in HASH TABLE SLOT
// ORDER -- deterministic, but a function of the hash rather than of anything
// a reader can predict -- so they are sorted by extension before printing.
// There is no map iteration order to inherit here, and slot order would be
// one more thing a hash change could move without anyone noticing.
def ext_table(out: str) -> str {
    let ord = order_buckets();
    out += paint(C_BOLD, padl("ext", 14));
    out += paint(C_BOLD, padl("files", 7));
    out += paint(C_BOLD, padl("bytes", 11));
    out += paint(C_BOLD, padl("largest", 10));
    out += paint(C_BOLD, "path\n");
    let i = 0;
    while (i < len(ord)) {
        let b: Bucket = BKT[ord[i]];
        out += paint(C_CYAN, padl(b.ext, 14));
        out += f"{b.nfiles:>7}";
        out += f"{b.nbytes:>11}";
        out += f"{b.biggest:>10}";
        out += "  ";
        out += b.bpath;
        out += "\n";
        i = i + 1;
    };
    out += "extensions  " + tostring(len(ord)) + " of " + tostring(len(BKT)) + "\n";
    out
};

def wanted(e: Entry) -> bool {
    if (OPT_EXT != "" && e.ext != OPT_EXT) { false }
    else if (OPT_FIND != "" && e.path.index_of(OPT_FIND) < 0) { false }
    else { true }
};

def listing(out: str) -> str {
    // --largest switches the ordering to size descending with the path order
    // as the tiebreak, so EQUAL SIZES still have one defined order rather
    // than whatever order the walk happened to produce.
    if (OPT_LARGEST > 0) { SORT_KEY = 1 } else { SORT_KEY = 0 };
    let ord = sort_idx(N_FILE, ECMPS[0]);
    let limit = N_FILE;
    if (OPT_LARGEST > 0 && OPT_LARGEST < limit) { limit = OPT_LARGEST };
    out += paint(C_BOLD, padl("size", 6));
    out += paint(C_BOLD, padl("hash", 20));
    out += paint(C_BOLD, padl("ext", 7));
    out += paint(C_BOLD, "path");
    if (HEAD_COLS > 0) { out += paint(C_BOLD, "  first line") };
    out += "\n";
    let shown = 0;
    let i = 0;
    while (i < limit) {
        let e: Entry = ENT[ord[i]];
        if (wanted(e)) {
            out += f"{e.size:>6}";
            // EVERY append inside an `if` arm carries its `;` INSIDE the
            // braces.  With it outside -- `if (c) { out += x } else { ... };`
            // -- the append is value-used, the fast in-place path is lost, and
            // the whole loop becomes O(n^2) in heap with byte-identical
            // output.  That is the filed `str +=` in a value-used position
            // bug (examples/BUGS.md); the fix it names is exactly this, and
            // the -S audit plus a heap measurement are in README.md.
            if (WANT_HASH) { out += "0x" + hex16(e.hash) + "  "; } else { out += "                    "; };
            out += paint(C_CYAN, padl(e.ext, 7));
            out += e.path;
            if (HEAD_COLS > 0) {
                out += "  ";
                // bit 1 of flags: the first line had no newline.  Shown
                // rather than guessed at, because the two cases are
                // indistinguishable in the bytes and the reader wants to
                // know which one it is.
                if ((e.flags & 2) != 0) { out += paint(C_DIM, "[no newline] "); };
                out += e.head;
            };
            out += "\n";
            shown = shown + 1;
        };
        i = i + 1;
    };
    if (shown == N_FILE) { out += tostring(shown) + " files\n"; }
    else { out += tostring(shown) + " of " + tostring(N_FILE) + " files\n"; };
    out
};

def report() -> str {
    let out: str = "";
    out = hdr(out, "indexer", "1.0");
    out = hdr(out, "root", ROOT);
    out = hdr(out, "entries",
        tostring(N_DIR) + " dirs, " + tostring(N_FILE) + " files, "
        + tostring(N_BYTES) + " bytes, " + tostring(N_LINK) + " symlinks, "
        + tostring(N_UNREAD) + " unreadable, " + tostring(N_CAP) + " capped");
    out = hdr(out, "hash", if (WANT_HASH) { "fnv1a-64" } else { "off" });
    out = hdr(out, "order", if (OPT_LARGEST > 0) { "size desc, path breaks ties" } else { "path: case-folded, raw bytes break ties" });
    out = hdr(out, "symlinks", if (FOLLOW) { "followed, (dev,ino) cycle guard" } else { "not followed" });
    out = hdr(out, "view",
        "head " + tostring(HEAD_COLS) + " cols, strict " + yn(STRICT)
        + (if (OPT_EXT != "") { ", ext " + OPT_EXT } else { "" })
        + (if (OPT_FIND != "") { ", find " + OPT_FIND } else { "" }));
    out += "\n";
    out = ext_table(out);
    out += "\n";
    out = listing(out);
    out
};

// The report with the diagnostics folded in, which is what the CLI prints.
// report() alone is what the property check compares, so a warning cannot
// make the idempotence check pass by hiding a difference.
def report_with_diag() -> str {
    let out = report();
    let i = 0;
    while (i < len(DIAG)) {
        out += "warning  " + DIAG[i] + "\n";
        i = i + 1;
    };
    out
};

export { Entry, Bucket, Cmp, ICmp, XT_CAP, VD_CAP, SORT_CAP, MAX_FILES, MAX_DEPTH,
         ENT, BKT, NAMES, DIAG, N_DIR, N_FILE, N_LINK, N_OTHER, N_UNREAD, N_BYTES,
         N_CYCLE, N_CAP, HEAD_FLAGS, ROOT, FOLLOW, WANT_HASH, HEAD_COLS, DEPTH_CAP,
         COLOR, CMPS, ECMPS, SORT_KEY,
         FNV_BASIS, FNV_PRIME, fnv_str, hex16, lower_byte, cmp_bytes, cmp_path,
         sort_str, sort_idx, sort_perm, ent_cmp, base_of, ext_of, rel_of, errno_name,
         hash_file, head_of, read_dirs, n_names, lmode, smode, ssize,
         xt_find, xt_put, xt_reset, xt_used, XT_PROBES, XT_LOOKUPS, XT_INSERTS, XT_FULL,
         vd_claim, vd_reset, VD_COUNT, walk, clear, add_entry, note, warn_once };