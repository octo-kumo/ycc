// TODO.md item 10: `.field` on a map.
//
// `m.k` is the entry named "k" -- the same thing `m["k"]` is, spelled with a
// dot -- so it reads and assigns as the VALUE, not as the option a bracket
// read gives, and the program stops when the entry is not there: a dot is a
// claim that the entry is there, and a typo must not read as `none`.
// `m["k"]` stays the probe and `m["k"]!` its answer.
//
// `m.length` is the number of entries (as for an array or a string), so a map
// with an entry called "length" reaches it with brackets. Nothing else is
// reserved: `keys(m)` and `values(m)` are the program's view of the map's two
// arrays, in the same insertion order, so keys(m)[i] and values(m)[i] are one
// entry.

let m: { str => long } = { "k": 1, "j": 2 };
print(m.k, " ", m.j, " ", m.length);

// assign, and read-modify-write: the entry is created if it is not there
m.n = 40;
m.k += 1;
m.n += 2;
print(m.k, " ", m.n, " ", m.length);

// a value type is irrelevant to the spelling
let s: { str => str } = { "greeting": "hi" };
print(s.greeting);
let b: { str => bool } = { "on": true };
print(b.on);
let o: { str => str? } = { "maybe": some("here"), "gone": none };
if let str t = o.maybe { print("got ", t); } else { print("no"); };
print(o.gone == none);

// nothing is reserved but `length`
let reserved: { str => str } = { "keys": "k", "vals": "v", "boxes": "b", "length": "L" };
print(reserved.keys, " ", reserved.vals, " ", reserved.boxes, " ",
      reserved["length"], " ", reserved.length);

// the pair: same order, same length, and a copy (not the live arrays)
let p: { str => long } = {};
p.b = 2;
p.a = 1;
let ks = keys(p);
let vs = values(p);
print(ks, " ", vs, " ", len(ks), " ", len(vs));
foreach (i in range(len(ks))) {
    print(ks[i], "=", vs[i], " ");
};
print("");
// the copies are independent of the map
ks += "zz";
vs[0] = 99;
print(len(ks), " ", len(keys(p)), " ", p.a, " ", values(p));

// `m.k` and `m["k"]!` are the same value
print(m.k == m["k"]!);

// a dot read reads its base exactly once, whatever it is an expression of
let made: { str => long } = { "v": 7 };
def give() -> { str => long } {
    print("built ");
    made
}
print(give().v, " ");
made.v = 8;
print(give().v, " ", made["v"]!);

// a dot through a call chain, and through an index
let maps: [{ str => long }] = [{ "a": 1 }, { "b": 2 }];
print(maps[0].a, " ", maps[1].b);