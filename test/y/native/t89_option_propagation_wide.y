// `?.` against the rest of the language: every optional link of a record
// chain, arrays and maps and unions behind it, the loops, the string
// methods, closures, threads and f-strings reading through it. Each
// optional link carries its own `?.`, and the chain ends in ONE option.
type Leaf = { tag: str, n: long };
type Mid = { leaf: Leaf?, xs: [long], name: str };
type Cfg = { port: long, host: str };
type Deep = { mid: Mid?, cfg: Cfg? };

def here() -> Deep? {
    some({ mid: some({ leaf: some({ tag: "T", n: 3 }), xs: [1, 2, 3], name: "nm" }),
           cfg: some({ port: 80, host: "h" }) })
};
def hollow() -> Deep? { some({ mid: some({ leaf: none, xs: [], name: "" }), cfg: none }) };
def gone() -> Deep? { none };

// a chain of records with every link optional: the value where it is
// there, none from the first missing link on
print(here()?.mid?.leaf?.tag, "|", here()?.mid?.leaf?.n, "|", here()?.cfg?.port);
print(hollow()?.mid?.leaf?.tag, "|", hollow()?.cfg?.host, "|", gone()?.mid?.leaf?.tag);

// what hangs off the end of a propagated chain: a field, an index, a slice,
// `.length` and the string methods, each of them read only where the
// receiver is there
print(here()?.mid?.name.length, "|", here()?.mid?.xs[1], "|", here()?.mid?.xs[0:2]);
print(here()?.mid?.xs.length, "|", gone()?.mid?.xs.length, "|", gone()?.mid?.name.length);
print(here()?.cfg?.host.upper(), "|", here()?.cfg?.host.split("h"), "|", gone()?.cfg?.host.trim());

// an option of an array of options: `?.` at both levels, in every loop form
let items: [long?]? = some([some(1), none, some(3)]);
let i = 0;
let while_sum = 0;
while (i < unwrap(items?.length)) {
    if (is_some(items?.[i])) { while_sum = while_sum + unwrap(items?.[i]) };
    i = i + 1;
};
print(while_sum, "|", unwrap(items?.length));
let for_sum = 0;
for k in 0..unwrap(items?.length) {
    if (is_some(items?.[k])) { for_sum = for_sum + unwrap(items?.[k]) }
};
print(for_sum, "|", is_some(items?.[1]), "|", items?.[1]);
let fe_sum = 0;
foreach (e in [some(1), none, some(3)]) { fe_sum = fe_sum + len(tostring(e)) };
print(fe_sum);
let no_items: [long?]? = none;
print(no_items?.[0], "|", no_items?.length);

// maps: a read is already an option, so it prints as one, and a record
// read through it propagates; an option of a map indexes as one
let mo: {str => long?} = {};
mo["a"] = some(5);
print(mo["a"], "|", mo["b"], "|", mo["zz"]);
let mr: {str => Cfg} = { "x": { port: 1, host: "hx" } };
print(mr["x"]?.port, "|", mr["y"]?.port, "|", mr["x"]?.host.length);
let om: {str => long}? = some({ "k": 9 });
print(om?.["k"], "|", om?.["nope"], "|", unwrap(om?.["k"]));

// a union: the field every member has reads through `?.`, and a member's
// own field still needs the match first
type Rect = { w: long, h: long };
type Named = { label: str, w: long };
type Shape = Rect | Named;
let s1: Shape = { w: 2, h: 3 };
let s2: Shape = { label: "sq", w: 4 };
let shapes: [Shape]? = some([s1, s2]);
print(shapes?.[0]?.w, "|", shapes?.[1]?.w, "|", shapes?.length);
let one: Shape? = some(s2);
print(one?.w, "|", match one! { Named s => s.label, _ => "-" });

// a `?.` after a link that is not an option itself: the earlier `?.` has
// already made the chain an option, so this one reads through it
type Holder = { mid: str, deep: Cfg? };
let hold: Holder? = some({ mid: "m", deep: some({ port: 3, host: "dd" }) });
print(hold?.mid?.length, "|", hold?.mid?.upper(), "|", hold?.mid?.split("m"));
print(hold?.deep?.port, "|", hold?.deep?.host, "|", hold?.mid?.repeat(2));

// a str is bytes: `?.[i]` gives a byte, and `?.` a byte array a length
let text: str? = some("abc");
let digits: [byte]? = some(bytes("48"));
print(text?.[1], "|", text?.length, "|", digits?.[0], "|", digits?.length);

// an optional parameter is an option inside the def, like any other, and
// passing a plain value wraps it
def port_of(c?: Cfg) -> long? { c?.port };
print(port_of({ port: 7, host: "h" }), " ", port_of(), " ", port_of(unwrap(here()?.cfg)));

// a propagated chain in a return, and in an f-string field (with a spec)
def name_of(d: Deep?) -> str? { d?.mid?.name };
print(name_of(here()), "|", name_of(gone()), "|", name_of(hollow()));
print(f"{here()?.cfg?.port} {gone()?.cfg?.port}", "|", f"{here()?.cfg?.port:4}", "|", f"{here()?.cfg?.host:s}");

// inside a closure, over a captured option, and the value shared out
let captured: Cfg? = some({ port: 11, host: "cap" });
let bump = 0;
let read = def() -> str? { bump = bump + 1; captured?.host };
print(read(), " ", read(), " ", bump);
let seen: str? = none;
let take = def() -> void { seen = captured?.host };
take();
print(seen);

// threads and processes: the value a `join` hands back read through `?.`
def worker() -> Cfg? { some({ port: 5, host: "thr" }) };
let th = spawn { worker() };
print(join(th)?.port, "|", join(th)?.host.upper());

// `?.` in a ternary arm, and under the short-circuiting operators
let maybe: Cfg? = none;
print(1 == 1 ? maybe?.port : none, "|", maybe?.port || -1, "|", maybe?.port && -1, "|", unwrap(here()?.cfg?.port) > 0);

// a `const` naming an option, and `+=` on the value one holds: the payload
// is not a buffer that variable owns, so the append builds a new one and
// the option keeps the string it had
const host: str? = some("const-host");
print(host?.length, "|", host?.upper());
let grown: str? = some("ab");
let payload = grown!;
payload += "cd";
print(payload, "|", grown?.length, "|", grown?.upper(), "|", grown?.[0:3]);

// `!` takes the value out, and the propagation keeps working from there
let first: Cfg? = some({ port: 1, host: "a" });
let pulled = first!;
print(pulled.port, "|", pulled.host.length, "|", first?.port);