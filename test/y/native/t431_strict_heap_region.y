// flags: --strict-heap
// --strict-heap and regions: a region places what it allocates, and what the defs it calls allocate:
// none of this repeats unfreed. `heap { .. }` takes its block back out.
def scratch(i: long) -> [long] { [i, i * 2] }
let cache: [str] = [];
for i in 0..3 {
    region {
        let row = scratch(i) + [i];
        let s = tostring(row.length) + "x";
        heap { cache += "c" + tostring(i); } // expect-warning: heap: this string concatenation repeats in a loop // expect-warning: heap: the call to 'tostring' repeats in a loop
        print(s);
    }
}
print(cache);
