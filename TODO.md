- DONE: add 0xffab 0b101 1e10 1.2e-10 etc support
  (hex/binary integer literals with `_` separators in both frontends;
  scientific notation and float literals work in every engine now that
  the native backend has `float`)
- DONE: add built in byte type (ycc should try to use byte arrays, assembly should be optimized for bytes when bytes are used)
  (`byte` is an 8-bit unsigned integer in all three engines, and `[byte]`
  arrays are PACKED in the native backend — one byte per element, so 100k
  elements cost 256 KB instead of 2 MB. The element width flows from the
  static type into every access (`movzbq`/`movb`), into the allocation
  size, and into `push`/`slice`/`==`/`join`/`foreach`, which now take it
  as a parameter. `bytes(s)` / `from_bytes(b)` convert to and from `str`.)
- add type aliasing (type a = [int])
- DONE (mechanism landed, migration ongoing): reduce raw assembly embeded inside ycc, try to do more with y code in std.
  (`src/y/std/prelude.y` is runtime code written in Y, spliced ahead of the
  program when referenced. `readline()` is the first resident: ~90 lines of
  hand-written assembly became twenty lines of Y over the `syscall`
  intrinsic plus `bytes`/`from_bytes`. The rule is that arch_x64.y provides
  small general PRIMITIVES and the prelude provides behaviour; more of
  arch_x64.y can move across the same way.)
- DONE: add more type inference
  (native `def` return types are inferred from the body when unannotated;
  `let` locals were already inferred. Params still need annotations.)
- DONE: optimize arrays to be in place most of the time, clone has to be explicit or during concat.
  (arrays/maps/records are reference values in all three engines now —
  removing copy-on-store is what made self-hosting possible: the
  assembler went from 651 MB to 747 KB on a 20 KB binary)

- DONE: arr += elem should be added as language feature
  (also -=, *=, /= for any type: `x op= e` desugars to `x = x op e`)
- DONE: arr1 + arr2 should concat to form a new arr3
- DONE: arr + elem should concat, same goes for elem + arr
  (arrays win over strings in `+`; the operands are never mutated, so `+`
  is the explicit-copy counterpart of the in-place `push`)

- DONE: add JS/TS spread syntax `{a:1, ...b}` `{...c, ...d}`
  (C frontend; later keys win, sources are never mutated. The native
  frontend does not have it yet.)
- DONE: `str` ordering — `<`, `>`, `<=`, `>=` compare strings
  lexicographically in all three engines (they used to be a hard error:
  "Operands must be numbers"), so sorting strings needs no helper.

- is there some sort of code in ycc.y and the other .y that are due to a limitation in the language? are we missing some very convinient language feature? if yes add.
  Yes — the workarounds are catalogued in AGENTS.md ("Y code portability").
  Progress:
  - DONE: early `return` (the C frontend had none, so examples/ysh.y was
    being silently truncated at its first `return`).
  - DONE: `&&`/`||` short-circuit in all three engines (they were eager in
    the C frontend, which is why guards are written as nested ifs).
  - DONE: `x.y[i]` parses correctly — dot is a postfix suffix now, not a
    binary operator whose RHS swallowed the index.
  - DONE: `!x.y` means `!(x.y)` (postfix binds tighter than unary).
  - DONE: empty blocks `{}` are legal and safe in both engines.
  - DONE: dot-assign `s.f = v` works in the C frontend now (and
    `m["k"] = v` with it); the Y frontend already had it.
  - DONE: `self` no longer shadows a binding of that name — it is only
    bound as the recursion handle when the function has no parameter
    called `self`.
  All the workarounds listed in AGENTS.md "Y code portability" are now
  either fixed or reduced to `&x`/`*p` syntax (ycc-pipeline-only by
  design). The `0;` fillers and `let t = x.y;` bindings left in
  src/y/*.y are harmless and can be simplified opportunistically.

- DONE: closures and first-class functions in the native backend
  (`[code, caps...]` records; the closure is pushed deepest so param
  offsets match a direct call. Capturing functions are emitted at their
  creation site, because only the enclosing env knows capture types.)
- DONE: `for`, `for x in lo..hi`, `foreach`, `range()`, array slicing
  `a[lo:hi]`, structural array equality and anonymous `def` literals in
  the native backend.
- DONE: `float` (IEEE754 double) in the native backend — literals,
  arithmetic, comparison, negation, `tostring`, `print`, `str + float`.
- DONE: block expressions `{ let t = 1; t + 1 }` in the Y frontend.
  `{` is a record literal only for `{}` / `{key: ...}` / `{"key": ...}`;
  everything else is a block.
- DONE: calling an arbitrary expression — `(def(x){...})(41)`, `f0(21)`
  where `f0` came out of an array — not just a named function.