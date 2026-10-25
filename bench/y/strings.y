// bench/y/strings.y — string building and searching: concat, tostring,
// string slicing, index_of, comparisons. This is the compiler's own hot shape
// (every emitted line is built this way).
def strings(n: long) -> long {
let hits = 0;
let i = 0;
let acc = "";
while (i < n) {
    let s = "item-" + tostring(i) + "-end";
    if (index_of(s, "-") == 4) {
        hits = hits + 1;
        0
    } else { 0; };
    if (s[:4] == "item") {
        hits = hits + 1;
        0
    } else { 0; };
    if (s != "item-x-end") {
        hits = hits + 1;
        0
    } else { 0; };
    acc = acc + "x";
    if (len(acc) > 512) {
        acc = "";
        0
    } else { 0; };
    i = i + 1;
    0
};
hits + len(acc)
};

print(strings(60000));
