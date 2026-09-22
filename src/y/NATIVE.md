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

- `long`/`int` (same), `bool` (0/1), pointer `*T`, `str` (NUL-terminated bytes
  in `.rodata`, value = address), option `T?` (0 = none, else heap box):
  **every value is exactly 8 bytes** on the stack/in regs/on the heap.
- Locals live at fixed `rbp` offsets (one flat frame per function, 8 bytes/slot).
  Fixed arrays `[v; n]` reserve `n` slots (element `k` at base+8k).
- Heap (bump allocator over `brk`, stateless — no retained end pointer):
  dynamic arrays `[v, ...]` as `{len, cap, data...}` headers, option boxes.
  Nothing is ever freed (arena); no GC to write until something needs it.
- Expression values in `%rax`; operands that must survive nested evaluation are
  **pushed** (nothing live in caller-saved regs across a call).
- Y functions use a private convention: args pushed on the stack left to
  right, caller cleans up, result in `%rax`. The last-pushed arg sits at
  `rbp+16`, so param `k` of an `n`-arg function lives at
  `rbp+16+8*(n-1-k)` (arity-dependent by construction).
- No heap yet: maps/closures heap literals are **rejected** by types.y with a
  clear error. No GC to write until there is a heap.

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
- Fixed arrays are not first-class (no copies/aliasing/passing/returning —
  only element access, `len`, same-size refill, address-of). Heap arrays ARE
  first-class values (pointer copy): assign, pass, return, `push` (grows,
  rebind: `a = push(a, v)`). Indexing either kind is bounds-trapped (`y_oob`).
  Unwrap of `none` traps (`y_opt_unwrap`).
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

Now: `long`/`int`, `bool`, `str`, `*T`, `[T; N]`, `[T]`, `T?`, monomorphic
`def` (annotations **required** on params + returns in native mode; locals
inferred), captures rejected with positions, `if` cond must be `bool`,
branch types must match, `while` is `null`-typed, `str`→`*T` and
`none`-unification are the only implicit conversions. Error messages strip
rename's `$N` suffixes and carry line/col (LSP feeds on these).
Later: generics, records, borrow rules, exhaustiveness,
methods/traits if Y grows them.

## Self-hosting checklist (ycc compiling itself, then to fixed point)

Measured against what `src/y/*.y` actually use (counts are map-literal /
string-builtin occurrences): heap **maps** with string keys + dot access
(parser 86, types 131, native 81, rename 42, asm 48, enc64 97), heap
**strings** with concat/compare/slice (`substr` 105, `tostring` 93, `ord` 71,
`join`/`split`/`trim`/`index_of`/`tonum` everywhere), **closures** and
first-class functions (`mapx`/`filterx`/callbacks across all modules),
`for`/`foreach` loops, floats, and broader builtins. Each needs a memory
story (heap + GC or refcounts) and a lowering story (closure conversion,
defunctionalization) before `ycc -o ycc src/y/ycc.y` can work. The build still
uses cc ONLY to compile the reference-seeded `ycc` binary itself; every user
program is already cc-free.

## Testing

`test/sh/test_native.sh` compiles `test/y/native/*.y` → `.s` → binary via the
**real** `ycc -S` path and checks stdout/exit. `t*.y` assert behavior
(`.expected` stdout, `.exit` code, `.stdin` for input); `e*.y` assert rejection (first line
`// expect-error: <substring>` must appear in the compiler output). Native
programs must also keep passing if the C path ever learns the feature — one
behavior, two backends.

## Known native limitations

- Negating `LONG_MIN` traps (unsigned division edge in `y_print_long` and a
  potential `#DE` in `idiv`); everything else in long range is exact.
- Division/modulo by zero, OOB indexing, unwrap-of-none, OOM each exit
  cleanly with a message + exit 1.
- No floats, maps, heap strings/string-ops, closures, `for`/`foreach`
  (clear type errors — see the self-hosting checklist).
- `str` flows into `*T` positions but has no byte access yet.
- Arena heap: nothing is freed (no leaks that matter for short-lived
  binaries; long-running programs want the planned GC).
