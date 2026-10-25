// `if let T c = o` on an option whose payload is a record: the option's own
// none test, then the record bound as T. The `T { f, g }` field-list form too.
type Lvl = { n: long, tag: str };
def f(x: Lvl?) -> long { if let Lvl c = x { c.n } else { -1 } };
let o: Lvl? = some({ n: 5, tag: "s" });
let p: Lvl? = none;
if let Lvl c = o { print(c.tag) } else { print("none") };
if let Lvl c = p { print(c.tag) } else { print("none") };
if let Lvl { n, tag } = o { print(tag + tostring(n)) } else { print("none") };
print(f(o));
print(f(p));
// a recursive alias: the payload is the alias, not a record written out
type Node = { next: Node?, v: long };
def total(n: Node?) -> long { if let Node c = n { c.v + total(c.next) } else { 0 } };
print(total(some({ next: some({ next: none, v: 4 }), v: 3 })));
