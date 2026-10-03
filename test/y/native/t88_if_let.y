// `if let PATTERN = EXPR { ... } else { ... }`: the block when EXPR matches
// PATTERN (with the pattern's names bound), the else when it does not. The
// `else` is optional, and a missing one is a statement -- not a value, and
// not an empty branch (the level-1 lint below must stay quiet).
type Leaf = { tag: str, n: long };
type Node = { leaf: Leaf?, name: str };

def payload(o: long?) -> long {
    if let some(x) = o { x } else { -1 }
};
print(payload(some(7)), " ", payload(none));

// both arms, with the binding visible in the first
let o: long? = some(7);
let n: long? = none;
if let some(v) = o { print("some ", v) } else { print("none") };
if let some(v) = n { print("some ", v) } else { print("none") };

// no else: nothing runs where the pattern does not match
if let some(v) = n { print("some ", v) };
if let some(v) = o { print("some ", v) };

// as an expression: the value is the arm that ran
print(if let some(v) = o { v * 2 } else { -1 });
print(if let some(v) = n { v * 2 } else { -1 });

// a record payload, and the fields of the bound value
let node: Node = { leaf: some({ tag: "T", n: 3 }), name: "root" };
let bare: Node = { leaf: none, name: "bare" };
if let some(rec) = node.leaf {
    print("leaf ", rec.tag, " ", rec.n);
};
if let some(rec) = bare.leaf {
    print("leaf ", rec.tag);
} else {
    print("no leaf");
};

// the record and type patterns a match arm takes, as `if let` takes them
let lf: Leaf = { tag: "L", n: 5 };
if let Leaf { n: k } = lf { print("k ", k) } else { print("no k") };
if let Leaf { tag: t } = lf { print("t ", t) } else { print("no t") };

// `some()` with no name: the test on its own
if let some() = o { print("any some") } else { print("none") };
if let some() = n { print("any some") } else { print("none") };

// a value pattern, and the subject read exactly once
let calls = 0;
def counted() -> long { calls = calls + 1; calls };
if let 2 = counted() { print("two") } else { print("not two") };
print("calls ", calls);

// `if let` over a propagated chain: the binding takes the option's payload,
// so the two agree on where the value is
let wrap: {leaf: Leaf?}? = some({ leaf: some({ tag: "P", n: 9 }) });
let hollow: {leaf: Leaf?}? = some({ leaf: none });
let absent: {leaf: Leaf?}? = none;
if let some(rec) = wrap?.leaf { print("propagated ", rec.tag) };
if let some(rec) = hollow?.leaf { print("propagated ", rec.tag) } else { print("nothing there") };
if let some(rec) = absent?.leaf { print("propagated ", rec.tag) } else { print("absent") };

// a loop over a list of options: the `if let` is the `while`'s body test
let items: [long?] = [some(1), none, some(3)];
let i = 0;
let total = 0;
while (i < len(items)) {
    if let some(v) = items[i] { total = total + v };
    i = i + 1;
};
print("total ", total);