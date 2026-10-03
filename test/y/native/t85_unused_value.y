// flags: -W 1
// Level 1: a read or a literal used as a statement. Each computes a
// value nobody reads; a `let` binding the same expression is fine.
type Rec = { a: long, b: str };

def go(r: Rec, xs: [long]) -> long {
    r.a;                 // expect-warning: the value computed here is not used
    xs[0];               // expect-warning: the value computed here is not used
    xs[0:2];             // expect-warning: the value computed here is not used
    &r;                  // expect-warning: the value computed here is not used
    { a: 1, b: "" };     // expect-warning: the value computed here is not used
    [1, 2];              // expect-warning: the value computed here is not used
    [7; 2];              // expect-warning: the value computed here is not used
    // the same reads, bound this time
    r.a + xs[0]
};
let r: Rec = { a: 5, b: "x" };
let xs: [long] = [3, 4, 5];
print(tostring(go(r, xs)), " ", r.a, xs[0]);
