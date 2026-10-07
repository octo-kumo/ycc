# AGENTS.md — y compiler

C (gnu99/gcc) + the Y compiler for `.y`. `src/y/` compiles straight to static
x86-64 ELFs — its own assembler and ELF writer, no cc/as/ld. `src/c/` is a
**1:1 C copy** of `src/y/` (`PORTING.md`): same modules, same functions, same
semantics. **Every change to `src/y/*.y` gets the same change in `src/c/*.c`.**

## Build

- `make` → `./cycc` (the C copy).
- `make ycc` → builds `./ycc` with `cycc`, attaches the std pack, then verifies
  `cmp ycc refs/ycc.ref` (byte-identical to the last blessed compiler, pack
  included) and that `./ycc` self-compiles to the same bytes. The gate.
- `make cycc.exe` → Windows cross-build (mingw-w64), gated by
  `test/sh/cycc-win.sh` under wine; `--target=windows` by `pe-gate.sh`,
  `pe-packinv.sh`, `pe-fixtures.sh`. The four `t34{1,2,3,4}_threads_*` and four
  `ELF-OUTPUT-DIFF` cases are known PE gaps, not regressions. A PE runs the NT
  syscall self-test at startup (`arch/wselftest.s`, from `w_self_test_lines`), so
  a drifted `w_sysno` fails loudly instead of calling the wrong Nt function.
- `make yserve` → the language server; both compilers must produce it
  byte-identically. `make lsp-ext` / `lsp-vsix` build the VS Code extension.
- `make ytest` → `./ytest` (`suites`, `coverage`, `report`). A measurement tool,
  not a gate.
- Never commit artifacts: `*.o`, `cycc`, `cycc.exe`, `cycc-asan`, `ycc`, `_ycc*`,
  `ynew`, `ytest*`, `*.pack`, `a.out`, `_check/`, `_ktmp/`. `refs/` is gitignored
  and is **not** disposable: it is the port's ground truth.
- Every `src/y/std/*.y` is embedded into the compiler when it is built (`embed`
  in native.y, `Y_EMBED` in native.c; `STD_EMBEDS` in the Makefile lists them so
  an edit forces a rebuild) — edit them directly; there is no generator, and
  `str.y` holds no string literals. A compile reads the source from disk when one
  is reachable (the checkout, a package root, `std/`) and falls back to the
  embedded copy otherwise, which is what makes a lone `ycc` self-contained.
- `src/y/arch/*.s` is embedded the same way, through `arch_x64.y`/`arch_x64.c`
  (PORTING.md rules 11–12). Whole-line `#` comments are dropped before the
  in-tree assembler sees them; `make asm-check` checks the files with GNU `as`.
- **Under 4 GB of memory, always** — the machine goes down past it. The Makefile
  runs recipes through `test/sh/capped.sh` (`ulimit -S -v 3670016`); by hand,
  `(ulimit -v 3670016; timeout … cmd)`, valgrind/gdb/perf included. Hitting the
  cap is a bug to fix, never a reason to raise it.
- ASan has its own cap (`make asan`, `make test-asan`,
  `ASAN_OPTIONS=hard_rss_limit_mb=3500`); programs a sanitized compiler emits
  still run under the normal one.

## Changing the compiler

1. Change `src/y`, port it to `src/c`, add fixtures and docs.
   `make fmt` formats `src/y`, `src/y/std` and `src/tools/lsp` **in place** with
   the editor's formatter (`src/tools/lsp/fmt.y`, LSP.md R3); `make fmt-check` is
   the gate — **idempotence** over the tree (0 non-idempotent) plus a `src/y`
   fixed-point count that is a signal, not a gate (currently 27/38 files
   byte-identical; the rest is the formatter's deliberate author-layout policy,
   LSP.md R3.6, so run `make fmt` only when the reformatting is wanted). A buffer
   the scanner cannot lex is skipped, never mangled. `src/c` is not formatted: it
   is a Y formatter.
2. `make check` (~90 s) — builds `./ynew` from `src/y` with the blessed compiler
   (generations 2 and 3 byte-identical), requires `cycc` to build it byte for
   byte, runs every suite with it as the reference, then compares with `BASE`
   (`refs/ycc.ref`): programs that compile or behave differently, benchmark
   instruction counts, and the SCORE. **Read every difference it lists.**
3. `make rebless` — builds with `cycc`, checks the fixpoint and the port gate,
   installs it as `refs/ycc.ref` (+ `./ycc`, `refs/SHA256SUMS`). Commit with the
   numbers.

Standalone: `make ynew`, `make port-check` (failures only), `make corpus-diff`
(`FILES="a.y b.y"` narrows it), `make bench`, `make bench-ir`. Measured on 8
cores: `make cycc` 5.5 s, `make rebless` 18.5 s, the full suite run ~47 s,
`make check` ~90 s — the compare and bench phases are the slow part, not the bless.

**Performance.** Anything that can move compile time, output size or program
speed gets `make check`'s numbers plus `make bench` in the commit message. A
SCORE within 100 ± 2.5 is no change; instruction counts are exact. Explain what
moved with the callgrind table, `perf`, or `ycc --time`.

## Run / verify

- `./ycc f.y -o /tmp/b && /tmp/b`; the same through `./cycc`; `./ycc -S f.y`.
- `--gc=auto|always|never` (default `auto`): whether the collector is linked.
  Auto omits it when no loop or recursion can reach the allocator, so a program
  that allocates once carries neither; `always` is the escape hatch and
  `--no-gc` is `--gc=never`. `--gc-stress` runs a cycle at *every* allocating
  slow path — the collector's own test (a missed root shows up as a crash in
  minutes, not days), used by the `gc` suite, and a very slow build.
- `ycc run f.y` compiles and runs in one step; `ycc -E f.y` dumps the source the
  pass saw (meta blocks expanded); `ycc build` / `ycc vendor` for `y.toml`
  projects.
- `./ycc --time f.y` prints a phase table to stderr. Builtins: `clock_us()`,
  `heap_used()`, `eputs(v)`.
- `-g` adds symbols, DWARF and section headers (code unchanged), so `perf`,
  `valgrind --tool=callgrind`, `gdb` (`break file.y:N`, no variables), `nm` and
  `addr2line` name things.
- Always feed `</dev/null` in scripts.
- **A built `ycc` is self-contained.** Every std source is embedded in the
  compiler (native.y `embed`, the C copy's `Y_EMBED`) and the four core runtime
  units travel precompiled in the std pack attached to the binary, so a copy in
  an empty directory compiles `import fs`/`net`/`args`-style programs. Resolution
  still prefers `src/y/std/` when it is there (that is how a std unit is edited
  and tested); the embedded text is the fallback when no source is on disk.
  The embedding costs ~540 KB of compiler binary and `STD_EMBEDS` in the
  Makefile lists every std source so a rebuild picks up an edit.
- Branches and worktrees: `master`, plus `mem-lifetime` (`.worktrees/mem`),
  `kernel` (`.worktrees/kernel`) and `bigint-math` (`../compiler-bigint`). Merge
  forward into `master`; never rewrite a branch another worktree has checked out.

## Tests

`make test` runs all 22 suites (`test/sh/run_all.sh`; `-j N`, `YSHARD=k/n`,
`./run_all.sh -j4 port native` for a subset). They take `CYCC`, `YREF`, `YCC`,
`YSELF`, `YQUIET` and `YPORT_SELF` from the environment.

| suite | what it pins |
|---|---|
| port | every `test/y/**.y` compiles to identical bytes under `cycc` and the reference, with the same warnings |
| pe-port | the same for `--target=windows`, with and without `-g` |
| native | `test/y/native/t*` (stdout, exit, warning markers) and `e*` (rejection messages) |
| native-examples | every `test/y/examples/*.y` the built compiler accepts prints what the reference prints |
| examples, audit, loops, comprehensive | the regression corpora and the inline edge cases |
| ycc-units, ycc | `test/y/ycc/*`; one-liners, warnings, driver failures |
| fixpoint | three self-compiles byte-identical; `src/y` and `src/y/std` warning-free |
| debug, link, pkg | `-g` output; the std pack; `ycc build`/`vendor` over real projects |
| stdin-eof, net | stdin/EOF; loopback HTTP/TCP, DNS and TLS |
| lsp | the server's fixtures under both compilers, `check-refs.py`, `check-names.py`, formatter idempotence |
| math | `test/math/ulp_table.txt` within 1 ulp, plus the kernel and threshold audits |
| coverage | every diagnostic and manual section has a checked test (`test/COVERAGE.md`) |
| gc | the collector under a cap: two threads of 300k allocations must run in 64 MiB (`test/y/native/t385_gc_threads_alloc.y`), with `--gc=never` as the control that does not fit, and two threads of 20k under `--gc-stress` (a cycle at every allocation, `test/y/native/t389_gc_stress_threads.y`) |
| treeshake, std-suites | the unused-code cost ratchets, plus four checks a runtime addition must pass: a program that allocates nothing names no `y_alloc` and no collector block, `--gc=auto` omits the collector for a one-shot allocation while `always` keeps and `never` drops it (same output), `test/sh/deadcode.py` counts instructions the shake leaves unreachable (`test/treeshake/deadcode.txt`), and `test/treeshake/shapes.txt` records the size of the shapes a runtime change moves first; the `test/std/` self-test suites |

Run by hand (not in `make test`): `test/sh/cycc-win.sh` (wine),
`test/sh/w_sysno.py`, `test/sh/run-parity.sh` (`ycc run` == compile + execute),
`test/sh/mem-meta.sh`, `./ytest`, `make lsp-e2e`.

Fuzzing (`test/fuzz/fuzz.sh [ITER] [SEED]`): mutates corpus programs and compiles
each with both compilers under the cap and a timeout; a crash or a divergence is
saved with its input. Run it after touching the lexer, parser, checker or
emitter, and turn each finding into a `test/y/native/e*.y` fixture. Malformed
input gets an error at the offending token — never a crash, never silent
acceptance.

## Pipeline

Splice imports, pick the std units → per unit: strip namespaces (`strip_ns`,
`strip_type`) → rename → typecheck → lint (warnings to stderr; the program's unit
and its packages, never a std unit) → hoist → emit bodies → link and tree-shake
the units into one `.s` → `asm.y` assembles → `elf.y` writes the ELF (`-g`:
`dwarf.y`'s line table). `y_` is a **reserved prefix**: such a def is emitted
under its bare name because generated code calls it by label, and a program's own
`y_` def replaces the std one at link time.

## Y code style (hard rules)

- An **empty block is legal** and void — `{ }`, no `0;` filler. A block's value
  is its last statement **without** a `;`: `{ f() }` is `f`'s value, `{ f(); }` is
  void. `if` arms need not agree: disagreeing arms make the `if` void.
- Postfix binds tighter than unary: `!x.y` is `!(x.y)`, `x.y[i]` is `(x.y)[i]`.
  `&&`/`||` short-circuit and take any non-zero value as true.
- Recursion is `self`, never the function's own name.
- `#{ … }#` is a **meta block**: compiled and *run* at compile time, its output
  spliced in its place. Top level only; the generator runs in a forked child, so
  a trap in a block is a diagnostic rather than a dead compiler. In a file with a
  block, a top-level statement must be a declaration.
- `ndef f(params) -> T [= "label"];` declares a bodyless def implemented by an
  assembly label (`y_` prefix, top level, return type written).
- A nested `def` captures the bindings already in scope where it is written;
  captures are shared with the enclosing scope. Avoid **new** closures in
  `src/y`: the C value model has no function value. Top-level variables are
  globals, never captures.
- Arrays, maps and records are **references**; strings and numbers are immutable
  (`s += t` may append in place only into a buffer nothing else can see).
- Arrays are **homogeneous**. Records are **exact**: a record type is its fields,
  and a record goes only where its own type — or a union holding it — is expected.
- **No unknown types**: every parameter is annotated or has a literal default;
  `[]`/`none` take their type from the annotation or the context; a forward-called
  def has its return type written. A union field other than the shared ones is
  read after a cast (`let c: Call = node;`, or a `match` binding); a cast copies
  when the layouts differ, so never write through one expecting the union to
  change.
- **No warnings** in `src/y` or `src/y/std` (`test_fixpoint.sh`). An unused
  parameter is fine, an unused local is not. A record or union type used in more
  than one place gets a `type` alias in the module that owns it.
- `/** … */` is a **doc comment**: the scanner marks it and the server shows the
  comment above a declaration in hover. Keep it short, and keep `//` shorter.

## Arrays and pointers

- `a + b` → a NEW array (the operands untouched). `arr + elem` / `elem + arr` → a
  new array with one element. `arr += v` → in place: an array of `arr`'s element
  type appends wholesale, anything else pushes one element. `arr *= v` → prepends
  one element, in place. `a = b` → both names alias one array.
- `arr.length` (also `str.length`) is `len(arr)`; `arr.ptr` is a `*T` to the first
  element (arrays only — string bytes may live in `.rodata`).
- `s.m(args)` on a `str` is a string method: one table, `str_method` in `types.y`,
  feeds the checker and the emitter. Method names are not reserved words.
- `const x = v` fixes the value as well as the binding: every store through a
  place, `op=`, `++`/`--` and in-place `+=`/`*=` on a const array are type errors.
  A pointer still launders it (`&a[0]`, `*p = 1`) — the checker does not follow.
- A **fixed** `[T; N]` cannot grow: `+=`/`*=` on it is a type error.
- `x++`, `++x`, `x--`, `--x` and `x op= e` evaluate the target's subexpressions
  exactly once.
- `& | ^ ~ << >> >>>` take integers and bind tighter than comparisons
  (`x & 1 == 0` is `(x & 1) == 0`). `>>` is arithmetic, `>>>` logical; a count of
  64 or more shifts every bit out, a negative count traps.
- Pointers: `&x`, `*p`, `p + n` / `n + p`, and `p - q` for identical pointer
  types. Only `+=`/`-=` take offsets (`*p *= n` is an error), and `*long + *long`
  is not an expression.

## Layout

- `src/y/` — the compiler: `ycc.y` (driver), `pkg.y` (`ycc build`), `lexer.y`,
  `parser.y`, `rename.y`, `types.y` (checker), `lint.y` (warnings and `--fix`),
  `native.y` (emitter), `meta.y`, `arch_x64.y`, `enc64.y`, `asm.y`, `elf.y`,
  `pe.y`, `dwarf.y`, `target.y`, `tags.y`; `std/` (the four embedded units, plus
  `fs`, `net`, `struct`, `math`, `crypto`, `x509`, `tls`, `regex`, `json`,
  `args`, `tui`, `utf8`, … — all of them embedded, see Build); `arch/*.s`.
- `src/c/` — the 1:1 copy, plus `yv.c`/`yv.h` (the value model; no Y twin).
  `PORTING.md` is the contract.
- `src/tools/lsp/` — `yserve` and its modules (`LSP.md` is the design; the VS Code
  extension is under `vscode-y-lang/`) with `test/` (fixtures, harnesses, node
  drivers, and two measurement programs, `scope-coverage.y` and
  `request-cost.y`). Syntax highlighting is the **TextMate grammar** the extension
  ships; the server does diagnostics, hover, definition, completion and
  formatting. `check-names.py` also tests each module's basename, because
  `strip_ns` rewrites any `name.field` program-wide as a module reference.
- `src/tools/ytest/` — the suite timer and gcov coverage reporter.
- `refs/` — reference binaries for the port gate. `test/` — `sh/` drivers, `y/`
  fixtures (`native/`, `audit/`, `examples/`, `ycc/`, `net/`), `std/`, `math/`,
  `fuzz/` and `COVERAGE.md`. `bench/` — benchmarks and the compare/profile
  scripts. `docs/` — the manual (`make docs`). `ideas/` — designs not yet built.

## Native backend

Unboxed 8-byte values (`long`/`int`/`byte`/`bool`/`float`/`ptr`/`str`/option/
function); `[byte]` arrays are packed. Stable heap headers `{len, cap, data,
front}` with capacity doubling at the back for `+=` and room reserved in front for
`*=`, so both are amortized O(1); `s += t` on an owned `str` likewise. Closures
are `[code, caps…]` records; records are laid out by field name (a union member:
the shared fields first) with a pointer to their type descriptor before the
fields. `for`/`for..in`/`foreach`/`while` with `break`/`continue` (a jump out of a
`def` nested in a loop is refused by the checker); block expressions; `type`
aliases, record unions and `match`. Threads (`spawn`/`join`, `mutex`/`lock`,
`sem`) are `clone(2)`s with a heap of their own; processes are `fork`/`wait_pid`;
every exit is `exit_group`. `ycc` is native-only — no cc/as/ld at run time — and
the shipped binary is a static ELF carrying its std pack.
