// Option propagation: `x?.f` is `f` when x is there and none when x is
// not, and so is every link after it -- `x?.a.b` reads a.b only when x is
// there, and `x?.[i]` is an index that gives none rather than trapping.
// The result is an option (the value or none), so a `?.` may follow it.
type Leaf = { tag: str };
type Mid  = { leaf: Leaf?, n: long };
type Deep = { mid: Mid, name: str, xs: [long], part: str };

def here() -> Deep? {
    some({ mid: { leaf: some({ tag: "T" }), n: 7 }, name: "nm",
           xs: [10, 20, 30], part: "a b c" })
};
def gone() -> Deep? { none };

// the value when the receiver is there, none when it is not
print(here()?.name);
print(gone()?.name);
print(here()?.mid.n);
print(gone()?.mid.n);

// the whole chain after the `?.` propagates: `.length` is read off the
// name, and a call too, but only where the object is there
print(here()?.name.length);
print(gone()?.name.length);
print(here()?.part.split(" "));
print(gone()?.part.split(" "));

// an optional field in the middle needs no `!` of its own, and the chain
// ends in ONE option: `here()?.mid.leaf` is already `Leaf?`
print(here()?.mid.leaf?.tag);
print(gone()?.mid.leaf?.tag);

// `?.[i]`: an index that propagates too, on a none and on a present array
print(here()?.xs[1]);
print(gone()?.xs[1]);
print(here()?.xs[0:2]);
print(gone()?.xs[0:2]);

// a `?.` partway down a chain that already propagates
print(here()?.mid.leaf?.tag.length);
print(gone()?.mid.leaf?.tag.length);

// the receiver is read once, chain or no chain: the call below happens
// three times and no more
let calls = 0;
def counted() -> Deep? { calls = calls + 1; some({ mid: { leaf: none, n: 1 }, name: "c", xs: [], part: "" }) };
let cd = counted();
print(cd?.name, " ", calls);
print(counted()?.name.length, " ", calls);
print(counted()?.mid.leaf?.tag, " ", calls);

// the value is an option: `!` unwraps it, and is_some says which
let p = here()?.name;
print(is_some(p), " ", unwrap(p));
let q = gone()?.name;
print(is_some(q), " ", q);

// a void call through `?.` runs where the object is there, and nowhere else
type Box = { hits: long, bump: (Box) -> void };
def bump_it(b: Box) -> void { b.hits = b.hits + 1; };
let b: Box? = some({ hits: 0, bump: bump_it });
let nb: Box? = none;
b?.bump(b!);
nb?.bump(b!);
print(unwrap(b).hits);