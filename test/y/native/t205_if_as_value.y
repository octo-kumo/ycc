// The forms that work, next to the one that doesn't (e175): an `if` in
// expression position is an expression, so a `[` after it indexes its value
// and a `;` after it makes it a statement. These are the ledger's shapes
// with that `;` in place -- all of them compile and run.
type TA = { n: long };
type TC = { v: { str => long }, w: long };
type U = TA | TC;

def t1(u: U) -> [str] {
    if let TC c = u { return keys(c.v); };
    []
}
def t2(u: U) -> [str] {
    let r: [str] = [];
    if let TC c = u { r = keys(c.v); };
    r
}
def t3(u: U) -> long {
    if let TC c = u { return len(keys(c.v)); };
    0
}
def t4(u: U) -> [str] {
    if let TC c = u { let m = c.v; return keys(m); };
    []
}
def t6(c: TC) -> [str] { keys(c.v) }

// an `if` as a value: the arms' values, picked from by an index or an `if`
def pick(c: bool) -> [str] { if (c) { ["y"] } else { ["z"] } }
def first(c: bool) -> str { pick(c)[0] }
print(t1({ n: 1 }));
print(t2({ v: { "k": 7 }, w: 1 }));
print(t3({ v: { "k": 7 }, w: 1 }));
print(t4({ v: { "k": 7 }, w: 1 }));
print(t6({ v: { "k": 7 }, w: 1 }));
print(first(true), " ", first(false));

// a block as a value, the same way: its value is the trailing expression,
// so `{ [["s"], ["t"]] }[1][0]` is "t"
def blk() -> str { { [["s"], ["t"]] }[1][0] };
print(blk());