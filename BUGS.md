# List of all bugs of YCC
Only include bugs of the compiler, make sure to include minimal reproduction.

***INSTRUCTIONS WHEN FINISH*** remove the BUG item from this file when it has been completed

## The C copy OOMs where the Y copy hits the meta generator's 32 MiB cap

A `#{ ... }#` block whose text grows past `MG_MAX` (33554432, `src/y/meta.y`
and `src/c/meta.c`) must stop with `error: the meta generator emitted more
than 33554432 bytes`. The Y compiler does, and in well under a second; the C
copy instead keeps going (quadratic-looking) and dies with `runtime error: out
of memory`, so the two copies disagree on a hostile input. Found by the fuzzer
(seed 9432, iteration 264: a mutation of `test/y/native/e184_meta_emits_too_much.y`).

### Minimal reproduction

```y
def huge() -> str {
    let line = "0123456789012345678901234567890123456789";
    let out = "";
    for i in 0..600000 { out += line; };
    out
};
let x = #{ huge() }#;
print(1);
```

`./ycc f.y -o /tmp/x` prints `1` and then `error: the meta generator emitted
more than 33554432 bytes`; `./cycc f.y -o /tmp/x` runs for minutes and OOMs
under `ulimit -v 2000000`. Both exit 1, so only the message differs -- but the
C copy never reaches the cap, which is the bug.

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
