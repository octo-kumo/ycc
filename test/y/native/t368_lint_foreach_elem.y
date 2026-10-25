// flags: --warnings=all
def f(a: [long]) -> long {
    let s = 0;
    a.foreach((_el, i) => { // expect-warning: the element parameter of this 'foreach' is unused; use it instead of indexing 'a' again
        s += a[i];
    });
    s
};
def main() -> long { print(f([1, 2, 3])); 0 };
exit(main());
