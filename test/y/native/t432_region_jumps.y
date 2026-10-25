// flags: --gc=never
import memstat;
// A jump out of `region { .. }` or `heap { .. }` -- `break`, `continue`, a
// labelled jump, `return` -- leaves the block on the way (native.y
// gen_rg_leave_to), innermost first, so the region's memory is returned and the
// allocator is back where it was. With no collector, a jump that skipped the
// release would keep every turn's megabyte: tens of gigabytes here.

let n = 0;
for i in 0..4000 {
    region {
        let a = [i; 131072];
        if (i % 3 == 0) { continue; };
        if (i == 3998) { break; };
        n += a[0] % 2;
    }
}
print(n);

// `return` from inside nested regions and a heap block: all three are left,
// and the value survives (it is a long).
// Kept values are setup data. Repeated allocating heap escapes now require
// opting in to GC; the repeated returns below test region unwinding alone.
let kept = ["k0", "k1000", "k2000", "k3000"];
def pick(i: long) -> long {
    region {
        let a = [i; 131072];
        region {
            let b = a[0:4];
            heap {
                if (i % 1000 == 0) { return b.length + 100; };
            }
            if (i % 2 == 1) { return b[1]; };
        }
    }
    -1
}
let s = 0;
for i in 0..4000 { s += pick(i); }
print(s);
print(kept);

// A labelled jump to an outer loop leaves every region opened inside it.
let m = 0;
for i in 0..2000 {
    for j in 0..3 {
        region {
            let c = [j; 131072];
            if (j == 1) { continue i; };
            m += c[0] + 1;
        }
    }
}
print(m);
let rss = memstat.rss_kb();
print(rss < 65536);

// After all that, the allocator is the collector's again: this is outside any
// region and survives.
let after = [1, 2, 3] + [4];
print(after);
