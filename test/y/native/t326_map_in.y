// TODO.md item 14: `"k" in m` -- is that key in the map.
//
// `in` is a KEYWORD (`for x in xs`, `foreach (k in keys(m))`), so this is a new
// position for it rather than a new keyword, and it binds as a comparison:
// looser than arithmetic, tighter than `&&`/`||`. It costs what a map read
// costs -- the same key scan, in its "has" form -- and it is the way to ask a
// map about a key without naming the value's type, which `if let long v =
// m["k"]` has to.
let m: { str => long } = { "a": 1, "b": 2 };
print("a" in m, " ", "zz" in m, " ", typeof("a" in m));

let empty: { str => long } = {};
print("a" in empty, " ", len(keys(empty)), " ", empty.length);

// precedence: a comparison
print(1 + 1 == 2, " ", ("a" in m) && ("b" in m), " ", "a" in m && false);
print(!("zz" in m), " ", ("a" in m) == true, " ", 2 > 1 == "a" in m);

// every key type (a map literal writes string keys only, so these are built)
let by_long: { long => str } = {};
by_long[1] = "x";
print(1 in by_long, " ", 2 in by_long);
let by_byte: { byte => str } = {};
by_byte[7b] = "y";
print(7b in by_byte, " ", 8b in by_byte);

// exactly once: the map and the key are each evaluated one time
def map_of(k: str) -> { str => long } {
    print("map");
    let out: { str => long } = {};
    out[k] = 1;
    out
}
def key_of(k: str) -> str { print("key"); k }
print(key_of("k") in map_of("k"), " ", key_of("zz") in map_of("k"));

// and it agrees with the two read spellings it sits beside
print(m.a, " ", "b" in m, " ", m["b"] != none, " ", is_some(m["zz"]));
print("a" in m, " ", m["a"]! == 1);

// and it works where a bool is wanted: the guard of a read-modify-write
let counters: { str => long } = { "hits": 0 };
if "hits" in counters { counters["hits"] = counters["hits"]! + 1; };
if "misses" in counters { counters["misses"] = 1; };
print(counters, " ", "misses" in counters);