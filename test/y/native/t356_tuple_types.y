// Tuples: a parenthesized type list is a record with positional field names,
// so `.0`/`.1` reads and a tuple returned from a function are ordinary
// first-class record values.
def divmod(a: long, b: long) -> (long, long) {
    (a / b, a % b)
};

def sum(t: (long, long)) -> long { t.0 + t.1 };

def main() -> long {
    let tup: (long, str, float) = (1, "hello", 3.14);
    let inferred = (2, "world", 2.71);
    print(tup.0);
    print(tup.1);
    print(tup.2);
    print(inferred.0);
    print(inferred.2);
    let q = divmod(17, 5);
    print(q.0);
    print(q.1);
    print(sum((10, 20)));
    0
};

exit(main());
