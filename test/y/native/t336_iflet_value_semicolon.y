// The fix for the shape an old bug report kept recording: a `;` after
// the `if let` block. Without it, the `[]` on the next line is an index of
// the `if` (`e190_iflet_block_indexed.y` shows that diagnostic); with it, the
// `[]` is the function's own value and the narrowed field reads normally --
// no local copy of the map is needed, and none is taken.
type TA = { n: long };
type TC = { v: { str => long } };
type U = TA | TC;

// keys() of the narrowed field, as the arm's value, directly
def names_of(u: U) -> [str] {
    if let TC c = u { return sorted_names(keys(c.v)); };
    []
};

// a map READ of the narrowed field, in place, boxed by the map's own read
def one_of(u: U, k: str) -> long? {
    let hit: long? = none;
    if let TC c = u { hit = c.v[k]; };
    hit
};

def sorted_names(xs: [str]) -> [str] {
    let out: [str] = [];
    let rest = xs;
    while (len(rest) > 0) {
        let bi = 0;
        let i = 0;
        while (i < len(rest)) { if (rest[i] < rest[bi]) { bi = i; }; i = i + 1; };
        out += rest[bi];
        let nx: [str] = [];
        i = 0;
        while (i < len(rest)) { if (i != bi) { nx += rest[i]; }; i = i + 1; };
        rest = nx;
    };
    out
};

let a: U = { v: {"only": 5} };
let b: U = { n: 7 };
let na = names_of(a);
print(len(na));
print("|".join(na));
print(len(names_of(b)));
let h = one_of(a, "only");
if (h == none) { print("hit=none"); } else { print("hit=" + tostring(h!)); };
let m = one_of(a, "absent");
print("miss=" + tostring(m == none));
