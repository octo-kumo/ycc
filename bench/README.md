# bench/ — benchmarks for ycc and for what it produces

Everything here is a **benchmark**, not a test: nothing under `bench/` runs
in the test suites, so adding weight here never slows `make test` down.
The programs are deterministic CPU workloads sized to run in ~0.05–0.15 s
each; the harness runs each measurement several times and takes the
median.

## The workflow for a change that can affect performance

1. **Propose** the change and say what you expect it to move.
2. **Branch** (`git switch -c ...`) — never benchmark in place.
3. **Build** both sides: `make ycc` on the base branch, save the binary,
   then `make ycc` on the branch.
4. **Bench**: `bench/compare.sh /tmp/ycc-base ./ycc`
5. **Decide** from the score and the per-function tables, and say which in
   the merge request. Revert or rework when the score regresses; a
   deliberate trade (say, faster compile / bigger binary) belongs in the
   commit message with the numbers.

```sh
make ycc && cp ycc /tmp/ycc-base       # while on master
git switch my-change && make ycc
bench/compare.sh /tmp/ycc-base ./ycc   # 5 runs per metric by default
bench/compare.sh /tmp/ycc-base ./ycc 9 # more runs = less noise
```

## What is measured

`bench/run.sh YCC [runs]` benchmarks one build and prints TSV
(`bench metric value`); `bench/compare.sh BASE NEW [runs]` runs it for
both and prints the deltas. Per program in `bench/y/`:

| metric | what |
|---|---|
| `compile_us` | wall time to compile the program |
| `run_us` | wall time to run the produced binary |
| `binary_bytes` | size of the produced executable |
| `asm_bytes` | size of `ycc -S` output |
| `self` (extra) | compiling `src/y/ycc.y`: also `asm_lines` and `heap_kb` |

`BENCH_SELF=0 bench/compare.sh BASE NEW` leaves out the `self` rows, for
a base build that cannot compile the current sources at all (one that
ran out of memory there, say); the score then covers `bench/y/` only.

**SCORE** = 100 x the geometric mean of `base/new` over every
(benchmark, metric) pair of `compile_us`, `run_us` and `binary_bytes`.
100 = no change; 105 = the new build is 5% better overall; below 100 is a
regression. The table above it is the detail — look at it, not only at
the score, because a big win on `self` can hide a loss on `strings`.

Small programs all produce an 8312-byte binary (the ELF is page-aligned),
so `binary_bytes` only moves once code crosses a page; it is most
informative on `self`.

## Per-function profiles

`compare.sh` ends by building every benchmark with **`ycc -g`** (symbol
table) on both sides, running each once under valgrind's **callgrind**,
and joining the two `callgrind_annotate` tables by function name —
instructions executed in each function's own body (self Ir):

```
--- lines   total Ir: base 918005565, new 917004120  -0.11%
  function                    Ir_base         Ir_new      delta
  readline                  451414505      450413060      -0.2%
  y_arr_push                273600055      273600055      +0.0%
```

Instruction counts are exact and repeatable — unlike the timings above
they do not move when the machine is busy, so they catch a 1% change
and say which function it lives in. They are not time: a cache miss
costs more than an add, which is what the run-time rows are for (and
`perf record` on a `-g` build, see `src/y/NATIVE.md`). The section is
skipped without valgrind; a function shown as `-` on one side is absent
there (renamed, or the build has no `-g`). Programs with no `.bss` (no
heap, no globals — `hello`) show raw addresses: valgrind attaches symbols
only to executables with a read+write file mapping.

## Adding a benchmark

Drop a `.y` file in `bench/y/`. Rules of thumb:

- **deterministic**: same output every run, no clock/IO/randomness, and
  print something so a wrong build is noticed;
- **sized**: ~50–150 ms of run time (fast enough to run many times, slow
  enough that timer noise is a few percent);
- **named after what it stresses** (`strings`, `arrays`, `fib`, ...), and
  put the work inside a function — top-level code lands in `_start` and
  the profile becomes one opaque row;
- never reference the network or files; benchmarks run anywhere. The
  one exception is a benchmark of I/O itself: `lines.y` measures
  `readline()`, and since the harness gives every benchmark stdin at
  `/dev/null`, it writes its input to a pid-named file under `/tmp`,
  `dup2`s it onto fd 0 and unlinks it before reading.

They are picked up automatically by both scripts — no registration.
