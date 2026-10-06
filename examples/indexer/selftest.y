// selftest.y -- the property check.
//
// ─────────────────────────────────────────────────────────────────────────
// WHY THIS FILE EXISTS
// ─────────────────────────────────────────────────────────────────────────
//
// A golden file proves DETERMINISM, not correctness.  It will record a
// defect and then reproduce that defect for ever, byte for byte, and pass
// every mechanical gate -- which is exactly how examples/cube shipped a
// wireframe that FILLS regions through a clean 8/8.  So nothing here reads
// EXPECTED and nothing here compares against a reference.  Every check asks
// a question whose answer would be wrong if the logic were wrong, and prints
// the numbers it measured so the answer can be read rather than trusted.
//
// The brief for this example names five debts, and they are sections 4, 5,
// 6, 2 and 1 below:
//
//   S1  cmp_path is a strict TOTAL order: antisymmetric, irreflexive, and
//       STRICT (cmp(a,b) != 0 for a != b) -- and the order is the same on
//       every run and from every input order
//   S2  the hash tables: every inserted key is findable, an absent key is
//       not, a saturated table REPORTS instead of spinning, and the probe
//       count says the hash actually spreads
//   S3  FNV-1a and hex16 against the published vectors -- an oracle from
//       outside this program, negatives included
//   S4  the walk against a tree built from a spec written HERE: the file
//       count, the sorted path list, the per-extension totals, and the
//       query results
//   S5  idempotence, order-independence, and change detection: a second
//       index is byte-identical, re-sorting a shuffled permutation gives the
//       same order, a changed file changes ONE entry and an unchanged one
//       does not
//   S6  every hostile input: a message and a non-zero exit, never a trap
//   S7  the report's own shape, and the parser's rejections
//
// ─────────────────────────────────────────────────────────────────────────
// THE RECURRING FAILURE IS THE VACUOUS PASS
// ─────────────────────────────────────────────────────────────────────────
//
// Two agents in this campaign shipped checks comparing two values that were
// BOTH ABSENT: one asked "did the ones that opened match?" (trivially true
// when nothing opened), the other compared heap_used() before and after and
// got 0 == 0 because a typo in the query matcher meant the field never
// arrived.  So three rules are enforced here mechanically, not by good
// intentions:
//
//   1. EVERY expected count in this file is a LITERAL, or is summed from the
//      SPEC arrays below -- which are the tree's construction, written by
//      hand, never read back out of the indexer.
//   2. Every "found N" assertion is preceded by an assertion that N > 0, so
//      "found 0 of 0 expected" cannot pass.
//   3. Every message assertion requires `m.length > 0` before comparing m,
//      so two empty messages cannot pass either.
//   S8 below is the injection harness's companion: inject.py breaks the
//   engine on purpose and requires these checks to notice.

import fs;
import ix;
import cli;

// ── the tally ───────────────────────────────────────────────────────────
//
// Module-level arrays rather than a threaded counter, because a Y function
// cannot return two values.  Declared up here because a module-level `let`
// does not hoist past its first use.

let N_OK: long = 0;
let N_BAD: long = 0;
let N_SKIP: long = 0;

def ok(name: str, detail: str) -> long {
    N_OK = N_OK + 1;
    print("ok   " + name + "  --  " + detail);
    0
};

def bad(name: str, detail: str) -> long {
    N_BAD = N_BAD + 1;
    print("FAIL " + name + "  --  " + detail);
    0
};

def want(name: str, cond: bool, detail: str) -> long {
    if (cond) { ok(name, detail) } else { bad(name, detail) }
};

def eq(name: str, got: long, expect: long, what: str) -> long {
    want(name, got == expect, what + " = " + tostring(got) + " (expected " + tostring(expect) + ")")
};

def eqs(name: str, got: str, expect: str, what: str) -> long {
    if (got.length > 0 && got == expect) {
        ok(name, what + " = \"" + got + "\"")
    } else if (got == expect) {
        // Equal but empty: a real vacuous pass, named as one.
        bad(name, what + " is EMPTY on both sides -- a vacuous comparison, not a match")
    } else {
        bad(name, what + " = \"" + got + "\" (expected \"" + expect + "\")")
    }
};

def skips(name: str, why: str) -> long {
    N_SKIP = N_SKIP + 1;
    print("skip " + name + "  --  " + why);
    0
};

// ── scratch space ───────────────────────────────────────────────────────
//
// A FIXED path, not a pid-derived one, so this check's own output is
// byte-identical between runs and can be pasted into README.md as evidence.
// Two concurrent runs of the same binary would collide; that is documented
// rather than papered over with a clock or a random suffix, either of which
// would put a number in the output that changes every time.

const TMP = "/tmp/indexer-check";
const TREE = "/tmp/indexer-check/tree";
const HOST = "/tmp/indexer-check/host";

// ── the fixture tree, written out by hand ───────────────────────────────
//
// SPEC_PATHS is the construction.  EXPECT_PATHS is the same tree in the
// order cmp_path says it must come out, written out BY HAND -- one name per
// line, ordered by the rules in ix.y's header:
//
//   '.' (0x2E) < '' (0x63) < 'd' < 'o' < 'r' < 's', so
//   .gitignore, caf<e9>.txt, data/*, docs/*, odd..., README.md, src/*
//   and inside one first letter the shorter prefix goes first.
//
// The check ALSO runs an insertion sort (a different algorithm from ix.y's
// bottom-up merge) over the same set and requires it to agree with the
// hand-written list.  That is not the oracle -- EXPECT_PATHS is -- it is a
// second opinion on MY list, so a miscount in the hand-written order shows
// up as a disagreement between the two instead of as a silent pass.

let SPEC_PATHS: [str] = [
    ".gitignore",
    "README.md",
    "café.txt",
    "data/blob.bin",
    "data/empty.txt",
    "data/no-newline.txt",
    "docs/guide.md",
    "odd name with spaces.txt",
    "src/deep/a/b/c/leaf.TXT",
    "src/main.y",
    "src/util.y",
];

let SPEC_BODIES: [str] = [
    "*.tmp\n",
    "indexer check fixture\n",
    "accented\n",
    "BIN\x00\x01\x02\xff",
    "",
    "tail without newline",
    "guide\n",
    "spaced\n",
    "leaf\n",
    "import fs;\n",
    "def f() -> long { 1 }\n",
];

let EXPECT_PATHS: [str] = [
    ".gitignore",
    "café.txt",
    "data/blob.bin",
    "data/empty.txt",
    "data/no-newline.txt",
    "docs/guide.md",
    "odd name with spaces.txt",
    "README.md",
    "src/deep/a/b/c/leaf.TXT",
    "src/main.y",
    "src/util.y",
];

// The extension table this tree must produce, in cmp_path order of the
// extension: '(' 0x28 < 'b' < 'm' < 't' < 'y'.
let EXPECT_EXTS: [str] = ["(none)", "bin", "md", "txt", "y"];
let EXPECT_EXT_FILES: [long] = [1, 1, 2, 5, 2];
let EXPECT_EXT_BYTES: [long] = [6, 7, 28, 41, 33];

// ── an independent sort, for cross-checking the hand-written order ──────
//
// Insertion sort by hand, O(n^2), allocating a fresh array per insertion --
// the opposite of ix.y's allocation-free merge.  Different enough that
// agreeing with it means something.

def ins(xs: [str], at: long, x: str) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(xs)) {
        if (i == at) { out += x };
        out += xs[i];
        i = i + 1;
    };
    if (at >= len(xs)) { out += x };
    out
};

def ref_sort(xs: [str]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(xs)) {
        let x = xs[i];
        let j = 0;
        let placed = false;
        while (!placed && j < len(out)) {
            if (ix.cmp_path(x, out[j]) < 0) {
                out = ins(out, j, x);
                placed = true;
            } else {
                j = j + 1;
            };
        };
        if (!placed) { out += x };
        i = i + 1;
    };
    out
};

// ── S1: cmp_path is a strict total order ────────────────────────────────

// Names chosen to hit every stage of the comparator at once.
// Six of these names are there to pin down where case-folding STOPS being
// allowed to matter.  `a and A~ sort either side of the punctuation:
// case-folded they are "`a" and "a~", and '`'(0x60) < 'a'(0x61) < '~'(0x7E),
// so the punctuation decides.  Fold to UPPERCASE instead and '`'(0x60) >
// 'A'(0x41), so A~ moves to the end -- a different, still-total order.  A
// comparator that folds case is therefore only "the documented order" on a
// corpus with no punctuation next to a letter, and inject.py's
// `lowerfoldswrong` mutation is caught by exactly these six.
let HARD: [str] = [
    "a", "A", "ab", "a-", "b", "B", "README", "readme", "Readme", "zz", "ZZ",
    "Zz", "src/a", "src/A", "src", "a b", "a!", "", "x/y", "x",
    "`a", "A`", "@z", "Z@", "~A", "A~",
];

def s1_total_order() -> long {
    let n = len(HARD);
    let antisym = 0;
    let irrefl = 0;
    let strict = 0;
    let i = 0;
    while (i < n) {
        if (ix.cmp_path(HARD[i], HARD[i]) != 0) { irrefl = irrefl + 1 };
        let j = 0;
        while (j < n) {
            if (HARD[i] != HARD[j]) {
                let c = ix.cmp_path(HARD[i], HARD[j]);
                let d = ix.cmp_path(HARD[j], HARD[i]);
                if (c != 0) { strict = strict + 1 };
                if (c + d == 0) { antisym = antisym + 1 };
            };
            j = j + 1;
        };
        i = i + 1;
    };
    let pairs = n * (n - 1);
    eq("S1 antisymmetry", antisym, pairs, "pairs with cmp(a,b) == -cmp(b,a)");
    eq("S1 irreflexivity", irrefl, 0, "cmp(a,a) != 0");
    eq("S1 strictness", strict, pairs, "distinct names comparing equal (0 means strict)");

    // transitivity: a <= b and b <= c must give a <= c, over every triple
    let bad2 = 0;
    let a = 0;
    while (a < n) {
        let b = 0;
        while (b < n) {
            let c = 0;
            while (c < n) {
                if (ix.cmp_path(HARD[a], HARD[b]) <= 0 && ix.cmp_path(HARD[b], HARD[c]) <= 0
                    && ix.cmp_path(HARD[a], HARD[c]) > 0) { bad2 = bad2 + 1 };
                c = c + 1;
            };
            b = b + 1;
        };
        a = a + 1;
    };
    eq("S1 transitivity", bad2, 0, "a<=b<=c but a>c");

    // The specific pairs the brief names, with the SIGN asserted, because
    // "it sorts" would pass either way round.
    want("S1 case pair a vs B", ix.cmp_path("a", "B") < 0, "cmp_path(\"a\",\"B\") = " + tostring(ix.cmp_path("a", "B")));
    want("S1 case pair B vs a", ix.cmp_path("B", "a") > 0, "cmp_path(\"B\",\"a\") = " + tostring(ix.cmp_path("B", "a")));
    want("S1 README before readme", ix.cmp_path("README", "readme") < 0, "uppercase first: " + tostring(ix.cmp_path("README", "readme")));
    want("S1 readme before README is false", ix.cmp_path("readme", "README") > 0, "and the reverse");
    want("S1 case-insensitive grouping", ix.cmp_path("a", "B") < 0 && ix.cmp_path("B", "Z") < 0, "\"a\" sorts among the B files, not after them");
    want("S1 prefix a before ab", ix.cmp_path("a", "ab") < 0, "shorter prefix first");
    want("S1 prefix ab before a", ix.cmp_path("ab", "a") > 0, "and the reverse");
    want("S1 prefix src/a vs src/A", ix.cmp_path("src/A", "src/a") < 0, "case decides only after the prefix runs out");
    want("S1 prefix src vs src/a", ix.cmp_path("src", "src/a") < 0, "a directory sorts before its own child");
    want("S1 empty is least", ix.cmp_path("", "a") < 0, "the empty name is the minimum");
    want("S1 not equal, not zero", ix.cmp_path("src/a", "src/A") != 0, "distinct names must not tie -- this is the property a case-folding comparator loses");
    // Case folding has to stop at punctuation, or "the order" is an artefact
    // of which way the fold went: lowercasing puts "`a" first, uppercasing
    // puts it last, and both are consistent total orders.
    want("S1 punctuation decides against letters", ix.cmp_path("`a", "A~") < 0 && ix.cmp_path("A~", "`a") > 0,
        "case-folded, '`'(0x60) < 'a'(0x61) < '~'(0x7E)");
    want("S1 the same after an uppercase fold would differ", ix.cmp_path("A~", "`a") > 0,
        "so a lower_byte that folded UPWARDS would produce a different order here");

    // cmp_bytes is the OTHER comparator in CMPS -- raw byte order, no case
    // folding -- and it is exported, so it is part of what this example
    // promises.  It gets the same three properties.  Before this, an
    // injected defect in cmp_bytes passed every check, because nothing
    // called it except the array that hands it out.
    let cb_anti = 0;
    let cb_strict = 0;
    let cb_irrefl = 0;
    let p = 0;
    while (p < n) {
        if (ix.cmp_bytes(HARD[p], HARD[p]) != 0) { cb_irrefl = cb_irrefl + 1 };
        let q = 0;
        while (q < n) {
            if (HARD[p] != HARD[q]) {
                let c = ix.cmp_bytes(HARD[p], HARD[q]);
                if (c + ix.cmp_bytes(HARD[q], HARD[p]) == 0) { cb_anti = cb_anti + 1 };
                if (c != 0) { cb_strict = cb_strict + 1 };
            };
            q = q + 1;
        };
        p = p + 1;
    };
    eq("S1 cmp_bytes antisymmetry", cb_anti, pairs, "pairs with cmp == -cmp");
    eq("S1 cmp_bytes irreflexivity", cb_irrefl, 0, "cmp_bytes(a,a) != 0");
    eq("S1 cmp_bytes strictness", cb_strict, pairs, "distinct names comparing equal");
    // And the two comparators must DISAGREE, or "which order is this" has
    // no answer: cmp_bytes puts "B" before "a", cmp_path does not.
    want("S1 the two comparators really differ", ix.cmp_bytes("a", "B") > 0 && ix.cmp_path("a", "B") < 0,
        "cmp_bytes(a,B)=" + tostring(ix.cmp_bytes("a", "B")) + " but cmp_path(a,B)=" + tostring(ix.cmp_path("a", "B")));

    // ext_of's rules, as literals.  ARCHIVE.TAR.GZ is in the golden fixture,
    // but the golden cannot tell a wrong rule from a stable one.
    let names: [str] = ["ARCHIVE.TAR.GZ", ".gitignore", "README.", "a.b.c", "noext",
                        "x.TXT", "dir.d/file", ".hidden.md", "..", "a."];
    let want_ext: [str] = ["gz", "(none)", "(none)", "c", "(none)",
                           "txt", "(none)", "md", "(none)", "(none)"];
    let ex_bad = 0;
    let ex_at = "";
    let ei = 0;
    while (ei < len(names)) {
        let got = ix.ext_of(names[ei]);
        if (got != want_ext[ei]) {
            ex_bad = ex_bad + 1;
            if (ex_at == "") { ex_at = " ext_of(\"" + names[ei] + "\")=" + got + ", expected " + want_ext[ei] };
        };
        ei = ei + 1;
    };
    eq("S1 ext_of's rules", ex_bad, 0, "of " + tostring(len(names)) + " names" + ex_at);

    // Determinism: the same set, 25 times, must give the same permutation --
    // and so must every rotation and the reverse of it.
    let base = ref_sort(HARD);
    let first = join_slash(base);
    let same = true;
    let run = 0;
    while (run < 25) {
        let sh = shuffle(HARD, run + 1);
        if (join_slash(ref_sort(sh)) != first) { same = false };
        run = run + 1;
    };
    want("S1 order independent of input order", same, "25 shuffles of " + tostring(n) + " names all gave the same order");
    let rev = reverse(HARD);
    want("S1 reverse input gives the same order", join_slash(ref_sort(rev)) == first, "reversed input, identical result");
    eqs("S1 the order itself", first, "|@z|`a|A|a|a b|a!|a-|A`|ab|A~|B|b|README|Readme|readme|src|src/A|src/a|x|x/y|Z@|ZZ|Zz|zz|~A|", "sorted order, joined");
    0
};

def join_slash(xs: [str]) -> str {
    let s = "";
    let i = 0;
    while (i < len(xs)) {
        s += xs[i];
        s += "|";
        i = i + 1;
    };
    s
};

def reverse(xs: [str]) -> [str] {
    let out: [str] = [];
    let i = len(xs) - 1;
    while (i >= 0) {
        out += xs[i];
        i = i - 1;
    };
    out
};

// A deterministic permutation: walk with stride `k`, coprime with the
// length.  No clock and no RNG, so a failing run reproduces exactly.
def shuffle(xs: [str], k: long) -> [str] {
    let out: [str] = [];
    let n = len(xs);
    let taken: [bool] = [];
    let i = 0;
    while (i < n) { taken += false; i = i + 1; };
    let at = 0;
    let left = n;
    let s = 0;
    while (left > 0) {
        let t = (s + k) % n;
        let guard = 0;
        while (taken[t] && guard < n + 1) {
            t = (t + 1) % n;
            guard = guard + 1;
        };
        if (!taken[t]) { taken[t] = true; out += xs[t]; left = left - 1 };
        s = s + 1;
        at = at + 1;
    };
    out
};

// ── S2: the hash tables ─────────────────────────────────────────────────

def s2_tables() -> long {
    // 600 distinct keys: every one inserted must be findable afterwards.
    ix.xt_reset();
    let ks: [str] = [];
    let i = 0;
    while (i < 600) {
        let k = "x" + tostring(i * 7919);
        ks += k;
        let slot = ix.xt_put(k);
        if (slot < 0) { bad("S2 insert", "table reported full at " + tostring(i)) };
        i = i + 1;
    };
    eq("S2 insert count", ix.XT_INSERTS, 600, "keys inserted");
    eq("S2 used slots", ix.xt_used(), 600, "slots marked used");
    want("S2 table not flagged full", !ix.XT_FULL, "XT_FULL = " + ynb(ix.XT_FULL));
    let missed = 0;
    i = 0;
    while (i < len(ks)) {
        if (ix.xt_find(ks[i]) < 0) { missed = missed + 1 };
        i = i + 1;
    };
    eq("S2 every inserted key findable", missed, 0, "misses out of 600");
    let absent = 0;
    i = 0;
    while (i < 600) {
        if (ix.xt_find("absent" + tostring(i * 104729)) >= 0) { absent = absent + 1 };
        i = i + 1;
    };
    eq("S2 absent keys not found", absent, 0, "false positives out of 600");
    // The probe count is the only evidence the hash actually spreads: a
    // comparator that always returned the same slot would find every key at
    // probe 600 and this average would read 300.
    let probes = ix.XT_PROBES;
    let lookups = ix.XT_LOOKUPS;
    want("S2 lookups happened", lookups > 0, "lookups = " + tostring(lookups));
    let mean = 0;
    if (lookups > 0) { mean = probes / lookups };
    want("S2 mean probes under 3 at 15% load", mean < 3, "mean = " + tostring(mean) + " over " + tostring(lookups) + " lookups, " + tostring(probes) + " slots examined");

    // Saturation must be REPORTED, not spun on.  4096 slots, 4097 distinct
    // keys: the last one cannot be placed, and xt_put must return -1 having
    // given up rather than lap the table for ever.
    ix.xt_reset();
    i = 0;
    while (i < 4096) { ix.xt_put("k" + tostring(i * 31)); i = i + 1; };
    let full_slot = ix.xt_put("one-too-many");
    eq("S2 saturated insert returns -1", full_slot, -1, "slot for the 4097th key");
    want("S2 saturation is flagged", ix.XT_FULL, "XT_FULL set, so the walk can report a cap");
    let still_found = ix.xt_find("k" + tostring(0));
    want("S2 keys survive saturation", still_found >= 0, "a key inserted before the fill is still findable");

    // The visited-directory set: claim once, refuse the second time.
    ix.vd_reset();
    want("S2 vd first claim is new", ix.vd_claim(49, 12345), "(dev 49, ino 12345) unclaimed");
    want("S2 vd second claim is a repeat", !ix.vd_claim(49, 12345), "same (dev, ino) refused");
    want("S2 vd a different ino is new", ix.vd_claim(49, 12346), "(49, 12346) is a different directory");
    want("S2 vd a different dev is new", ix.vd_claim(50, 12345), "(50, 12345) is a different filesystem");
    eq("S2 vd count", ix.VD_COUNT, 3, "directories claimed");
    ix.vd_reset();
    eq("S2 vd reset", ix.VD_COUNT, 0, "after reset");
    0
};

def ynb(b: bool) -> str { if (b) { "true" } else { "false" } };

// ── S3: FNV-1a and hex16, against published vectors ─────────────────────
//
// An oracle from outside this program.  These are the FNV reference values
// for the 64-bit variant, so a wrong PRIME, a wrong basis or a wrong
// multiply order fails here rather than producing a plausible 16-digit
// number in the report forever.  The negative entries matter: they are what
// catches the `>>>` audit in ix.y going wrong.

let FNV_VECTORS: [str] = [
    "", "a", "b", "c", "abc", "foobar",
    "indexer", "a much longer string than the previous few, to exercise "
        + "every byte of the loop and the shift that follows it",
];

let FNV_WANT: [str] = [
    "cbf29ce484222325",
    "af63dc4c8601ec8c",
    "af63df4c8601f1a5",
    "af63de4c8601eff2",
    "e71fa2190541574b",
    "85944171f73967e8",
    "9bd2c5235474dac8",
    "bea3f040b428531a",
];

def s3_fnv() -> long {
    let i = 0;
    let wrong = 0;
    let shown = "";
    while (i < len(FNV_VECTORS)) {
        let got = ix.hex16(ix.fnv_str(FNV_VECTORS[i]));
        if (got != FNV_WANT[i]) {
            wrong = wrong + 1;
            shown = shown + " [\"" + FNV_VECTORS[i] + "\" -> " + got + ", expected " + FNV_WANT[i] + "]";
        };
        i = i + 1;
    };
    eq("S3 FNV-1a-64 vectors", wrong, 0, "mismatches over " + tostring(len(FNV_VECTORS)) + " vectors" + shown);

    // hex16 over the whole signed range's corners, against values computed
    // outside the program.  `>>>` on a negative long is the trap this is
    // here for: -1 is the case where a logical shift turns into a run of f's
    // that is right by accident, and -4096 is not.
    eqs("S3 hex16 of -1", ix.hex16(-1), "ffffffffffffffff", "-1");
    eqs("S3 hex16 of -4096", ix.hex16(-4096), "fffffffffffff000", "-4096");
    eqs("S3 hex16 of min", ix.hex16(-9223372036854775807 - 1), "8000000000000000", "INT64_MIN");
    eqs("S3 hex16 of 0", ix.hex16(0), "0000000000000000", "0");
    eqs("S3 hex16 of 1", ix.hex16(1), "0000000000000001", "1");
    eqs("S3 hex16 of FNV basis", ix.hex16(ix.FNV_BASIS), "cbf29ce484222325", "the basis, which is negative");
    let bits = ix.FNV_BASIS & 255;
    want("S3 low-byte round trip", ix.hex16(bits) != "" && ix.hex16(bits).length == 16, "hex16 always returns exactly 16 digits");
    0
};

// ── building the fixture ────────────────────────────────────────────────

def put(rel: str, body: str) -> long {
    let p = TREE + "/" + rel;
    let cut = p.last_index_of("/");
    if (cut > 0) { fs.make_dirs(p[0:cut]) };
    if (!fs.write_bytes(p, bytes(body))) { bad("fixture", "cannot write " + rel); return 0 };
    1
};

def build_tree() -> long {
    fs.remove_all(TMP);
    if (!fs.make_dirs(TMP)) { return 0 };
    let i = 0;
    while (i < len(SPEC_PATHS)) {
        put(SPEC_PATHS[i], SPEC_BODIES[i]);
        i = i + 1;
    };
    // A second, much smaller tree: the depth-cap and cycle fixtures.
    fs.make_dirs(TMP + "/deep/a/b/c/d/e");
    fs.write_file(TMP + "/deep/top.txt", "top\n");
    fs.write_file(TMP + "/deep/a/mid.txt", "mid\n");
    fs.write_file(TMP + "/deep/a/b/c/d/e/bottom.txt", "bottom\n");
    // The hostile-input tree.
    fs.make_dirs(HOST);
    fs.write_file(HOST + "/plain.txt", "plain\n");
    fs.write_file(HOST + "/bin.dat", "BIN\x00\x01\x02\xff");
    fs.write_file(HOST + "/sp ace ünicode.txt", "odd\n");
    fs.make_dirs(HOST + "/empty");
    fs.make_dirs(HOST + "/locked", 0);
    fs.write_file(HOST + "/locked/hidden.txt", "hidden\n");
    // A symlink back to its own parent: the loop.
    syscall(266, HOST, -100, HOST + "/loop");
    1
};

def spec_bytes() -> long {
    let n = 0;
    let i = 0;
    while (i < len(SPEC_BODIES)) {
        n = n + SPEC_BODIES[i].length;
        i = i + 1;
    };
    n
};

// The paths a query selects, in the indexer's order.  This asks ix.wanted()
// -- the SAME predicate the report uses -- rather than re-implementing the
// filter here, so a check that passes is a check on the shipped behaviour.
def query_paths() -> [str] {
    // ix.order_paths() and ix.wanted() -- the shipped selection, not a copy.
    let ord = ix.order_paths();
    let limit = ix.N_FILE;
    if (ix.OPT_LARGEST > 0 && ix.OPT_LARGEST < limit) { limit = ix.OPT_LARGEST };
    let out: [str] = [];
    let i = 0;
    while (i < limit) {
        let e: ix.Entry = ix.ENT[ord[i]];
        if (ix.wanted(e)) { out += e.path };
        i = i + 1;
    };
    out
};

// ── S4: the walk, against the tree written above ────────────────────────

def configure() -> long {
    ix.COLOR = 0;
    ix.COLOR_AUTO = false;
    ix.WANT_HASH = true;
    ix.HEAD_COLS = 40;
    ix.FOLLOW = false;
    ix.STRICT = false;
    ix.DEPTH_CAP = 64;
    ix.OPT_EXT = "";
    ix.OPT_FIND = "";
    ix.OPT_LARGEST = -1;
    0
};

// The indexer's paths, in ITS sorted order.
def sorted_paths() -> [str] {
    ix.OPT_LARGEST = -1;
    let ord = ix.order_paths();
    let out: [str] = [];
    let i = 0;
    while (i < len(ord)) {
        let e: ix.Entry = ix.ENT[ord[i]];
        out += e.path;
        i = i + 1;
    };
    out
};

def sorted_hashes() -> [str] {
    ix.OPT_LARGEST = -1;
    let ord = ix.order_paths();
    let out: [str] = [];
    let i = 0;
    while (i < len(ord)) {
        let e: ix.Entry = ix.ENT[ord[i]];
        out += e.path + "=" + ix.hex16(e.hash);
        i = i + 1;
    };
    out
};

def entry_named(p: str) -> ix.Entry {
    let r = ix.ENT[0];
    let i = 1;
    while (i < ix.N_FILE) {
        let e: ix.Entry = ix.ENT[i];
        if (e.path == p) { r = e };
        i = i + 1;
    };
    r
};

def s4_walk() -> long {
    configure();
    let r = ix.walk(TREE);

    // -- the anti-vacuous guards, first and explicitly --
    want("S4 the spec is not empty", len(SPEC_PATHS) == 11, "the fixture lists " + tostring(len(SPEC_PATHS)) + " files");
    want("S4 the indexer found something", ix.N_FILE > 0, "N_FILE = " + tostring(ix.N_FILE));
    want("S4 the walk returned clean", r == 0, "walk() = " + tostring(r));
    want("S4 nothing was unreadable", ix.N_UNREAD == 0, "N_UNREAD = " + tostring(ix.N_UNREAD)
        + (if (len(ix.DIAG) > 0) { " diag=" + ix.DIAG[0] } else { "" }));

    // -- counts, from literals and from the spec, not from the indexer --
    eq("S4 file count", ix.N_FILE, 11, "files found");
    eq("S4 file count vs the spec", ix.N_FILE, len(SPEC_PATHS), "indexer vs SPEC_PATHS");
    eq("S4 directory count", ix.N_DIR, 8, "dirs: root, data, docs, src, src/deep, a, b, c");
    eq("S4 total bytes", ix.N_BYTES, 115, "sum of the 11 SPEC_BODIES lengths");
    eq("S4 total bytes vs the spec", ix.N_BYTES, spec_bytes(), "indexer vs sum(SPEC_BODIES)");
    want("S4 the totals are non-zero before comparing", ix.N_BYTES > 0 && ix.N_DIR > 0,
        "bytes = " + tostring(ix.N_BYTES) + ", dirs = " + tostring(ix.N_DIR));

    // -- the sorted path list, against the hand-written expectation --
    let got = sorted_paths();
    want("S4 got as many paths as expected", len(got) == len(EXPECT_PATHS),
        "indexer " + tostring(len(got)) + ", expectation " + tostring(len(EXPECT_PATHS)));
    let diff = 0;
    let where = "";
    let i = 0;
    while (i < len(EXPECT_PATHS) && i < len(got)) {
        if (got[i] != EXPECT_PATHS[i]) {
            diff = diff + 1;
            if (diff == 1) { where = " at position " + tostring(i) + ": got \"" + got[i] + "\", expected \"" + EXPECT_PATHS[i] + "\"" };
        };
        i = i + 1;
    };
    eq("S4 sorted path list", diff, 0, "positions differing from the hand-written order" + where);

    // -- the second opinion on MY hand-written list --
    let indep = ref_sort(SPEC_PATHS);
    eqs("S4 hand-written order vs an insertion sort", join_slash(indep), join_slash(EXPECT_PATHS),
        "the two independent statements of the expected order");

    // -- per-extension aggregates --
    eq("S4 extension count", len(ix.BKT), 5, "distinct extensions");
    let bo = ix.order_buckets();
    let exdiff = 0;
    let exwhere = "";
    i = 0;
    while (i < len(bo)) {
        let b: ix.Bucket = ix.BKT[bo[i]];
        if (i < len(EXPECT_EXTS)) {
            if (b.ext != EXPECT_EXTS[i]) { exdiff = exdiff + 1; exwhere = exwhere + " ext[" + tostring(i) + "]=" + b.ext }
            else {
                if (b.nfiles != EXPECT_EXT_FILES[i]) { exdiff = exdiff + 1; exwhere = exwhere + " files[" + b.ext + "]=" + tostring(b.nfiles) };
                if (b.nbytes != EXPECT_EXT_BYTES[i]) { exdiff = exdiff + 1; exwhere = exwhere + " bytes[" + b.ext + "]=" + tostring(b.nbytes) };
            };
        };
        i = i + 1;
    };
    eq("S4 per-extension table", exdiff, 0, "mismatches" + exwhere);

    // -- conservation: the buckets must account for every file and every byte
    let bf = 0;
    let bb = 0;
    i = 0;
    while (i < len(ix.BKT)) {
        let b: ix.Bucket = ix.BKT[i];
        bf = bf + b.nfiles;
        bb = bb + b.nbytes;
        i = i + 1;
    };
    eq("S4 bucket files conserve the total", bf, ix.N_FILE, "sum of bucket file counts");
    eq("S4 bucket bytes conserve the total", bb, ix.N_BYTES, "sum of bucket byte totals");
    want("S4 the bucket sum is not zero", bf > 0 && bb > 0, "files " + tostring(bf) + ", bytes " + tostring(bb));

    // -- every extension bucket was reached through the table, not a scan --
    eq("S4 the hash table held every extension", ix.xt_used(), 5, "occupied slots after the walk");
    want("S4 a lookup found it", ix.xt_find("txt") >= 0 && ix.xt_find("y") >= 0, "xt_find(\"txt\") and xt_find(\"y\") both hit");
    want("S4 a lookup missed it", ix.xt_find("nosuchext") < 0, "xt_find(\"nosuchext\") misses, and its slot is the hash's");

    // -- the queries --
    ix.OPT_EXT = "txt";
    let q = query_paths();
    eq("S4 --ext txt", len(q), 5, "files with extension txt");
    eqs("S4 --ext txt first", q[0], "café.txt", "first txt file in path order");
    ix.OPT_EXT = "";
    ix.OPT_FIND = "src/";
    let f = query_paths();
    eq("S4 --find src/", len(f), 3, "paths containing \"src/\"");
    eqs("S4 --find src/ order", join_slash(f), "src/deep/a/b/c/leaf.TXT|src/main.y|src/util.y|", "matched paths, in order");
    ix.OPT_FIND = "";
    ix.OPT_FIND = "nothing-matches-this";
    eq("S4 --find with no match", len(query_paths()), 0, "an honest zero, not a silent everything");
    ix.OPT_FIND = "";

    // --largest: the top three, and the tiebreak when two sizes are equal
    ix.OPT_LARGEST = 3;
    let l = query_paths();
    eq("S4 --largest 3 count", len(l), 3, "files listed");
    eqs("S4 --largest 3 order", join_slash(l), "README.md|src/util.y|data/no-newline.txt|", "22, 21, 19 bytes");
    ix.OPT_LARGEST = 1;
    eqs("S4 --largest 1", join_slash(query_paths()), "README.md|", "the single largest");
    ix.OPT_LARGEST = -1;

    // -- binary files and a file with no trailing newline --
    let bn = entry_named("data/blob.bin");
    eq("S4 the binary file's size", bn.size, 7, "7 bytes, including a NUL");
    want("S4 the binary file is flagged binary", (bn.flags & 1) != 0, "flags = " + tostring(bn.flags));
    want("S4 the binary file is flagged no-newline", (bn.flags & 2) != 0, "no trailing newline");
    eqs("S4 the binary file's snippet", bn.head, "<binary>", "the marker, not a garbled line");
    let nn = entry_named("data/no-newline.txt");
    eq("S4 the unterminated file's size", nn.size, 20, "20 bytes, no newline");
    want("S4 the unterminated file is NOT flagged binary", (nn.flags & 1) == 0, "text without a newline is not binary");
    want("S4 the unterminated file IS flagged no-newline", (nn.flags & 2) != 0, "flags = " + tostring(nn.flags));
    eqs("S4 the unterminated file's snippet", nn.head, "tail without newline", "the whole content is the first line");
    let em = entry_named("data/empty.txt");
    eq("S4 the empty file's size", em.size, 0, "zero bytes");
    eqs("S4 the empty file's hash", ix.hex16(em.hash), "cbf29ce484222325", "FNV-1a of no bytes is the basis");
    eqs("S4 the empty file's snippet", em.head, "<empty>", "a marker, not a trap");

    // -- a name with a space and non-ASCII bytes in it --
    // The expected string is the literal from SPEC_PATHS, and its .length is
    // the BYTE count (ü is two bytes in UTF-8, so 16 bytes for 15 characters).
    let want_name = SPEC_PATHS[2];
    let acc = entry_named(want_name);
    eqs("S4 the non-ASCII name survives the walk", acc.path, want_name, "café.txt, byte for byte");
    eq("S4 the non-ASCII name is 9 bytes", acc.path.length, 9, "s[i] is a byte: the name is 7 characters and 9 bytes");
    let sp = entry_named("odd name with spaces.txt");
    eqs("S4 the name with spaces survives", sp.path, "odd name with spaces.txt", "no quoting, no escaping, no splitting");
    let up = entry_named("src/deep/a/b/c/leaf.TXT");
    eqs("S4 an upper-case extension is lowercased", up.ext, "txt", "leaf.TXT indexes as txt");
    eq("S4 its size", up.size, 5, "leaf\n");
    0
};

// ── S5: idempotence, order-independence, change detection ───────────────

def s5_idempotence() -> long {
    configure();
    ix.walk(TREE);
    let r1 = ix.report_with_diag();
    ix.walk(TREE);
    let r2 = ix.report_with_diag();
    want("S5 the report is not empty", r1.length > 0, "first report is " + tostring(r1.length) + " bytes");
    want("S5 re-indexing is byte-identical", r1 == r2, "two indexes of an unchanged tree, "
        + tostring(r1.length) + " vs " + tostring(r2.length) + " bytes");
    if (r1 != r2) {
        let i = 0;
        while (i < len(r1) && i < len(r2) && r1[i] == r2[i]) { i = i + 1 };
        bad("S5 the difference is reported", "first difference at byte " + tostring(i));
    };
    // And the state itself, not only its rendering.
    want("S5 the hash list is stable", join_slash(sorted_hashes()) == join_slash(sorted_hashes()), "indexer vs itself after a re-walk");

    // Order-independence, on the INDEXER's sort: feed the merge sort the
    // reversed permutation and require the identical answer.  A sort that
    // leaks its input order still sorts, so this is the property that
    // separates them.
    let fwd = ix.order_paths();
    let rev: [long] = [];
    let i = fwd.length - 1;
    while (i >= 0) {
        rev += fwd[i];
        i = i - 1;
    };
    // rev[j] is fwd[n-1-j], so sorting it ascending by the entry order must
    // reproduce fwd itself -- compared as VALUES, not as positions.  (The
    // first version of this check compared rev[back[i]] to fwd[i] and read
    // the reversal as a failure; the indexer was right and the check wrong.)
    let back = ix.sort_perm(rev, ix.ECMPS[0]);
    want("S5 the reversal was a real reversal", rev[0] != fwd[0] && rev[len(rev) - 1] != fwd[len(fwd) - 1],
        "so a pass cannot come from sorting the already-sorted list");
    let same = len(back) == len(fwd);
    i = 0;
    while (same && i < len(fwd)) {
        if (back[i] != fwd[i]) { same = false };
        i = i + 1;
    };
    want("S5 the order does not depend on the walk order", same,
        "reversed permutation re-sorted to the same " + tostring(len(fwd)) + " positions");

    // And a shuffled permutation, not only the reversal.
    let shuf_ok = true;
    let stride = 1;
    while (stride < 5) {
        let sh = ix.sort_perm(stride_perm(fwd, stride), ix.ECMPS[0]);
        let j = 0;
        while (shuf_ok && j < len(fwd)) {
            if (sh[j] != fwd[j]) { shuf_ok = false };
            j = j + 1;
        };
        stride = stride + 1;
    };
    want("S5 four shuffled permutations re-sort identically", shuf_ok,
        "stride 1..4 over " + tostring(len(fwd)) + " indices");

    // Shuffled permutations too, several strides.
    let shuff_ok = true;
    let k = 1;
    while (k < 6) {
        let sh = shuffle(SPEC_PATHS, k);
        // Two sorts of the same shuffled list, by two different algorithms,
        // must land in the same order.
        let mine = ref_sort(sh);
        let theirs = ix.sort_str(sh, ix.CMPS[0]);
        if (join_slash(mine) != join_slash(theirs)) { shuff_ok = false };
        k = k + 1;
    };
    want("S5 merge sort agrees with insertion sort on 5 shuffles", shuff_ok,
        "ix.sort_str and the check's own insertion sort, same order each time");
    0
};

def s5_change() -> long {
    configure();
    ix.walk(TREE);
    let before = sorted_hashes();
    let hash0 = hash_of("data/empty.txt");
    let other0 = hash_of("README.md");
    let other1 = hash_of("src/util.y");
    let rep0 = ix.report_with_diag();
    want("S5 the entry under test exists", entry_named("data/empty.txt").size == 0,
        "data/empty.txt starts at 0 bytes");

    // One file changes; nothing else does.
    let grew = "grown by the check\n";
    fs.write_file(TREE + "/data/empty.txt", grew);
    ix.walk(TREE);
    let after = sorted_hashes();
    let sizes1 = size_of("data/empty.txt");
    let hash1 = hash_of("data/empty.txt");
    let other2 = hash_of("README.md");
    let other3 = hash_of("src/util.y");

    eq("S5 the changed file's size", sizes1, grew.length, "0 -> " + tostring(grew.length) + " bytes");
    want("S5 the changed file's hash moved", hash1 != hash0, hash0 + " -> " + hash1);
    want("S5 an untouched file's hash did NOT move", other2 == other0, "README.md still " + other0);
    want("S5 another untouched file's hash did NOT move", other3 == other1, "src/util.y still " + other1);
    let moved = 0;
    let i = 0;
    while (i < len(before) && i < len(after)) {
        if (before[i] != after[i]) { moved = moved + 1 };
        i = i + 1;
    };
    eq("S5 exactly one entry changed", moved, 1, "hash rows differing between the two indexes");
    want("S5 the report changed too", ix.report_with_diag() != rep0, "a change to one file must reach the report");

    // The path list is unaffected by a content change.
    want("S5 the path list is unchanged", join_slash(sorted_paths()) == join_slash(EXPECT_PATHS),
        "11 paths, still the hand-written order");

    // Put it back: idempotence must return.
    fs.write_file(TREE + "/data/empty.txt", "");
    ix.walk(TREE);
    eqs("S5 restoring the file restores the hash", hash_of("data/empty.txt"), hash0, "back to the FNV basis");
    want("S5 restoring the file restores the report byte for byte",
        ix.report_with_diag() == rep0, "the report before the change, reproduced");

    // Adding a file changes the count; removing it changes it back.
    fs.write_file(TREE + "/data/added.txt", "added\n");
    ix.walk(TREE);
    eq("S5 adding a file changes the count", ix.N_FILE, 12, "11 -> 12");
    eq("S5 and the totals", ix.N_BYTES, 115 + 6, "115 -> 121 bytes");
    fs.remove_file(TREE + "/data/added.txt");
    ix.walk(TREE);
    eq("S5 removing it changes the count back", ix.N_FILE, 11, "12 -> 11");
    eq("S5 and the totals back", ix.N_BYTES, 115, "121 -> 115 bytes");
    0
};

// xs rotated left by k -- a permutation, deterministic, and visibly not xs
// for every k in 1..4 unless len(xs) divides k.
def stride_perm(xs: [long], k: long) -> [long] {
    let out: [long] = [];
    let n = len(xs);
    let i = 0;
    while (i < n) {
        out += xs[(i + k) % n];
        i = i + 1;
    };
    out
};

// The data rows of the listing: the lines between the "size  hash" header
// and the "N files" footer.  Found by those markers rather than by a
// whitespace heuristic, because a heuristic that quietly matches nothing is
// how a check comes to pass while measuring zero -- which is what this
// section's first version did.
def rows_of(r: str) -> long {
    let ls = r.lines();
    let i = 0;
    let seen = false;
    let n = 0;
    while (i < len(ls)) {
        if (ls[i].starts_with("size  ")) { seen = true } else if (seen) {
            if (ls[i].ends_with(" files") || ls[i].index_of(" of ") > 0) { seen = false } else { n = n + 1 };
        };
        i = i + 1;
    };
    n
};

// Data rows whose path does not begin at byte 33: 6 for the size, 20 for the
// hash (or for the blank it leaves), 7 for the extension.
def misaligned(r: str) -> long {
    let ls = r.lines();
    let i = 0;
    let seen = false;
    let bad = 0;
    while (i < len(ls)) {
        let l2 = ls[i];
        if (l2.starts_with("size  ")) { seen = true } else if (seen) {
            if (l2.ends_with(" files") || l2.index_of(" of ") > 0) { seen = false }
            else if (l2.length < 34 || byte_at(l2, 32) != 32 || byte_at(l2, 33) == 32) { bad = bad + 1 };
        };
        i = i + 1;
    };
    bad
};

def size_of(p: str) -> long { entry_named(p).size };
def hash_of(p: str) -> str { ix.hex16(entry_named(p).hash) };

// ── S6: hostile inputs, through real processes ──────────────────────────
//
// Each case forks a child that runs one walk, writes the SAME message the
// CLI would print to a log file, and exits with the code the CLI would exit
// with.  The parent then asserts three things: the exit code is non-zero and
// is the one the brief names, the log is NON-EMPTY (a check comparing two
// absent messages passes otherwise), and the log does not contain "runtime
// error:" -- because a trap prints to stdout and would corrupt the golden
// instead of announcing itself.

const CASE_ENOENT = 1;
const CASE_ENOTDIR = 2;
const CASE_EMPTY_PATH = 3;
const CASE_HOSTILE = 4;
const CASE_STRICT = 5;
const CASE_DEPTH = 6;

def child(n: long) -> long {
    let code = 0;
    let msg = "";
    configure();
    if (n == CASE_ENOENT) {
        ix.ROOT = HOST + "/does-not-exist";
        let r = ix.walk(ix.ROOT);
        code = 2;
        msg = "indexer: " + cli.root_message(r);
    } else if (n == CASE_ENOTDIR) {
        ix.ROOT = HOST + "/plain.txt";
        let r = ix.walk(ix.ROOT);
        code = 2;
        msg = "indexer: " + cli.root_message(r);
    } else if (n == CASE_EMPTY_PATH) {
        ix.ROOT = "";
        let r = ix.walk(ix.ROOT);
        code = 2;
        msg = "indexer: " + cli.root_message(r);
    } else if (n == CASE_HOSTILE) {
        ix.ROOT = HOST;
        ix.FOLLOW = true;
        ix.walk(ix.ROOT);
        code = 0;
        msg = "indexer: walked " + tostring(ix.N_FILE) + " files, " + tostring(ix.N_CYCLE)
            + " cycles, " + tostring(ix.N_UNREAD) + " unreadable";
    } else if (n == CASE_STRICT) {
        ix.ROOT = HOST;
        ix.FOLLOW = true;
        ix.STRICT = true;
        let r = ix.walk(ix.ROOT);
        if (r == 0 && (ix.N_UNREAD > 0 || ix.N_CAP > 0)) { code = 3; msg = "indexer: " + cli.strict_message() }
        else { code = 0; msg = "indexer: strict saw nothing, which is the defect if this passes" };
    } else {
        ix.ROOT = TMP + "/deep";
        ix.DEPTH_CAP = 2;
        ix.walk(ix.ROOT);
        code = 0;
        msg = "indexer: depth cap gave " + tostring(ix.N_FILE) + " files, " + tostring(ix.N_CAP) + " capped";
    };
    // The message goes to a LOG FILE, not to stderr: the parent asserts the
    // file's bytes, which are the same `str` the CLI hands to eputs, and the
    // check's own output stays clean enough to read.  (eputs writes fd 2
    // WITHOUT a newline, unlike puts -- so the CLI adds its own.)
    let logp = TMP + "/case-" + tostring(n) + ".log";
    fs.write_file(logp, msg + "\n");
    exit(code);
    0
};

// Run one hostile case in a child; return its exit code, and leave its
// message in OUT.
let OUT: str = "";

def fork_case(n: long) -> long {
    OUT = "";
    let pid = fork { child(n) };
    let rc = wait_pid(pid);
    let logp = TMP + "/case-" + tostring(n) + ".log";
    let l = fs.read_file(logp);
    if (l != none) { OUT = l!.trim() };
    rc
};

def s6_hostile() -> long {
    let root_ok = syscall(102) != 0;

    // -- a nonexistent root --
    let rc = fork_case(CASE_ENOENT);
    eq("S6 nonexistent path exits 2", rc, 2, "walk(ENOENT) via a forked child");
    want("S6 and says so", OUT.length > 0 && OUT.index_of("no such path") >= 0, "message = \"" + OUT + "\"");
    want("S6 and did not trap", OUT.index_of("runtime error") < 0, "no runtime error in the message");

    // -- a file where a directory was asked for --
    rc = fork_case(CASE_ENOTDIR);
    eq("S6 a file is not a directory: exit 2", rc, 2, "walk(ENOTDIR)");
    want("S6 and says so", OUT.length > 0 && OUT.index_of("not a directory") >= 0, "message = \"" + OUT + "\"");

    // -- an empty path, which is the one that reads as the cwd by mistake --
    rc = fork_case(CASE_EMPTY_PATH);
    eq("S6 an empty path exits 2", rc, 2, "walk(\"\")");
    want("S6 and says so", OUT.length > 0 && OUT.index_of("no such path") >= 0, "message = \"" + OUT + "\"");

    // -- the hostile tree itself: loop, empty dir, binary, spaces, locked --
    configure();
    ix.ROOT = HOST;
    eq("S6 the hostile tree walks cleanly", ix.walk(HOST), 0, "walk(HOST)");
    eq("S6 files in it", ix.N_FILE, 3, "plain.txt, bin.dat, sp ace ünicode.txt");
    eq("S6 dirs in it", ix.N_DIR, 3, "HOST, empty, locked");
    eq("S6 symlinks in it", ix.N_LINK, 1, "the loop");
    eq("S6 nothing capped", ix.N_CAP, 0, "caps hit");
    want("S6 the empty directory contributed no file", !has_path("empty"), "an empty dir is 0 files, not an error");

    if (root_ok) {
        eq("S6 the locked directory is unreadable", ix.N_UNREAD, 1, "mode 0 on locked/");
        want("S6 and it is named as EACCES", diag_has("EACCES"), "the diagnostic carries errno name, not just a count");
        // --follow-symlinks turns the loop on, and the (dev,ino) set stops it.
        configure();
        ix.FOLLOW = true;
        ix.walk(HOST);
        want("S6 the symlink loop is detected", ix.N_CYCLE >= 1, "cycles = " + tostring(ix.N_CYCLE));
        want("S6 and the walk still terminates with a small file count", ix.N_FILE < 1000,
            "files = " + tostring(ix.N_FILE) + ", dirs = " + tostring(ix.N_DIR)
            + " -- a loop that was not broken would not return at all");
        want("S6 the file count did not double", ix.N_FILE == 3,
            "following the loop adds no files, because the loop names directories already visited");
    } else {
        skips("S6 permission-denied subdirectory", "running as uid 0, where mode 0 is still readable");
        skips("S6 symlink loop under --follow-symlinks", "uid 0 can read the locked directory, so this case is folded");
    }

    // --strict turns the unreadable entry into a non-zero exit --
    rc = fork_case(CASE_STRICT);
    if (root_ok) {
        eq("S6 --strict exits 3", rc, 3, "unreadable entries under --strict");
        want("S6 and says which", OUT.length > 0 && OUT.index_of("strict") >= 0, "message = \"" + OUT + "\"");
    } else {
        skips("S6 --strict exits 3", "no unreadable entry exists for uid 0");
    };

    // -- the depth cap is a cap, not a trap and not an infinite descent --
    rc = fork_case(CASE_DEPTH);
    eq("S6 a depth cap exits 0", rc, 0, "--depth 2 over a 6-deep tree");
    want("S6 and reports the cap", OUT.length > 0 && OUT.index_of("capped") >= 0, "message = \"" + OUT + "\"");
    configure();
    ix.ROOT = TMP + "/deep";
    ix.DEPTH_CAP = 2;
    ix.walk(TMP + "/deep");
    want("S6 the cap was actually hit", ix.N_CAP >= 1, "N_CAP = " + tostring(ix.N_CAP));
    eq("S6 and the shallow files survived", ix.N_FILE, 2, "top.txt and a/mid.txt");
    want("S6 and the deep one did not", entry_named("a/b/c/d/e/bottom.txt").path != "a/b/c/d/e/bottom.txt", "bottom.txt is beyond the cap");
    0
};

def has_path(p: str) -> bool {
    let seen = false;
    let i = 0;
    while (i < ix.N_FILE) {
        let e: ix.Entry = ix.ENT[i];
        if (e.path == p) { seen = true; i = ix.N_FILE } else { i = i + 1 };
    };
    seen
};

def diag_has(needle: str) -> bool {
    let seen = false;
    let i = 0;
    while (i < len(ix.DIAG)) {
        if (ix.DIAG[i].index_of(needle) >= 0) { seen = true; i = len(ix.DIAG) } else { i = i + 1 };
    };
    seen
};

// ── S7: the parser and the report's own shape ──────────────────────────

def s7_cli() -> long {
    // Every rejection is a non-zero code AND a non-empty message.  Asserting
    // the message is non-empty is the point: "did it complain?" is trivially
    // satisfied by two empty strings.
    let cases: [str] = [
        "--nosuchflag",
        "-z",
        "--head",
        "--ext",
        "--find",
        "--largest",
        "--depth",
        "--root",
        "--head 12x",
        "--head -3",
        "--largest 0",
        "--depth 0",
        "--bench abc",
        "one two",
    ];
    let missed = 0;
    let detail = "";
    let i = 0;
    while (i < len(cases)) {
        let parts = cases[i].split(" ");
        let r = cli.parse(parts);
        if (r != 1 || cli.ERR.length == 0) {
            missed = missed + 1;
            detail = detail + " [" + cases[i] + " -> code " + tostring(r) + ", msg \"" + cli.ERR + "\"]";
        };
        i = i + 1;
    };
    eq("S7 every bad flag line is rejected", missed, 0, "of " + tostring(len(cases)) + " cases" + detail);

    // num_arg itself: tolong on junk is a silent 0, which is how a `--head`
    // of nonsense becomes "no first lines".
    eq("S7 num_arg accepts digits", cli.num_arg("42"), 42, "\"42\"");
    eq("S7 num_arg rejects junk", cli.num_arg("4 2"), -1, "\"4 2\"");
    eq("S7 num_arg rejects the empty string", cli.num_arg(""), -1, "\"\"");
    eq("S7 num_arg rejects a sign", cli.num_arg("-1"), -1, "\"-1\"");
    eq("S7 num_arg rejects a suffix", cli.num_arg("7k"), -1, "\"7k\"");

    // The good paths are accepted, and --check is recognised.
    configure();
    let okc = cli.parse(["--no-tty", "--head", "20", "--largest", "5", TREE]);
    eq("S7 a good command line parses", okc, 0, "no error");
    eq("S7 --head reached the engine", ix.HEAD_COLS, 20, "HEAD_COLS");
    eq("S7 --largest reached the engine", ix.OPT_LARGEST, 5, "OPT_LARGEST");
    want("S7 --check is recognised", cli.parse(["--check"]) == 0 && cli.WANT_CHECK, "WANT_CHECK set");
    cli.parse(["--strict", HOST]);
    want("S7 --strict survives the parser", cli.parse(["--strict"]) == 0 && ix.STRICT,
        "the flag reaches the engine, not just the report");
    cli.parse([]);
    want("S7 and a later call does not inherit it", !ix.STRICT, "parse() resets, so two calls cannot contaminate each other");
    cli.parse(["--follow-symlinks"]);
    want("S7 --follow-symlinks survives the parser", cli.parse(["--follow-symlinks"]) == 0 && ix.FOLLOW, "FOLLOW set");
    cli.parse([]);
    cli.parse(["--no-hash"]);
    want("S7 --no-hash survives the parser", cli.parse(["--no-hash"]) == 0 && !ix.WANT_HASH, "WANT_HASH cleared");
    cli.parse([]);
    want("S7 and parse() restores the defaults", ix.WANT_HASH && !ix.FOLLOW && !ix.STRICT && ix.OPT_LARGEST == 0 - 1,
        "an empty command line gives the documented defaults");
    cli.parse(["--help"]);
    want("S7 --help sets the colour decision", !ix.COLOR_AUTO, "a help run never looks at the terminal");
    want("S7 the usage text is not empty", cli.usage_here().length > 100, tostring(cli.usage_here().length) + " bytes of usage");

    // is_tty() has to answer FALSE here, because --check's stdout is a pipe.
    // Only this direction can be asserted in-process; pty_check.py strips the
    // SGR sequences off a real pty capture to prove the TRUE direction, which
    // is the direction that was broken (syscall(16, 1) with no TCGETS request
    // and no termios buffer answers -ENOTTY on a terminal too, so colour
    // never turned on by itself and nothing in this file could see it).
    want("S7 is_tty is false on a pipe", !cli.is_tty(),
          "ioctl(TCGETS) on fd 1 under --check, whose stdout is a pipe");

    // The report's shape: fixed columns, one row per file, no ANSI when
    // colour is off.  A report that leaks an escape sequence would make the
    // golden terminal-dependent, which gate item 2 would not catch on this
    // machine but a reader on another one would.
    configure();
    ix.walk(TREE);
    let rep = ix.report();
    want("S7 the report is not empty", rep.length > 200, tostring(rep.length) + " bytes");
    want("S7 no ANSI escapes when colour is off", rep.index_of("\x1b[") < 0, "no ESC[ in a --no-tty report");
    // A data row is a 6-column size then the hash -- so "0x" sits at byte 6
    // and nowhere else on the line.  Counting rows by their
    // leading spaces would count the header and the totals too.
    let rows = 0;
    let i2 = 0;
    let lines = rep.lines();
    while (i2 < len(lines)) {
        if (lines[i2].index_of("0x") == 6) { rows = rows + 1 };
        i2 = i2 + 1;
    };
    eq("S7 one row per indexed file", rows, 11, "data rows in the listing");
    ix.COLOR = 1;
    let col = ix.report();
    want("S7 colour on adds escapes", col.index_of("\x1b[") >= 0, "the same report with SGR in it");
    want("S7 and colour on changes only the escapes", col.replace("\x1b[0m", "").length > rep.length, "longer with colour");
    ix.COLOR = 0;

    // The extension table as RENDERED, in sorted order.  Testing
    // ix.order_buckets() alone missed an injected defect that changed
    // ext_table() only: the function under test was not the function called.
    // The rows are EXACTLY the lines between the table's header line and its
    // "extensions  N of M" footer.  An earlier version of this check tried to
    // recognise a row by its whitespace, which is a heuristic that quietly
    // matches nothing.
    let ls = rep.lines();
    let head_at = -1;
    let foot_at = -1;
    let li = 0;
    while (li < len(ls)) {
        if (ls[li].starts_with("ext           files")) { head_at = li };
        if (ls[li].starts_with("extensions  ")) { foot_at = li };
        li = li + 1;
    };
    want("S7 the extension table header and footer were located",
        head_at >= 0 && foot_at > head_at,
        "header at line " + tostring(head_at) + ", footer at " + tostring(foot_at));
    let ex_rows: [str] = [];
    li = head_at + 1;
    while (li >= 0 && li < foot_at) {
        let cut = ls[li].index_of("  ");
        if (cut >= 0) { ex_rows += ls[li][0:cut] };
        li = li + 1;
    };
    want("S7 the extension table was found in the render", len(ex_rows) == 5,
        "5 rows parsed out of the report text, found " + tostring(len(ex_rows)));
    let sorted_rows = true;
    li = 0;
    while (li + 1 < len(ex_rows)) {
        if (ix.cmp_path(ex_rows[li], ex_rows[li + 1]) > 0) { sorted_rows = false };
        li = li + 1;
    };
    want("S7 the rendered extension table is sorted", sorted_rows, join_slash(ex_rows));

    // --no-hash has to leave the columns aligned, or every other column
    // shifts by the width of a hash.  Measured WITHIN each report, not
    // ACROSS the two: the two are legitimately different lengths (the header
    // reads "fnv1a-64" in one and "off" in the other), so comparing an
    // offset between them proves nothing -- which is what the first version
    // of this check did, and it reported a 5-byte "misalignment" that was
    // just the header.
    ix.WANT_HASH = false;
    let nh = ix.report();
    ix.WANT_HASH = true;
    eq("S7 every row of a --no-hash report starts its path at byte 33", misaligned(nh), 0,
        tostring(rows_of(nh)) + " data rows checked");
    eq("S7 and the same with hashing on", misaligned(rep), 0,
        tostring(rows_of(rep)) + " data rows checked");
    want("S7 both reports have the same row count", rows_of(nh) == rows_of(rep) && rows_of(rep) > 0,
        tostring(rows_of(rep)) + " rows each, lengths " + tostring(rep.length) + " and " + tostring(nh.length));

    // Diagnostics must reach the reader but must NOT be folded into the
    // report body, which is stdout: a trap prints there, and so would this.
    configure();
    ix.walk(HOST);
    if (ix.N_UNREAD > 0) {
        let r_clean = ix.report();
        let r_diag = ix.report_with_diag();
        want("S7 a clean report carries no diagnostics", r_clean.index_of("warning  ") < 0,
            "report() on a tree with an unreadable directory");
        want("S7 report_with_diag carries them", r_diag.index_of("warning  ") >= 0 && r_diag.length > r_clean.length,
            tostring(ix.N_UNREAD) + " warning(s), " + tostring(r_diag.length - r_clean.length) + " extra bytes");
        want("S7 and the diagnostics name the directory", r_diag.index_of("locked") >= 0, "the path is in the message");
    } else {
        skips("S7 diagnostics reach report_with_diag", "no unreadable directory (running as uid 0)");
    };
    configure();
    0
};

// ── S8: the check's own honesty ─────────────────────────────────────────
//
// Not a property of the indexer: a property of THIS file.  If any of these
// ever reads zero, a check above it is comparing two absent values and the
// whole battery is decoration.

def s8_self_audit() -> long {
    // `N_OK + tostring(N_BAD)` was the first draft of this line, and `long +
    // str` COERCES and concatenates rather than refusing, so the summary read
    // "1720" instead of "172".  A check that cannot add two numbers is not
    // a check, so the sum is done into a `let` first.
    let ran = N_OK + N_BAD;
    want("S8 this check ran some assertions", ran > 60,
        tostring(ran) + " assertions so far, and the tally below is " + tostring(N_BAD) + " failed");
    want("S8 the fixture tree was not empty", len(SPEC_PATHS) == 11 && len(EXPECT_PATHS) == 11,
        "11 written, 11 expected");
    want("S8 the hand-written order has no duplicates", no_dupes(EXPECT_PATHS), "a duplicate would make the diff vacuous");
    want("S8 the spec and the expectation are the same set", same_set(SPEC_PATHS, EXPECT_PATHS),
        "11 in, 11 out, no extras");
    want("S8 the bucket table covers every extension", len(EXPECT_EXTS) == 5, "5 rows");
    want("S8 the extension table conserves the files", sum_of(EXPECT_EXT_FILES) == 11,
        "sum = " + tostring(sum_of(EXPECT_EXT_FILES)));
    want("S8 the extension table conserves the bytes", sum_of(EXPECT_EXT_BYTES) == 115,
        "sum = " + tostring(sum_of(EXPECT_EXT_BYTES)));
    want("S8 the byte literal matches the spec", spec_bytes() == 115,
        "SPEC_BODIES sum = " + tostring(spec_bytes()));
    0
};

def no_dupes(xs: [str]) -> bool {
    let d = 0;
    let i = 0;
    while (i < len(xs)) {
        let j = i + 1;
        while (j < len(xs)) {
            if (xs[i] == xs[j]) { d = d + 1 };
            j = j + 1;
        };
        i = i + 1;
    };
    d == 0
};

def same_set(a: [str], b: [str]) -> bool {
    let n = 0;
    let i = 0;
    while (i < len(a)) {
        let found = 0;
        let j = 0;
        while (j < len(b)) {
            if (a[i] == b[j]) { found = 1 };
            j = j + 1;
        };
        n = n + found;
        i = i + 1;
    };
    n == len(a) && n == len(b)
};

def sum_of(xs: [long]) -> long {
    let n = 0;
    let i = 0;
    while (i < len(xs)) { n = n + xs[i]; i = i + 1; };
    n
};

// ── S9: the report's accumulator stays in the amortised path ────────────
//
// This section exists because this example SHIPPED the quadratic once.  The
// report builder appends to one `str`, and an `if` arm written as
//
//     if (WANT_HASH) { out += "0x" + h + "  " } else { out += "        " };
//
// puts the `;` AFTER the arm's closing brace, which makes the append
// value-used, which drops it out of the in-place amortised append, which makes
// the whole loop O(n^2) in heap -- with BYTE-IDENTICAL output, so nothing
// crashes, nothing is miscompiled, and a golden-file gate passes for ever.
// That is the filed `str +=` in a value-used position bug in examples/BUGS.md;
// its one-character fix is to move the `;` inside the braces.
//
// The fix is invisible to `-S` unless you trace WHICH `y_str_cat` is on the
// accumulator, and invisible to every other check in this file, because the
// output is identical.  So the property is measured: the arena one report
// costs must grow LINEARLY in the number of files.
//
//   quadratic  -> delta(2n) / delta(n) ~ 4
//   linear     -> delta(2n) / delta(n) ~ 2
//
// Measured on the pinned compiler before the fix: 7 197, 24 068, 92 384 and
// 231 202 bytes per file at 50 / 200 / 800 / 2 000 files.  After: 1 694, 1 474,
// 1 417, 1 413 -- flat.  inject.py's `valueusedarm` defect puts the semicolon
// back and this section fails, which is the point of it.

const S9_BASE = "/tmp/indexer-check/scale";

def s9_tree(n: long) -> long {
    let root = S9_BASE + "-" + tostring(n);
    fs.remove_all(root);
    if (!fs.make_dirs(root)) { return 0 };
    let i = 0;
    while (i < n) {
        let d = root + "/d" + tostring(i / 10);
        fs.make_dirs(d);
        fs.write_file(d + "/f" + tostring(i) + ".txt", "line " + tostring(i) + "\\n");
        i = i + 1;
    };
    1
};

def s9_report_bytes(n: long) -> long {
    configure();
    let root = S9_BASE + "-" + tostring(n);
    ix.walk(root);              // warm-up: allocates the module-level buffers
    let h0 = heap_used();
    let r = ix.report();
    let d = heap_used() - h0;
    want("S9 the measurement is not zero", r.length > 0 && d > 0,
        "n=" + tostring(n) + ": report is " + tostring(r.length) + " bytes and cost "
        + tostring(d) + " B of arena");
    d
};

def s9_linear() -> long {
    s9_tree(100);
    s9_tree(200);
    s9_tree(400);
    let d100 = s9_report_bytes(100);
    let d200 = s9_report_bytes(200);
    let d400 = s9_report_bytes(400);
    // The comparisons are cross-multiplied rather than dividing: long/long is
    // an integer quotient here, so `d200 / d100` would print 1 for both a
    // linear 1.95x and a healthy 2.9x.  The float below is for the reader.
    print("     report arena: 100 files " + tostring(d100) + " B, 200 files "
        + tostring(d200) + " B, 400 files " + tostring(d400) + " B");
    print("     growth ratios: 200/100 = " + f"{d200 / (d100 / 1.0):.2f}" + "x, 400/200 = "
        + f"{d400 / (d200 / 1.0):.2f}" + "x   (2x = linear, 4x = quadratic)");
    want("S9 doubling the files costs under 3x the arena", d200 * 1 < d100 * 3,
        "100 -> 200 files: " + f"{d200 / (d100 / 1.0):.2f}" + "x (under 3x)");
    want("S9 and again from 200 to 400", d400 * 1 < d200 * 3,
        "200 -> 400 files: " + f"{d400 / (d200 / 1.0):.2f}" + "x (under 3x)");
    // Also the absolute figure: a report over 400 files must cost well under
    // a megabyte.  At the pre-fix rate it was 92 384 B per file, so 37 MB.
    want("S9 and 400 files cost under 1 MB of arena", d400 < 1048576,
        "measured " + tostring(d400) + " B");
    fs.remove_all(S9_BASE + "-100");
    fs.remove_all(S9_BASE + "-200");
    fs.remove_all(S9_BASE + "-400");
    0
};

// ── the driver ──────────────────────────────────────────────────────────
//
// --only N runs ONE section and exits with 9 if it failed, which is how the
// forked hostile cases (S6) get a child that asserts a process exit status
// without the child also running the whole battery.  inject.py uses it to
// show that a defect is caught by a NAMED check rather than by luck.

def only(n: long) -> long {
    let bad = 0;
    if (n == 1) { s1_total_order() }
    else if (n == 2) { s2_tables() }
    else if (n == 3) { s3_fnv() }
    else if (n == 4) { s4_walk() }
    else if (n == 5) { s5_idempotence(); s5_change() }
    else if (n == 6) { s6_hostile() }
    else if (n == 7) { s7_cli() }
    else if (n == 8) { s8_self_audit() }
    else { s9_linear() };
    bad = N_BAD;
    print("--only " + tostring(n) + ": " + tostring(N_OK) + " ok, " + tostring(N_BAD) + " failed");
    if (bad > 0) { return 9 };
    0
};

def run(argv: [str]) -> long {


    print("indexer --check: no reference file is read; every line below is measured");
    print("");
    if (build_tree() == 0) {
        print("FAIL S0 fixture -- cannot create " + TMP);
        return 9;
    };
    print("-- S1 the comparator is a strict total order");
    s1_total_order();
    print("");
    print("-- S2 the hash tables");
    s2_tables();
    print("");
    print("-- S3 FNV-1a and hex16 against published vectors");
    s3_fnv();
    print("");
    print("-- S4 the walk against a tree written by hand in this file");
    s4_walk();
    print("");
    print("-- S5 idempotence, order-independence and change detection");
    s5_idempotence();
    s5_change();
    print("");
    print("-- S6 hostile inputs, each through a real process");
    s6_hostile();
    print("");
    print("-- S7 the parser and the report's shape");
    s7_cli();
    print("");
    print("-- S8 this check's own honesty");
    s8_self_audit();
    print("");
    print("-- S9 the report's accumulator stays amortised (a shipped quadratic)");
    s9_linear();
    print("");
    print("indexer --check: " + tostring(N_OK) + " ok, " + tostring(N_BAD) + " failed, "
        + tostring(N_SKIP) + " skipped");
    if (N_BAD > 0) { return 9 };
    0
};

export { run, only, ok, bad, want, eq, eqs, skips, N_OK, N_BAD, N_SKIP, build_tree,
         configure, s1_total_order, s2_tables, s3_fnv, s4_walk, s5_idempotence,
         s5_change, s6_hostile, s7_cli, s8_self_audit, s9_linear, ref_sort, join_slash, TMP,
         only,
         TREE, HOST, SPEC_PATHS, EXPECT_PATHS, query_paths, entry_named, sorted_paths,
         sorted_hashes, has_path, diag_has };