// bench/y/trees.y — allocation-heavy recursion: build, walk and drop binary
// trees of records (the collector's bread and butter), plus plain recursion.
type T = { l: T?, r: T?, v: long };
def build(d: long, v: long) -> T? {
    if (d == 0) { none } else { some({ l: build(d - 1, v * 2), r: build(d - 1, v * 2 + 1), v: v }) }
};
def sum(t: T?) -> long {
    if let T n = t { n.v + sum(n.l) + sum(n.r) } else { 0 }
};
def depth_sum(n: long) -> long { if (n == 0) { 0 } else { n + self(n - 1) } };
def run() -> long {
    let total = 0;
    for i in 0..40 { total = total + sum(build(16, i)); };
    total + depth_sum(5000)
};
print(run());
