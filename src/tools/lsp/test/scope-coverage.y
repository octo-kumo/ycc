// scope-coverage.y -- how much of a file the M4 index can actually resolve.
//
// How much does Stage A resolve? For every identifier token in every src/y/*.y,
// does nav.find_decl find a declaration, and what are the misses?
//
// It exists because "is Stage A good enough, or does Stage B earn its keep" is a
// question about a NUMBER, and the number nobody had was 46% -- which turned out
// to be two bugs rather than a limit. Run it over src/y:
//
//   ./ycc src/tools/lsp/test/scope-coverage.y -o /tmp/cov && /tmp/cov
//
// and it reports what share of the corpus's identifier tokens nav.find_decl
// resolves, and -- the part the decision turns on -- how many of the misses are
// names that ARE declared, in another file. Those are what Stage B closes and
// what Stage A cannot see, because Stage A reads one buffer.
//
// It imports ONLY fs/scan/scope/nav. diag reaches the whole compiler (types.y,
// native.y, parser.y, rename.y, lint.y), and a program carrying all of it sits
// at 3.1 GB of the 3.5 GB arena before this loop starts, so indexing src/y on
// top of that dies of "out of memory" -- a fact about the probe, not about
// scope.y. The builtin list is copied for the same reason, so treat the
// builtin/non-builtin split as approximate; the totals are not.
import fs;
import scan from "../scan.y";
import scope from "../scope.y";
import nav from "../nav.y";

// native.is_intrinsic_name's list, verbatim.
const BUILTINS: [str] = ["print", "syscall", "len", "push", "some", "is_some", "unwrap",
    "opt$test", "opt$val", "trim", "ord", "byte_at", "chr", "tonum", "tostring",
    "index_of", "prepend", "last_index_of", "join", "split", "puts", "eputs",
    "clock_us", "time_us", "sleep", "heap_used", "keys", "spawn", "fork", "wait_pid",
    "mutex", "sem", "lock", "try_lock", "post", "wait", "exit", "argv", "range",
    "typeof", "bytes", "from_bytes", "ptr_addr", "self", "none", "#fmt"];

let files = fs.list_dir("src/y")!;
let total = 0;
let hit = 0;
let miss_builtin = 0;
let miss_other = 0;
let names: [str] = [];
let seen: { str => long } = {};

let i = 0;
while (i < len(files)) {
    let f = files[i];
    if (f.ends_with(".y")) {
        let src = fs.read_file("src/y/" + f)!;
        let idx = scope.index_src(src, f);
        let sps = scan.scan_full(src).spans;
        let k = 0;
        while (k < len(sps)) {
            let s = sps[k];
            if (s.kind == scan.K_ident) {
                total = total + 1;
                let nm = src[s.off:s.end];
                // A declaration's own NAME resolves to itself and counts as a hit.
                // The question is what a USE reaches.
                let r = nav.find_decl(idx, nm, s.line - 1, s.col - 1);
                if is_some(r) { hit = hit + 1; }
                else {
                    let isb = false;
                    foreach (b in BUILTINS) {
                        if (b == nm) { isb = true; };
                    };
                    if (isb) { miss_builtin = miss_builtin + 1; }
                    else {
                        miss_other = miss_other + 1;
                        if is_some(seen[nm]) { seen[nm] = seen[nm]! + 1; }
                        else { seen[nm] = 1; names += nm; };
                    };
                };
            };
            k = k + 1;
        };
    };
    i = i + 1;
};

// Second pass: every name declared anywhere in the corpus. A miss that IS in
// this set is one Stage A cannot see because it lives in another file -- which
// is exactly what Stage B's `rename_program_x2` over the spliced program would.
let anywhere: { str => long } = {};
let j2 = 0;
while (j2 < len(files)) {
    let f2 = files[j2];
    if (f2.ends_with(".y")) {
        let src2 = fs.read_file("src/y/" + f2)!;
        let idx2 = scope.index_src(src2, f2);
        let q = 0;
        while (q < len(idx2.decls)) {
            let dn = idx2.decls[q].name;
            if is_some(anywhere[dn]) { anywhere[dn] = anywhere[dn]! + 1; }
            else { anywhere[dn] = 1; };
            q = q + 1;
        };
    };
    j2 = j2 + 1;
};

print("src/y files: " + tostring(len(files)));
print("heap after the corpus: " + tostring(heap_used()));
print("identifier tokens: " + tostring(total));
print("resolved by Stage A: " + tostring(hit) + " (" + tostring(hit * 100 / (total + 1)) + "%)");
print("miss, a builtin: " + tostring(miss_builtin));
print("miss, something else: " + tostring(miss_other));
print("distinct names in that last line: " + tostring(len(names)));
// How many of the unresolved TOKENS would Stage B close?
//
//   cross-file : the name IS declared in another src/y file. Stage B resolves
//                these because rename runs over the whole spliced program, so
//                the binding carries its file and position.
//   primitive  : a primitive type name (long, str, ...). Neither stage resolves
//                these as a declaration; they are built into the language.
//   unknown    : neither -- a name declared nowhere in the corpus.
let cross = 0;
let prim = 0;
let unknown = 0;
const PRIMS: [str] = ["long", "str", "bool", "float", "byte", "void", "int"];
let nn = 0;
while (nn < len(names)) {
    let nm2 = names[nn];
    let got2 = seen[nm2];
    if is_some(got2) {
        if is_some(anywhere[nm2]) { cross = cross + 1; }
        else {
            let isp = false;
            foreach (q2 in PRIMS) { if (q2 == nm2) { isp = true; }; };
            if (isp) { prim = prim + 1; } else { unknown = unknown + 1; };
        };
    };
    nn = nn + 1;
};
print("of the " + tostring(len(names)) + " distinct unresolved names:");
print("  declared in another src/y file (Stage B would close): " + tostring(cross));
print("  a primitive type name (neither stage declares it):    " + tostring(prim));
print("  declared nowhere in the corpus:                       " + tostring(unknown));
print("--- the most frequent, biggest first ---");
let shown = 0;
while (shown < 22) {
    let best = "";
    let bestn = 0;
    foreach (nm in names) {
        let got = seen[nm];
        if is_some(got) {
            let c = got!;
            if (c > bestn) { bestn = c; best = nm; };
        };
    };
    if (best == "") { break; };
    print("  " + best + "  (" + tostring(bestn) + ")");
    seen[best] = 0;
    shown = shown + 1;
};

