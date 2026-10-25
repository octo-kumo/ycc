// A callback updates the enclosing local accumulator.
def total() -> long {
    let a: [long] = [1, 2, 3, 4];
    let t = 0;
    a.foreach((x) => { t += x; });
    t
};
print(total());
