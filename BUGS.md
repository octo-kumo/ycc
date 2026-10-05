# List of all bugs of YCC
Only include bugs of the compiler, make sure to include minimal reproduction.

***INSTRUCTIONS WHEN FINISH*** remove the BUG item from this file when it has been completed

## An imported module's `type` alias does not resolve under its qualified name

A `type` alias declared in an imported module is visible from the importing file
under its BARE name and not under the module-qualified one. `import m from
"./mod.y"` then `let p: m.Pair` is rejected with `unknown type 'm.Pair'`, while
the same program with `let p: Pair` compiles and runs. Since the qualified form
is what a program uses to say which module's alias it means -- and the only form
that is unambiguous when two modules declare the same alias name -- the bare form
working is not a workaround but a second, incompatible resolution of the same
declaration.

### Minimal reproduction

```y
// mod.y
type Pair = { a: long, b: long };
def mk(a: long, b: long) -> Pair { { a: a, b: b } };
```
```y
// main.y
import m from "./mod.y";
let p: m.Pair = m.mk(1, 2);      // error: unknown type 'm.Pair'
print(p.a + p.b);
```

```
$ ycc main.y -o main
2:1: error: unknown type 'm.Pair'
```

Change `m.Pair` to `Pair` and it compiles, runs, and prints `3`.

### Verified matrix

Reproduced with `refs/ycc.ref` -- so it predates the current tree and is not
from anything recent. Deterministic across runs. Both spellings, one program
pair:

**Fails:**

```y
let p: m.Pair = m.mk(1, 2);
```

**Works:**

```y
let p: Pair = m.mk(1, 2);
```

### Where it happens

`rename.rn_drop_typedefs` (rename.y 577) removes every top-level `typedef` from
the statement list, which is correct: an alias has no value and nothing to emit.
The alias is meant to survive in the checker's `st.tys`, and `rn_prepass_one`
(rename.y 187) registers it -- qualified as `m.T` when the statement belongs to a
module, bare otherwise:

```
// aliases hoist like defs: every annotation in the block sees them.
// A module's are its own: `m.T`, the names of its aliases in T
// qualified the same way (rn_qual_type).
```

So the qualified key is created and the lookup misses it. Either `rn_mods` is
empty by the time the prepass runs for this statement -- `rn_mod_types` is built
later, at rename.y 1465, so the prepass cannot see it yet -- or the checker's
resolution of a qualified type does not consult that key. The symptom says the
former: the bare registration is the one that takes effect.

### Note

This is also why a `type` alias does not appear in a language server's AST walk:
it is not a statement by the time the tree is walked. Any index of declarations
has to take aliases from `st.tys` (or from a scan of the source), not from the
statement list -- see LSP.md 11.4.

## A field of an `if let`-narrowed binding loses its map/array type

When the value of an `if let` arm is produced *from* the narrowed binding's map-
or array-typed field, that field is seen as `void`. The rejection is spurious and
the diagnostic is wrong: `cannot index void (only arrays and maps)` fires for
`keys(x.v)`, where the source contains no index operation at all.

### Minimal reproduction

```y
type TA = { n: long };
type TC = { v: { str => long } };
type U = TA | TC;

def bad(u: U) -> [str] {
    if let TC c = u { return keys(c.v); }
    []
}
```

```
$ ycc bug.y -o bug
7:5: error: cannot index void (only arrays and maps)
```

### Verified matrix

Reproduced with `refs/ycc.ref`; deterministic across runs. Each case is
standalone — the four type declarations above plus one function.

**Fails:**

```y
// 1. keys() of the narrowed field, returned
def t1(u: U) -> [str] {
    if let TC c = u { return keys(c.v); }
    []
}

// 2. indexing the narrowed field, arm ends in a return
def t4(u: U) -> [str] {
    if let TC c = u { let k = "a"; if (is_some(c.v[k])) { return ["x"]; } }
    []
}

// 3. same, with the arm's value coming from an if/else
def t5(u: U) -> [str] {
    if let TC c = u { let k = "a"; if (is_some(c.v[k])) { ["x"] } else { [] } }
    ["y"]
}

// 4. binding the field to a local first does NOT help
def t7(u: U) -> [str] {
    if let TC c = u { let m = c.v; return keys(m); }
    []
}
```

**Compiles:**

```y
// 5. assign to an outer local, return after the arm
def t2(u: U) -> [str] {
    let r: [str] = [];
    if let TC c = u { r = keys(c.v); }
    r
}

// 6. keys() wrapped in another call
def t3(u: U) -> long {
    if let TC c = u { return len(keys(c.v)); }
    0
}

// 7. no narrowing: a plain parameter of the record type
def t6(c: TC) -> [str] { keys(c.v) }
```

Case 5 is the workaround: **never let the arm's value come from the narrowed
field — assign to a local declared outside the `if let` and read it after.**
Case 6 shows the field's type is correct when it is merely an argument, so the
loss is specific to the position, not to the binding. Case 7 shows narrowing is
what triggers it.

### Where the checker gets it wrong

Cases 2 and 3 index the field, so `cannot index void` is at least the right
*shape* of message — but the field is `{str => long}`, so `c.v[k]` is `long?`,
which is a perfectly valid map read. Case 1 and 4 never index anything, and
still get the indexing message.

### Workaround

As case 5. This is the shape `src/lsp/` code will have to use throughout, since
M4's symbol index narrows an AST node and reads its fields on nearly every node
kind.

### Why it matters here

Found while writing `src/y/std/json.y` (`LSP.md` §15), which calls `keys()` on
every object it emits.

### Suspected cause

Untraced. The field's type is right when it is an argument (case 6) and right
when read after the arm (case 5), and wrong when the arm's value derives from
it — so the narrowing's environment appears to be popped, or the expected type
of the arm's value installed, before the field's type is looked up. The
diagnostic text suggests the lookup yields void, which `keys`'s argument check
and the index check both then report as a non-array/non-map.
