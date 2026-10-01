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
| `src/y/arch_x64.y` | x86_64 behind the arch interface: `arch_id/word/sysno`, `arch_fn_label/loc_label/str_label`, `arch_header/rodata/text`, `arch_prelude`, `arch_consts`, `arch_frame` (16-align), `arch_exit`. The prelude is only the **primitives** that need raw machine state (allocator, traps, record lookup, the byte-moving string/array cores, float formatting, argv) |
| `src/y/native.y` | pipeline driver: `native_resolve` (splice imports + optional std modules) → strip namespaces → rename → check → hoist → frame layout → tree shake → arch emit |
| `src/y/rename.y` | uniquify pass: every binding gets `name$N`, killing scopes/shadowing downstream |
| `src/y/enc64.y` | x86_64 instruction encoding for exactly the forms we emit |
| `src/y/asm.y` | two-pass assembler over our asm dialect |
| `src/y/elf.y` | minimal ELF64 writer: one PT_LOAD (R+E), plus a zero-filled RW one for `.bss` when a program has globals or a heap; static, entry `_start`; `-g` adds `.symtab` and section headers |
| `src/y/std/` | standard library **in Y**: `rt.y` (the runtime library, spliced into every program), `prelude.y` (`readline`/`clear_eof`), `exec.y` (`exec`, its own file for `--no-exec`) and `str.y` (the helper-backed string methods) — those four embedded into the compiler — then `io.y` (file I/O over raw syscalls), `net.y` (TCP/HTTP, an optional module), `struct.y` (pack/unpack helpers) |

New Y modules under `src/y/` must get a **1:1 C twin** in `src/c/` (see
`PORTING.md`) -- the two compilers are kept in lockstep. (`src/y/std/` is
the exception: those files are spliced into *compiled programs*, never
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
  `y_arr_push`/`y_arr_prepend`/`y_arr_slice`/`y_arr_eq` take `esz` as an
  argument, so one implementation serves both layouts. 100k elements are
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
- **Arrays and records are reference values**: a binding stores the address,
  never a copy. `let b = a`, passing, returning and storing all share, and
  `a[i] = v` / `s.f = v` are observable through every alias. Both
  implementations use the same model. (Copy-on-store used to emulate value
  semantics here; it made every helper that returned an accumulator O(n), so
  the assembler was O(n²) and self-compilation OOMed past 7.5 GB.)
- Heap (bump allocator over 4 MB anonymous `mmap` chunks; its state — the
  bump pointer, the chunk end and the bytes handed out so far — lives in
  three `.bss` words, `y_heap`, which a program that never allocates shakes
  out): dynamic arrays `[v, ...]` as `{len, cap, data, front}` headers
  (element block allocated separately), option boxes. A request of 256 KB
  or more gets a mapping of its own.
  Nothing is ever freed (arena); no GC to write until something needs it.
- Expression values in `%rax`; operands that must survive nested evaluation are
  **pushed** (nothing live in caller-saved regs across a call).
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

## Output: our own executables

`ycc -o prog prog.y` writes a static ELF64 directly: `enc64.y` encodes each
emitted instruction (fixed-size near jumps/calls, so lengths are known in
pass 1), `asm.y` assembles (two passes + fixups + rodata), `elf.y` wraps one
PT_LOAD (R+E) with entry `_start`, plus — when the program has globals or
a heap — a second, RW PT_LOAD with no file bytes that the kernel
zero-fills: the `.bss` section (`.zero N` reserves space there; data or
code in `.bss` is an assembler error). `-g` appends a symbol table and
section headers past all of that (see "Debugging and profiling" below).
Verified byte-for-byte behaviorally against
binutils-built binaries for the whole corpus. The assembled bytes go straight
out through the `write_bytes` builtin (raw `open`/`write`/`chmod` over
syscalls, mode 493 = 0755), so NULs pass through untouched. No cc/as/ld
involved.

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
- Memory safety today = static types + trapped OOB + arena heap (nothing
  freed, nothing dangles; no pointer arithmetic — `p + 1` is a type error).
  Later: GC, heap maps/strings, fat pointers or a borrow checker.

## Syscalls & std

- `syscall(num, a1, …, a6)` is a **compiler intrinsic** (not a C builtin):
  native backend emits the `syscall` instruction with the Linux ABI
  (`rdi,rsi,rdx,r10,r8,r9`, number in `rax`). 1–7 args, each `long`/`bool`/
  `str`/`*T`; returns `long`. Type errors otherwise.
- `src/y/std/io.y` wraps raw numbers (`openat`, `read`, `write`, `close`,
  `fchmodat`): file I/O with zero C code (`test/y/native/t12_cat.y` is a pure-Y
  cat; `t10_filewrite.y` creates/writes files). It has no `exit` def on
  purpose — a def named `exit` shadows the intrinsic program-wide (see the
  export list).

## Type system (types.y) — the law, expanded over time

Now: `long`/`int`, `bool`, `float`, `str`, `byte`, `*T`, `[T; N]`, `[T]`,
`T?`, `{f: T}` records, `{K => V}` maps, record unions `A | B`,
function types `(A, B) -> R`, monomorphic `def` (a param without an
annotation infers the poison type `<error>` — annotate; return types and
locals are inferred), captures resolved into closures, `if` cond must be
`bool`, `if` arms that disagree make the `if` `void` (a statement; using it
as a value errors), `while` is `void`-typed, and the only implicit
conversions are `long`→`float`, `byte`→`long`/`float`, `long`→`byte` at an
annotated site, `str`→`*T` and `none`-unification. There is no `null`:
`none` is the empty option and postfix `x!` is `unwrap(x)`. Error messages
strip rename's `$N` suffixes and carry line/col (LSP feeds on these).
Later: generics, borrow rules, methods/traits if Y grows them.

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
- **`print(a, b, ...)`** is `print(tostring(a) + tostring(b) + ...)`.
- **Default parameters** `def f(n, acc = 1)`: the default must be a
  literal and types an unannotated parameter; rename.y fills omitted
  trailing arguments of direct calls.
- **Optional parameters** `def f(a: long, b?: long)`: the body sees `b` as
  a `long?`; a direct call passes a plain `long` (rename.y wraps it in
  `some`) or leaves it out (`none`). Passing an option is a type error
  (that is what `b: long?` is for), and so is a required parameter after
  an optional one; defaults may mix with them.
- **`const x = v`** binds like `let` but the checker rejects rebinding it
  (`=`, `op=`, `++`/`--`); the value it names stays mutable in place.
- **Properties** `a.length` / `s.length` (= `len`) and `a.ptr` (`*T` to
  element 0, arrays only) are checked in types.y (`typeof_prop`) and
  emitted by `gen_prop`.
- **Tail calls** recycle the frame for `self(...)` and for a call naming
  the function being emitted.
- **`type A = T`** aliases are resolved by rename.y (scoped to their block,
  hoisted like defs); unions are flattened.
- **Unions** `A | B` hold record types only. Records carry their field
  table, so the member a value holds is recognized at run time by its
  field names (`y_rec_has` in the prelude). A record flows into a union
  that has a compatible member; a union flows nowhere but another union
  until a `match` narrows it. Unions print as the member they hold.
- **`match e { pat => arm, ... }`** is lowered by the parser to
  `{ let $m = e; if (test) { binds; arm } else if ... }` over three node
  kinds: `rectest` (has T's fields), `narrow` (the value typed as T) and
  `matchend` (the fall-through). Patterns: `_`, `T x`, `T {f, g: y}`, `T`,
  record patterns `{f: v} x` / `({f: v}) x` (fields equal to values) and
  literals (`1`, `"s"`, `c'a'`, `true`, `none`, `-2`, `(expr)`). Arms follow
  the `if` law. Without `_`, every union member must be covered by a type
  arm or the match is rejected as non-exhaustive. A value pattern (a
  literal, or a record pattern like `({f: 10}) x`) matches only the values
  it names, so it never counts as covering a member — the error says so.
- **Strings**: `s[i]` is the `byte` at i (trapped out of bounds), `s[lo:hi]`
  the substring — half-open and clamped like an array slice (`lo < 0`
  counts from 0, `hi > len` stops at len, `hi <= lo` is `""`), with
  `s[:hi]` and `s[lo:]` for the omitted bounds. There is no `substr`:
  `substr(s, a, n)` is `s[a:a + n]`. **`c'a'`** is a `byte` literal.
- **String methods** `s.m(args)`, as in `"str 1 2 3".split(" ")`, work on
  any `str`-typed receiver. One table, `str_method` in types.y, drives
  both the checker (`typeof_method`: arity, argument types, result) and
  the emitter (`gen_method`). Builtin-backed methods are the builtin with
  the receiver as its first argument: `split`, `trim`/`strip`,
  `index_of`, `last_index_of`, `bytes`, `tonum`, `ord`, `byte_at`, and
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
  a spec, ...) lexes to one `ferr` token, which the parser turns into an
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

## Self-hosting: done

`ycc` compiles its own source to a byte-identical binary. The chain is
`cycc → ycc → _ycc`, gated by `cmp ycc refs/ycc.ref` and `cmp ycc _ycc`
(`make ycc`), and `test/sh/test_fixpoint.sh` re-checks it from an
already-built `./ycc`, including a third generation and a smoke compile
with the self-built binary.

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

`src/y/std/rt.y` holds runtime code written **in Y**, spliced in front of
every program by `native_resolve` (always — generated code calls into it by
fixed label, so there is no name to test for). These are ordinary defs:
they go through rename, typecheck and emit like any user function, so a bug
in them is a bug in Y code rather than in hand-rolled x86.

The rule is that `arch_x64.y` provides small, general **primitives** and the
runtime provides **behaviour**. What stays in assembly is only what needs raw
machine state: the `y_alloc` bump allocator, the trap stubs (div/0, OOB,
unwrap-of-none, OOM), dynamic record lookup (`y_dot_lookup`), the
byte-moving string cores (`y_str_eq/cmp/cat/join/slice`), `str`↔`[byte]`
conversion, the generic array cores (`y_arr_push`/`y_arr_prepend`/`y_arr_slice`/
`y_arr_eq` — one implementation each, parameterized by element width,
because Y has no generics), long and float formatting, and argv
materialization. Everything else —
the whole print/put/eput family, `trim`/`ord`/`chr`/
`tonum`/`index_of`/`split`, `range`, time, files — is Y. (`join` went
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
  `y_stdin_sync`, which is in the prelude trigger list, so splicing exec
  always pulls `std/prelude.y` in as well.

`ycc --no-exec` simply does not splice `std/exec.y`, so the call fails
with "undefined function 'exec'" and the binary has no path to a shell.

`rt.y`, `prelude.y`, `exec.y` and `str.y` are plain Y files, and the
compiler carries their text: native.y says `embed RT_SRC from
"./std/rt.y";` (see *Embedding files* below), the C copy
`Y_EMBED(RT_SRC, ...)`, because the shipped `ycc` is a standalone static
ELF — it cannot read a support file at run time. `rt.y` is spliced
always; the others only when the program mentions one of their names
(`prelude_names`/`exec_names`/`str_names` in native.y). One pass over the
program's text, `words_seen`, checks all three lists. It reads the text
the way the lexer does, skipping comments and the insides of string
literals, and counts whole words only (`executable` is not `exec`).
`str.y`'s names count only in method-call form, `.name(`, because that
is the only way to reach a helper-backed method. `std/str.y` holds those
methods (*String methods* above), and the `y_fmt_*` helpers behind
f-string specs: `words_seen` walks each f-string with the lexer's own
`fstr_walk`, scans its fields as code, and splices `str.y` when a field
has a spec. Even so, the scan over-approximates:
`r.count(x)` calling a record field splices `str.y` too. So `str.y` must
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
runtime helper by defining the same name later (the last def wins the bare
label); anything else starting with `y_` is on its own.

## Tree shaking

Nothing reaches the binary that the program does not reach itself:

- **bodies** — `prune_bodies` drops every function nothing calls, rooted at
  `_start` plus whatever the arch prelude references from Y (so a helper
  the prelude calls by label survives). An unused stdlib function costs
  nothing but its parse.
- **arch blocks** — `shake_refs` splits the arch prelude and the rodata
  constants into labelled blocks and keeps exactly the ones referenced from
  the surviving code or from another kept block (`call`, `lea`, a jump, or a
  computed immediate like `$ystr_end-ystr`, which names both), plus any
  block the previous kept block falls through into. Labels never merge
  blocks, so an internal loop label travels with its own references and dead
  code is dropped even mid-function.

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
`y_str_index` is still Y).

A hello world is 8 KB (8312 bytes, the page-aligned ELF) and under 100
asm lines: `_start`, `y_print_hstr` and `y_put_hstr` — not even the
allocator. `print(42)` adds `y_long_tostr` and `y_alloc` (232 lines); the
splitter, the file layer and the float formatter are not there because the
program does not use them.

The scanners walk a `bytes()` copy of the emitted text and materialize only
the symbols they reference; a per-character slice would cost an allocation
per character.

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

The file found is spliced exactly like `import x from "path"` and its defs
are flattened into one namespace with everything else (strip_ns rewrites
`net.listen_tcp` to `listen_tcp`). A def that replaces one from another
file is a compile error (`find_dup`, which knows each line's file from
the origin map `native_resolve_x` builds while splicing), so a module
picks names that will not collide with the other std modules —
`net.close_fd`, `net.send_str` — and uses the namespace when calling them
anyway. Modules are compile-time input only: the program that runs has
no use for the file.

`src/y/std/net.y` is the first optional module: TCP over raw sockets
(`socket_tcp`/`bind_tcp`/`listen_fd`/`accept_tcp`/`connect_tcp`/
`send_str`/`recv_str`/`local_port`) and a tiny HTTP server
(`http_response`, `http_read_head`, `http_serve_one`, `listen_http`), all Y
over `syscall`. A `ui` module would land the same way.

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

`-g` adds what the standard tools need to name code: section headers
(`.text`, `.rodata`, `.bss`) and a symbol table — an `STT_FUNC` per
function (user defs, the runtime's `y_*` helpers, `readline`, …), an
`STT_OBJECT` per global, `_start` the one global symbol. Names are the
source names (the rename pass's `yfn_<uid>_`/`yg_<uid>_` prefix and `$N`
suffix are stripped), so they line up across builds; a symbol's size runs
to the next symbol. It changes nothing that runs: the tables and headers
are appended past the loaded image, and the code, rodata and every address
are those of the plain build (`test/sh/test_debug.sh` checks it). One
difference is invisible to the program: valgrind reads an executable's
symbols only once it has seen a file-backed read+write mapping, so a `-g`
build takes the first 8 bytes of its `.bss` from zeros in the file. There
is no line information (DWARF) yet — tools name functions, not lines.

```
ycc -g -o prog prog.y
perf record ./prog && perf report      # sampled cpu, by function
valgrind --tool=callgrind ./prog       # exact instruction counts + call graph
callgrind_annotate callgrind.out.*     # (what bench/compare.sh tabulates)
valgrind --tool=massif --pages-as-heap=yes ./prog   # memory over time
gdb -ex 'break leaf' -ex run -ex bt ./prog          # breakpoints by name
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
The workflow for a performance-affecting change (propose → branch →
bench → decide) is in AGENTS.md; the details are in `bench/README.md`.

## Testing

`test/sh/test_native.sh` compiles `test/y/native/t*.y` and `e*.y`
straight to executables with the built `./ycc` (`ycc -o bin prog.y`, no
`-S`) and checks stdout/exit. `t*.y` assert behavior
(`.expected` stdout, `.exit` code, `.stdin` for input); `e*.y` assert rejection (first line
`// expect-error: <substring>` must appear in the compiler output). Native
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
- Division/modulo by zero, OOB indexing, unwrap-of-none, OOM each exit
  cleanly with a message + exit 1.
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
- `y_alloc` rounds every request up by 8–15 bytes, and when a request
  under 256 KB does not fit in the current 4 MB chunk the chunk's tail is
  abandoned (at most 256 KB, ~6%, per chunk).
