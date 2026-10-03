# AGENTS.md — y compiler

C (gnu99/gcc) + the Y compiler for the `.y` language. The Y compiler in
`src/y/` compiles `.y` straight to static x86-64 ELFs (its own assembler
and ELF writer — no cc/as/ld). The C compiler in `src/c/` is a **1:1
copy of the Y code** (see `PORTING.md`): same modules, same functions,
same semantics.

## Build

- `make` → builds `./cycc`, the C copy of the compiler.
- `make ycc` → builds the compiler with `cycc`, attaches its std pack
  (the std units precompiled, `--std-pack`; NATIVE.md, "Compilation
  units and the std pack") to make `./ycc`, then **verifies**:
  - `cmp ycc refs/ycc.ref` — the C copy's output is byte-identical to
    the reference `ycc` binary, pack included (the acceptance gate for
    the port), and
  - `./ycc` self-compiles byte-identically (fixpoint).
  `refs/` holds the backed-up reference binaries (gitignored; see
  `refs/SHA256SUMS`).
- Do not commit build artifacts: `*.o`, `cycc`, `cycc-asan`, `ycc`,
  `_ycc`, `_ycc0`, `ynew`, `*.pack`, `a.out`, `_check/` (all gitignored;
  `make clean` removes them).
  `refs/` is gitignored too but is **not** disposable — it is the port's
  ground truth.
- The std units the compiler links into programs are plain Y in
  `src/y/std/rt.y`, `prelude.y`, `exec.y`, `str.y`, embedded into both
  compilers when they are built (`embed` in native.y, `Y_EMBED` in
  native.c — PORTING.md rule 10). Edit those files directly; there is no
  generator (`make ycc`/`ynew` rebuild the pack). `str.y` must not
  contain string literals (see NATIVE.md, "Runtime library").
- `make asan` builds `./cycc-asan` (ASan+UBSan); `make test-asan
  SUITES_ASAN="..."` runs suites against it (`CYCC`/`YCC` overridable).
  A sanitized compiler cannot run under `ulimit -v` (ASan reserves
  terabytes of *virtual* address space): its cap is ASan's own,
  `ASAN_OPTIONS=hard_rss_limit_mb=3500` (lib.sh and `make test-asan` set
  it). The programs a sanitized compiler emits still run under `ulimit
  -v` (`run_bin` in `test/sh/lib.sh`, `YPROG_MEM_KB`), so a test that
  must see an allocation fail still does.
- **Every process runs under a memory cap below 4 GB** — this machine
  goes down past 4 GB, and it has, twice. The Makefile's recipes run in
  `test/sh/capped.sh` (`ulimit -S -v 3670016`, 3.5 GiB); lib.sh, check.sh
  and the bench scripts set the same cap themselves; anything run by hand
  gets `(ulimit -v 3670016; timeout ... cmd)` — valgrind, gdb and perf
  included (they run the program inside the cap). A run that hits the cap
  is a bug to fix (find what allocates; `cycc` never frees, so all it
  ever allocates counts), never a reason to raise the cap.
- When changing `src/y/*.y`: the C copy (`src/c/`) must get the same
  change (it is a 1:1 copy — see PORTING.md), then `make ycc` must stay
  byte-identical, and `make test` green. The Makefile has a target for
  each step — see "Changing the compiler" below.

## Changing the compiler (the development loop)

`make ycc` checks the C copy against `refs/ycc.ref`, the last *blessed*
compiler, so a compiler change runs this loop (`BASE` defaults to
`refs/ycc.ref`, `NEW` to `./ynew`):

1. Change `src/y`, port it to `src/c` (PORTING.md); fixtures, docs,
   `test/COVERAGE.md`.
2. `make check` — everything below in one command, ~2 minutes, a summary
   on screen and each step's full output in `_check/`:
   - **verify**: builds `./ynew` from `src/y` with the blessed compiler
     (generations 2 and 3 byte-identical), requires `cycc` to build it
     byte for byte, and every suite to pass with it as the reference and
     the built compiler;
   - **compare** with `BASE`: the test programs that now compile to
     different code or behave differently (run under both), and the
     instructions executed compiling and running every benchmark (exact);
   - **time**: the benchmark SCORE, plus every size that changed and every
     time of 40 ms or more that moved 10% (shorter ones are noise; their
     instruction counts are the signal).

   Check that every change it lists is intended.
3. `make rebless` builds the compiler with `cycc`, checks its fixpoint and
   the port gate, and installs it as `refs/ycc.ref` (and `./ycc`,
   `refs/SHA256SUMS` updated) — `make check` already ran every suite on
   it. Commit with the numbers.

The steps on their own: `make ynew` (no C port needed yet), `make
port-check` (the port gate against `./ynew`; prints only failures), `make
corpus-diff` (`FILES="a.y b.y"` narrows it; fails on any change of
behavior or diagnostics), `make bench`, `make bench-ir` (see
"Performance" below).

## Run / verify (use these exact forms)

- Compile + run: `./ycc file.y -o /tmp/t_bin && /tmp/t_bin`
- Same through the C copy: `./cycc file.y -o /tmp/t_bin && /tmp/t_bin`
- Assembly only: `./ycc -S file.y > /tmp/t.s`
- `make test` runs everything: the port gate + all `test/sh/*.sh`
  suites, `JOBS` at a time (default: every CPU; ~45 s), each suite's
  output printed whole when all are done; `JOBS=1` runs them one by one
  with live output. `./test/sh/run_all.sh [-j N] [suite ...]` runs a
  subset.
- `make test-compile` — tiny smoke test (both compilers, one example).
- Compiler profiling: `./ycc --time file.y` prints a per-phase table
  (elapsed ms + heap KB + counters) to **stderr**. It still needs an
  input file — `ycc` with no FILE is the error `no input file`. Y-level
  builtins: `clock_us()`, `heap_used()`, `eputs(v)`.
- Program profiling/debugging: `./ycc -g` adds a symbol table, DWARF
  line info and section headers (code and addresses unchanged), so the
  standard tools name functions and source lines: `perf
  record`/`report`/`annotate` (on WSL run
  `/usr/lib/linux-tools/*/perf` directly — the `/usr/bin/perf` wrapper
  refuses the kernel), `valgrind --tool=callgrind` + `callgrind_annotate`
  (exact instruction counts), `valgrind --tool=massif
  --pages-as-heap=yes` (the heap is `mmap`ed, not `malloc`), `gdb`
  (`break fn`, `break file.y:N`, `next`/`step`, `bt` with file:line —
  no variables), `nm`/`addr2line`/`objdump -dl`, `strace -c`.
- Always feed `</dev/null` in scripts (some programs read stdin).

## Test suites (`test/sh/`)

Sixteen suites, run by `test/sh/run_all.sh` (named below in brackets). Most
compile each program with **both** compilers — the reference side is
`refs/ycc.ref` — and require the outputs to agree (byte-identical
binaries, the same warnings, identical program behavior). `test_native.sh`,
`test_native_examples.sh`, `test_debug.sh`, `test_link.sh`, `test_pkg.sh`,
`test_ycc.sh` and `test_fixpoint.sh` drive the built `./ycc` itself, so
`run_all.sh` skips those **seven** when it is missing (`make test-fast`).

`run_all.sh -j N` runs N suites at once and splits the long ones (port,
comprehensive, native) into shards (`YSHARD=K/N`: every Nth case, see
`next_case` in `lib.sh`). The suites take the compilers they test from
the environment: `CYCC` (the C copy), `YREF` (the reference, default
`refs/ycc.ref`), `YCC` (the built compiler driven by native,
native-examples, debug and ycc) and `YSELF` (fixpoint, link, pkg,
stdin-eof).
`YPORT_SELF=0` leaves `src/y/ycc.y` out of the port gate, for when that
very build was just compared (`make test`, `check`, `rebless` do);
`YQUIET=1` prints failures only.

- `test_port.sh` [port] — the port gate: every `test/y/**.y` (plus
  `src/y/ycc.y` itself) compile to byte-identical binaries with
  `cycc` and the reference `ycc`, with the same warnings; a program
  both reject must get the same diagnostics from both.
- `test_native.sh` [native] — `test/y/native/*.y`: `t*` assert
  stdout/exit (`.expected`/`.exit`, stdin from `.stdin`) and their
  warnings (each `// expect-warning: MSG` marker needs a warning
  containing MSG on its own line, and no other line may warn), `e*`
  assert rejection: the output must contain every `// expect-error:`
  line of the file (at least one; the checker reports all errors at
  once).
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
  compared with the reference's output; warnings (an import's file
  named, stderr only, `-w` keeps the bytes); plus the driver's failures
  (bad flags and paths, failed writes, import depth): both compilers
  print the same message and exit 1.
- `test_fixpoint.sh` — three generations of self-compilation are
  byte-identical (the second with `./ycc`'s std pack, the third from
  the std sources) and the self-built binary still compiles working
  programs; the compiler's source and every `src/y/std` file compile
  without a warning.
- `test_debug.sh` [debug] — `ycc -g`: both compilers emit identical
  `-g` binaries, the program runs the same, code and rodata match the
  plain build, readelf/nm/addr2line (gdb and callgrind when installed)
  see the functions and globals by name, and the line table maps code
  to file:line (an import's too; `-S -g` assembles with GNU `as`).
- `test_link.sh` [link] — std units and the std pack: `./ycc` carries a
  well-framed pack, the one `--std-pack` writes and the C copy writes
  too; linking from it gives the same bytes as `--std-src` (plain and
  `-g`, programs linking every std unit); a stale or missing pack falls
  back to source; a program's own `y_` helper or `readline` replaces
  std's; `--no-exec`; std line markers only under `-g`, renumbered.
- `test_pkg.sh` [pkg] — `ycc build`/`ycc vendor` on projects made in
  /tmp: a diamond of path dependencies (each package compiled once, its
  top level run once, dependencies first), qualified names, defaults and
  read-only globals across packages; the object cache (a rebuild compiles
  nothing and gives the same bytes; a body change recompiles one
  package, an interface change its importers; damaged or foreign objects
  are rebuilt); imports, argv, exec, `--no-exec` and `-g` inside packages;
  warnings (a package's when it compiles, a bin's on every build, `-w`);
  every manifest, graph and command-line error; git dependencies (local
  repos: fetch, `y.lock` pins, revs, `ycc vendor`). The C copy must print
  the same and build the same bytes.
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
  suite. New diagnostic → new `e*.y` marker (a new warning: an
  `expect-warning` marker in a `t*.y`); new manual section → new
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

## Performance: bench and profile at the end

A change that can affect performance (compile time, output size, or the
speed of compiled programs) gets a **thorough bench and profiling at the
end**, once it is done. Its numbers go in the commit message. A
deliberate trade is fine; an unnoticed one is not. The tools compare a
base build (normally the blessed `refs/ycc.ref`) with the new one
(`./ynew`, from `make ynew`):

- `make check` (step 2 of the loop above) measures as part of checking.
- `make bench` (override with `BASE=`, `NEW=`, `ROUNDS=`; it runs
  `bench/compare.sh` on copies under `/tmp`) scores the two builds
  (100 = unchanged) over compile time, run time and binary size. Asm
  bytes and lines are shown per benchmark but not scored. It then lists
  the callgrind instruction counts per function for every benchmark
  (`bench/profile.sh`: `-g` builds, needs valgrind). To use another base,
  run `make ycc` on it and `cp ycc /tmp/ycc-base`.
- `make bench-ir` (`bench/compile_ir.sh`) adds what the timings cannot
  resolve: the exact instructions each compiler executes compiling every
  benchmark and `ycc.y`.
- Profile whatever moved: the callgrind table, `perf` on a `ycc -g` build,
  or `ycc --time` for the compiler's phases. Use them to explain a
  regression, not just to spot it.

Keep both binaries on the same filesystem. Under WSL, a binary run from
`/mnt/c` pages in through drvfs and measured ~30% slower in every phase,
which is easy to mistake for a regression. `bench/y/*.y` are benchmarks,
**not tests**. Times are wall clock on a shared machine:
- a SCORE within 100 ± 2.5 is no change (two copies of one build scored
  99.7–100.6 in six runs; one real pair scored 99.8 and 102.3);
- a row of 40 ms or more agrees to ~8%;
- a shorter row swings by 20% or more (`bench/compare.sh ... 9` takes
  more samples).

Instruction counts are exact.

## Pipeline (`src/y/native.y`)

splice imports, pick the std units → per unit (the program's, each
package's under `ycc build` unless its object in `build/obj` is current,
and each std unit unless the std pack has it): strip namespaces → rename
(uniquify) → typecheck (static, errors fatal) → lint (`lint.y`:
warnings, to stderr; the program's unit and packages, never a std unit)
→ hoist → emit bodies →
link the units (tree shake across them) into `.s` → `asm.y` assembles →
`elf.y` writes a static ELF (`-g`: plus `dwarf.y`'s line table). `y_` is
a **reserved prefix**: such a def is emitted under its bare name because
generated code calls it by fixed label (a program's own `y_` def
replaces the std one at link time).

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
  and number values are immutable (`s += t` may append in place, but only
  into a buffer nothing else can see — NATIVE.md, "Owned strings").
- Arrays are **homogeneous** — element types must match; heterogeneous
  literals are rejected.
- **Records are exact**: a record type is its set of fields (in any
  order), and a record goes only where its own type, or a union holding
  it, is expected — no prefix view of a bigger record (a node of seven
  fields is no `{k: str, params: [str]}`), and no record type takes "any
  record": `{k: str}` is the record of one field.
- **No unknown types**: every parameter is annotated (or has a literal
  default); `[]` and `none` get their type from where they go, or the
  `let` binding them is annotated; a def called before its body is
  checked (a forward call) has its return type written. The compiler's
  own AST and type nodes are the unions `Node` and `Type` (parser.y): a
  field every member has (`k`, and `line`/`col` on AST nodes) reads
  straight through, any other after a cast to the member
  (`let c: Call = node;`, or a parameter typed `Call`), which the program
  checks against the value's tag. A member held in a union is laid out
  with the union's shared fields first, so a cast **copies** the record
  where that differs from the member's own layout: never write through a
  cast value expecting the union value to change (or the other way
  round) — the C copy shares records, so the port gate catches it. A
  `match` binding (`Call c =>`) is such a cast; a destructuring pattern
  (`TFree { free: fr } =>`) reads in place.
- `--no-exec` strips the `exec()` builtin (no shell access).
- **No warnings**: `src/y` and `src/y/std` compile without one
  (`test_fixpoint.sh` checks). A record or union type used in more than
  one place gets a `type` alias, declared in the module that owns it and
  imported where it is used (a module imported only for an alias: a
  `// For its alias X.` line above the import — the import splicer,
  `native_resolve_seen`, reads an `import` line whole, so a comment
  cannot trail it). An unused parameter is fine; an unused local is not.

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
- `x++`, `++x`, `x--`, `--x` and `x op= e` (`+= -= *= /= %=`, and
  `&= |= ^= <<= >>= >>>=` on integers) evaluate the target's
  subexpressions **exactly once**; numbers take the arithmetic, strings
  only `+=`, arrays the two in-place forms above.
- The bitwise operators `& | ^ ~ << >> >>>` take integers and yield a
  long; they bind tighter than the comparisons (`x & 1 == 0` is
  `(x & 1) == 0`, unlike C). `>>` is arithmetic, `>>>` logical; a count
  of 64 or more shifts every bit out and a negative count traps.

## Layout

- `src/y/` — the Y compiler: `ycc.y` (driver), `pkg.y` (`ycc build`:
  `y.toml`, the dependency graph, git, `y.lock`), `lexer.y`, `parser.y`,
  `rename.y`, `types.y` (checker), `lint.y` (warnings), `native.y`
  (emitter), `arch_x64.y`
  (asm + prelude), `enc64.y`, `asm.y`, `elf.y`, `dwarf.y` (`-g` line
  info); `std/` (`rt.y` runtime
  in Y, `prelude.y` (`readline`), `exec.y` (`exec`), `str.y` (string
  methods) — the four embedded into the compiler — and `fs.y` (files,
  paths, directories: `import fs;`), `io.y`, `net.y`, `struct.y`).
- `src/c/` — the 1:1 C copy of the above + `yv.c`/`yv.h` (the value
  model; no Y twin). `PORTING.md` is the contract.
- `refs/` — backed-up reference binaries for the port gate (see
  `PORTING.md` for where the current `ycc.ref` came from).
- `test/` — `test/sh/` (suite drivers + `lib.sh` + `ytool.sh` +
  `corpus_diff.sh`, which is `make corpus-diff`, not a suite, + `check.sh`,
  which is `make check`), `test/y/`
  (`native/` fixtures with expected/exit/stdin, `audit/` edge cases,
  `examples/` regression corpus, `ycc/` unit fixtures, `net/` servers
  for `test_net.sh`), `test/COVERAGE.md` (feature → test matrix).
- `bench/` — benchmarks + `compare.sh` + `profile.sh` + `compile_ir.sh`
  (see the workflow above).

## Native backend (see `src/y/NATIVE.md`)

Unboxed values (long/int/byte/bool/float/ptr/str/option/function = 8
bytes); `[byte]` arrays are packed; stable heap headers `{len, cap,
data, front}` (elements in a separate block) with capacity doubling
(0→8→×2) at the back for `+=` and room reserved in front for `*=`, so
both are amortized O(1); `s += t` on a `str` variable appends in place
into a buffer only that variable owns, also amortized O(1);
closures as `[code, caps...]` records; records laid out by field name
(a member held in a union: the union's shared fields first),
a pointer to their type's descriptor before the fields; `&x`, `*p`,
`a[i]`, `a[lo:hi]`, `T?`, `x!`, `void`, `float`, `byte` types;
`for`/`for..in`/`foreach`/`while`; block expressions; `type` aliases
(recursive through a record field or a function type), record unions and
`match`;
`def` params are annotated (or have a literal default; there is no
unknown type), return types are inferred. `ycc` is
native-only: `ycc [-o OUT] [-S] [-t] [-g] [-w] [--no-exec] [--std-src] FILE`,
cc-style (`-w`: no warnings; they go to stderr and never change the
output) (and `ycc build [DIR]` / `ycc vendor [DIR]` for projects with a
`y.toml`: NATIVE.md, *Packages*); the shipped binary needs nothing at runtime — it is a static
ELF invoking raw syscalls, carrying its std units precompiled (the std
pack, appended by `make ycc`).
