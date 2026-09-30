# Not Done
- all features used in TODO.y and exhaustive tests




# Done
(remember to verify items without "DONE" if not done move up to not done, then remove that label and this message)

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
- the optimizer's loop paid the runtime-in-Y trade down (SCORE 110.78,
  bench/compare.sh of `6a753ae` against `ea83b05`: self-compile +21%,
  string-heavy output +30.8%, heap -18.7%). What the loop left open, in
  order of measured size:
  - `y_alloc` costs two `brk` syscalls per allocation and sits under
    every string/array operation. Caching the break needs a home: %r12
    was rejected (the prelude helpers push/pop it, which would rewind the
    cache and hand out overlapping blocks) and the ELF has no writable
    segment — so this wants either a .data segment in asm.y/elf.y or a
    helper rework that frees a callee-saved register. Measured upside is
    the largest remaining lever.
  - `y_str_join` builds with push-per-byte (the asm_text joins move MBs
    per self-compile); either it returns to being a byte mover in
    arch_x64.y or the emit path stops joining into one string at all.
  - `from_bytes` could accept a fixed `[byte; N]` (the runtime already
    reads the same header), which would drop an allocation from
    y_long_tostr and y_str_chr.

- add type aliasing (type a = [int])
- DONE: reduce raw assembly embeded inside ycc, try to do more with y code in std.
  (`src/y/std/rt.y` is the runtime library written in Y, spliced in front of
  every program; tree shaking drops what a program does not reach. The rule
  is that arch_x64.y provides small general PRIMITIVES — allocator, traps,
  record lookup, byte-moving string/array cores, float formatting, argv —
  and Y provides behaviour: number formatting, the print/put/eput family,
  `trim`/`ord`/`chr`/`tonum`/`index_of`/`join`/`split`, `range`, time,
  files. arch_x64.y went from 2357 lines to 976; `readline()` and `exec()`
  made the same move earlier.)
- DONE: tree shaking (only the code a program reaches ships).
  (`prune_bodies` drops uncalled functions; `shake_refs` drops unreferenced
  arch-prelude and rodata blocks. A hello world is an 8 KB binary whose
  hand-written runtime is just the allocator, the str<->[byte] bridge and
  the digit loop of `y_long_tostr`.)
- DONE: optional std libraries imported by name (`import net;`, `net.xxx`).
  (A module is a plain Y file in `src/y/std/` — add one by dropping a file
  there; `std_resolve` in native.y finds it next to the importer (vendor or
  shadow), then in `std/` and `src/y/std/` from the cwd and the ycc binary.
  `src/y/std/net.y` — TCP over raw sockets plus a tiny HTTP server — is the
  first one: `net.listen_http(8080, handler)` / `net.listen_tcp(22, handler)`.
  Its functions flatten into one namespace with the other modules, so they
  carry uncollidable names (`close_fd`, `send_str`); a `ui` module lands the
  same way.)
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