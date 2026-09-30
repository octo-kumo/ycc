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
  `_ycc`, `a.out`, `src/c/prof_lines.c`, `src/c/std_lines.c`,
  `src/y/std/prof_lines.y` (all gitignored; `make clean` removes the
  binaries and both generated C twins — `src/c/std_lines.c` is tracked,
  so `git checkout` it after a clean). `refs/` is gitignored too but is
  **not** disposable — it is the port's ground truth.
- `make asan` builds `./cycc-asan` (ASan+UBSan); `make test-asan
  SUITES_ASAN="..."` runs suites against it (`CYCC`/`YCC` overridable).
  Do NOT put a `ulimit -v` on sanitized runs — ASan reserves terabytes
  of *virtual* address space.
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
- Profiling: `./ycc --time` prints a per-phase table (elapsed ms + heap
  bytes + counters) to **stderr**. Y-level builtins: `clock_us()`,
  `heap_used()`, `eputs(v)`.
- Always feed `</dev/null` in scripts (some programs read stdin).

## Test suites (`test/sh/`)

Twelve suites, run by `test/sh/run_all.sh` (named below in brackets). Most
compile each program with **both** compilers — the reference side is
`refs/ycc.ref` — and require the outputs to agree (byte-identical
binaries, identical program behavior). `test_native.sh`,
`test_native_examples.sh` and `test_prof.sh` drive the built `./ycc`
itself, so they skip when it is missing.

- `test_port.sh` [port] — the port gate: every `test/y/**.y` (and the
  compiler sources themselves) compile to byte-identical binaries with
  `cycc` and the reference `ycc`.
- `test_native.sh` [native] — `test/y/native/*.y`: `t*` assert
  stdout/exit (`.expected`/`.exit`, stdin from `.stdin`), `e*` assert
  rejection (first-line `// expect-error:` marker).
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
  compared with the reference's output.
- `test_fixpoint.sh` — three generations of self-compilation are
  byte-identical and the self-built binary still compiles working
  programs.
- `test_prof.sh` — `ycc --prof`: instrumentation leaves stdout alone,
  the report is framed and named, call counts are exact (times are never
  asserted).
- `test_stdin_eof.sh` — stdin/EOF behavior.

## Performance: bench before merging (mandatory workflow)

Anything that can move compile time, output size, or the speed of
compiled programs is **proposed, benchmarked on a branch, then
decided**. Never merge one on taste:

1. **Propose**: say what the change should move.
2. **Branch**: `git switch -c bench/whatever`.
3. **Build both sides**: `make ycc` on master, `cp ycc /tmp/ycc-base`,
   then `make ycc` on the branch.
4. **Bench**: `bench/compare.sh /tmp/ycc-base ./ycc` — scores the two
   builds (100 = unchanged), per-benchmark deltas for compile time, run
   time, binary size, asm size; joins `ycc --prof` reports per function.
5. **Decide**: merge or revert from the numbers; put the numbers in the
   commit message. A deliberate trade is fine — an unnoticed one is not.

`bench/y/*.y` are benchmarks, **not tests**. `ycc --prof` instruments a
compiled program and reports per-function call counts and cpu times on
stderr — use it to explain a regression, not just to spot it. Numbers
are noisy at the few-percent level; `bench/compare.sh ... 9` takes more
samples.

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
  other way round. Avoid *new* closures in `src/y`: the C twin's value
  model (`yv.h`: `none|bool|long|float|str|array|record`) has no function
  value to store one in.
- **Arrays, maps and records are references**, in both copies; an array
  header never moves, so `arr += v` is visible through every alias. String
  and number values are immutable.
- Arrays are **homogeneous** — element types must match; heterogeneous
  literals are rejected.
- `--no-exec` strips the `exec()` builtin (no shell access).

## Array operators (the language's rules)

- `arr + arr2` → a NEW array, `arr1 ++ arr2` — the operands untouched.
  `arr + elem` / `elem + arr` → a new array with one element added
  (element types must match).
- `arr += v` → **in place**: an array value appends its elements
  (element types must match); anything else pushes one element.
- `arr *= v` → **in place**: prepends one item (element type must match).
- `arr = arr2` → both names alias one array.
- A **fixed** `[T; N]` cannot grow: `+=` / `*=` on it is a type error
  ("its length is part of its type; use `[T]` instead").
- `x++`, `++x`, `x--`, `--x` and `x op= e` (`+= -= *= /= %=`) evaluate
  the target's subexpressions **exactly once**; numbers take the
  arithmetic, strings only `+=`, arrays the two in-place forms above.

## Layout

- `src/y/` — the Y compiler: `ycc.y` (driver), `lexer.y`, `parser.y`,
  `rename.y`, `types.y` (checker), `native.y` (emitter), `arch_x64.y`
  (asm + prelude), `enc64.y`, `asm.y`, `elf.y`; `std/` (`rt.y` runtime
  in Y, `prelude.y` (`readline`/`exec`), `io.y`, `net.y`, `prof.y`,
  `struct.y`).
- `src/c/` — the 1:1 C copy of the above + `yv.c`/`yv.h` (the value
  model; no Y twin). `PORTING.md` is the contract.
- `refs/` — backed-up reference binaries for the port gate (see
  `PORTING.md` for where the current `ycc.ref` came from).
- `test/` — `test/sh/` (suite drivers + `lib.sh` + `ytool.sh`), `test/y/`
  (`native/` fixtures with expected/exit/stdin, `audit/` edge cases,
  `examples/` regression corpus, `ycc/` unit fixtures).
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
native-only: `ycc [-o OUT] [-S] [-t] [--no-exec] [--prof] FILE`,
cc-style; the shipped binary needs nothing at runtime — it is a static
ELF invoking raw syscalls.
