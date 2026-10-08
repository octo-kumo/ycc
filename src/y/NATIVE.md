# ycc native backend — roadmap

Goal: ycc compiles Y **directly to real executables** with **unboxed native data**
(a `long` is 8 bytes in memory — no `YValue`, no tagged union, no `runtime.c`),
backed by a **static type system** and a **standard library written in Y**.
No toolchain: no cc, no as, no ld, no libc — ycc writes static ELF itself.
First target: **Linux x86_64**. Later: more arches.

## Where things live

| file | role |
|---|---|
| `src/y/lexer.y` | tokens; `&` is an `op` (pointer/address-of) |
| `src/y/parser.y` | AST (nested maps) **plus type nodes** (`typ` fields, additive); every node carries line/col |
| `src/y/types.y` | static checker: AST → `[errors]` with line/col; the law |
| `src/y/lint.y` | warnings: `lint_unit` reads a unit that typechecked (the renamed tree for unused or write-only locals, dropped values, unreachable code, `x = x`, `x < x`, a division by a literal zero, a key given twice; the parse tree for record and union types written out instead of named) → `[{msg,line,col}]`. Only the program's unit and packages' (never a std unit's); the driver prints them on stderr (`ycc.y` `print_native_warnings`) unless `-w`. Never fatal, and the output is the same bytes with or without them |
| `src/y/arch_x64.y` | x86_64 behind the arch interface: `arch_id/word/sysno`, `arch_fn_label/loc_label/str_label`, `arch_header/rodata/text`, `arch_prelude`, `arch_consts`, `arch_frame` (16-align), `arch_exit`. The prelude is only the **primitives** that need raw machine state (allocator, traps, record lookup, the byte-moving string/array cores, float formatting, argv) |
| `src/y/native.y` | pipeline driver: `native_resolve` (splice imports, pick the std units) → per compilation unit: strip namespaces → rename → check → lint (warnings) → hoist → frame layout → arch emit; then link the units (tree shake across them) into parts the assembler takes: the bodies as instruction items (`ir.y`), the header, the arch prelude, the rodata and the `.bss` cells as text (what `asm.y` still lexes) |
| `src/y/rename.y` | uniquify pass: every binding gets `name$N`, killing scopes/shadowing downstream |
| `src/y/enc64.y` | x86_64 instruction encoding for exactly the forms we emit |
| `src/y/asm.y` | two-pass assembler over our asm dialect |
| `src/y/elf.y` | minimal ELF64 writer: one PT_LOAD (R+E), plus a zero-filled RW one for `.bss` when a program has globals or a heap; static, entry `_start`; `-g` adds `.symtab`, the `.debug_*` line table and section headers |
| `src/y/dwarf.y` | DWARF 4 line information for `-g`: `.debug_line` (a row per `.loc` marker) plus a minimal `.debug_info`/`.debug_abbrev` (one compile unit) |
| `src/y/pkg.y` | `ycc build`/`ycc vendor`: the `y.toml` reader (a TOML subset), the dependency graph, git fetching, `y.lock`, vendoring, and the hash behind the package objects' keys (*Packages* below) |
| `src/y/std/` | standard library **in Y**: `rt.y` (the runtime library, linked into every program), `prelude.y` (`readline`/`clear_eof`), `exec.y` (`exec`, its own file for `--no-exec`) and `str.y` (the helper-backed string methods) — those four embedded into the compiler and compiled as separate units (*Compilation units* below) — then the optional modules: `fs.y` (the file system: whole files as text or bytes, paths, directories, fds), `net.y` (TCP, DNS, an HTTP server), `struct.y` (pack/unpack helpers), `math.y` (integers, bits, float
comparisons and constants, RNGs, `[float]` array work), `crypto.y` (SHA-2, HMAC/HKDF, ChaCha20-Poly1305, AES-GCM, X25519, RSA and ECDSA verification), `x509.y` (certificates, trust anchors, chain and name checks), `tls.y` (a TLS 1.3 client) |

New Y modules under `src/y/` must get a **1:1 C twin** in `src/c/` (see
`PORTING.md`) -- the two compilers are kept in lockstep. (`src/y/std/` is
the exception: those files are compiled into *programs*, never
ported, so they may use the whole native surface -- `&x`, `*p`,
`syscall`.)

## Data representation

- `long`/`int` (same), `byte` (8-bit unsigned), `bool` (0/1), `float`
  (IEEE754 double bits), pointer `*T`, `str` (a `.rodata` header, value =
  its address), option `T?` (0 = none, else heap box),
  function values (address of a closure record): **every value is exactly 8
  bytes** on the stack/in regs/on the heap.
- **`[byte]` arrays are packed**: one byte per element, not eight. Every
  element lives at `data + i*esz`, and `esz` comes from the static
  element type — so the scale factor, the allocation size and the load/store
  width follow from the type alone (`movzbq`/`movb` instead of `mov`).
  `y_arr_push`/`y_arr_prepend`/`y_arr_slice`/`y_arr_eq`/`y_arr_extend` take
  `esz` as an argument, so one implementation serves both layouts.
  `arr += other` with one element type is `y_arr_extend`: the block grows
  once, to the capacity pushing the elements one by one would reach, and
  they move in bulk (`y_mem_copy`, words then bytes); element types that
  convert (a `long` into a `[float]`, a member into a union) still go one
  by one, each converted (`gen_opassign_arr`). 100k elements are
  98 KB packed versus 781 KB unpacked; pushed one at a time (capacity
  doubling on the bump heap) they cost 256 KB versus 2 MB of heap.
  `bytes(s)` and `from_bytes(b)` convert
  to and from `str` (`from_bytes` takes a fixed `[byte; N]` too — it is the
  same header); a `byte` widens to `long` in arithmetic, and a `long`
  narrows to `byte` at annotated sites (there is no cast syntax).
- **Equality** (`gen_bin_rest`): scalars, records, maps, pointers and
  functions compare as words (records and maps by identity), `str` with
  `y_str_eq`, `float` with `ucomisd`. Two options compare payloads
  (`gen_eq_opt`): both none, or both boxes with equal contents; `x == none`
  stays a word test. Arrays compare length then elements, each with the
  element type's own `==`: words with `y_arr_eq` (by `esz`), strings with
  `y_arr_eq_str`, and options, arrays and floats in an inline loop
  (`gen_eq_arr_deep`) whose state sits on the stack, since each element
  compare may recurse or call those cores. `gen_eq_vals` is the one
  dispatcher: left pushed, right in `%rax`, 0/1 back in `%rax`.
- Locals live at fixed `rbp` offsets (one flat frame per function, 8 bytes/slot).
  A block releases its slots as it ends and a statement releases its
  temporaries as it does (`st_slots`/`st_temp` over `EmitSt.slots`/`temp`), so
  the frame is the **deepest** the body ever reached (`frame_max`), not the sum
  of every slot ever taken — the two counters are separate because a
  statement's temporaries must outlive the blocks inside that statement.
  **Top-level variables are globals**: each gets an 8-byte `.bss` cell
  (`yg_<n>_<name>`, read and written `%rip`-relative), so every function —
  hoisted or not, called from anywhere — sees the same variable.
  Arrays — fixed `[v; n]` and dynamic `[v, ...]` alike — are **heap headers**
  `{len, cap, data, front}` where `data` points at a separately allocated
  element block; a local holds the header address, so `[T; N]` is as
  first-class as `[T]` (it can be bound, passed, returned; only `+=`/`*=`
  growth is rejected, since `N` is part of the type). `cap` counts the
  slots from `data` to the end of the block, `front` the free slots
  before `data`. A header is `y_alloc(24)`, and `y_alloc` hands out
  `(n + 15) & -8` = 32 bytes of never-reused, zeroed memory, so `front`
  costs nothing and starts at 0 without a store; only `y_arr_prepend`
  makes it nonzero (stepping `data` back into room it reserved), and
  `y_arr_push` zeroes it when it moves the elements to a bigger block.
  So `a *= v` is amortized O(1), like `a += v`.
- **`str`** is a length-prefixed `.rodata` header `[len, data..., NUL]`, and
  the value is that header's address — so a `str` may carry embedded NULs
  and `len` is a load, not a `strlen`.
- **Records** are heap blocks laid out by field name: the fields sorted,
  the one in slot i at `record + 8i` whatever order a literal or a type
  writes them in, so a field read is one load at an offset fixed at
  compile time. The word at `record - 8` points to the descriptor of the
  record's type, `ytt_<hash>` (native.y "records at run time"): one per
  structural type, named by a 64-bit FNV-1a hash of its canonical form
  (`types.tcanon`: fields and union members sorted, a recursive alias's
  references back to itself `^N`). A unit emits the descriptors its code
  uses and the link keeps one per label (two forms under one label stop
  the link). A descriptor is one byte: its address is the type's tag. A
  union value is a member record laid out for the union (native.y "union
  layouts", CHOICES_MADE.md 25): the union's shared fields -- those every
  member has, with one type -- first, sorted, then the member's others,
  sorted, so a shared field is one load at one offset whatever the
  member. Where that is not the member's own (sorted) layout, the
  record's descriptor is the member's *in that layout* (its form plus
  `@` and the slot order, `ty_desc_in`), so `match` and casts, which
  compare descriptors, tell a `Bin` held in a `Node` from a standalone
  `Bin`. A value crossing layouts -- a member into a union, a union into
  a member or into another union -- is converted (`gen_convert`): copied
  into the other layout where the two differ, a new record, after a
  union cast checked the tag. A
  record literal is created as the type declared where it goes (`gen_as`
  passes it to `gen_reclit`), in that place's layout, so its descriptor
  names that type, not the literal's own.
- **Owned strings: `s += t` appends in place.** A `str` variable that is a
  `+=` target, whose address is never taken (`&s`) and that no closure
  captures (those are boxed) gets a companion word `c`: locals and params
  the slot below the value (`bind_own`, env kind `"own"`), globals a
  `.bss` cell `ygo_<n>_<name>` (env entry `<name>#o`; `#` cannot occur
  in a Y name). `c` is 0, 1 (an append is in flight), or the address of
  the buffer this variable's last append produced. Every read
  (`gen_id`) zeroes it; assignments leave it alone, since ownership is
  checked by pointer equality. An append statement (`gen_sappend`; only
  in discarded positions — `gen_stmt`, `gen_discard` — a value-used
  `{ s += t }` keeps the plain `s = s + t`) pins `c := (c == s)`,
  evaluates `t` (a read of `s` there zeroes `c`, a nested append
  replaces it), then calls `y_str_app(s, t, c)`: with the flag still 1
  the buffer is this variable's own, so `t` goes in place when it fits
  and otherwise into a block of twice the size; with 0 it copies
  exactly. Owned buffers are `[cap][len][bytes][NUL]` (the value points
  at `len`, so to everything else it is an ordinary `str`). 10,000
  one-byte appends: 50 MB of heap and 22.7 ms → 23 KB and 0.18 ms.
  The value-used form is `y_str_cat`, which allocates exactly
  `len(s) + len(t)` — that is what makes the copy necessary (a string read
  out of `s` before the append must not see the append, so the result
  cannot be the old buffer), but it also makes a loop of them quadratic:
  10,000 iterations building 120 KB allocate 1.2 GB. `lint.y` warns on the
  shape (`isvused`/`dropnext` mirror `gen_block_as`'s `dropped`), and the
  one-character fix is the `;`.
- **Arrays and records are reference values**: a binding stores the address,
  never a copy. `let b = a`, passing, returning and storing all share, and
  `a[i] = v` / `s.f = v` are observable through every alias. Both
  implementations use the same model. (Copy-on-store used to emulate value
  semantics here; it made every helper that returned an accumulator O(n), so
  the assembler was O(n²) and self-compilation OOMed past 7.5 GB.)
- Heap (bump allocator over 4 MB anonymous `mmap` chunks; its state — the
  bump pointer, the chunk end, the bytes handed out so far and a flag
  set by the first spawn (*Threads and processes* below) — lives in four
  `.bss` words, `y_heap`, which a
  program that never allocates shakes out): dynamic arrays `[v, ...]` as
  `{len, cap, data, front}` headers
  (element block allocated separately), option boxes. A request of 256 KB
  or more gets a mapping of its own.
  Nothing is ever freed (arena); no GC to write until something needs it.
- Expression values in `%rax`; operands that must survive nested evaluation are
  **pushed** (nothing live in caller-saved regs across a call). Two places relax
  that, and they share one predicate — `leaf_expr` in `native.y`, true for a
  literal, an identifier, or a unary operator over either, which is all a
  `mov $imm, %rax` or a `mov off(%rbp), %rax`:
  - a **float** binary operator. The leaf cannot write an SSE register, so the
    left operand stays in `%xmm0` across the right one's evaluation. Worth 25%
    of a fitted polynomial kernel — a Horner chain is nothing but such
    operators.
  - an **integer comparison that branches on flags** (`gen_cmp_flags`, which is
    what `if x < 1` compiles to). The leaf clobbers neither `%rcx` nor the
    stack, so the left goes straight into `%rcx` where the right one lands.
    This is the hottest shape in the language: 3660 such comparisons in `ycc`'s
    own output. `cmp` is dst-minus-src either way, so which register holds
    which operand does not move the flags.

  Both are guarded by a predicate rather than by a flag, because getting the
  predicate wrong would produce a *wrong answer*, not a slow one. Anything that
  may call (`gen_eq_vals`'s left operand, an array read whose bounds check can
  call `y_oob`, a field read, a nested float operator) still pushes.
- Y functions use a private convention: args pushed on the stack left to
  right, caller cleans up, result in `%rax`. The last-pushed arg sits at
  `rbp+16`, so param `k` of an `n`-arg function lives at
  `rbp+16+8*(n-1-k)` (arity-dependent by construction).
- **Closures** are heap records `[code_addr, cap0, cap1, ...]`; a function
  value is that record's address. An indirect call pushes the closure
  **first** (deepest), then the args left to right, so param offsets are
  identical to a direct call and the closure sits at `rbp+16+8*nargs`. One
  body serves both call forms — capture-free bodies simply never read that
  slot. A capturing function is emitted at its *creation site*, because only
  the enclosing environment knows each captured name's type. Every capture
  slot holds a pointer to one heap **cell**, so a captured variable is
  *shared* between the enclosing frame and every closure over it — writes
  are visible in both directions. The cell is allocated where the variable
  is **bound** (`box_bound`: declaration, parameter entry, each loop
  iteration's refresh of a `for x in a..b`/`foreach` variable), never where
  the closure is made: every read and write of a captured variable, on every
  path, goes through the cell. So a `foreach`/range variable is fresh per
  iteration, while a variable declared before a loop (a C-style
  `for (let i ...)` one included) is one variable shared by all of the
  loop's closures. A named function that captures is a closure wherever it
  is named — calls from its siblings and from itself pass its record.
- Maps `{K => V}` are lowered to a `{keys: [K], vals: [V], boxes: [V?]}`
  record and every map operation (literal, `m[k]`, `m[k] = v`, `len`,
  printing) to synthetic AST over those arrays -- no map-specific
  assembly. Reads are always `V?` (`none` on a miss), and an option is a
  heap box, so `boxes[i]` caches the box of `vals[i]`: the first read
  after the entry was written makes it, later reads share it, and a write
  clears it (a reader may still hold the old box; boxes are never
  mutated). Reads whose option cannot escape skip the box altogether:
  `m[k]!` reads `vals[i]`, and `is_some(m[k])`, `m[k] == none` and
  `m[k] != none` are the scan's verdict -- so they never allocate, and an
  escaping read allocates at most once per entry and write. Sharing a
  box is invisible to the program: `==` on two options compares their
  payloads (`gen_eq_opt`), not their boxes.
  `is_hash_key` accepts `str`, `long`,
  `byte`, `bool` and `float`, but `map_type_of` hard-codes `tstr`, so a
  map **literal** only infers a `str` key -- build a non-`str`-keyed map
  from `let m: {long => long} = {};` and store into it.

## Pipeline (now → later)

```
source → lexer → parser (+types) → splice imports → strip namespaces
  → rename (uniquify) → types.y (static check, ERRORS ARE FATAL)
  → lint.y (warnings, stderr; never fatal)
  → [later: ANF/CPS, defunctionalization]
  → frame layout → arch emit → asm.y (assemble) → elf.y → executable
```

- **Now**: direct AST→asm (stack machine + heap values). A capture-free
  `def` (top-level or nested) is hoisted to a top-level function and called
  directly; one that captures is closure-converted and emitted at its
  creation site. Top-level defs never capture (top-level variables are
  globals), so every top-level def is hoisted. No scopes/shadowing
  downstream of rename (flat envs).
- **Next**: ANF lowering (explicit eval order), defunctionalization,
  register allocation, GC (only when something must free).
- Semantics disputes between the Y and C implementations are resolved toward
  "what would a reasonable scoped functional language do" (TypeScript/Rust
  intuition): lexical scope, `self` for recursion, no implicit coercions
  (except `str`→`*T` and `none` unification), exhaustiveness where cheap.
- **The float primitives (`src/y/arch/math.s`)** are the other half of the same
  story: four functions (`y_sqrt`, `y_to_int`, `y_fbits`, `y_bitsf`), each a
  leaf reached through a `ndef`, each written by hand because only the
  machine can do it. `sqrtsd` is the hardware's own correctly-rounded root, so
  sqrt is four instructions with no table and no tolerance; `cvttsd2si` is the
  truncating conversion and returns the "integer indefinite" value for a NaN,
  an infinity or an out-of-range magnitude, which the caller checks rather than
  trusting; the two bit casts are moves. They live in `arch/*.s` like the rest
  of the machine code (embedded by both copies, `make asm-check` reads them
  with GNU `as`), and `native.y uses_math` looks at the program's references
  before looking at them at all — a program that calls none of them pays
  nothing, and one that does keeps the block through the ordinary shaking.
  Their arguments come off the stack at `8(%rsp)` (leaf convention: the return
  address is at `0(%rsp)`) and a float result goes back in `%rax` as its bits.
- **The transcendental kernels (`src/y/arch/math.s`)** are a third kind of thing
  in that file: not primitives, but whole functions that Y *can* write and the
  machine writes several times faster. `y_exp`, `y_log`, `y_sin` and `y_cos` are
  each generated from `std/math.y`'s own constants by a script under
  `test/math/`, walk the same operations in the same order as the Y function
  beside them, and are bit-identical to it — which is the whole promise, so each
  is gated by a fixture that compares thousands of arguments bit for bit
  (`t311`, `t312`, `t313`, `t315`). They are reached the same way, through a
  `ndef`, and each has its `*_y` oracle kept beside it in the module. The
  generator exists because a retyped coefficient table would silently disagree
  with the function it is meant to reproduce, and nothing else would notice.

  `y_pow` is the fifth and the odd one out, because it is the first of them that
  *calls*: the dispatch, the two-part logarithm, `exp2` of the pair and `ldexp`
  are four routines rather than one leaf. Every SSE register is caller-saved, so
  it is the only kernel with a frame, and two conventions fall out of that: a
  routine that has to outlive a call keeps the value in its frame and reloads it,
  and an internal helper answers a pair in *two registers* where the Y leaves it
  in module-level cells. Its generator emits the same intermediate probes the
  other three do (`l`, `lo`, `p`, `q`, `e1`, `e2`), each returning one
  intermediate against the Y's own value at that point — which is what makes a
  472-instruction routine debuggable at all, and `ideas/math.md` §8 has the
  six bugs they found.
- **`ndef`: a declaration with no body.** `ndef name(params) -> T
  [= "label"];` declares a function whose implementation is an assembly
  label. The parser makes a `Decl` with `kind: "native"` whose value is a
  `Func` carrying the label in a new `label: str` field and an *empty* body —
  the parser's own header errors, if any, live there, which is how they still
  reach the diagnostics. The rules live in `types.y` (`typeof_def`'s `isnat`):
  the return type must be written (nothing to infer it from), the label must
  start with `y_`, and the declaration must be at the top level; the name
  cannot be taken twice, which only `parser.y` can see, since renaming has
  already made every name unique by then. `rename.y` passes the label through
  untouched (`rn_decl_native`: there is no body to walk). In the emitter a
  native is an ordinary hoisted `FnDef` that keeps the label it declared
  (`native.y`, the hoisting loop) and gets **no body emitted** — the call
  path already resolves through `env_find` → `e.label`, so `call y_label`
  needs nothing new. A label with no assembly behind it surfaces as
  `undefined label` from `asm_link`, which is the honest failure: the
  declaration is a promise about the assembly, and nothing can check it (as
  with an `extern` declaration in C). Because a native is called with the
  ordinary convention — arguments pushed on the stack, result in `%rax` — it
  can reach the runtime's string/array helpers but not one written for the
  binary-float convention (`y_fmod`, which reads `%xmm0`/`%xmm1`).

## Output: our own executables

`ycc -o prog prog.y` writes a static ELF64 directly: `enc64.y` encodes each
emitted instruction (fixed-size near jumps/calls, so lengths are known in
pass 1), `asm.y` assembles (two passes + fixups + rodata), `elf.y` wraps one
PT_LOAD (R+E) with entry `_start`, plus — when the program has globals or
a heap — a second, RW PT_LOAD with no file bytes that the kernel
zero-fills: the `.bss` section (`.zero N` reserves space there; data or
code in `.bss` is an assembler error). `-g` appends a symbol table, a DWARF
line table and section headers past all of that (see "Debugging and
profiling" below).
### The asm dialect, in one paragraph

`src/y/arch/*.s` is written in GNU as's **AT&T** spelling, which is what the
encoder reads: source operand first, destination last (`movq %rax, %xmm0`,
`mulsd tab+8(%rip), %xmm0`). Three things about it are worth knowing before
writing a kernel.

* **A comment is a whole line, or it is a bug.** The loader
  (`arch_asm_lines`) drops a line only when its *first* byte is `#`, so a
  comment trailing an instruction reaches the assembler, which reads it as an
  operand: `L###: bad operand`, on a line whose opcode the prelude uses
  everywhere. `make asm-check` passes such a line, because GNU as reads
  trailing comments and this assembler does not.
* **`label+N(%rip)` names the Nth eight-byte entry of a table.** One label per
  table, not per entry: a label in `arch_consts` costs the shaker ~2K
  instructions of label-map fixpoint on *every* compile, so sixty coefficients
  as sixty labels would cost every program ~120K instructions forever.
* **`.quad` is a 64-bit bit pattern**, so a negative value is a legitimate one
  and half of every double's pattern is negative (that is the sign bit). A
  range check cannot replace the old non-negativity rule either: the read is
  `parse_num` --- the same one `is_num_text` validated --- which accumulates
  modulo 2^64, so 2^63 comes back as -2^63 and the eight bytes stored are the
  same ones. `tolong` is the wrong read here and was a trap for a while: it
  requires a fully valid `long` and answers `none` outside the range, where a
  `.quad` is a bit pattern and wants the wrap.

Verified byte-for-byte behaviorally against
binutils-built binaries for the whole corpus. The assembled bytes go straight
out through `fs.write_bytes` (std/fs.y: raw `openat`/`write`/`fchmodat`
over syscalls, mode 493 = 0755), so NULs pass through untouched. No
cc/as/ld involved.

## Pointers, stack arrays, heap arrays, options

- Syntax: `&x` address-of a local/param, `&a[i]` element address,
  `*p` load, `*p = v` store, `a[i]` / `a[i] = v`, `len(a)`, `a.length`,
  `a.ptr` (a `*T` to element 0; arrays only), `s.length`,
  `let buf = [v; n]`, `[v, ...]` (heap), `[T; N]` / `[T]` types,
  `T?` option types (`int` is `long`), `some(v)` / `none` / `is_some` / `unwrap`.
- Types: `*T`, `[T; N]`, `[T]`, `T?`. `&x : *T`, `&a[i] : *T`.
  `&a` on a whole array is **rejected for both kinds**: a slot holds the
  `{len, cap, data}` header, so `&a` would hand out the header address
  (the kernel would then overwrite the array's own bookkeeping). Write
  `&a[0]` or `a.ptr`, the data address, which works for `[T]` and `[T; N]`.
  `str` flows into `*T`; `none` unifies with any `T?`. A load or store through
  a `*T` moves `T`'s width: one byte for a `*byte` (packed `[byte]`), 8 bytes
  for everything else.
- Fixed and heap arrays are both first-class reference values: assign, pass,
  return, alias. The difference is only the type: `[T; N]` carries its length
  statically and rejects `+=`/`*=` (growing it would break the type), while
  `[T]` grows in place via `+=`/`*=` (no rebind: the header never moves, so
  every alias sees the growth).
  Indexing either kind is bounds-trapped (`y_oob`). Unwrap of `none` traps
  (`y_opt_unwrap`).
- Memory safety today = static types + trapped OOB + arena heap (nothing is
  freed; no pointer arithmetic — `p + 1` is a type error). **Heap values never
  dangle** — an array, a string, a record and a fixed array all live in a heap
  cell that outlives every frame, and a `&a[i]` points into one. **A pointer
  into a frame does**: `&x` on a local or a parameter is the address of a cell
  in that frame, and the frame goes when the function returns, so such a
  pointer is only valid while that frame is live. Nothing catches it — the
  checker cannot see how long a value lives — and the manual's pointers section
  (docs/src/08-functions.tex) says so. Later: GC, heap maps/strings, fat
  pointers or a borrow checker (which is what would make the frame case an
  error instead of a rule).

## Syscalls & std

- `syscall(num, a1, …, a6)` is a **compiler intrinsic** (not a C builtin):
  native backend emits the `syscall` instruction with the Linux ABI
  (`rdi,rsi,rdx,r10,r8,r9`, number in `rax`). 1–7 args, each `long`/`bool`/
  `str`/`*T`; returns `long`. Type errors otherwise.
- `src/y/std/fs.y` wraps raw numbers (`openat`, `read`, `write`, `lseek`,
  `close`, `newfstatat`, `getdents64`, …): file I/O with zero C code
  (`test/y/native/t12_cat.y` is a pure-Y cat; `t10_filewrite.y` and
  `t102_io_roundtrip.y` write files through fds).

## Type system (types.y) — the law, expanded over time

Now: `long`/`int`, `bool`, `float`, `str`, `byte`, `*T`, `[T; N]`, `[T]`,
`T?`, `{f: T}` records (exact: a record goes only where its own type,
its fields in any order, or a union holding it is expected; `{k: str}`
is the record of one field `k`; `{f?: T}` an optional field, which a
literal may leave out), `{K => V}` maps,
record unions `A | B` (a union value converts to a member type, or a
union of some members, with a cast checked at run time),
recursive type aliases,
function types `(A, B) -> R`, monomorphic `def` (every param has a type,
written or its default's; return types and locals are inferred, and a
call before the callee's body is checked needs its return type written
-- there is no unknown type), captures resolved into closures, `if` cond must be
`bool`, `if` arms that disagree make the `if` `void` (a statement; using it
as a value errors), `while` is `void`-typed, `break`/`continue` are
`void`-typed and legal only inside a loop **and** in the same function
(the closure-inside-a-loop case is a jump out of a function, which the
checker refuses rather than the emitter, whose answer would be a jump to
another function's label), and the only implicit
conversions are `long`→`float`, `byte`→`long`/`float`, `long`→`byte` at an
annotated site, `str`→`*T` and `none`-unification. There is no `null`:
`none` is the empty option and postfix `x!` is `unwrap(x)`. Error messages
strip rename's `$N` suffixes and carry line/col (LSP feeds on these).
Later: generics, borrow rules, methods/traits if Y grows them.

### What the checker keeps, for a caller that asks

The checker computes the type of every expression, and it and the renamer both
know where every binding was defined. All of it used to be dropped on the way out;
these are the three doors back in, added for the language server
(`src/tools/lsp/LSP.md` §9.2) and useful to anything else that has to answer a
question about a program without re-deriving it.

**`types.Binding` carries `line` and `col`** — the **name's** position, not the
keyword's, because a diagnostic wants the keyword (`let` is where the reader looks)
and a go-to-definition wants the name, and one pair of fields cannot be both. So
the AST keeps the keyword's in `Decl.line/col` and the name's in `Decl.nline/ncol`
(and the member key's in `Dot`/`DotAssign`), and `st_bind` records the latter.
**−1 means the binding has no position in the source at all** — an intrinsic, or a
name the program links against from another unit — and no consumer may read it as
line 1. A parameter records the `Func`'s own position: the parser keeps no position
per parameter, and the imprecision is one token's worth.

**`types.type_index_on()` / `expr_type(line, col)`** — the type inferred for every
EXPRESSION, keyed by position. **Off by default**, because `typeof_expr` is the
checker's hottest loop and an ordinary compile has no use for the table; the flag
costs it one predictable branch, and `bench/compile_ir.sh` says what that is worth
(+0.09% on `ycc.y`). The table is shaped like `inferred_ret`'s — 1024 buckets of
indices into parallel key/type arrays, keyed `line * 65536 + col` — because that
one is read by `native.y` on every compile and the shape is therefore proven at
this scale. `check_program` empties it, and only while the flag is on.

`expr_type` returns **`tunk()` when nothing is indexed**, not `tnone`: `tnone` is
a type a program can write, and a caller must be able to tell "the checker says
none" from "there is nothing here", or it will print a type the checker never gave
it. A member access also records at the KEY's position, since `a.b` parses with
the `Dot` at the `.` and the field's name is where a cursor goes.

**`rename.rename_program_x2(ast, …) -> { ast, defs }`** — the def site of every
binding, `defs` being a `parser.NameIx` of `uniq -> line * 65536 + col`. A SECOND
`NameIx` beside the `types.tc_ix` that already indexes bindings, not a new
container. `rename_program_x` is a thin wrapper returning the `ast`, so the
compiler's own callers are unchanged. The map holds the bindings of the unit passed
in, since a program is checked one unit at a time. Read it with `rn_def_site` /
`rn_def_line` / `rn_def_col` rather than unpacking the packing yourself.


## Newer language features

All of these are lowered early, so the checker and emitter see little new:

- **`c ? a : b`** parses to `if (c) { a } else { b }` (lowest precedence,
  right-associative); arms that disagree make it void, so
  `a ? f() : none;` is a fine statement.
- **Trailing `;` is void**: `{ f(); }` computes nothing, `{ f() }` is f's
  value. The parser appends a `void` statement; a trailing `return x;` (or
  an if/else that returns on every path) keeps its value. The emitter
  emits nothing for that `void`, and a tail call before it stays a tail
  call.
- **`break` / `continue`** are a bare `jmp` to a label the enclosing loop
  generator published (`brk_label` / `cont_label`, module state in
  native.y; `emit_one_fn` clears both, so a closure body can never
  inherit its creator's loop). All four loop kinds lower to the same
  shape — head label, test, body, step, `jmp` back, exit label — so
  `break` is the exit label everywhere. `continue` is the one place the
  shapes differ, and the difference is a trap worth writing down: it
  cannot be the head label for any loop with a step, because the step
  sits at the *bottom*, after the body, so a `continue` that jumped to
  the head would re-run the body on the same value and never end.
  `for`, `for..in` and `foreach` therefore emit a third label between
  the body and the step; only `while`, which has no step, continues to
  the head. (For `for..in`/`foreach` the fresh per-turn `box_bound` cell
  is made at the *top* of the next turn, which the `jmp` back after the
  increment reaches — so the cell still refreshes.)

  The third label is emitted for every counted loop, including the ones with
  no `continue` in them: a label has to exist before the body that jumps to it
  is generated, so deciding lazily would mean walking the body first (and
  knowing which `continue`s belong to *this* loop, not a nested one or a
  closure). Measured, the unconditional label costs 12 bytes of asm per
  counted loop — 587 bytes, +0.01%, on ycc's own output, which has 49 of
  them — against emitted code that is otherwise byte-identical. That is the
  trade: 0.01% of asm for no extra walk and no extra state.
- **`print(a, b, ...)`** is `print(tostring(a) + tostring(b) + ...)`.
- **Default parameters** `def f(n: long, acc = 1)`: the default must be a
  literal, and gives an unannotated parameter its type; rename.y fills
  omitted trailing arguments of direct calls.
- **Optional parameters** `def f(a: long, b?: long)`: the body sees `b` as
  a `long?`; a direct call passes a plain `long` (rename.y wraps it in
  `some`) or leaves it out (`none`). Passing an option is a type error
  (that is what `b: long?` is for), and so is a required parameter after
  an optional one; defaults may mix with them.
- **Optional record fields** `{url: str, timeout?: long}`: the field's
  type is `long?` (parser.y, `Field.opt`). A record literal where the
  type is declared may leave it out -- it is none, which y_alloc's zeroed
  memory already is, so nothing is stored -- or give a plain `long`,
  wrapped (types.y `opt_wraps`, native.y `lit_wraps`, `gen_box_rax`), or
  a `long?`. `lit_target` takes a literal that leaves optional fields
  out (`lit_fits`); in a union, the member with exactly its field names,
  else the only one it fits. The mark is not part of the type (teq,
  tcanon and the descriptors ignore it); tcode writes the field as
  `name?`, so it crosses a package. `some({...})` where `T?` is declared
  -- an optional argument passed is one -- creates the literal as `T`
  (`typeof_want`, `gen_as`).
- **`const x = v`** binds like `let` but the checker rejects rebinding it
  (`=`, `op=`, `++`/`--`); the value it names stays mutable in place.
- **Properties** `a.length` / `s.length` (= `len`) and `a.ptr` (`*T` to
  element 0, arrays only) are checked in types.y (`typeof_prop`) and
  emitted by `gen_prop`.
- **Tail calls** recycle the frame for `self(...)` and for a call naming
  the function being emitted.
- **`type A = T`** aliases are resolved by rename.y (scoped to their block,
  hoisted like defs); unions are flattened. An alias may be recursive
  through a record field or a function type: every reference to it is
  one shared `tref` node (rename.y `RnRef`, `to` the alias spelled out)
  that the checker and the emitter unfold where they look into a type
  (types.y `unfold`; `typeof_expr` and `infer` unfold their results).
  Any other cycle is an error at the `type` and the unknown type.
- **Record literals** are checked against the type declared where they go
  (types.y `typeof_want` at a typed `let`, an argument, a `return` or a
  def's tail, an assignment, a field, element or map store, `+=`/`*=`,
  `*p =`): a literal of that record type, or of the union member with
  its field names (`lit_target`), is created as it, each value checked
  and converted against its field, nested literals likewise.
- **Unions** `A | B` hold records whose type is exactly a member. A record
  goes into a union when it is a member; a union goes into another union
  holding all its members, or -- through a cast checked at run time,
  where the type is written (an annotated `let`, a parameter, a declared
  return) -- into one member or a union of some. A field every member has
  with one type is read and written through the union in one move
  (`union_field`, native.y `gen_union_slot`: such fields come first in
  every member held in the union). Unions print as the member they hold.
- **`match e { pat => arm, ... }`** is lowered by the parser to
  `{ let $m = e; if (test) { binds; arm } else if ... }` over three node
  kinds: `rectest` (the value's descriptor is T's, or that of a member
  with a record pattern's fields), `narrow` (the value typed as T: a
  binding `T x` is a cast, copied into T's layout where it differs; a
  pattern's field reads, `T {f}` and `{f: v}`, read the union value in
  place, `gen_narrow_field`) and
  `matchend` (the fall-through). Patterns: `_`, `T x`, `T {f, g: y}`, `T`,
  record patterns `{f: v} x` / `({f: v}) x` (fields equal to values) and
  literals (`1`, `"s"`, `'a'`, `true`, `none`, `-2`, `(expr)`). Arms follow
  the `if` law. Without `_`, every union member must be covered by a type
  arm or the match is rejected as non-exhaustive. A value pattern (a
  literal, or a record pattern like `({f: 10}) x`) matches only the values
  it names, so it never counts as covering a member — the error says so.
- **Strings**: `s[i]` is the `byte` at i (trapped out of bounds), `s[lo:hi]`
  the substring — half-open and clamped like an array slice (`lo < 0`
  counts from 0, `hi > len` stops at len, `hi <= lo` is `""`), with
  `s[:hi]` and `s[lo:]` for the omitted bounds. There is no `substr`:
  `substr(s, a, n)` is `s[a:a + n]`. **`'a'`** is a `byte` literal.
- **String methods** `s.m(args)`, as in `"str 1 2 3".split(" ")`, work on
  any `str`-typed receiver. One table, `str_method` in types.y, drives
  both the checker (`typeof_method`: arity, argument types, result) and
  the emitter (`gen_method`). Builtin-backed methods are the builtin with
  the receiver as its first argument: `split`, `trim`/`strip`,
  `index_of`, `last_index_of`, `bytes`, `tolong`, `ord`, `byte_at`, and
  `join`, whose receiver is the separator and goes last
  (`", ".join(xs)`). The rest are Y helpers in `std/str.y`, called by
  fixed label (`y_str_pad_left`, …):
  - `trim_start`/`lstrip` and `trim_end`/`rstrip`;
  - `pad_left(w, fill = " ")`, `pad_right` and `center`. Widths are in
    bytes; the fill repeats and is cut to fit; `center` puts the odd byte
    on the right;
  - `starts_with`, `ends_with`, `contains` (`""` is in everything);
  - `count` and `replace`: non-overlapping, left to right, and an empty
    pattern counts 0 and replaces nothing;
  - `upper`/`lower` (ASCII), `repeat(n)` (`""` for `n <= 0`);
  - `lines()`: split at LF, drop a CR before it, and no empty last line
    after a final newline.
- **F-strings** `f"a{x}b{y:>5}"` are lowered by the lexer (`lex_fstring`)
  to the tokens of `("a" + #fmt(x, "") + "b" + #fmt(y, ">5"))`; `#fmt` is
  a name no program can bind. Each field's text is tokenized on its own
  and its tokens keep their own line and column, so an error inside a
  field points into it; the synthesized tokens sit at the field's `{`.
  `fstr_walk` finds the fields, the way Python does: an expression ends
  at the first `}` or `:` outside brackets, except a `:` answering a `?`.
  A malformed f-string (unterminated, a lone `}`, an empty field, `{` in
  a spec, ...) lexes to one `ferr` token, as does a radix prefix without
  a digit (`0x`, `0b2`), which the parser turns into an
  `err` node for the checker to report. The checker (`typeof_fmt`) reads
  the spec (`fmt_spec`, Python's mini-language without nested fields)
  and checks it against the field's type (`fmt_check`). The emitter
  (`gen_fmt`) emits `tostring` for an empty spec; otherwise it packs the
  spec into one long (`fmt_code`) and calls `y_fmt_s`, `y_fmt_i` or
  `y_fmt_f` in `std/str.y`. A float goes as its IEEE bits, and its
  digits are exact (base-10^9 limbs), rounded half to even.

  Method names are not reserved. A def, a variable or a record field may
  use one, and `obj.f(x)` on a record still calls the field.
  `s.length` stays a property; `s.length()` is an error that says so.
- **Slice assignment** `a[lo:hi] = b` copies b's elements into that range;
  the range must lie inside a and hold exactly `len(b)` elements
  (`y_arr_setslice1`/`8` in rt.y trap otherwise).
- **Bitwise operators** `& | ^ ~ << >> >>>` take integers (a byte widens)
  and yield a long (`typeof_bits` in types.y); their compound forms
  `&= |= ^= <<= >>= >>>=` lower through `gen_opassign_arith` like `+=`, so
  a byte target keeps the low 8 bits. `&`, `|`, `^` and `~` are one
  instruction each; `gen_shift` emits `shl`, `sar` (`>>`) or `shr`
  (`>>>`). A literal count of 0 to 63 is the immediate. Any other count is
  tested first, because x86 would use only its low 6 bits: a negative one
  jumps to `y_shift_neg` (rt.y), and 64 or more gives 0 (`sar` by 63 for
  `>>`). The precedence sits between `::` and `+ -` (`|` < `^` < `&` <
  shifts), so unlike C, `x & 1 == 0` is `(x & 1) == 0`.

## Self-hosting: done

`ycc` compiles its own source to a byte-identical binary. The chain is
`cycc → _ycc0 → _ycc`: `_ycc0` plus its own std pack (*Compilation
units* below) is `ycc`, gated by `cmp ycc refs/ycc.ref` (the pack
included) and `cmp _ycc0 _ycc` (`make ycc`), and
`test/sh/test_fixpoint.sh` re-checks it from an already-built `./ycc`,
including a third generation (compiled from the std sources, not the
pack) and a smoke compile with the self-built binary.

Measured on the self-compile (`ycc --time -o ycc src/y/ycc.y`, re-run
2026-10-01): 756 KB of spliced source, 171 K tokens, 3.2 MB of assembly,
an 820 KB static ELF, in ~2 s and ~0.8 GB of heap. The checker is the
largest phase (~0.7 s), then the assembler's encoder and the emitter
(~0.4 s each). The shape is the point, not the speed; the figures move as
the compiler grows.

What made it possible was not new features but removing copies: arrays and
records became reference values everywhere (copy-on-store made the
assembler O(n²) — 651 MB to build a 20 KB binary — and self-compilation OOMed
past 7.5 GB), and the output writer stopped issuing one `write` syscall per
byte.

Still missing for a *comfortable* self-host (the compiler works around each
today): nothing structural any more -- maps `{K => V}` and record spread
have landed. Records with static shapes cover what `src/y/*.y` needs;
closures, first-class functions, `for`/`foreach`, block expressions and
floats have all landed since.

## Runtime library: Y, not assembly

`src/y/std/rt.y` holds runtime code written **in Y**, linked into every
program (always — generated code calls into it by fixed label, so there
is no name to test for). These are ordinary defs: they go through rename,
typecheck and emit like any user function, so a bug in them is a bug in
Y code rather than in hand-rolled x86.

The rule is that `arch_x64.y` provides small, general **primitives** and the
runtime provides **behaviour**. What stays in assembly is only what needs raw
machine state: the `y_alloc` bump allocator, the trap stubs (div/0, OOB,
unwrap-of-none, OOM, a failed union cast), the
byte-moving string cores (`y_str_eq/cmp/cat/join/slice`, and the scans
behind `index_of`, `split` and `trim`: `y_str_index/split/trim`), `str`↔`[byte]`
conversion, the generic array cores (`y_arr_push`/`y_arr_prepend`/`y_arr_slice`/
`y_arr_eq`/`y_arr_extend` — one implementation each, parameterized by element width,
because Y has no generics), long and float formatting, and argv
materialization. Everything else —
the whole print/put/eput family, `ord`/`chr`/`tolong`/
`last_index_of`, `range`, time, files — is Y. (`join` went
back to assembly: in Y it pushed one byte at a time through a `[byte]`
accumulator, and the compiler joins megabytes of asm text per
self-compile — one sizing pass and one allocation instead took 9.9% off
the self-compile and 8.1% off its peak heap. `y_long_tostr` followed: in
Y it cost a fixed array, a slice and a copy — five allocations and two
`idiv`s per digit — and, because `y_float_tostr` calls it, its body and
everything it uses rode along in every program. In asm it is one `idiv`
per digit and one allocation: `tostring`-heavy output 27% faster, a hello
world's asm 84% smaller.) Two worked
examples of the same move landed earlier:

- `readline()` — the backend contributes only the `syscall` intrinsic and
  `bytes`/`from_bytes`; stopping at the newline, growing the buffer and
  handling EOF are ordinary Y. It replaced ~90 lines of assembly. It first
  read one byte per `read(2)`; it now fills a 16 KB stdin buffer (globals
  at the top of `std/prelude.y`, allocated on the first read) and slices
  lines out of it — `bench/y/lines.y`, 5 MB of short lines, went from
  1.25 s to 0.10 s. EOF is still never latched: an empty buffer always
  means a fresh `read(2)`.
- `exec(cmd)` — `fork`/`execve`/`wait4` through `syscall`, with the
  `char**` argv built out of `[byte]` buffers and `ptr_addr` (the one
  primitive that lets a pointer's value cross into `long`). No new
  assembly at all. It first calls `y_stdin_sync()`, which gives the
  unread part of the stdin buffer back with `lseek(0, -unread, SEEK_CUR)`
  when stdin is a file, so the child starts right after the last line
  `readline()` returned; a pipe cannot seek, and bytes already buffered
  stay with the parent (the C stdio contract). `std/exec.y` calls
  `y_stdin_sync`, which is in the prelude trigger list, so linking exec
  always links `std/prelude.y` as well.

`ycc --no-exec` simply does not link `std/exec.y`, so the call fails
with "undefined function 'exec'" and the binary has no path to a shell.

`rt.y`, `prelude.y`, `exec.y` and `str.y` are plain Y files, and the
compiler carries their text: native.y says `embed RT_SRC from
"./std/rt.y";` (see *Embedding files* below), the C copy
`Y_EMBED(RT_SRC, ...)`, because the shipped `ycc` is a standalone static
ELF — it cannot read a support file at run time. `rt.y` is linked
always; the others only when the program mentions one of their names
(`prelude_names`/`exec_names`/`str_names` in native.y). One pass over the
program's text, `words_seen`, checks all three lists. It reads the text
the way the lexer does, skipping comments and the insides of string
literals, and counts whole words only (`executable` is not `exec`).
`str.y`'s names count only in method-call form, `.name(`, because that
is the only way to reach a helper-backed method. `std/str.y` holds those
methods (*String methods* above), and the `y_fmt_*` helpers behind
f-string specs: `words_seen` walks each f-string with the lexer's own
`fstr_walk`, scans its fields as code, and links `str.y` when a field
has a spec. Even so, the scan over-approximates:
`r.count(x)` calling a record field links `str.y` too. So `str.y` must
stay free of string literals and record values. Tree shaking drops unused
bodies, but the string literals they emitted stay in `.rodata`, and so do
the type descriptors of the records they build; every such program would
carry them. `str.y` writes `s[0:0]` for `""` and byte codes for
`"\n"`, and splits a would-be record result into two functions
(`y_fmt_exact`/`y_fmt_places`). A Y helper may call intrinsics (`bytes`, `from_bytes`,
`tostring`, `syscall`, …), slice strings (`s[a:b]` is the asm
`y_str_slice`) and call other helpers, but never an assembly-only
label directly — the checker would call it undefined — so every bridge into
the primitives goes through an intrinsic or an operator.

**`y_` is a reserved prefix.** A `y_*` def is emitted under its bare name
(`fn_label_of` in native.y) because generated code calls it by fixed label:
`print(long)` compiles to `call y_print_long` and must find exactly that
label, rename's `$N` suffix notwithstanding. A program may override a
runtime helper by defining the same name: its body replaces the std
unit's at link time, for every caller, the std units' own calls included
(`link_units` drops the std body of every `y_` label the program
defines); anything else starting with `y_` is on its own.

## Threads and processes

`spawn { }`, `join`, `mutex()` with `lock`/`try_lock`, `sem(n)` with
`post`/`wait`, `fork { }` and `wait_pid` (CHOICES_MADE.md 33; the
manual's *Threads and processes*) are builtins on closures: the parser
turns `spawn { e }` into `spawn(def () { e })` and `lock m { e }` into
`lock(m, def () { e })` (`parse_primary`, contextual: no word is
reserved), so the checker and the emitter see ordinary calls. `mutex`
and `sem` are record types no program can spell (`{$m: long}`,
`{$n: long, $w: long}`, parser.y `sync_type`). The runtime is assembly
in `arch_x64.y`, because it needs raw machine state, in a prelude of its
own (`arch_prelude_threads`) that `link_units` adds only when the kept
code calls one of its entry points (`uses_threads`): every compile pays
for shaking the prelude text it is given, line by line, so a program
without threads does not scan this one.

- **A thread is a `clone(2)`** sharing memory, files and signal handlers
  (`CLONE_VM|FS|FILES|SIGHAND|THREAD|SYSVSEM|SETTLS|PARENT_SETTID|
  CHILD_CLEARTID`), on an 8 MiB stack of its own: an `mmap` with a
  `PROT_NONE` guard page below it, so a runaway recursion faults as it
  does on the main thread. Its control block (72 bytes of the spawner's
  heap) is `[cur, end, used, self, stack, spare, tid, value, closure]`,
  its first words a heap block like `y_heap`'s. A spawn's value is the
  closure `[y_join_code, tcb]`, so `join t` is `t()`: it futex-waits
  until the kernel clears `tid` (CHILD_CLEARTID) and returns `value`. The
  thread calls the closure, stores the value, unmaps its own stack
  (nothing after the `munmap` touches it) and ends with `exit` (60).
- **Each thread allocates from a heap of its own**, so `y_alloc` stays a
  bump without a lock, and a program without threads pays nothing for
  them: `y_alloc`'s fast path is the bump on the global `y_heap`, as it
  always was. The first spawn (`y_threads_on`) moves the main thread's
  heap state into a block of its own, points `%fs` at it
  (`arch_prctl(ARCH_SET_FS)`; word 3 of every thread's block is its
  address, so `%fs:24` finds it), empties `y_heap` and sets its flag:
  from then on the bump on `y_heap` fails in every thread, and
  `y_alloc_slow` sends it to its own block. A threaded program's
  allocation thus takes that detour (about 14 instructions more), and
  `y_heap`'s words are only read, never written, so the threads do not
  fight over its cache line. Nothing is freed, so a thread's values
  outlive it. The unused
  tail of a dead thread's chunk is not lost either: the first join takes
  it (an `xchg` on its `end`, so two joins cannot both take it) onto the
  joining thread's `spare` list, and that thread's next spawn starts its
  new thread there. A thousand threads spawned and joined in a row share
  one 4 MB chunk instead of mapping a thousand (t160 checks it under the
  memory cap); a thread nobody joins keeps its tail.
- **Every process exit is `exit_group`** (231): a program's end, `exit`
  and every trap end all its threads. Only a thread's own end is `exit`,
  and `exec`'s child, a lone process anyway.
- **A mutex** is one word: 0 free, 1 held, 2 held with a thread perhaps
  waiting (Drepper's "Futexes Are Tricky", with `xchg` alone, the one
  atomic the assembler has). A waiter marks it 2 before it sleeps
  (`FUTEX_WAIT_PRIVATE`), and only an unlock that finds 2 makes a
  syscall: an uncontended `lock m { }` costs two `xchg`s and the block's
  call (24 ns, against 158 ns when every unlock woke). `try_lock` takes
  it with `xchg 1`; when that erased a 2 it puts the 2 back, which takes
  the mutex if it was released in between. **A semaphore** is its count
  and a mutex guarding it; `wait` sleeps on the count while it is 0, and
  every `post` wakes one sleeper.
- **`fork { }`** is `fork(2)`: the child (a copy holding only the forking
  thread) calls the closure and ends with `exit_group(0)`; the parent gets
  the pid, or `-errno`. `wait_pid` (rt.y) is `wait4`: the exit code, 128
  plus the signal, or -1.

`readline()`'s stdin buffer (prelude.y) is the one piece of runtime state
shared without a lock: one thread at a time may read stdin.

## Compilation units and the std pack

A program is **linked from units**: its own — the program file and the
files it imports, spliced into one text — and the std units it needs, in
link order `prelude`, `exec`, `str`, `rt` (`native_resolve_x` picks
them, see above). `compile_unit` takes one unit from AST to its bodies as
instruction **items** — strip namespaces, rename, check, emit, one body
per function, each a flat `[long]` (`ir.y`: the form, then its field
words) — and `link_units` shakes the units' bodies together (*Tree
shaking* below) and hands the assembler the kept ones as parts: the
header, the arch prelude and every unit's rodata and `.bss` cells are
text (what `asm.y` still lexes), the bodies are items (`asm_assemble`
walks both; `enc_form` encodes an item by its form's id rather than by a
mnemonic string). Nothing is spelled as assembly text and lexed back on
that path, which is what the items are for; `-S` is the one place a body
becomes text again (`link_text` renders each item back to the line it
replaces, byte for byte, so a `-S` listing still assembles with `as`).

- **Labels** cannot collide: a unit numbers its uids (function, string
  and local labels) and its global cells from its own base
  (`std_unit_base`: 1e9 for the prelude up to 4e9 for rt; the program's
  is 0, so its labels are what they always were).
- **Exports**: a unit's top-level defs, by the names they were written
  with (`unit_exports`), with their labels and types. The program
  checks and calls against the exports of the **library** units
  (prelude, exec) — bound as externs in `types.check_program(ast, ext)`
  and in the emitter's function table, behind the program's own defs, so
  a program's `readline` still wins. The **runtime** units (rt, str)
  are linked but not bound: generated code calls their `y_` helpers by
  fixed label, and the checker's and emitter's scopes stay free of a
  hundred-odd helper names (the self-compile's typecheck got 10% faster).
- **Init functions**: a unit's top-level statements become an init
  function, and `_start` calls each linked unit's init first, in link
  order. Only the prelude has one (readline's buffer globals), so a
  program that links it starts with one call more than when the std
  files were spliced into its text; every other program compiles to the
  same bytes as then.
- **Line markers**: a std unit always compiles with its `.loc` markers
  (all `file 1`, its only file); linking renumbers them to the unit's
  place in the program's `.file` table under `-g` — the program's files
  first, then the units', the last linked first: packages (see
  *Packages*), then rt, str, exec, prelude — and strips them otherwise
  (`link_locs`).

**The std pack.** The std units compile the same for every program, so
`ycc` carries them precompiled: `ycc --std-pack FILE` compiles all four
and writes them to FILE, and the build appends that file to the `ycc`
that wrote it — `[ycc][pack][pack length, 8 digits][YCCPACK1]` (the
Makefile's `PACK`). Each compile reads the pack back from
`/proc/self/exe` (`self_pack` in ycc.y) and links the units it needs
straight from it. The pack is netstrings: a version line
(`ycc-std-pack 7`), then each unit's name and fields as netstrings —
its bodies, each body's label and the labels it references (so linking
never rescans std code), rodata, globals, init label, and its exports
with their types in a prefix code (`tcode`/`tdecode`: total over every
type the checker produces, unions and the unknown type included),
decoded only for the library units the program binds.
A body's field is its **instruction items**, the same ones the emitter
writes for a unit it compiles itself (`pack_body`/`unpack_body` in
native.y): one byte per item's form, then each operand's field words as
they come — a register's two, a memory operand's five, an immediate's
one — each word in one byte when it is small and a few more when it is
not, and a label field as its *name* (ids are minted per run, and the
pack is written by one build and read by the next). A body's raw lines,
which its comment items index, travel beside them. A link decodes only
the bodies the tree shaker keeps, and the assembler encodes items and
text parts alike (see the emitter and linker below).
What is precompiled is therefore everything up to the encoder: the std
units are stored as items, not machine code, and the assembler still
encodes the std bodies a program keeps along with the program's own.

### The pack's size, and what is left to the codec

`test/sh/pack_stats.py` parses the pack field by field and now knows the
shapes (almost every field is "count, then items"; only `init` is one
netstring). Measured on the payload after `refs` became derived (126,614 B):

    bodies 116,322 (91.9%)   iface 6,446   labels 2,044   rodata 1,130
    btext 377   globals 120   files 62   init 48
    gzip -9 20,559 (6.16x)   xz -9 16,480 (7.68x)     (`--target`)

Three of the fields left are repetition a codec subsumes -- label operands are
39% of the body bytes (2,786 occurrences of 42/87/411/532 distinct names per
unit), type codes repeat across exports, and `files` repeats one path -- so the
next size step is a deterministic LZ block codec over the payload rather than
more field surgery. Two removals are *not* repetition and stay on the list: the
2,229 B of `tcode` for units whose reader never decodes it (an unbound std unit
-- `std_unit_bound` false -- while the `ycc build` object format always wants
types), which needs `pack_unit_fields` to know its reader, and the 377 B of
`btext` in a unit with no IR_TEXT item. Each is worth under a percent once the
payload compresses, so they follow the codec only if the measurement still
cares.

The codec's home is the trailing frame: keep `[payload][8-digit length]
[YCCPACK1]` and let `self_pack` hand `std_unpack` a plain payload of the
current version -- a method byte after the length, or a second magic. The
language server reads the pack with its own copy of that frame
(`src/tools/lsp/yserve.y`), so whatever the frame says, yserve has to decode it
too, and the codec must be reachable from both.


`--std-src` ignores the pack and compiles the std units from the
embedded sources, as does a ycc whose pack is missing (cycc, or a ycc
just written by a self-compile) or of another version: the output is the
same bytes either way (`test/sh/test_link.sh` checks it over programs
that link every unit; `make ycc`, `ynew` and the fixpoint suite each
compile the compiler with the pack and compare with a build from source).
A hello world compiles in 5.1 ms instead of 13.8 ms from source (the
spliced build before units took 14.1 ms). The pack adds 81 KB to `ycc`
(it held 162 KB of assembly text before).

## Packages

`ycc build [DIR]` (ycc.y `build_project`) builds a project — a
directory with a `y.toml` (the manual's *Packages* section has the
format). pkg.y reads the manifests and walks the dependency graph
(`pk_load`): every package the project depends on, each after the ones
it depends on, then the project's own `lib`; git dependencies are
cloned into `build/git` and pinned in `y.lock` (`pk_fetch`,
`pk_lock_write`), `vendor/NAME` winning when present. Each package is
**its own unit**:

- **Resolving**: a package's `lib` is resolved like a program
  (`native_resolve_pk`), except that a bare `import NAME;` of one of
  its own dependencies is not spliced but recorded (`Resolved.pkgs`),
  and its project's `src` roots join the search path (`res_roots`).
- **Labels**: package k (in graph order) numbers its uids and cells
  from 5e9 + k·1e9 (`pkg_base`), above the std units.
- **Names**: an importer keeps a package's names qualified:
  `strip_ns` rewrites `json.parse` to the identifier `json.parse` when
  `json` is a package the unit imports (`pkg_ns`), rather than dropping
  the namespace, and `json.x = v` to an assignment to `json.x`. The
  package's exports (`pkg_exports`: every top-level def and let, with
  the companion cell of a string global) are bound in the importer under
  those names (`unit_externs`), globals as `const` — read-only, so
  `cannot assign to constant 'json.x'`. Their parameter defaults travel
  along (`Unit.dfl`: `unit_dfl` encodes the literals, `lit_decode`
  rebuilds them, `rename.rename_program_x` seeds them), so a call fills
  in defaults and optional parameters as it does for a local def.
- **Objects**: `compile_package` compiles with line markers, like a std
  unit, so one object serves plain and `-g` builds. `unit_obj` writes it
  to `build/obj/NAME.yo` — `ycc-unit 4`, its key, its name, then the
  unit's fields as in the std pack — and `unit_unobj` takes it back only
  under the same key and at its exact length. The key (`build_key`, a
  two-lane hash, `pk_hash_*`) covers the compiler binary itself
  (`pk_self_id`), the package's name and base, `--no-exec`, its resolved
  text and origin map (so the paths the build saw), its std needs, and
  the interface (`unit_iface`: exported names, labels, types, defaults)
  of each package it imports: a body change recompiles that package
  alone, an interface change its importers too. A package's warnings
  (`lint.y`) come back from `compile_package` and print when it
  compiles (its files named as in its errors); one loaded from its
  object prints none. Bins warn on every build.
- **Parallel levels**: the package order is topological, so every
  dependency has a lower index than its importer and a run of packages
  that depend only on what is already compiled is a *level* — the
  packages in it are independent of each other, which is where a
  project's build time is. `build_dispatch_level` hands each one to a
  child compiler (`ycc build --one NAME`, through a single `exec` of a
  shell line with `&` and `wait`, `BUILD_JOBS` at a time), and the loop
  then reads the objects they wrote exactly as on a warm build. A child
  that fails leaves no object and the loop compiles that package
  itself, so the bytes and the diagnostics do not depend on the
  dispatch; warnings come back in a sidecar named for the object's key
  and print where the serial loop would have printed them. Not
  `spawn`/`join`: a thread shares the address space and 51 module-level
  lets with it. Nothing goes out for a level of one, for a package
  whose object is there, or under `--std-src`.
- **Linking**: each `[bin]` is resolved and compiled by `emit_program`
  with the units it reaches (`build_reach`: the packages it imports,
  through other packages too) and the std units all of them need.
  `_start` runs the std units' inits, then each package's (dependencies
  first), then the program's top level; it captures `argv` when a linked
  package's code reads it. A program's `y_` def still overrides the
  runtime's, and so does a package's: `y_` labels are global.

Limits: a package's type aliases stay its own (an importer spells the
type out); its globals are read-only to importers; objects are keyed by
the paths the build saw, so building the same project from another
directory compiles its packages again. `test/sh/test_pkg.sh` covers the
format's every error, the graph, the cache, git and vendoring, and
checks that the C copy builds the same bytes.

## Tree shaking

Nothing reaches the binary that the program does not reach itself:

- **bodies** — `prune_bodies` drops every function nothing calls, rooted at
  `_start` plus whatever the kept arch prelude references from Y (so a
  helper the prelude calls by label survives: `link_units` shakes the
  prelude with the kept bodies' references and, when a kept block names a
  body not kept, shakes both again; no prelude block calls Y today). It works across units: the std
  units' bodies and the program's are shaken together, from each body's
  label and the labels it references (computed once per unit). An unused
  stdlib function costs nothing — not even its parse, with the std pack.
- **arch blocks** — the arch prelude and the rodata constants are split
  into labelled blocks, of which exactly the ones referenced from the
  surviving code or from another kept block are kept (`call`, `lea`, a
  jump, or a computed immediate like `$ystr_end-ystr`, which names both),
  plus any block the previous kept block falls through into. Labels never
  merge blocks, so an internal loop label travels with its own references
  and dead code is dropped even mid-function. The prelude comes as its
  lines (`arch_prelude_lines`: labels alone at column 0, everything else
  indented), so `prelude_blocks` finds its ~190 blocks by each line's
  first byte and `shake_prelude` scans only the blocks a program reaches
  for their references; the constants (a few lines) go through
  `shake_refs`, which scans text. Scanning the whole ~1.7k-line prelude on
  every compile was two thirds of a hello world's compile: shaking it by
  lines took that compile from 16.9M instructions to 4.9M.

Measured cost, and what was paid back: the move cost compile time and
string-heavy output when it landed (17-25% slower compiles, up to 2x on
`tostring`/`index_of` loops). The optimization loop documented in
AGENTS.md has since paid most of it back — same benchmarks, loop start
(`6a753ae`) against loop end: SCORE 110.78, self-compile +21.3%
(2.46 s -> 1.93 s), string-heavy output +30.8% (100 -> 69 ms), arena
-18.7%, output sizes unchanged. What made the difference: `byte_at`
(the string byte primitive) so the Y string helpers scan instead of
copying, plus allocation-free character classification in the lexers.
What remained on the table was chiefly the allocator: two `brk` syscalls
per allocation, because the ELF had no writable segment to cache the
break in. Globals moving to `.bss` gave it one; `y_alloc` is now a bump
over `mmap` chunks with its state in `.bss` (bench/compare.sh against
`d2ffa81`: SCORE 176.73 — compiles 60-70% faster, self-compile 7.09 s ->
2.16 s; allocation-heavy output up to 12x faster, closures 105 -> 8.6 ms,
strings 158 -> 27 ms; peak heap and output unchanged but for one program
header).

Measured against the pre-tree-shaking compiler (bench/compare.sh of this
work against commit `ae6cff1`, same benchmark programs on both sides):
output is 33–50% smaller and the asm is 55–79% smaller for small
programs, at a cost — compiling is 17–25% slower (every program now
compiles the ~350-line runtime chunk, and the primitives that moved to Y
do more work per call) and string-heavy output (`tostring`/`index_of` in
loops) can run up to 2x slower than when they were hand-written asm. The
self-compile slowed less than its source grew (562 KB vs 427 KB spliced,
8% slower per KB). That trade — binary size and readable runtime for
compile time and string-heavy speed — is deliberate; the next lever was
the remaining hot primitives (`y_long_tostr`, now asm again — see above;
`y_str_index`, `y_str_split` and `y_str_trim` are asm again too: in Y
they scanned ~40 instructions a byte, a seventh of a self-compile spent in
the assembler's searches of its own lines).

A hello world is 8 KB (8312 bytes, the page-aligned ELF) and under 100
asm lines: `_start`, `y_print_hstr` and `y_put_hstr` — not even the
allocator. `print(42)` adds `y_long_tostr` and `y_alloc` (232 lines); the
splitter, the file layer and the float formatter are not there because the
program does not use them.

A body's own references come out of its items (`ir_refs`: every label
operand, the label of a `lea lbl(%rip)`, both labels of a `mov $A-B` --
the same set the text scan found). The scanners below walk the *text*
parts -- the arch prelude and the rodata constants -- through a
`bytes()` copy and materialize only the symbols they reference; a
per-character slice would cost an allocation per character.

## Optional std modules

`import net;` — no `from` — pulls in an optional std module by NAME, and
every function is called through the namespace:

```y
import net;

def hello(req: str) -> str {
    net.http_response(200, "hi there")
};

net.listen_http(8080, hello);        // blocking, serving forever
// net.listen_tcp(22, tcp_handler);  // raw connections instead
```

A module is a plain Y file; adding one is dropping a file in `src/y/std/`.
`import name;` looks for `name.y` next to the importing file (a project can
vendor or shadow a module), then in `std/` and `src/y/std/` relative to the
working directory, then in the same places relative to the `ycc` binary — so
the test suite works from any directory. `std_resolve` in native.y holds the
list.

The file found is spliced like `import x from "path"`, but it keeps its
own scope (rename.y): its top-level defs and lets are bound as
`fs.read_file` — one name, with a `.` no source can write — so they never
meet the program's names, and a program may define its own `exists` or
`let cwd = fs.cwd();`. The resolver records which file each name came in
as (the origin map's `mods`); rename.y's `rn_top` qualifies a module's
top-level names (`rn_qualify`; a `y_` name stays global, as generated code
calls it by label) and renames each statement with `rn_mod` set to its
module, so `rn_lookup` finds the module's locals, then its own top-level
names, then the program's. `fs.x` is resolved there too (`rn_qualified`):
when `fs` is a module and no binding named `fs` is in scope, it is the
name `fs.x`; a local `fs` keeps its field. find_dup qualifies the same
way, so only files imported by path, which share the program's
namespace (strip_ns rewrites `util.f` to `f`), can collide.

**A module may import the program back.** `native_resolve_seen`
de-duplicates spliced modules through a `seen` list, and the program
counts as already spliced: `resolve_unit` passes its own normalised path
down as `self_path` and the already-spliced test consults it. It is passed
*beside* `seen`, not inside it, because `seen` is also the file-id
counter -- a nested call is handed `len(seen)` -- so seeding it would shift
every module's id in `origin.file` by one and mis-attribute whole files.
`src/y/asm.y` imports `src/y/ir.y` and `ir.y` imports asm.y back, which is
legal (they are separate units, and a unit may be imported by more than
one); the program was spliced twice, so every one of its declarations stood
in the tree twice and `ycc src/y/asm.y` reported a duplicate definition
for each. It is only ever compiled as a unit of `ycc.y`, so nothing caught
it until the language server checked the file a person had open.
`test/y/native/t316_circ_import.y`, and the module it imports back
(`test/y/native/m316/circ.y`, a program in its own right), check the cycle
from both ends.

The qualifier is still recorded: a module reaching the program by name
keeps its namespace, so the already-spliced branch pushes the name into
`imports` and `strip_ns` flattens it, exactly as for any other
already-spliced module.

Where the program *declares* a name still decides whether a module can use
it, because the splice is a flat text and a module's lines land where the
import line was. A module can name a `def` of the program wherever that
`def` sits; a top-level `let` only if it came earlier in the file. That is
a property of the splice, not of the cycle -- `ir.y` references nothing
across its own cycle for the same reason.

**A path import flattens types as well as expressions.** `strip_ns` has two
entry points and they used to disagree: `strip_ns` for nodes, and
`strip_type` for the annotations on them (`Decl.typ`, `Func.ptypes`,
`Func.ret`), reached from `strip_decl` and the `K.func` arm. A module
imported by path contributes no name to the origin map's `mods` — its
names are already flat — so `rn_stmt_mod` returns `""` for its
statements and `rn_prepass_one` registers its type aliases under their
BARE names. A reference written `m.T` arrives from the parser as a tname
spelled `"m.T"` (`parse_type`, `m.T` branch), and before `strip_type`
nothing rewrote it: `let p: m.Pair` was `unknown type 'm.Pair'` while
`let p: Pair` compiled. Two spellings of one declaration in a language
that documents a path import as flattened.

So `strip_ns_name` drops the `m.` from `m.T` when `m` is in the import
list, and `strip_type` applies it through every arm of the type union —
`tname`, `tptr`, `tarr`, `tarrfix`, `topt`, `tmap`, `tparams`, `tunion`,
`tfunc`, `trec` — so a nested annotation flattens at any depth. A
PACKAGE-qualified name is left alone: a package is linked as a unit of
its own, so `pkg_ns` keeps its qualification on purpose.

Cost: one extra walk of every annotation the program writes, whether or
not any of them is qualified. `bench/compile_ir.sh` on the fix:
+0.03% of the instructions `ycc.y` takes to compile itself, +0.05% at
the most (std_struct.y), +0.01% at the least. `native/t216_strip_ns_types.y`
checks every arm.

A module's
type aliases are scoped the same way: `rn_prepass_one` registers one as
`m.T`, the names of the module's other top-level aliases in its type
qualified too (`rn_qual_type`, from the list `rn_top` makes), and
`rn_alias_index` tries `rn_mod + "." + name` before the bare name; the
parser reads `m.T` in a type and in a type pattern. lint.y keys aliases
the same way (`lint_unit` gets the origin map), so a program's alias
named like a module's is no redeclaration. The labels keep the `.`
(`yfn_12_fs.exists$3`; `is_id_b` reads it as part of a symbol), so `-g`
names the function `fs.exists`. A package's exports leave out the modules
it imports (`export_name`). Modules are compile-time input only: the
program that runs has no use for the file.

`src/y/std/fs.y` is the file system (the builtins `read_file`,
`write_file` and `write_bytes` moved into it, `import fs;`): whole
files as text or bytes (`read_file`, `read_bytes`, `read_lines`,
`write_file`/`write_bytes` with an optional mode, `append_*`,
`copy_file`), paths (`exists`, `is_file`, `is_dir`, `file_size`,
`rename`, `remove_file`, `set_mode`), directories (`make_dir`,
`make_dirs`, `list_dir` — sorted —, `remove_dir`, `remove_all`, `cwd`,
`chdir`) and fds opened with a mode string (`open_file(path, "r" | "w" |
"a" | "x" [+ "+"])`, `read_some`, `read_all`, `write_text`, `seek`,
`close_file`); manual §"Files (the fs module)". The compiler itself
reads its sources and writes its binaries through it.

`src/y/std/net.y` is the first network module: TCP over raw sockets
(`socket_tcp`/`bind_tcp`/`listen_fd`/`accept_tcp`/`connect_tcp`/
`send_str`/`recv_str`/`local_port`), host names (`resolve`: a dotted quad,
/etc/hosts, then DNS to the /etc/resolv.conf nameservers -- `search`
domains for a name without a dot; `resolve_with` asks one server: an A
query over UDP, twice with 2 s each, over TCP when the answer is
truncated; a malformed answer is no addresses, never a crash), so
`connect_tcp` takes a name, and a tiny HTTP server (`http_response`,
`http_read_head`, `http_serve_one`, `listen_http`), all Y over `syscall`
(it imports `fs` for the two files). IPv4 only. A `ui` module would land
the same way.

`src/y/std/math.y` is the number module (`import math;`): integer and bit
helpers (`min`/`max`/`abs`/`clamp`/`sign`, `gcd`/`lcm`, `isqrt`, `popcount`,
`ctz`/`clz`, `next_pow2`, and `mul_mod`/`pow_mod`/`inv_mod` for a modulus up to
2^31, where reducing the operands first keeps the product inside a `long`), the
float comparisons and constants (`fmin`, `fmax`, `fabs`, `fsign`, `lerp`,
`is_nan`/`is_inf`/`is_finite`, `pi` and friends, `nan`/`inf` as values), the
SplitMix64 and xoshiro256**/+ generators over a caller-owned `[long]`, and
whole-array work over `[float]` (`fsum`, the Neumaier-compensated `fsum_kahan`,
`fdot`, `fmin_of`/`fmax_of`, in-place `fscale`/`faxpy`, `fmean`, `fvariance`).
Y has no overloading, so the float flavours carry an `f`. There is deliberately
**no** `sqrt`, `exp`, `log`, `pow` or `sin`: each needs a `float`→`long`
conversion or a look at a float's bits, and Y has neither way to get at either
(see the *Limits* note on `float` below), so they are not merely missing but
unwritable until the machine primitives exist.

`src/y/std/crypto.y`, `x509.y` and `tls.y` are a TLS 1.3 client in plain
Y, each importing the one before it. crypto: SHA-256/384/512, HMAC, HKDF,
ChaCha20-Poly1305 (RFC 8439), AES-128/256-GCM (T-tables, a bitwise
GHASH), X25519 (TweetNaCl's limbs), and for signatures Montgomery
arithmetic on 30-bit limbs: RSA PKCS #1 v1.5 and PSS, ECDSA on P-256 and
P-384 (Jacobian coordinates, Shamir's trick). x509: DER and PEM, the
system CA bundle (read once), path building to an anchor (depth 8, every
issuer a CA in its period with a good signature), one-label wildcards; no
revocation, name constraints or policies. tls: RFC 8446 with X25519 and
the three suites, the chain checked by x509, CertificateVerify and
Finished checked, ALPN, KeyUpdate; no HelloRetryRequest, resumption or
client certificates. Rough speeds: X25519 5 ms, ChaCha20-Poly1305 13
MB/s, AES-GCM 7 MB/s, SHA-256 21 MB/s; a chain verifies in 10-80 ms. The
fixtures `t158_crypto.y` (known answers) and `t159_x509.y` (a chain made
for it, at fixed times) run offline; test_net.sh runs the client against
`openssl s_server` when there is one.

`src/y/std/regex.y` is regular expressions (`import regex;`): a Pike VM --- a
Thompson NFA simulated with priority-ordered thread lists --- so a match costs
time linear in the subject times the pattern and `(a*)*b` or `(a|aa)+b` against
a megabyte of `a` answer at once. That is what it buys with no backtracker:
there are no backreferences and no pattern recursion, and the only run-time
recursion is a lookaround's (bounded at compile time). It matches **bytes**,
like every other text operation in the tree; `compile` gives `Re?` and `check`
the message, since a pattern is data rather than a caller bug. The whole API
takes the compiled pattern as its first argument (`regex.search(re, s)`) rather
than being a method on the record: `x.f(...)` is a field read, and a method
would have to be a closure, which the C twin's value model cannot hold. Four
compile-time prefilters keep the common cases cheap without a second engine:
`anchored` (a leading `^`/`\A`), `first` (the byte set a match can begin with,
and a byte compare when it is a single byte), `literal` (the bytes every match
must begin with) and `need` (bytes every match must contain anywhere, which
settles the whole question in one scan when the subject does not have them).
Rough speeds on an 8.2 MB subject of log lines: a literal `find` 38 ms, `\d+`
`find` 216 ms for 1.1 M matches (that is 274 MB of `Match` values, which is what
returning every match costs in a heap that never frees), `(?i)STATUS=OK` `find`
51 ms, `(\d+)-(\d+)` `replace` 899 ms, `(\w+)@(\w+)` 10 ms and no allocation
when the subject has no `@`, and the two hostile patterns under a millisecond
over 64 KB. The fixtures are `t191_regex.y` (the dialect and every
diagnostic), `t192_regex_groups.y`, `t193_regex_sweep.y`,
`t194_regex_group_trap.y` and `t195_regex_corpus.y` (178 cases, generated by
`ideas/regex/gen.py`, whose expected output is what Python's `re` says about the
same bytes — a different engine, so agreement is evidence);
manual §"Patterns (the regex module)".

## Embedding files

`embed NAME from "path";` on a line of its own declares `const NAME =
"<the file's bytes>";`, read when the program is compiled:

```y
embed HELP from "help.txt";   // relative to this file, like an import
print(HELP);
```

The program carries the bytes; the file is not needed at run time. The
path is relative to the file that says it (an absolute path stays as is),
a missing file is a compile error, and any bytes go — quotes, backslashes,
control bytes, no final newline (`t66`, `e58`). `native_resolve_seen`
handles the line like an import: `embed_decl` writes the const with the
contents quoted onto that one line (`quote_text`), so every line number
after it holds (`e57`). A line that merely starts with the word
(`embed = 1;`) is code. The compiler embeds its own runtime this way (see
the runtime library above).

## Debugging and profiling compiled output (`ycc -g`)

`-g` adds what the standard tools need to name code and map it back to
the source: section headers (`.text`, `.rodata`, `.bss`), a symbol table
— an `STT_FUNC` per function (user defs, the runtime's `y_*` helpers,
`readline`, …), an `STT_OBJECT` per global, `_start` the one global
symbol — and DWARF 4 line information. Names are the source names (the
rename pass's `yfn_<uid>_`/`yg_<uid>_` prefix and `$N` suffix are
stripped), so they line up across builds; a symbol's size runs to the
next symbol.

The line table has a row per statement, per function entry, per `else
if` test and per loop step (the back edge), each at the file and line
the code was written on: an import keeps its own file name and lines, and
the embedded std modules show as `std/rt.y`, `std/str.y`, …. native.y
writes GNU as's own `.file N "path"` and `.loc FILE LINE` directives into
the asm text — renumbered into the program's file table (a linked unit's
own file numbers move by that unit's offset, in the assembler and in the
`-S` listing alike, so the two agree) — so `ycc -g -S` output still
assembles with `as`, which builds the same table — asm.y records each
marker's code offset, and
dwarf.y encodes `.debug_line` plus a minimal `.debug_info`/
`.debug_abbrev` (one compile unit; relative paths are relative to its
`DW_AT_comp_dir`, the directory `ycc` ran in). There are no types,
variables or frame descriptions: gdb breaks, steps and backtraces by
file:line, but `print x` and `info locals` know nothing, and the asm
prelude and `_start`'s entry have no source line.

It changes nothing that runs: the tables and headers are appended past
the loaded image, and the code, rodata and every address are those of the
plain build (`test/sh/test_debug.sh` checks it). One difference is
invisible to the program: valgrind reads an executable's symbols only once
it has seen a file-backed read+write mapping, so a `-g` build takes the
first 8 bytes of its `.bss` from zeros in the file.

```
ycc -g -o prog prog.y
perf record ./prog && perf report      # sampled cpu, by function
perf annotate --stdio -l               # ... and by source line
valgrind --tool=callgrind ./prog       # exact instruction counts + call graph
callgrind_annotate callgrind.out.*     # per function, then the source annotated
valgrind --tool=massif --pages-as-heap=yes ./prog   # memory over time
gdb -ex 'break leaf' -ex run -ex bt ./prog          # breakpoints by name
gdb -ex 'break prog.y:12' -ex run ./prog            # ... or by line; next/step
addr2line -e prog 0x4002c7             # an address -> prog.y:3
objdump -dl prog                       # disassembly with file:line
strace -c ./prog                       # syscall counts (read/write/mmap)
```

Notes: `y_alloc` takes memory with `mmap` (not `malloc`/`brk`), so massif
needs `--pages-as-heap=yes` to see it, and memcheck sees one big mapping,
not separate heap blocks (it cannot flag an overrun into a neighbour). gdb unwinds through the `%rbp` frame chain. A program with no
`.bss` at all (it never allocates and has no globals) gets no names under
valgrind — it has no read+write mapping to back. On WSL the
`/usr/bin/perf` wrapper may refuse the kernel; run the real binary under
`/usr/lib/linux-tools/*/perf`. `ycc --time` is the compiler's own
per-phase profile (time, heap, counters).

## Benchmarks

`bench/` holds benchmarks for the compiler and for what it produces —
none of it runs in the test suites. `bench/compare.sh BASE_YCC NEW_YCC`
scores two builds (100 = unchanged) over compile time, run time and
binary size — asm bytes and asm lines are reported as detail but are
**not** part of the score — then runs every benchmark's `-g` build of
both under callgrind and tabulates instructions per function.
A change that can affect performance gets a thorough bench and profiling
at the end (AGENTS.md); the details are in `bench/README.md`.

## Testing

`test/sh/test_native.sh` compiles `test/y/native/t*.y` and `e*.y`
straight to executables with the built `./ycc` (`ycc -o bin prog.y`, no
`-S`) and checks stdout/exit. `t*.y` assert behavior
(`.expected` stdout, `.exit` code, `.stdin` for input); `e*.y` assert rejection (first line
`// expect-error: <substring>` must appear in the compiler output). A `t*.y`
line marked `// expect-warning: <substring>` must draw a warning containing
it, and no unmarked line may draw one. Native
programs must also keep passing if the C path ever learns the feature — one
behavior, two backends.

`test/sh/test_native_examples.sh` is the ratchet on the example corpus:
every `test/y/examples/*.y` the built `./ycc` accepts must print what the
reference compiler's output prints. Its `UNSUPPORTED` map is currently
**empty** — every example compiles — and the suite fails as soon as one of
them starts compiling again, so the list can only shrink.

## Known native limitations

- Division and modulo are exact across the whole long range, including
  `LONG_MIN / -1` and `LONG_MIN % -1` (`idiv` raises `#DE` on that pair, so
  divisor `-1` is compiled as a negation / a constant zero instead).
  Negating `LONG_MIN` still wraps to `LONG_MIN`, as the language requires.
- `%` truncates toward zero (C's) and `mod(a, b)` floors (the sign of `b`);
  they agree when the remainder is zero or the operands share a sign. Both
  are exact at `LONG_MIN` (`mod(LONG_MIN, -1)` is 0, not `#DE`), and both
  trap on a zero divisor.
- Division/modulo by zero, a negative shift count, OOB indexing,
  unwrap-of-none, OOM each exit cleanly with a message + exit 1.
- Maps are linear-scan (a `{keys, vals, boxes}` record): fine for small
  tables, O(n) per lookup. Records, heap strings, string slices and the string
  builtins (`join`/`split`/`tostring`/`ord`/…) are supported — the compiler
  itself relies on them.
- `float` is IEEE754 double, held in `%rax` as raw bits and moved through
  `%xmm` only for arithmetic and comparison, so slots and the calling
  convention are unchanged. Literals (including scientific notation) are
  built at run time as `mantissa × 10^n` with `cvtsi2sd` — IEEE arithmetic
  is correctly rounded, so the compiler needs no float parser. Printing is
  fixed 6-decimal, matching the reference's `%f` formatting, but only for magnitudes below
  2^63: `cvttsd2si` cannot take anything larger, and reproducing printf's
  exact expansion needs bignum arithmetic, so those print
  `<float magnitude >2^63>` rather than noise.
- **There is no `float` → `long` conversion, and no way to read a float's
  bits.** `cvttsd2si` exists (it is how `y_float_tostr` splits a double into
  its integer and fractional parts) and `movq` moves a double between `%rax`
  and an `%xmm` register, but nothing exposes either to a program: `long` →
  `float` widens implicitly and that is the whole list. So a program cannot
  take a `float`'s integer part, cannot pull an exponent out of one, and cannot
  reinterpret one — which is exactly why `std/math.y` has no `sqrt`, `exp`,
  `log`, `pow` or `sin` (see *Optional std modules*): each of those needs a
  `float` → `long` conversion for its range reduction, and there is no
  spelling of one. Three small machine primitives — a truncating conversion,
  a bit cast each way, and `sqrtsd` — would unlock all of them, plus `floor`,
  `ceil`, `round`, `ldexp` and `frexp`; that is the one thing standing between
  this language and a numeric library.
- `str` supports `<`, `>`, `<=`, `>=` (lexicographic, via `y_str_cmp`
  returning the sign), matching `strcmp` semantics.
- **Embedded NUL bytes.** A `str` is length-prefixed (`{len, data..., NUL}`),
  so `from_bytes([65, 0, 66])` is a 3-byte string and `bytes()` returns all
  three. Use `[byte]` arrays for binary data.
- Unbounded (non-tail) recursion exhausts the stack: there is no
  recursion limit, so deep non-tail recursion dies on a guard page. Tail
  recursion is constant-space (see above).
- Arena heap: nothing is freed (no leaks that matter for short-lived
  binaries; long-running programs want the planned GC).
- Threads lock nothing for the program: an array, a map or an owned
  string two threads change at once needs a mutex around it, and
  `readline()` serves one thread at a time. A thread nobody joins keeps
  the unused tail of its heap chunk (address space only: untouched pages
  cost no memory).
- A record built where no type is declared gets the descriptor of its
  own type: `let r = {a: none};` is an `{a: none}`, not the `{a: long?}`
  it is later stored as, so a `match` on a union holding it finds no
  member (`no match arm matched`). Write the literal where the type is
  declared, or annotate the binding. Two spellings of one recursive type
  unrolled differently (`{x: {x: A?}?}` against `A = {x: A?}`) are told
  apart the same way.
- A cast between a union and a member, or between two unions, copies the
  record where their layouts differ (`gen_convert`): a write through the
  copy is not seen through the original, and every copy allocates. A
  `match` arm's binding (`T x`) is such a cast; a destructuring pattern
  (`T {f, g}`) reads the fields in place and copies nothing.
- `y_alloc` rounds every request up by 8–15 bytes, and when a request
  under 256 KB does not fit in the current 4 MB chunk the chunk's tail is
  abandoned (at most 256 KB, ~6%, per chunk).
