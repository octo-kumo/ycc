// expect-error: 27:9: error: a reference made in this region is returned out of it
// expect-error: 33:19: error: a call through a function value inside a region: the compiler cannot see what it keeps
// expect-error: 41:9: error: a reference made in this region escapes to 'names', which outlives it
// expect-error: 42:16: error: this grows a value made outside the region, and the new block would be the region's
// expect-error: 43:9: error: this grows a value made outside the region, and the new block would be the region's
// expect-error: 44:13: error: a reference made in this region escapes to 'log', which outlives it
// expect-error: 45:9: error: a reference made in this region is stored into memory that outlives it
// expect-error: 47:21: error: this map read keeps a box of the entry in a map made outside the region (read it with '!' or test it with is_some)
// expect-error: 50:13: error: 'keep' may keep a reference or grow memory outside the region (it grows memory it was given or a global)
// expect-error: 51:13: error: 'grow' may grow or store into its argument 1, which was made outside the region
// expect-error: 52:22: error: 'spawn' inside a region (a region is one thread's, and a forked child would not have it)
// What is made in a region is freed when it ends, so nothing made there may be
// reachable after it (escape.y). Each of these would leave a dangling reference.
let names: [str] = [];
let counts: [long] = [];
let seen = {"z": 0};
let log = "";
type Rec = { name: str, n: long };
let rec: Rec = { name: "", n: 0 };
let cache: [str] = [];

def keep(s: str) -> void { cache += s; }
def grow(xs: [long]) -> void { xs += 1; }
def make(i: long) -> [long] {
    region {
        let a = [i, i];
        return a;
    }
    []
}
def call_it(f: (long) -> long) -> long {
    let r = 0;
    region { r = f(1); }
    r
}
def worker() { }

for i in 0..3 {
    region {
        let parts = split("a,b", ",");
        names = parts;
        counts += i;
        seen["k" + tostring(i)] = i;
        log += "x";
        rec.name = parts[0];
        rec.n = parts.length;
        let z = seen["z"];
        let zz = seen["z"]!;
        print(z == none || zz == 0 || seen["q"] == none || is_some(seen["q"]));
        keep("a" + tostring(i));
        grow(counts);
        let t = spawn(worker);
        join(t);
    }
}
print(make(1).length + call_it((x: long) => x));
