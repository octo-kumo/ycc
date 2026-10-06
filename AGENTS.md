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
- `make cycc.exe` → the C copy cross-compiled for Windows with mingw-w64.
  It is the SAME source as `cycc`: `src/c/ylong.h` is what makes Y's 64-bit
  `long` hold on Windows' LLP64. The gate is `test/sh/cycc-win.sh`, which
  needs wine: every fixture `cycc.exe` compiles must be byte-identical to
  Linux `cycc`'s, diagnostics and `-S` listing included (`-g` is not compared
  across hosts — DWARF records the host's own absolute path). Meta fixtures
  are the known gap (the M1 runner forks and maps a memfd). Not in
  `make test`. The `--target=windows` PE path is gated by
  `test/sh/pe-gate.sh` (a PE loads and runs under wine, and its output must
  not contain the startup self-test's message), `pe-packinv.sh` (a PE from the
  std pack and one from `--std-src` are identical, 230/230) and
  `pe-fixtures.sh` (every `t*.y` fixture run both ways; four `ELF-OUTPUT-DIFF`
  baseline failures are pre-existing, and the four `t34{1,2,3,4}_threads_*`
  fixtures are PE-only failures because the PE target has no `spawn`/`mutex`/
  `sem` yet -- that is the "fork/spawn/threads on NT" item in the goal, not a
  regression). A PE runs the W3 syscall self-test at
  startup — `src/y/arch/wselftest.s`, returned by `w_self_test_lines` and
  called from the `_start` prologue on that target only — so a `w_sysno`
  number that drifted on another Windows build prints `runtime error: NT
  syscall self-test failed ...` and exits 1 instead of calling some other real
  Nt function. Nothing is emitted for an ELF.
- `make ytest` → `./ytest`, the test/metrics runner written in Y
  (`src/tools/ytest/README.md`): `./ytest suites` times each `test/sh` suite,
  `./ytest coverage` reports gcov line coverage of the C copy over a corpus,
  and `./ytest report` writes `ytest-report.md`. A measurement tool, not a
  gate, and not in `make test`.
- Do not commit build artifacts: `*.o`, `cycc`, `cycc.exe`, `cycc-asan`, `ycc`,
  `_ycc`, `_ycc0`, `ynew`, `ytest`, `ytest-report.md`, `*.pack`, `a.out`,
  `_check/` (all gitignored; `make clean` removes them).
  `refs/` is gitignored too but is **not** disposable — it is the port's
  ground truth.
- The std units the compiler links into programs are plain Y in
  `src/y/std/rt.y`, `prelude.y`, `exec.y`, `str.y`, embedded into both
  compilers when they are built (`embed` in native.y, `Y_EMBED` in
  native.c — PORTING.md rule 11). Edit those files directly; there is no
  generator (`make ycc`/`ynew` rebuild the pack). `str.y` must not
  contain string literals (see NATIVE.md, "Runtime library").
- The compiler's own **assembly** is in `src/y/arch/*.s`, embedded the
  same way (`embed PRELUDE_ASM from "./arch/prelude.s";` in arch_x64.y,
  `Y_EMBED` in arch_x64.c — PORTING.md rule 12), so there is one copy of
  it rather than one per compiler. Whole-line `#` comments are allowed
  there and dropped before the in-tree assembler sees the text;
  `make asm-check` reads the files with GNU `as`. Edit the `.s` files
  directly — `make cycc`/`ynew`/`ycc` rebuild, and `ARCH_EMBEDS` lists
  them as prerequisites.
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

**What the loop costs, measured** (8 cores here), because "rebless is slow"
is a belief worth replacing with numbers: `make rebless` is **9.5 s** — 0.98 s
for `cycc` to compile the compiler, 0.44 s for the Y self-compile, hundredths
for the `cmp` and the pack, and **8.4 s (87%) for the port suite** over 142
fixtures, each compiled by both compilers, which is the gate. `make cycc` from
a clean tree is 5.5 s and `make -j8 cycc` is the same 5.5 s —
`src/c/native.c` is one 12,000-line translation unit and it *is* the build, so
there is nothing to overlap. The full 20-suite run is 37 s, and `make check`
adds the compare and bench phases on top of that; *those* are the slow steps,
not the bless. Numbers above the `rebless` target in the Makefile.

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

**`ycc run` is not a faster test driver**, and was measured rather than
assumed: on `bench/y/hello.y` it is 1.44 ms a run against 1.46 ms for
`-o /tmp/x` plus executing it (50 runs each: 0.072 s against 0.073 s;
compile+write alone is 1.06 ms and the exec 0.40 ms). It still assembles the
image and forks, and the ELF write lands in the page cache, so there is
nothing to win — and the suites cannot use it anyway: they compare **two**
compilers' binaries (`cmp`) and then run both, which one compile-and-run
cannot do. What it IS good for is leaving no file behind and passing argv
(`ycc run p.y -- -x`), which is why the examples campaign uses it.

## Test suites (`test/sh/`)

Twenty suites, run by `test/sh/run_all.sh` (named below in brackets).
Most compile each program with **both** compilers — the reference side is
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

Beyond the suites, three harnesses are run by hand because they need more than
the suite runner: `test/sh/cycc-win.sh` (W1: `cycc.exe` under wine must match
Linux `cycc` byte for byte), `test/sh/w_sysno.py` (prints the NT syscall number
a named `Nt*` function actually has in the installed wine ntdll, read from its
export stub -- the independent check for `arch_x64.y`'s pinned `w_sysno` table,
which otherwise only the W3 self-test verifies and only at runtime) and
`./ytest` (times the suites; gcov line coverage). None is in `make test`.

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
  connections under `ulimit -n 32` (no fd leak per connection); the
  resolver (`net.resolve_with`) against a fake DNS server
  (`dns_srv.y`: CNAME, TCP fallback, NXDOMAIN, a malformed answer), and
  the TLS 1.3 client (`tls_cli.y`, std/tls.y) against `openssl s_server`
  with each suite and an RSA and an ECDSA certificate (skipped without
  openssl).
- `test_math.sh` [math] — the accuracy gate for `std/math.y`: reads
  `test/math/ulp_table.txt` (**8340 cases**, 7285 of them taking one argument
  and 1055 taking two or three — the pinned edges, the overflow and flush
  points, both sides of 1, the poles, the signed zeros, and then seeded spreads
  over each function's own domain: uniform in the DECADES for `log2`, `log10`
  and `exp2`, where the structure is in the exponent; over [-1, 1] for `asin`
  and `acos`, the only two with a bounded domain; over |x| ≤ 1/2 for `tanh`'s
  polynomial branch; and a general [-8, 8] for the rest. A pinned list is not a
  spread, and the arguments BETWEEN the pins are where the defects live — four
  of the five found here sat between two values somebody had already written
  down — each line the function, its
  argument(s) and the reference answer as IEEE-754 bit patterns), evaluates
  every case with both compilers and
  **fails on anything more than 1 ulp from the reference**. The gap is counted
  through the monotone key of a double's bits, so it is exact at zero, across a
  sign change, for a subnormal, and infinite for a NaN. The worst gap and the
  function it came from are printed, so a regression names itself.

  Two things about that gate that are worth knowing before changing it. It ends
  in `exit(main())`, and it used to end in a bare `main();` — a statement whose
  value is discarded — so the 1 a failure produced went nowhere, the process
  always exited 0, and the "0 over 1" this module is held to was a number the
  harness counted correctly and then threw away. **The gate could not fail**,
  while its own header said a kernel that drifted past it would. And the `OVER`
  line printed only the *first* argument, so a two-argument failure could not be
  located in the table at all. Both are fixed; both are the kind of thing that
  reads as coverage right up until it is measured.

  And the two-argument functions got the sweep this suite did not have.
  `audit_float.py`'s header said of `hypot` and `atan2`: "covered by the table
  and by t325". That was load-bearing and wrong — `hypot` had **fourteen** table
  cases and `t325` pinned one corner. The omission had a cause worth naming
  rather than excusing: a sweep needs a reference, and Python 3.14's `decimal`
  has `exp`, `ln`, `log10`, `sqrt` and `power` and **no inverse trig**, with
  mpmath not installed. There was no `atan2` to call.
  `test/math/audit_pairs.py` writes one — arctangent by two exact identities plus
  the alternating series — and checks it against libm on all **557** two-argument
  table cases *before* the sweep runs, because a hand-written reference is the
  one thing that must not be trusted on its own. That check caught two bugs in the
  reference on its first run. The sweep is **20 000 pairs with each argument
  uniform in the decades and the two drawn independently** (independently is the
  point: a correlated draw makes `y == x` the common case, which is one point of a
  two-dimensional range rather than the shape of it). Both functions within
  1 ulp; pointed at the pre-fix module it reports 4 over for `hypot` and 18 for
  `atan2`. `YPAIRS` sets the count (4000 in the suite).

  That sweep was then shown **blind to a whole class**, and the reason generalises.
  `hypot` answered `+inf` for every `m` in `(9.4808e153, 1e154)` when `s` was
  comparable to it, because the direct path's `m*m + s*s` overflows while the
  answer does not. Of 20000 independently drawn pairs, 6 landed in that decade and
  **none** of the six had `s` within a factor of ten of `m`; the expected number
  where both conditions hold is `(1/628) x (2/600)`, so `20000 x that = 0.11` —
  about one chance in nine. Independent draws and correlated draws are not two
  settings of one knob, they are opposite: drawing the exponents independently is
  what makes *wide* ratios common and it is exactly what makes `s == m` rare.
  `audit_pairs.py` now carries both families.

  The defect was found instead by **pinned boundary cases**, and the rule that
  came out of it is the one to reuse: *every numeric literal a comparison in
  `std/math.y` tests against gets itself and its two neighbouring doubles,
  crossed with a partner close enough to it that the second condition also
  holds.* A sweep finds defects by **area** — it finds what is spread over the
  decades and is blind to a sliver of one — while a threshold is only findable if
  something names it. `gen_ulp_table.py` pins the code's constants **and** the
  true seam `sqrt(DBL_MAX/2)`, because the module's `1e153` stands well inside it
  and the reasoning that produced `1e154` is the reasoning a reader will repeat.
  Both catch the wrong bound: 2 cases, exit 1.

  **And that rule is now a gate over every seam at once.**
  `test/math/audit_thresholds.py` reads every comparison `std/math.y` makes
  against one of its own float **parameters** — literals and named constants
  alike — and reports how far the nearest table argument is from each, in ulps of
  the threshold. Restricted to parameters on purpose: "is there an argument near
  this threshold" is the right question for a value the caller passes and the
  wrong one for a derived quantity, since `hypot_scaled` tests `s/m < 1e-4`, a
  **ratio**, and no single argument is ever near 1e-4. 16 edge thresholds; 14 of
  them now have an argument within **1 ulp**. Wired into `test_math.sh` with its
  own selftest, and proved to fail by planting a seam.

  Its first run named two more, and pinning them found a defect in the
  **reference**: `sinh`'s overflow lambda returned `+inf` for a *negative*
  argument past the bound, where `sinh` is odd and the answer is `−inf`. Nothing
  had noticed because no case in the table was a negative argument beyond the
  bound — the pinned list and the overflow strip were all positive or small.
  That is the seventh time this work's own reference has been the thing that was
  wrong, and the shape is always the same: **a reference written for the cases
  that existed rather than for the function.**

  Two thresholds remain far from the table and both are **oracle** seams the
  table cannot reach — `exp_y`'s `exp_lo` and `pow_y`'s ±1024, inside functions
  that are not exported. Each is pinned once by the fixture that compares the
  oracle against the assembly kernel it stands in for, and each `KNOWN` entry
  names that fixture rather than asserting that it is fine.

  The three thinnest **rounding** functions were then grown, on the reasoning
  that an exact function needs few cases (finitely many answers) and a rounding
  function does not: `sqrt` had 23, `atan2` 35 and `hypot` **14**, and fourteen
  cases cannot gate a function whose difficulty is the ratio between its two
  arguments. Each pair's two exponents are drawn **independently**, which is
  what makes the ratios wide. The 768 cases that added found `atan2` dropping the
  sign of `y` at an infinite `x`, the same sign dropped twice in the *reference*
  (so the table agreed with the module on a case where the module was right), and
  `hypot` 2 ulps out on 0.75% of wide-ratio pairs.
  `test/math/ulp_check.y` says in its own header why the tolerance is 1 and what
  the four cases that used to sit over it were; `gen_ulp_table.py` wrote the
  table from this platform's libm (mpmath is not installed here, and a platform
  libm is the *relevant* reference anyway — the promise is to match what C
  gives), and `gen_kernel.py` fits and checks the kernels' coefficients.
  Three more things run here, and none of them is the ulp table:

  - `test/y/native/t328_split_unrolled.y`, which asks each of the module's eight
    **generated** polynomial kernels (`poly_exp`, `poly_log`, `poly_sinh`,
    `poly_tanh`, `poly_atan`, `poly_asin`, `poly_sin`, `poly_cos`) and
    `poly_split`, the loop each replaced, the same 32024 questions and requires
    the same **bits**. The chains perform the same operations in the same order,
    so anything but equality is a defect. The table cannot catch this class: it
    sees answers, and a kernel that drifts half an ulp hides inside the final
    rounding. Run under both compilers here, so a port that emitted a different
    chain would show as a disagreement rather than as nothing.
  - `gen_split_unroll.py --verify`, the other question: does `src/y/std/math.y`
    still hold byte-for-byte what the generator writes? It catches what t328
    cannot — a chain hand-edited after generation, or a banner whose caller list
    has gone stale, still answers within an ulp, because the coefficients are
    right and only the arrangement moved.
  - `test/math/find_repeats.py`, a **ratchet** on repeated computations, and the
    one static check in this suite. The defect class it looks for is "a behaviour
    decided by an accident of expression order", where the accident is in the
    *spelling* rather than the order: two places meaning the same thing and
    written differently, so a change reaches one and not the other. That is how
    `sin_cos_k` came to compute `x * x` three times. Its findings are in its
    `KNOWN` with the reason each is acceptable (two today, one a branch-
    disjointness false positive) and anything new fails; its `--selftest` plants
    one of each thing it claims to find, because a detector that silently stops
    detecting would leave the ratchet reading as coverage.

- `test_treeshake.sh` [treeshake] — the measurement behind "unused code
  costs nothing", as a ratchet. It compiles `test/treeshake/minimal.y` and
  then the same program with one unused `import` and reports what each unit
  adds; growth fails, shrinkage is reported so `test/treeshake/costs.txt`
  can be lowered deliberately. It used to record the tree shake's blind
  spot — **functions are dropped, data is not**, 6705 bytes for
  `std/math.y`'s top-level `const`s built at startup and read by nobody —
  and that is fixed: the emitter brackets each global's initializer with
  `ygiS_<cell>` / `ygiE_<cell>` labels and the link step deletes the range
  of a cell nothing reads, so `math`, `regex`, `crypto`, `fs` and `struct`
  are free. What is left is the *rule*, not a gap: 94 bytes for `x509` and
  `tls`, 25 for `json`, are top-level statements with an effect, and a range
  is droppable only when it makes no call but the allocator, writes no other
  cell and holds no raw text (`test/y/native/t348_unread_init_side_effect.y`
  is the regression that rule exists for — the first version of the pass
  deleted a call to `main` and produced a compiler that exited 0 and did
  nothing). `test/treeshake/dead.y` is the program with a dead table, dead
  helpers, a dead branch, an unused union and code after a `return`: 544
  bytes of it survive its own tree shake, and its import cost is on top.
  `test/sh/test_treeshake.sh` is run by both compilers and their results
  must agree.
- `test_std_suites.sh` [std-suites] — the self-test suites for the std units
  that have one, in `test/std/`: `fx_test.y` (292 checks, the vendored `fx.y`),
  `args_test.y` (61, `std/args.y` and the pacer it paces with),
  `fb_test.y` (41, the surface half of `std/tui.y`), `term_test.y` (108,
  the terminal half — needs a real pty) and `time_test.y` (47, the pacer and
  fps meter). Each is built with **both** compilers and must compile without
  a diagnostic. `fx_test` and
  `fb_test` are byte-deterministic, so the whole transcript is diffed against
  `test/std/golden/`; `time_test` and `args_test` print measured clock values
  that differ every run, so they are gated on exit status plus their PASS marker;
  `term_test` runs under `term_pty_test.py`, which forks a real pty because
  `TCGETS` and `TIOCGWINSZ` both return `ENOTTY` on a pipe. That driver is run
  with `--skip-crash`: its two `SIGKILL`-watchdog cases failed 1 run in 6 on this
  machine, and a gate that re-runs is worse than none. This folder was
  `examples/_toolkit/` until 2026-10-05; it left the corpus because four of its
  five modules had moved into `std` and what remained was a verification harness,
  which `examples/.gitignore` says does not belong there. `fx.y` stays vendored
  (14 examples hold a byte-identical copy, sha256 `4b47a9bfef0c1e30`, `wc -l` 694)
  because 18 of its 36 functions have no `std/math` counterpart and it is integer
  Q30 where `std/math` is float.
- `test_coverage.sh` [coverage] — static, compiles nothing: every
  diagnostic the compiler can print has its message in a test
  expectation, every builtin in the manual is called by a checked test,
  every keyword appears in a `t*.y`, and `test/COVERAGE.md` maps every
  manual section to the checked tests that exercise it. Unreachable
  diagnostics are listed there with a reason; a stale excuse fails the
  suite. New diagnostic → new `e*.y` marker (a new warning: an
  `expect-warning` marker in a `t*.y`); new manual section → new
  row.
- `test_lsp.sh` [lsp] — the language server, `src/tools/lsp/` (built by
  `make yserve`, designed in `src/tools/lsp/LSP.md`): its `t*.y` fixtures
  under both compilers against their `.expected` (which includes `std/json.y`
  and the diagnostics pipeline), `check-refs.py` over every symbol `LSP.md`
  cites, and the formatter over the whole corpus for idempotence.
  `test-e2e.sh` drives the built `yserve` as a real process — framing, fork
  containment, state across messages — and is **not** in `make test` (it needs
  a process per case); run it by hand or with `make lsp-e2e`.

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
which is easy to mistake for a regression.

**And run both from the same tree.** The std pack carries only the four units
`make` embeds — `rt`, `prelude`, `exec`, `str` (`STD_EMBEDS`) — and every other
std unit is read from the filesystem at compile time: `std_units` unpacks what
the pack has and, for anything else, `std_compile` asks `std_unit_src` for
`std/<name>.y` under **the directory the compiler is running in**. So a compiler
built in one tree and run from another silently compiles the *other* tree's
`math.y`. Two consequences worth knowing before a measurement surprises you:
- a cross-build comparison run from one tree compiles the *same* std sources
  with both compilers, so a `std/` change shows up in no `compile_ir` delta —
  only the emitter change does;
- and a base compiler built in a worktree, measured from the main tree, answers
  with the main tree's behaviour and looks like it already had the fix. This
  cost an hour of chasing a phantom: a "before" binary produced the corrected
  answers, which is only explicable by the pack not carrying `math.y`.

`bench/y/*.y` are benchmarks, **not tests**. Times are wall clock on a shared
machine:
- a SCORE within 100 ± 2.5 is no change (two copies of one build scored
  99.7–100.6 in six runs; one real pair scored 99.8 and 102.3);
- a row of 40 ms or more agrees to ~8%;
- a shorter row swings by 20% or more (`bench/compare.sh ... 9` takes
  more samples).

Instruction counts are exact.

## Pipeline (`src/y/native.y`)

splice imports, pick the std units → per unit (the program's, each
package's under `ycc build` unless its object in `build/obj` is current,
and each std unit unless the std pack has it): strip namespaces (`strip_ns` for
nodes, `strip_type` for the annotations on them — a path import flattens both,
and a qualified `m.T` used to be rejected where the bare `T` compiled) → rename
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
- **`#{ … }#` is a meta block**: its body is compiled and *run* at compile time,
  and what it prints is spliced into the source in place of the block. Top level
  only — a block inside a `def` or `type` body is a diagnostic — and a block
  whose text ends mid-token drops those bytes and hoists the call to the
  enclosing top-level statement (`docs/src/02-lexical.tex`, "Meta blocks";
  `ideas/meta.md` for the design). The generator runs in a **forked child**, so
  a trap in a block is a diagnostic naming it rather than a dead compiler.
  Because the generator's top level runs too, a top-level statement in a file
  with a block must be a declaration — `lint.y` warns when it is not.
- **`ycc run FILE`** compiles and runs in one step; **`ycc -E FILE`** dumps the
  source the pass actually saw (blocks expanded), which is the way to see what a
  block generated.
- **`ndef f(params) -> T [= "label"];`** is a declaration with no body
  whose implementation is an assembly label (docs `03-grammar.tex`, NATIVE.md
  "Backend"). It is the way std modules reach raw machine primitives: the
  return type must be written, the label must start with `y_`, and the
  declaration must be at the top level under its own name. `ndef` is a
  reserved keyword.
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
- `const x = v` fixes the value as well as the binding: `=`, `op=`,
  `++`/`--`, element/field/map stores (`a[i] = v`, `r.f = v`, `m[k] = v`),
  whole-slice writes and the in-place `+=`/`*=` on a const array are all
  type errors -- `cannot modify 'a': it is a constant` for the ones that
  reach it through a place, `cannot assign to constant 'a'` for the ones
  that name it (which is what a package's globals are, and `test_pkg.sh`
  pins). Not the JS rule: a shared buffer is what `const` is for here. A
  pointer still launders it (`&a[0]`, `*p = 1`), which the checker does not
  follow.
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

- `src/y/arch/*.s` — the compiler's own assembly: the arch prelude
  (`prelude.s`: allocator, traps, string/array cores, `y_fmod`, float
  formatting), the float primitives `math.s` (`y_sqrt`, `y_to_int`, `y_fbits`,
  `y_bitsf` — what a `ndef` reaches for), the thread runtime
  (`threads.s`) and the Windows syscall self-test (`wselftest.s`) — embedded
  by both copies, see PORTING.md rule 12. Every kernel access goes through the
  named layer: std says `os_call("y_os_read", ...)` and the ELF body lives in
  `prelude.s` while the Windows body is a `replace:` block in `wsys.s`, so a
  raw `syscall` number in a file both targets use is a target bug — `math.s`'s
  two traps had Linux numbers and `math.to_int(1.0/0.0)` returned instead of
  trapping on a PE until they were routed through `y_os_write`/`y_os_exit`.
- `src/y/` — the Y compiler: `ycc.y` (driver), `pkg.y` (`ycc build`:
  `y.toml`, the dependency graph, git, `y.lock`), `lexer.y`, `parser.y`,
  `rename.y`, `types.y` (checker), `lint.y` (warnings), `native.y`
  (emitter), `meta.y` (the compile-time pass: `#{ … }#` blocks, run in a
  forked child over an in-RAM image), `arch_x64.y`
  (asm + prelude), `enc64.y`, `asm.y`, `elf.y`, `dwarf.y` (`-g` line
  info); `std/` (`rt.y` runtime
  in Y, `prelude.y` (`readline`), `exec.y` (`exec`), `str.y` (string
  methods) — the four embedded into the compiler — and `fs.y` (files,
  paths, directories: `import fs;`), `net.y` (TCP, DNS), `struct.y`,
  `math.y` (integers, bits, float comparisons and constants, RNGs, `[float]`
  array work: `import math;` -- no transcendentals yet, they need machine
  primitives Y cannot reach), `crypto.y`, `x509.y`, `tls.y` (a TLS 1.3 client), `regex.y` (patterns:
  `import regex;` — a Pike VM over bytes, linear time, no
  backreferences)).
- `src/c/` — the 1:1 C copy of the above + `yv.c`/`yv.h` (the value
  model; no Y twin). `PORTING.md` is the contract.
- `src/tools/lsp/` — the Y language server, `yserve` (an all-in-Y daemon:
  a `Content-Length` framer, `fork(2)` per message, the compiler's own
  diagnostics on an unsaved buffer), its VS Code extension under
  `vscode-y-lang/`, its own `test/` (fixtures + four shell harnesses +
  two node drivers), and `LSP.md` (the design). `make yserve` builds it
  and checks `cycc` and the reference agree byte for byte; `check-refs.py`
  and `check-names.py` (both in `test_lsp.sh`) police the citations and
  the shared namespace — the server path-imports the compiler, so every
  name it defines lands in the compiler's vocabulary. `check-names.py`
  also tests each module's **basename**, because `strip_ns` rewrites any
  `name.field` program-wide as a module reference (that is why `scope.y`
  is not `index.y`; §5 of `LSP.md` has the 42 reads it broke).
  `src/tools/lsp/test/` holds two **measurement programs** as well as the
  fixtures: `scope-coverage.y` reports what share of a corpus's
  identifier tokens the M4 index resolves, and `request-cost.y` what one
  request costs per phase. Neither has an expectation — they print, so
  the number can be quoted rather than remembered; run them by hand, as
  the fixtures are for shapes and these are for sizes.
- `src/tools/ytest/` — the test/metrics runner (`make ytest` → `./ytest`,
  `README.md`): it times each `test/sh` suite, and `coverage` builds a
  `gcc --coverage` C copy, runs a corpus through it and reports gcov line
  coverage per source file. A Y program, and a customer of `std/exec.y`'s
  `popen`/`pread`/`pclose`. Not a gate and not in `make test`.
- `refs/` — backed-up reference binaries for the port gate (see
  `PORTING.md` for where the current `ycc.ref` came from).
- `test/` — `test/sh/` (suite drivers + `lib.sh` + `ytool.sh` +
  `corpus_diff.sh`, which is `make corpus-diff`, not a suite, + `check.sh`,
  which is `make check`), `test/y/`
  (`native/` fixtures with expected/exit/stdin, `audit/` edge cases,
  `examples/` regression corpus, `ycc/` unit fixtures, `net/` servers
  for `test_net.sh`), `test/std/` (the std self-test suites + their
  goldens and the pty driver; `test_std_suites.sh`), `test/math/`
  (`ulp_table.txt` + `ulp_check.y` + the generators + `find_repeats.py`;
  `test_math.sh`),
  `test/COVERAGE.md` (feature → test matrix).
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
`for`/`for..in`/`foreach`/`while` with `break`/`continue` (a jump to a
label the enclosing loop published; `continue` runs the step or increment
first, and a jump out of a `def` nested in a loop is refused by the
checker, not left to the emitter); block expressions; `type` aliases
(recursive through a record field or a function type), record unions and
`match`;
threads (`spawn { }`, `join`, `mutex`/`lock`, `sem`/`post`/`wait`) as
`clone(2)`s, each allocating from a heap of its own through `%fs`, and
processes (`fork { }`, `wait_pid`); every exit is `exit_group`;
`def` params are annotated (or have a literal default; there is no
unknown type), return types are inferred. `ycc` is
native-only: `ycc [-o OUT] [-S] [-t] [-g] [-w] [--no-exec] [--std-src] FILE`,
cc-style (`-w`: no warnings; they go to stderr and never change the
output) (and `ycc build [DIR]` / `ycc vendor [DIR]` for projects with a
`y.toml`: NATIVE.md, *Packages*); the shipped binary needs nothing at runtime — it is a static
ELF invoking raw syscalls, carrying its std units precompiled (the std
pack, appended by `make ycc`).
