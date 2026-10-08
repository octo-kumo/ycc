# ytest — every test, gate and measurement of this repo, in Y

`./ytest` (`make ytest`, built by `./cycc`) replaces the shell and Python
drivers that used to live in `test/sh/`, `bench/`, `test/math/` and
`src/tools/lsp/`. `./ytest help` lists everything it does.

```
./ytest -j4                      # all 24 suites, four cases at a time
./ytest native port              # just these
./ytest list                     # the suite names
./ytest check                    # make check: build ./ynew, gate, compare with refs/ycc.ref
./ytest bench BASE NEW [runs]    # the benchmark comparison
./ytest fuzz [ITER] [SEED]       # mutate the corpus, compile with both compilers
./ytest gcov [files...]          # gcov line coverage of src/c (a measurement)
```

## How it is built

- `yt.y` — the core: a process runner over raw syscalls (its own process
  group, `RLIMIT_AS` from `YMEM_KB`, a timeout that kills the group and answers
  124, stdin from a file or a string, output to files), scratch space under
  `$TMPDIR`, and the case scheduler: a case is a name and a closure, run in a
  forked child, `-j N` at a time, its PASS/FAIL/SKIP lines streamed in order.
- `yc.y` — the compilers under test (`CYCC`, `YREF`, `YCC`) and the
  comparisons every suite makes: the port check (identical bytes and warnings),
  parity (identical behaviour), a reference run.
- `su_*.y` — one module per suite, each answering its `[yt.Case]`; `yos.y`
  is the os suite and the Y-OS session driver.
- The tools: `deadcode.y`, `pack.y`, `pty.y`, `lsp_e2e.y` (drives `yserve`
  over JSON-RPC and runs the node checks), `pe.y` (the Windows gates, under
  wine), `ydev.y` (check, bench, fuzz, fmt), `mpairs.y`, `mstatic.y` and
  `bigf.y` (the math audits, with an exact big-float reference), `cov.y`.

## What `gcov` measures, and why `src/c`

Line coverage comes from **gcov**, which needs ordinary C: it builds
`gcc --coverage`'s version of the C copy, runs a corpus through it, and reads
the per-file `Lines executed: P% of N` gcov prints. The corpus defaults to the
self-compile plus a few fixtures chosen to reach what one self-compile does not.
The numbers are the C copy's lines; `src/c` is the 1:1 twin of `src/y`
(`PORTING.md`), so they stand for the Y source by construction. It is not a
gate: the gate for coverage is the `coverage` suite over `test/COVERAGE.md`.
