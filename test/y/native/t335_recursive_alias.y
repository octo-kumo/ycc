// A type alias may refer to itself through an ARRAY, an OPTION or a MAP, not
// only through a record field or a function type (TODO.md item 1). Each is a
// heap object with a header at run time, so the cycle is closed by a pointer
// -- the same reason a record field always worked. A cycle with NO
// indirection is still refused (e142_alias_cycle.y).
//
// This also turned up two bugs the new spellings could reach and nothing
// else could: an empty `{}` stored into a map of maps was created as an
// empty RECORD (its `!` then dereferenced a record as a map -- a SIGSEGV),
// and the map's value type was not unfolded where the emitter chooses
// map-vs-array and where the checker adopts an empty literal.
type Ids = [Ids];                     // array of itself
type Maybe = Maybe?;                  // option of itself
type Tree = { str => Tree };          // map of itself
type A = [B];                         // mutual, through two arrays
type B = [A];
type Node = { v: long, kids: [Node] };

def ids_len(x: Ids) -> long { len(x) };
def a_len(x: A) -> long { len(x) };
def b_len(x: B) -> long { len(x) };
def tree_len(t: Tree) -> long { len(t) };
def node_sum(n: Node) -> long {
    let s = n.v;
    foreach (k in n.kids) { s = s + node_sum(k); };
    s
};

let i: Ids = [];
print(ids_len(i));
let maybe: Maybe = none;
print(is_some(maybe));

let t: Tree = {};
t["a"] = {};
t["b"] = {};
print(tree_len(t));
// the stored value is itself a Tree; the empty map must read back as one
let sub: Tree = t["a"]!;
print(tree_len(sub));
sub["c"] = {};
print(tree_len(sub));
print(tree_len(t));
print(len(t["a"]!["c"]!));

let n: Node = { v: 3, kids: [{ v: 4, kids: [] }, { v: 5, kids: [] }] };
print(node_sum(n));

let a: A = [];
let b: B = [];
print(a_len(a));
print(b_len(b));
