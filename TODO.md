# Not Done
- everything still listed in TODO.y that the checker rejects (today:
  `match` without a catch-all or a type arm covering every union member,
  e.g. `match c { A a => 1, ({bfield: 10}) b => 2 }` on a `C = A | B` — a
  literal-value arm does not count as coverage)
- exhaustive tests for every feature (the audit corpus is at 65 cases; the
  native corpus at ~139)
-




# Done
(remember to verify items without "DONE" if not done move up to not done, then remove that label and this message)

- DONE: add 0xffab 0b101 1e10 1.2e-10 etc support
  (hex/binary integer literals with `_` separators in both compilers;
  scientific notation and float literals work now that the native backend
  has `float`)
- DONE: add built in byte type (ycc should try to use byte arrays, assembly should be optimized for bytes when bytes are used)
  (`byte` is an 8-bit unsigned integer in both compilers, and `[byte]`
  arrays are PACKED in the native backend — one byte per element, so 100k
  elements cost 256 KB instead of 2 MB. The element width flows from the
  static type into every access (`movzbq`/`movb`), into the allocation
  size, and into `y_arr_push`/`y_arr_prepend`/`y_arr_slice`/`y_arr_eq`,
  which now take it as a parameter. `bytes(s)` / `from_bytes(b)` convert
  to and from `str`.)
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
  files. arch_x64.y went from 2357 lines to ~1000; `readline()` and `exec()`
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
  (arrays/maps/records are reference values in both compilers now —
  removing copy-on-store is what made self-hosting possible: the
  assembler went from 651 MB to 747 KB on a 20 KB binary)

- DONE: arr += elem should be added as language feature
  (also -=, *=, /= for any type: `x op= e` desugars to `x = x op e` on
  numbers and strings; on arrays `+=` pushes / appends and `*=` prepends,
  in place, with no desugar through `+`)
- DONE: arr1 + arr2 should concat to form a new arr3
- DONE: arr + elem should concat, same goes for elem + arr
  (arrays win over strings in `+`; the operands are never mutated, so `+`
  is the explicit-copy counterpart of the in-place `+=`/`*=`)

- DONE: add JS/TS spread syntax `{a:1, ...b}` `{...c, ...d}`
  (later keys win the value, the first appearance keeps the position, and
  the sources are never mutated — `types.y`'s `field_merge` plus the
  emitter's static merge. Both compilers accept it.)
- DONE: `str` ordering — `<`, `>`, `<=`, `>=` compare strings
  lexicographically in both compilers (they used to be a hard error:
  "Operands must be numbers"), so sorting strings needs no helper.

- is there some sort of code in ycc.y and the other .y that are due to a limitation in the language? are we missing some very convinient language feature? if yes add.
  Yes — the workarounds are catalogued in AGENTS.md ("Y code style" and
  "Array operators"). Progress:
  - DONE: early `return` (`examples/ysh.y` used to be silently truncated
    at its first `return`).
  - DONE: `&&`/`||` short-circuit in both compilers (they used to be eager
    in the C compiler, which is why guards are written as nested ifs).
  - DONE: `x.y[i]` parses correctly — dot is a postfix suffix now, not a
    binary operator whose RHS swallowed the index.
  - DONE: `!x.y` means `!(x.y)` (postfix binds tighter than unary).
  - DONE: empty blocks `{}` are legal and safe.
  - DONE: dot-assign `s.f = v` and `m["k"] = v`.
  - DONE: `self` no longer shadows a binding of that name — it is only
    bound as the recursion handle when the function has no parameter
    called `self`.
  The remaining cost is the twin copy: every workaround in `src/y/*.y`
  needs the same shape in `src/c/*.c`, and a Y closure has no spelling in
  the C value model (`yv.h` has no function tag), so new closures in
  `src/y` should still be avoided. Leftover `let t = x.y;` bindings and
  `0;` fillers are harmless and can be simplified opportunistically.

- DONE: closures and first-class functions in the native backend
  (`[code, caps...]` records whose slots hold pointers to one shared cell
  per captured variable, so writes are visible in both directions; the
  closure is pushed deepest so param offsets match a direct call.
  Capturing functions are emitted at their creation site, because only the
  enclosing env knows capture types.)
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