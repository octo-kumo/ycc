# AGENTS.md — y compiler

C (gnu99/gcc) + the Y compiler for the `.y` language. The Y compiler in
`src/y/` compiles `.y` straight to static x86-64 ELFs (its own assembler
and ELF writer — no cc/as/ld). The C compiler in `src/c/` is a **1:1
copy of the Y code** (see `PORTING.md`): same modules, same functions,
same semantics.

## Build

- `make` → builds `./cycc`, the C copy of the compiler.
- `make ycc` → builds `./ycc` with `cycc`, then **verifies**:
  - `cmp ycc refs/ycc.ref` — the C copy's output is byte-identical to
    the reference `ycc` binary (the acceptance gate for the port), and
  - `./ycc` self-compiles byte-identically (fixpoint).
  `refs/` holds the backed-up reference binaries (gitignored; see
  `refs/SHA256SUMS`).
- Do not commit build artifacts: `*.o`, `cycc`, `cycc-asan`, `ycc`,
  `_ycc`, `a.out` (all gitignored; `make clean` removes them). `refs/` is
  gitignored too but is **not** disposable — it is the port's ground
  truth.
- The runtime the compiler splices into programs is plain Y in
  `src/y/std/rt.y`, `prelude.y`, `exec.y`, `str.y`, embedded into both
  compilers when they are built (`embed` in native.y, `Y_EMBED` in
  native.c — PORTING.md rule 10). Edit those files directly; there is no
  generator. `str.y` must not contain string literals (see NATIVE.md,
  "Runtime library").
- `make asan` builds `./cycc-asan` (ASan+UBSan); `make test-asan
  SUITES_ASAN="..."` runs suites against it (`CYCC`/`YCC` overridable).
  Do NOT put a `ulimit -v` on sanitized runs — ASan reserves terabytes
  of *virtual* address space. The programs a sanitized compiler emits
  still run capped (`run_bin` in `test/sh/lib.sh`, `YPROG_MEM_KB`), so a
  test that must see an allocation fail still does.
- When changing `src/y/*.y`: the C copy (`src/c/`) must get the same
  change (it is a 1:1 copy — see PORTING.md), then `make ycc` must stay
  byte-identical, and `make test` green.

## Run / verify (use these exact forms)

- Compile + run: `./ycc file.y -o /tmp/t_bin && /tmp/t_bin`
- Same through the C copy: `./cycc file.y -o /tmp/t_bin && /tmp/t_bin`
- Assembly only: `./ycc -S file.y > /tmp/t.s`
- `make test` runs everything: the port gate + all `test/sh/*.sh`
  suites. `./test/sh/run_all.sh [suite ...]` runs a subset.
- `make test-compile` — tiny smoke test (both compilers, one example).
- Compiler profiling: `./ycc --time file.y` prints a per-phase table
  (elapsed ms + heap KB + counters) to **stderr**. It still needs an
  input file — `ycc` with no FILE is the error `no input file`. Y-level
  builtins: `clock_us()`, `heap_used()`, `eputs(v)`.
- Program profiling/debugging: `./ycc -g` adds a symbol table and
  section headers (code and addresses unchanged), so the standard tools
  name functions: `perf record`/`report` (on WSL run
  `/usr/lib/linux-tools/*/perf` directly — the `/usr/bin/perf` wrapper
  refuses the kernel), `valgrind --tool=callgrind` + `callgrind_annotate`
  (exact instruction counts), `valgrind --tool=massif
  --pages-as-heap=yes` (the heap is `mmap`ed, not `malloc`), `gdb`
  (`break fn`, `bt`), `nm`/`addr2line`, `strace -c`. No line info yet.
- Always feed `</dev/null` in scripts (some programs read stdin).

## Test suites (`test/sh/`)

Fourteen suites, run by `test/sh/run_all.sh` (named below in brackets). Most
compile each program with **both** compilers — the reference side is
`refs/ycc.ref` — and require the outputs to agree (byte-identical
binaries, identical program behavior). `test_native.sh`,
`test_native_examples.sh`, `test_debug.sh`, `test_ycc.sh` and
`test_fixpoint.sh` drive the built `./ycc` itself, so `run_all.sh` skips
those **five** when it is missing (`make test-fast`).

- `test_port.sh` [port] — the port gate: every `test/y/**.y` (plus
  `src/y/ycc.y` itself) compile to byte-identical binaries with
  `cycc` and the reference `ycc`; a program both reject must get the
  same diagnostics from both.
- `test_native.sh` [native] — `test/y/native/*.y`: `t*` assert
  stdout/exit (`.expected`/`.exit`, stdin from `.stdin`), `e*` assert
  rejection: the output must contain every `// expect-error:` line of
  the file (at least one; the checker reports all errors at once).
- `test_native_examples.sh` [native-examples] — the ratchet: every
  `test/y/examples/*.y` the built `./ycc` accepts must print what the
  reference prints; its `UNSUPPORTED` list (currently empty) may only
  shrink.
- `test_comprehensive.sh`, `test_loops.sh` — inline regression cases:
  builtins, operators, functions, void/options, errors, loops,
  precedence.
- `test_examples.sh` — every `test/y/examples/*.y` runs and both
  compilers agree.
- `test_audit.sh` — all `test/y/audit/t*.y` edge cases; both compilers
  must agree exactly.
- `test_ycc_units.sh` [ycc-units] — every `test/y/ycc/test_*.y` must
  compile and run (two legacy snapshots are skiplisted with reasons).
- `test_ycc.sh` [ycc] — a few one-liners compiled by `./ycc` and
  compared with the reference's output, plus the driver's failures
  (bad flags and paths, failed writes, import depth): both compilers
  print the same message and exit 1.
- `test_fixpoint.sh` — three generations of self-compilation are
  byte-identical and the self-built binary still compiles working
  programs.
- `test_debug.sh` [debug] — `ycc -g`: both compilers emit identical
  `-g` binaries, the program runs the same, code and rodata match the
  plain build, and readelf/nm/addr2line (gdb and callgrind when
  installed) see the functions and globals by name.
- `test_stdin_eof.sh` — stdin/EOF behavior.
- `test_net.sh` [net] — the blocking `std/net` listeners over loopback:
  `test/y/net/` servers built by both compilers (identical binaries)
  answer real HTTP/TCP clients and exit cleanly, and one serves 100
  connections under `ulimit -n 32` (no fd leak per connection).
- `test_coverage.sh` [coverage] — static, compiles nothing: every
  diagnostic the compiler can print has its message in a test
  expectation, every builtin in the manual is called by a checked test,
  every keyword appears in a `t*.y`, and `test/COVERAGE.md` maps every
  manual section to the checked tests that exercise it. Unreachable
  diagnostics are listed there with a reason; a stale excuse fails the
  suite. New diagnostic → new `e*.y` marker; new manual section → new
  row.

### Fuzzing (`test/fuzz/`, not part of `make test`)

`test/fuzz/fuzz.sh [ITER] [SEED]` mutates corpus programs (`mutate.y`:
delete, duplicate or truncate a span, splice in a span of another
program, insert a token, a hostile literal, a stray byte or a run of
nesting) and compiles each with `./ycc` and `./cycc` under a memory cap
and a timeout. A
*crash* (signal, timeout, `runtime error:` trap, `INTERNAL`) or a
*divergence* (exit code, messages or binary differ) is saved once per
distinct message under `$FUZZ_OUT` (default `/tmp/yfuzz`) with the input
and both outputs; exit 0 means nothing was found. Run it after touching
the lexer, parser, checker or emitter (`YCC`, `CYCC`, `FUZZ_MEM_KB`,
`FUZZ_TIMEOUT` override), and turn every fixed finding into a
`test/y/native/e*.y` fixture. Malformed input must get an error at the
offending token — never a crash, never silent acceptance (the parser
plants `err` nodes; see the "malformed input" helpers in `parser.y`).

## Performance: bench before merging (mandatory workflow)

Anything that can move compile time, output size, or the speed of
compiled programs is **proposed, benchmarked on a branch, then
decided**. Never merge one on taste:

1. **Propose**: say what the change should move.
2. **Branch**: `git switch -c bench/whatever`.
3. **Build both sides**: `make ycc` on master, `cp ycc /tmp/ycc-base`,
   then `make ycc` on the branch and `cp ycc /tmp/ycc-new`.
4. **Bench**: `bench/compare.sh /tmp/ycc-base /tmp/ycc-new` — scores the
   two builds (100 = unchanged) over compile time, run time and binary
   size (asm bytes/lines are shown per benchmark but not scored); then
   callgrind instruction counts
   per function (`-g` builds, needs valgrind). Keep both binaries on the
   same filesystem: under WSL a
   binary run from `/mnt/c` pages in through drvfs and measured ~30%
   slower in every phase, which is easy to mistake for a regression.
5. **Decide**: merge or revert from the numbers; put the numbers in the
   commit message. A deliberate trade is fine — an unnoticed one is not.

`bench/y/*.y` are benchmarks, **not tests**. The callgrind table (or
`perf` on a `ycc -g` build) shows which functions moved — use it to
explain a regression, not just to spot it. Times are noisy at the
few-percent level (`bench/compare.sh ... 9` takes more samples);
instruction counts are exact.

## Pipeline (`src/y/native.y`)

splice imports + std modules → strip namespaces → rename (uniquify) →
typecheck (static, errors fatal) → hoist → tree shake → emit `.s` →
`asm.y` assembles → `elf.y` writes a static ELF. `y_` is a **reserved
prefix**: such a def is emitted under its bare name because generated
code calls it by fixed label.

## Y code style (hard rules — keep the two copies in sync)

`src/y/*.y` is compiled by the Y toolchain **and** ported 1:1 to
`src/c/`, so its habits matter:

- An **empty block is legal** and void — `{ }` needs no `0;` filler (the
  void redesign made the fillers optional; leftover ones are harmless).
- A block's value is its last statement **without** a trailing `;`:
  `{ f() }` is f's value, `{ f(); }` is void (a trailing `return x;` keeps
  its value). `if` arms do **not** have to agree in type any more:
  disagreeing arms simply make the `if` void (`types.y`, the "VOID law").
- Postfix binds tighter than unary: `!x.y` is `!(x.y)`, `x.y[i]` is
  `(x.y)[i]`. Dot chains and index chains parse correctly.
- `&&` / `||` short-circuit, in both forms. Operands need not be `bool` —
  any non-zero value is true (`typeof_logic` in `types.y`).
- Recursion uses `self`, not the function's own name.
- A nested `def` captures the enclosing bindings **that are already in
  scope where it is written** (a name declared later is an
  undefined-variable error — `let`s do not hoist, `rename.y`). Captures
  are **shared**: a write inside the closure is visible outside and the
  other way round — the variable lives in one heap cell from its binding
  on, so a `for x in a..b` / `foreach` variable is fresh per iteration
  while one declared before a loop is shared by all of the loop's
  closures. Top-level variables are globals (`.bss` cells), never
  captures. Avoid *new* closures in `src/y`: the C twin's value
  model (`yv.h`: `none|bool|long|float|str|array|record`) has no function
  value to store one in.
- **Arrays, maps and records are references**, in both copies; an array
  header never moves, so `arr += v` is visible through every alias. String
  and number values are immutable.
- Arrays are **homogeneous** — element types must match; heterogeneous
  literals are rejected.
- `--no-exec` strips the `exec()` builtin (no shell access).

## Array operators (the language's rules)

- `arr + arr2` → a NEW array — the operands untouched. (There is no
  `++` concatenation operator; `++` is increment only, and on an array
  it is the error `'++' needs a number target`.)
  `arr + elem` / `elem + arr` → a new array with one element added
  (element types must match). An array **is** an element when the other
  side holds arrays of its type: `[[T]] + [T]` appends it whole and
  `[T] + [[T]]` prepends it; `[[T]] + [[T]]` concatenates.
- `arr += v` → **in place**, the same reading as `+`: an array whose
  elements have arr's element type appends them; anything else (a `[T]`
  on a `[[T]]` included) pushes one element. Element types must match.
- `arr *= v` → **in place**: prepends one item (element type must match).
- `arr = arr2` → both names alias one array.
- `arr.length` (also `str.length`) is `len(arr)`; `arr.ptr` is a `*T` to
  the first element (arrays only — string bytes may live in read-only
  `.rodata`).
- `s.m(args)` on a `str` is a string method (`"a b".split(" ")`,
  `s.pad_left(5, "0")`, `", ".join(xs)`): one table, `str_method` in
  types.y, feeds the checker and the emitter (NATIVE.md, "String
  methods"). Method names are not reserved words.
- `const x = v` cannot be rebound (`=`, `op=`, `++`/`--` are type
  errors), but what it refers to stays mutable: `+=`/`*=` on a const
  array, element and field stores all work (JS `const`).
- A **fixed** `[T; N]` cannot grow: `+=` / `*=` on it is a type error
  ("its length is part of its type; use `[T]` instead").
- `x++`, `++x`, `x--`, `--x` and `x op= e` (`+= -= *= /= %=`) evaluate
  the target's subexpressions **exactly once**; numbers take the
  arithmetic, strings only `+=`, arrays the two in-place forms above.

## Layout

- `src/y/` — the Y compiler: `ycc.y` (driver), `lexer.y`, `parser.y`,
  `rename.y`, `types.y` (checker), `native.y` (emitter), `arch_x64.y`
  (asm + prelude), `enc64.y`, `asm.y`, `elf.y`; `std/` (`rt.y` runtime
  in Y, `prelude.y` (`readline`), `exec.y` (`exec`), `str.y` (string
  methods) — the four embedded into the compiler — and `io.y`, `net.y`,
  `struct.y`).
- `src/c/` — the 1:1 C copy of the above + `yv.c`/`yv.h` (the value
  model; no Y twin). `PORTING.md` is the contract.
- `refs/` — backed-up reference binaries for the port gate (see
  `PORTING.md` for where the current `ycc.ref` came from).
- `test/` — `test/sh/` (suite drivers + `lib.sh` + `ytool.sh`), `test/y/`
  (`native/` fixtures with expected/exit/stdin, `audit/` edge cases,
  `examples/` regression corpus, `ycc/` unit fixtures, `net/` servers
  for `test_net.sh`), `test/COVERAGE.md` (feature → test matrix).
- `bench/` — benchmarks + `compare.sh` (see the workflow above).

## Native backend (see `src/y/NATIVE.md`)

Unboxed values (long/int/byte/bool/float/ptr/str/option/function = 8
bytes); `[byte]` arrays are packed; stable heap headers `{len, cap,
data}` (elements in a separate block) with capacity doubling (0→8→×2);
closures as `[code, caps...]` records; `&x`, `*p`, `a[i]`, `a[lo:hi]`,
`T?`, `x!`, `void`, `float`, `byte` types; `for`/`for..in`/`foreach`/
`while`; block expressions; `type` aliases, record unions and `match`;
`def` params may be annotated (recommended: an unannotated param is a
poison-tolerant unknown), return types are inferred. `ycc` is
native-only: `ycc [-o OUT] [-S] [-t] [-g] [--no-exec] FILE`,
cc-style; the shipped binary needs nothing at runtime — it is a static
ELF invoking raw syscalls.
