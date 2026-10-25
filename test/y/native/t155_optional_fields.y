// A record field written `name?: T` is optional: its type is T?, and a
// literal where the record type is declared may leave it out (none) or
// give it a plain T (wrapped, some), as well as a T? or none. `{a?: long}`
// and `{a: long?}` are one type: only literals see the difference.
type Opts = { url: str, timeout?: long, retries?: long, tag?: str };
def show(o: Opts) {
    print(o.url, " ", o.timeout, " ", o.retries, " ", o.tag);
};
show({ url: "a" });
show({ url: "b", timeout: 5 });
let t: long? = some(7);
show({ url: "c", timeout: t, tag: "x" });
show({ url: "d", retries: none });

// every field optional: {} is a value
type Cfg = { verbose?: bool, depth?: long };
def depth(c: Cfg) -> long { if (is_some(c.depth)) { c.depth! } else { -1 } };
let c: Cfg = {};
print(depth(c), " ", depth({ depth: 3 }), " ", is_some(c.verbose));

// a plain value converts as any store does, then is wrapped
type P = { x: float, y?: float };
let p: P = { x: 1, y: 2 };
print(p.x, " ", p.y!);

// the same type as one with a T? field, which a literal must give
type Q = { x: float, y: float? }; // expect-warning: type 'Q' is the same type as 'P'
let q: Q = p;
print(q.y!);
let q2: Q = { x: 0.5, y: none };
let p2: P = q2;
print(is_some(p2.y));

// nested literals, a recursive type, union members
type Item = { v: long, next?: Item };
let chain: Item = { v: 1, next: { v: 2, next: { v: 3 } } };
print(chain.v, " ", chain.next!.v, " ", chain.next!.next!.v, " ", is_some(chain.next!.next!.next));
type Circle = { k: str, r: float };
type Rect = { k: str, w: float, h?: float };
type Shape = Circle | Rect;
let shapes: [Shape] = [];
shapes += { k: "circle", r: 1.0 };
shapes += { k: "bar", w: 2.0 };
shapes += { k: "box", w: 2.0, h: 3.0 };
foreach (s in shapes) {
    match s {
        Circle c => print(c.k, " r ", c.r),
        Rect { k, w, h } => print(k, " ", w, " x ", is_some(h) ? h! : w)
    };
};

// an optional parameter of such a type takes a literal too
def get(path: str, opts?: Opts) -> str {
    if (is_some(opts)) { path + " " + opts!.url + " " + tostring(opts!.timeout) } else { path }
};
print(get("x"));
print(get("y", { url: "z", timeout: 9 }));
print(get("w", { url: "v" }));
let o: Opts? = some({ url: "q" });
print(o!.url, " ", o!.tag);
