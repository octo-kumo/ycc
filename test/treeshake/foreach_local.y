// The common captured shape: a local accumulator the literal captures. It is
// inlined too (the record lives on the stack for the loop), so the listing has
// no indirect call -- test/sh/test_treeshake.sh gates that and the size.
def total() -> long {
    let a: [long] = [1, 2, 3, 4];
    let t = 0;
    a.foreach((x) => { t += x; });
    t
};
print(total());
