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
| `src/y/arch_x64.y` | x86_64 behind the arch interface: `arch_id/word/sysno`, `arch_fn_label/loc_label/str_label`, `arch_header/rodata/text`, `arch_prelude` (print_long/bool/cstr, div_zero), `arch_consts`, `arch_frame` (16-align), `arch_exit` |
| `src/y/native.y` | pipeline driver: `native_resolve` (splice imports) → strip namespaces → rename → check → hoist → frame layout → arch emit |
| `src/y/rename.y` | uniquify pass: every binding gets `name$N`, killing scopes/shadowing downstream |
| `src/y/enc64.y` | x86_64 instruction encoding for exactly the forms we emit |
| `src/y/asm.y` | two-pass assembler over our asm dialect (+ octal payload writer) |
| `src/y/elf.y` | minimal ELF64 writer: one PT_LOAD (R+E), static, entry `_start` |
| `src/y/std/` | standard library **in Y**: `io.y` (file I/O over raw syscalls), later `str.y`, `mem.y` |

New Y files must stay in the **portable subset** (no pointer syntax in their
own code): they are parsed by the C compiler's `parser.c` and compiled by the
C backend during the bootstrap.

## Data representation

- `long`/`int` (same), `byte` (8-bit unsigned), `bool` (0/1), `float`
  (IEEE754 double bits), pointer `*T`, `str` (NUL-terminated bytes in
  `.rodata`, value = address), option `T?` (0 = none, else heap box),
  function values (address of a closure record): **every value is exactly 8
  bytes** on the stack/in regs/on the heap.
- **`[byte]` arrays are packed**: one byte per element, not eight. Every
  element lives at `base + 16 + i*esz`, and `esz` comes from the static
  element type — so the scale factor, the allocation size and the load/store
  width follow from the type alone (`movzbq`/`movb` instead of `mov`).
  `y_arr_push`/`y_arr_slice`/`y_arr_eq` take `esz` as an argument, so one
  implementation serves both layouts. 100k elements cost 256 KB packed
  versus 2 MB unpacked. `bytes(s)` and `from_bytes(b)` convert to and from
  `str`; a `byte` widens to `long` in arithmetic, and a `long` narrows to
  `byte` at annotated sites (there is no cast syntax).
- Locals live at fixed `rbp` offsets (one flat frame per function, 8 bytes/slot).
  Arrays — fixed `[v; n]` and dynamic `[v, ...]` alike — are **heap headers**
  `{len, cap, data...}`; a local holds the header address, so `[T; N]` is as
  first-class as `[T]` (it can be bound, passed, returned; only `push` is
  rejected, since `N` is part of the type).
- **Arrays and records are reference values**: a binding stores the address,
  never a copy. `let b = a`, passing, returning and storing all share, and
  `a[i] = v` / `s.f = v` are observable through every alias. The VM and the
  compiled C runtime use the same model. (Copy-on-store used to emulate value
  semantics here; it made every helper that returned an accumulator O(n), so
  the assembler was O(n²) and self-compilation OOMed past 7.5 GB.)
- Heap (bump allocator over `brk`, stateless — no retained end pointer):
  dynamic arrays `[v, ...]` as `{len, cap, data...}` headers, option boxes.
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
  the enclosing environment knows each captured name's type.
- Maps with dynamic string keys are still **rejected** by types.y with a
  clear error.

## Pipeline (now → later)

```
source → lexer → parser (+types) → splice imports → strip namespaces
  → rename (uniquify) → types.y (static check, ERRORS ARE FATAL)
  → [later: ANF/CPS] → [later: closure conversion, defunctionalization]
  → frame layout → arch emit → asm.y (assemble) → elf.y → executable
```

- **Now**: direct AST→asm (stack machine + heap values), top-level `def` only, nested
  capture-free `def` is hoisted (baby lambda lifting), captures are a type error.
  No scopes/shadowing downstream of rename (flat envs + function-depth counter).
- **Next**: ANF lowering (explicit eval order), closure conversion
  (closures = code pointer + env), defunctionalization, register allocation,
  TCO, heap maps/strings, GC (only when something must free).
- Semantics disputes between the Y and C implementations are resolved toward
  "what would a reasonable scoped functional language do" (TypeScript/Rust
  intuition): lexical scope, `self` for recursion, no implicit coercions
  (except `str`→`*T` and `none` unification), exhaustiveness where cheap.

## Output: our own executables

`ycc -o prog prog.y` writes a static ELF64 directly: `enc64.y` encodes each
emitted instruction (fixed-size near jumps/calls, so lengths are known in
pass 1), `asm.y` assembles (two passes + fixups + rodata), `elf.y` wraps one
PT_LOAD (R+E) with entry `_start`. Verified byte-for-byte behaviorally against
binutils-built binaries for the whole corpus. Bytes leave Y as octal escapes
through `exec printf` (Y strings cannot carry NUL via `write_file`) + chmod;
at self-hosting this becomes a raw `write` syscall. No cc/as/ld involved.

## Pointers, stack arrays, heap arrays, options

- Syntax: `&x` address-of a local/param/fixed-array, `&a[i]` element address,
  `*p` load, `*p = v` store, `a[i]` / `a[i] = v`, `len(a)`,
  `let buf = [v; n]` (n stack slots), `[v, ...]` (heap), `[T; N]` / `[T]` types,
  `T?` option types (`int` is `long`), `some(v)` / `none` / `is_some` / `unwrap`.
- Types: `*T`, `[T; N]`, `[T]`, `T?`. `&x : *T`, `&a : *T` (fixed) / `&a[i] : *T`.
  `str` flows into `*T`; `none` unifies with any `T?`.
- Fixed and heap arrays are both first-class reference values: assign, pass,
  return, alias. The difference is only the type: `[T; N]` carries its length
  statically and rejects `push` (growing it would break the type), while `[T]`
  grows via `push` (rebind: `a = push(a, v)`, since growing may move it).
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
- `src/y/std/io.y` wraps raw numbers (`write`, `exit`, `openat`, `read`,
  `close`): file I/O with zero C code (`test/y/native/t12_cat.y` is a pure-Y
  cat; `t10_filewrite.y` creates/writes files). C builtins get gutted as Y-side
  replacements land; each removal must keep `make test` green on the C path
  until the native path owns that feature.

## Type system (types.y) — the law, expanded over time

Now: `long`/`int`, `bool`, `float`, `str`, `*T`, `[T; N]`, `[T]`, `T?`,
function types `(A, B) -> R`, monomorphic `def` (annotations **required** on
params in native mode; return types and locals inferred), captures resolved
into closures, `if` cond must be `bool`, branch types must match, `while` is
`null`-typed, `str`→`*T`, `long`→`float` and `none`-unification are the only
implicit conversions. Error messages strip rename's `$N` suffixes and carry
line/col (LSP feeds on these).
Later: generics, records, borrow rules, exhaustiveness,
methods/traits if Y grows them.

## Self-hosting: done

`ycc` compiles its own source to a byte-identical binary. The chain is
`yboot → cycc → ycc → _ycc` with `cmp ycc _ycc` as the gate (`make ycc`), and
`test/sh/test_fixpoint.sh` re-checks it from an already-built `./ycc`,
including a third generation and a smoke compile with the self-built binary.

Measured on the self-compile (`ycc --time -o ycc src/y/ycc.y`):
427 KB of spliced source, 93 K tokens, 1.89 MB of assembly, a 492 KB static
ELF, in ~2.5 s and ~365 MB of arena.

What made it possible was not new features but removing copies: arrays and
records became reference values in all three engines (copy-on-store made the
assembler O(n²) — 651 MB to build a 20 KB binary — and self-compilation OOMed
past 7.5 GB), and the output writer stopped issuing one `write` syscall per
byte.

Still missing for a *comfortable* self-host (the compiler works around each
today): heap maps with dynamic string keys, and record spread. Records with
static shapes cover what `src/y/*.y` needs; closures, first-class functions,
`for`/`foreach`, block expressions and floats have all landed since.

## Runtime library: Y, not assembly

`src/y/std/prelude.y` holds runtime code written **in Y**, spliced ahead of
the program by `native_resolve` when the program mentions one of its names
(a textual check, so an unused prelude costs nothing — there is no
dead-code pass). These are ordinary defs: they go through rename,
typecheck and emit like any user function, so a bug in them is a bug in Y
code rather than in hand-rolled x86.

The rule is that `arch_x64.y` provides small, general **primitives** and
the prelude provides **behaviour**. Two worked examples:

- `readline()` — the backend contributes only the `syscall` intrinsic and
  `bytes`/`from_bytes`; stopping at the newline, growing the buffer and
  handling EOF are twenty lines of Y. It replaced ~90 lines of assembly.
- `exec(cmd)` — `fork`/`execve`/`wait4` through `syscall`, with the
  `char**` argv built out of `[byte]` buffers and `ptr_addr` (the one
  primitive that lets a pointer's value cross into `long`). No new
  assembly at all.

`ycc --no-exec` simply does not splice the exec chunk, so the call fails
with "undefined function 'exec'" and the binary has no path to a shell.

The prelude text lives as a line array inside `prelude.y` because the
shipped `ycc` is a standalone static ELF — it cannot read a support file at
run time.

## Testing

`test/sh/test_native.sh` compiles `test/y/native/*.y` → `.s` → binary via the
**real** `ycc -S` path and checks stdout/exit. `t*.y` assert behavior
(`.expected` stdout, `.exit` code, `.stdin` for input); `e*.y` assert rejection (first line
`// expect-error: <substring>` must appear in the compiler output). Native
programs must also keep passing if the C path ever learns the feature — one
behavior, two backends.

`test/sh/test_native_examples.sh` is the ratchet on the example corpus:
every `test/y/examples/*.y` the native compiler accepts must print what the
VM prints. Examples it cannot take yet live in the script's `UNSUPPORTED`
map with a reason each, and the suite fails as soon as one of them starts
compiling — so the list can only shrink.

## Known native limitations

- Division and modulo are exact across the whole long range, including
  `LONG_MIN / -1` and `LONG_MIN % -1` (`idiv` raises `#DE` on that pair, so
  divisor `-1` is compiled as a negation / a constant zero instead).
  Negating `LONG_MIN` still wraps to `LONG_MIN`, as it does in the VM.
- Division/modulo by zero, OOB indexing, unwrap-of-none, OOM each exit
  cleanly with a message + exit 1.
- No heap maps with dynamic keys, and no record spread (clear type errors).
  Records, heap strings and the string builtins
  (`substr`/`join`/`split`/`tostring`/`ord`/…) are supported — the compiler
  itself relies on them.
- `float` is IEEE754 double, held in `%rax` as raw bits and moved through
  `%xmm` only for arithmetic and comparison, so slots and the calling
  convention are unchanged. Literals (including scientific notation) are
  built at run time as `mantissa × 10^n` with `cvtsi2sd` — IEEE arithmetic
  is correctly rounded, so the compiler needs no float parser. Printing is
  fixed 6-decimal, matching the VM's `%f`, but only for magnitudes below
  2^63: `cvttsd2si` cannot take anything larger, and reproducing printf's
  exact expansion needs bignum arithmetic, so those print
  `<float magnitude >2^63>` rather than noise.
- `str` supports `<`, `>`, `<=`, `>=` (lexicographic, via `y_str_cmp`
  returning the sign), matching `strcmp` in the VM and the C runtime.
- **Embedded NUL bytes are a known engine divergence.** A native `str` is
  length-prefixed (`{len, data..., NUL}`), so `from_bytes([65, 0, 66])` is a
  3-byte string and `bytes()` returns all three. The VM's `str` is a C
  `char *`, so the same value truncates to 1 byte there. NUL-free data — all
  text — round-trips identically in both. Binary data only survives
  natively; do not build a test that asserts parity on it.
- `str` flows into `*T` positions but has no byte access yet.
- **`push` may move the array.** The header and its elements live in one
  block (`{len, cap, data...}`), so growing past `cap` allocates a new
  block: other bindings keep pointing at the old one. The C runtime keeps a
  stable header with separately allocated data, so there growth is
  invisible to aliases. Always rebind — `a = push(a, v)` — and never rely
  on an alias taken before a `push`. (A `{len, cap, dataptr}` header would
  close the gap at the cost of one extra load per element access.)
- Arena heap: nothing is freed (no leaks that matter for short-lived
  binaries; long-running programs want the planned GC).
- `y_alloc` issues two `brk` syscalls per allocation (no writable segment to
  cache the break in), and rounds every request up by 8–15 bytes.
