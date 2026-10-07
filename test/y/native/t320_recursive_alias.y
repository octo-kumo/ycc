// TODO.md item 1: a recursive `type` alias may reach itself through any of the
// five heap indirections, not only a record field or a function type. A
// pointer, an array, a fixed array, an option and a map each hold what they
// hold behind a header (or an address), so the value inside can be smaller
// than the alias -- which is the whole reason a record field was allowed to
// reach back. Before, the one-field wrapper record was the price, and
// std/json.y still carries a `jobj()` that exists only to satisfy the rule.
//
// What does NOT work is the nesting, not the cycle: a value of one of these
// types can only be built through a store (`t["a"] = kid;`) or a binding
// (`let kid: Tree = {};`), never as a nested literal in one expression --
// `t["a"] = {}` is "map value: expected Tree, got {  }", and it said the same
// for a plain `{str => {str => long}}` before this item.

// ── an array of itself ───────────────────────────────────────────────────
type Ids = [Ids];

let leaf: Ids = [];
let xs: Ids = [];
// `+=` on arrays appends the other side's ELEMENTS, and an `Ids` is a list of
// `Ids`, so `xs += leaf` appends leaf's (zero) elements -- the reading the
// language gives every array of arrays. `*=` prepends one item, and `[leaf]`
// is a one-element array of `Ids` to append.
xs *= leaf;
xs += [leaf];
xs[0] = leaf;
print(len(xs), " ", len(xs[0]), " ", xs.length, " ", len(xs));
print(len(xs[0:1]));         // a slice is a new array of the same shape
foreach (e in xs) { print("elem ", len(e)); };

// ── a map of itself ──────────────────────────────────────────────────────
type Tree = { str => Tree };

let kid: Tree = {};
let t: Tree = {};
t["a"] = kid;
print(len(t), " ", len(t["a"]!), " ");
print("missing is none: ", t["zz"] == none);
print("typeof: ", typeof(t));
foreach (k in t) { print("key ", k, " -> ", len(t[k]!)); };

// the cast the manual documents still works through the alias
let also_a: Tree = t["a"]!;
print("cast ", len(also_a));

// ── an option of itself ──────────────────────────────────────────────────
// An alias that is its own option is an endless nesting, so `none` is the only
// finite value of the type: `let x: Maybe = some(1);` is "expected Maybe, got
// long?" because `Maybe` is `Maybe?`, which is `Maybe??`, and so on. The option
// of an alias is the useful shape -- that is the `List` above, written out.
type Maybe = Maybe?;

let none_m: Maybe = none;
if is_some(none_m) { print("no"); } else { print("none is empty"); };

type Wrap = Maybe?;          // one option layer over a self-referential alias
let one: Wrap = some(none);  // so `some(1)` is "expected Maybe?, got long?"
if is_some(one) { print("one holds a Maybe"); } else { print("bad"); };
let none_w: Wrap = none;
if is_some(none_w) { print("bad2"); } else { print("wrap none ok"); };

// ── a pointer to itself ──────────────────────────────────────────────────
// The declaration is the whole of it: `*Cell` is "a pointer to a Cell", and
// nothing is a Cell (that is what the alias says), so there is no `&x` that
// makes one and no value to pass. It is a type a signature can name.
type Cell = *Cell;

def holds(c: Cell) -> long { 1 }

print("pointer alias declared");

// ── a record, which always worked ────────────────────────────────────────
type List = { head: long, tail: List? };

let l: List = { head: 1, tail: some({ head: 2, tail: none }) };
print(l.head, " ", l.tail!.head);