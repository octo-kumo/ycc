// flags: --gc=never
import memstat;
// `region { .. }` frees everything its block allocates -- its callees'
// allocations too -- when the block ends, so
// with no collector at all a loop that churns a gigabyte stays small.

def churn(i: long) -> long {
    let xs: [long] = [];
    for j in 0..2000 { xs += j + i; };
    let s = "";
    for j in 0..300 { s = s + tostring(j % 10); };
    let parts = s.split("5");
    xs.length + s.length + parts.length
}

let total = 0;
for i in 0..20000 {
    region { total += churn(i); }
}
print(total);
// rss_kb() is -1 where the OS does not report it (a PE): then nothing to check.
let rss = memstat.rss_kb();
print(rss < 65536);

// Nested: an inner region's values die with it, the outer one's live on.
region {
    let outer = [1, 2, 3];
    for k in 0..3 {
        region {
            let inner = outer + [k * 10];
            outer[k] = inner[3] + inner.length;
        }
    }
    print(outer);
}

// More than a chunk at once, and many chunks in one region.
region {
    let big = [7; 400000];
    let sum = 0;
    for j in 0..20 {
        let b = [j; 100000];
        sum += b[99999];
    }
    print(big[399999] + sum);
}

// `heap { .. }` allocates outside the region: what it makes outlives it.
let kept: [str] = [];
// Three setup calls are finite; a repeating heap escape needs --gc=auto.
def remember(i: long) {
    region {
        let tmp = "tmp" + tostring(i);
        heap { kept += tmp[0:3] + tostring(i * 2); }
    }
}
remember(0); remember(1); remember(2);
print(kept);
heap { print("outside any region"); }
