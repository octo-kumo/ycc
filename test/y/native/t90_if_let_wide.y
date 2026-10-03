// `if let` against the rest of the language: every pattern a match arm
// takes, every subject the language can produce an option from, and the
// statement forms it sits inside -- loops, closures, `match` arms, a
// `return`, a function's value.
type Leaf = { tag: str, n: long };
type Cfg = { port: long, host: str };
type Rect = { w: long, h: long };
type Named = { label: str, w: long };
type Shape = Rect | Named;
type Holder = { leaf: Leaf?, cfg: Cfg? };

let table: {str => long} = { "a": 1 };
let node: Holder = { leaf: some({ tag: "L", n: 4 }), cfg: some({ port: 8, host: "h" }) };
let bare: Holder = { leaf: none, cfg: none };
let text: str = "  Trim  Me  ";
let nums: [long]? = some([5, 6, 7]);
let lf: Leaf = { tag: "L", n: 5 };
let leaves: [Leaf?] = [some({ tag: "A", n: 1 }), none, some({ tag: "B", n: 2 })];
let slots: [long?] = [some(1), none, some(3)];
let counter = 0;

def counted() -> long? { counter = counter + 1; some(counter) };
def deep() -> { cfg: Cfg? }? { some({ cfg: some({ port: 80, host: "wrap" }) }) };
def optional(p: long?) -> long { if let some(v) = p { v } else { -1 } };
def worker() -> long? { some(4) };

// every subject shape, one line each
if let some(v) = table["a"] { print("map ", v) } else { print("map none") };
if let some(v) = table["zz"] { print("map ", v) } else { print("map none") };
if let some(rec) = node.leaf { print("field ", rec.tag) } else { print("field none") };
if let some(rec) = bare.leaf { print("field ", rec.tag) } else { print("field none") };
if let some(c) = node.cfg { print("nested ", c.port, " ", c.host) } else { print("nested none") };
if let some(arr) = nums?.[0:2] { print("slice ", len(arr)) } else { print("slice none") };
if let some(rec) = leaves[2] { print("element ", rec.tag) } else { print("element none") };
print("param ", optional(some(6)), " ", optional(none));
if let some(v) = counted() { print("call ", v) } else { print("call none") };
print("calls ", counter);
if let some(c) = deep()?.cfg { print("propagated ", c.host) } else { print("propagated none") };
if let some(h) = node.cfg?.host { print("chained ", h.length) } else { print("chained none") };
if let some(h) = bare.cfg?.host { print("chained ", h) } else { print("chained none") };
let th = spawn { worker() };
if let some(v) = join(th) { print("thread ", v) } else { print("thread none") };

// every pattern a match arm takes
if let Leaf { n: k } = lf { print("destructure ", k) } else { print("destructure none") };
if let Leaf { tag: t } = lf { print("value ", t) } else { print("value none") };
if let "L" = lf.tag { print("literal str") } else { print("literal str no") };
if let "Q" = lf.tag { print("literal str") } else { print("literal str no") };
if let 5 = lf.n { print("literal long") } else { print("literal long no") };
if let true = lf.n > 1 { print("literal bool") } else { print("literal bool no") };
let sh: Shape = { label: "sq", w: 3 };
if let Named s = sh { print("union ", s.label, " ", s.w) } else { print("union other") };
if let Rect r = sh { print("union ", r.h) } else { print("union other") };
if let Rect { h: hh } = sh { print("union ", hh) } else { print("union other") };
if let some() = slots[1] { print("some() hit") } else { print("some() miss") };
if let some() = slots[0] { print("some() hit") } else { print("some() miss") };
if let some(v) = slots[1] { print("some ", v) } else { print("no value") };
if let none = some(1) { print("bare none hit") } else { print("bare none miss") };

// the subject is read once, whatever the pattern and however it fails
let hits = 0;
def once() -> long? { hits = hits + 1; if (hits < 3) { some(hits) } else { none } };
if let 2 = once()! { print("two") } else { print("not two") };
if let some(v) = once() { print("got ", v) } else { print("nothing") };
print("hits ", hits);

// as a value: a function's tail, an argument, an f-string field
def first_or(o: long?, alt: long) -> long {
    if let some(v) = o { v } else { alt }
};
print(first_or(some(9), 0), " ", first_or(none, 0));
let inline = if let some(c) = node.cfg { c.port } else { -1 };
print(inline);
print(f"{(if let some(c) = node.cfg { c.host } else { "-" })}");
let nested = if let some(rec) = node.leaf { rec.n + if let some(v) = slots[0] { v } else { 0 } } else { -1 };
print(nested);

// in a return, and inside a loop's body
def find(o: long?) -> long {
    if let some(v) = o { return v * 10 };
    -1
};
print(find(some(4)), " ", find(none));
let total = 0;
let i = 0;
while (i < len(slots)) {
    if let some(v) = slots[i] { total = total + v };
    i = i + 1;
};
print("total ", total);
for k in 0..len(slots) {
    if let some(v) = slots[k] { total = total + v }
};
foreach (e in slots) {
    if let some(v) = e { total = total + v } else { total = total + 100 }
};
print("total ", total);
foreach (e in leaves) {
    if let some(rec) = e { total = total + rec.n }
};
print("total ", total);

// inside a closure, over a captured option, sharing the write out
let outer: long? = some(3);
let seen = 0;
let look = def() -> long {
    if let some(v) = outer { seen = seen + v };
    seen
};
print(look(), " ", look(), " ", seen);

// inside a match arm, and a match inside `if let`
let shapes: [Shape] = [];
shapes += { w: 1, h: 2 };
shapes += { label: "n", w: 3 };
foreach (s in shapes) {
    match s {
        Named n => {
            if let some(w) = counted() { print("arm ", n.label, " ", w) } else { print("arm none") }
        },
        _ => print("arm other")
    }
};
print(match table["a"]! { 1 => "one", _ => "other" });
if let some(v) = table["a"] { print(match v { 1 => "one", _ => "other" }) };

// the binding is scoped to the body only
let same = "outer";
if let some(v) = slots[0] { print("body ", v, " ", same) };
print("after ", same);

// the arms may disagree: the `if` is then void, which a `let` would refuse,
// but as a statement it only matters which arm runs
if let some(v) = slots[0] { print("first ", v) } else { print("first arm") };
if let some(v) = slots[1] { print("second ", v) } else { print("second arm") };