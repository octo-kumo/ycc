// flags: --strict-heap --regions=off
import regex;
// (--regions=off: the loops here would otherwise become regions, which
// place what they allocate: t433_auto_region.y.)
// --strict-heap reports every allocation that repeats with nothing to free it
//; what runs a bounded number of times draws
// nothing, and the binary is the one a plain compile writes.

// Once: a top-level allocation, a def the top level calls once, a thread.
let table = [1, 2, 3];
def setup() -> { n: long, tag: str } { { n: len(table), tag: "t" + tostring(len(table)) } }
let cfg = setup();
def worker() { print([cfg.n].length); }
let t = spawn(worker);
join(t);
let t2 = spawn(() => { print("spawned " + cfg.tag); });
join(t2);

// In a loop: every kind of site.
let total = 0;
let big = 1n;
for i in 0..3 {
    let a = [i, i + 1]; // expect-warning: heap: this array literal repeats in a loop, and nothing frees it
    let z = [0; 4]; // expect-warning: heap: this array repeats in a loop, and nothing frees it
    let r = { x: i }; // expect-warning: heap: this record literal repeats in a loop, and nothing frees it
    let m = { "k": i }; // expect-warning: heap: this map literal repeats in a loop, and nothing frees it
    let s = "n" + tostring(i); // expect-warning: heap: this string concatenation repeats in a loop // expect-warning: heap: the call to 'tostring' repeats in a loop
    let b = a + z; // expect-warning: heap: this array concatenation repeats in a loop
    let c = b[0:2]; // expect-warning: heap: this slice repeats in a loop
    let parts = "a,b".split(","); // expect-warning: heap: the call to '.split' repeats in a loop
    big = big * 3n; // expect-warning: heap: this bigint arithmetic repeats in a loop
    total += r.x + unwrap(m["k"]) + c.length + parts.length + s.length;
}
print(total);
print(big);

// A closure: a def that captures a local is made where it is written.
def closures() -> long {
    let t = 0;
    for i in 0..3 {
        def bump(x: long) -> long { x + i } // expect-warning: heap: this closure repeats in a loop
        def plain(x: long) -> long { x * 2 }
        t += bump(1) + plain(i);
    };
    t
}
print(closures());

// A string `+=` grows one value in place -- unless something defeats that.
type Buf = { s: str };
def appends() -> long {
    let own = "";
    let read = "";
    let held = "";
    let b: Buf = { s: "" }; // expect-warning: heap: this record literal repeats: 'appends' is called in a loop
    let peek = () => { held.length }; // expect-warning: heap: this closure repeats: 'appends' is called in a loop
    let seen = 0;
    for i in 0..3 {
        own += "a";
        read += "b"; // expect-warning: heap: this copying string append repeats in a loop
        seen += read.length;
        b.s += "c"; // expect-warning: heap: this copying string append repeats in a loop
        held += "d"; // expect-warning: heap: this copying string append repeats in a loop
    };
    own.length + seen + b.s.length + peek()
}
for i in 0..2 { print(appends()); }

// An option is a box: `some` allocates, and so does a call handing one back.
def find(xs: [str], w: str) -> str? {
    let r: str? = none;
    foreach (x in xs) { if (x == w) { r = some(x) }; }; // expect-warning: heap: the call to 'some' repeats in a loop
    r
}
for i in 0..2 { print(find(["p" + tostring(i)], "p0") != none); } // expect-warning: heap: this array literal repeats in a loop // expect-warning: heap: this string concatenation repeats in a loop // expect-warning: heap: the call to 'tostring' repeats in a loop
let re = regex.compile("[0-9]+")!;
for i in 0..2 { print(regex.search(re, "ab 12") != none); } // expect-warning: heap: the call to 'regex.search' repeats in a loop

// In a def that repeats: why it does.
def fact(n: long) -> [long] {
    if (n == 0) { [1] } else { fact(n - 1) + [n] } // expect-warning: heap: this array literal repeats: 'fact' is recursive // expect-warning: heap: this array concatenation repeats: 'fact' is recursive // expect-warning: heap: this array literal repeats: 'fact' is recursive
}
def label(i: long) -> str { "#" + tostring(i) } // expect-warning: heap: this string concatenation repeats: 'label' is called in a loop // expect-warning: heap: the call to 'tostring' repeats: 'label' is called in a loop
def inner() -> [long] { [7] } // expect-warning: heap: this array literal repeats: 'inner' is called by 'outer', which repeats, and nothing frees it
def outer() -> long { inner()[0] }
def cb(x: long) -> str { tostring(x) } // expect-warning: heap: the call to 'tostring' repeats: 'cb' is used as a function value
print(fact(3));
for i in 0..2 { print(label(i)); print(outer()); }
let xs = [4, 5];
let ys = xs.map(cb);
xs.foreach((e) => { print([e]); }); // expect-warning: heap: this array literal repeats: a function literal is passed as a value
print(ys);
