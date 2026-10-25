// flags: --gc=stress
// `heap { .. }` inside a region allocates in the collector's heap, and a
// collection there must treat the suspended region's chunks as roots: here a
// region array is the only thing that holds the heap strings and its own
// grown storage (arch/prelude.s y_region_roots). --gc=stress runs a cycle at
// every allocation that takes the slow path, which a large block always does.

def pad(i: long) -> str { "v" + tostring(i) + "-" + tostring(i * i) }

// The appends happen in a frame that is gone by the time the collector looks,
// so no stale stack word keeps the storage alive by luck.
def keep(held: [str], i: long) -> void {
    heap { held += pad(i); }
}

// Overwrite the stack where keep's frames were.
def scrub(n: long) -> long { if (n == 0) { 0 } else { self(n - 1) + n } }

def churn() -> long {
    let held: [str] = [];
    for i in 0..40 { keep(held, i); };
    print(scrub(200));
    // A cycle, then blocks of every size the lost ones had: a block the
    // collector freed would be zeroed and handed out again here.
    heap {
        let big = [0; 40000];
        let reuse: [[str]] = [];
        for i in 0..3000 {
            let row: [str] = [];
            for j in 0..64 { row += pad(j + 7000); };
            reuse += row;
        };
        if (big.length + reuse.length == 0) { print("never"); };
    }
    let total = 0;
    foreach (s in held) { total += s.length; };
    print(held[39]);
    total
}

region { print(churn()); }

// The collector's heap goes on after the region, and a later region reuses
// the chunk the first one kept.
let after: [str] = [];
for i in 0..30 { after += pad(i); };
region {
    let t = [1, 2, 3] + [4];
    print(t.length + after.length);
}
print(after[29]);
