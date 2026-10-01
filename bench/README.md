# bench/ — benchmarks for ycc and for what it produces

Everything here is a **benchmark**, not a test: nothing under `bench/` runs
in the test suites, so adding weight here never slows `make test` down.
The programs are deterministic CPU workloads sized to run in ~0.05–0.15 s
each; the harness runs each measurement several times and takes the
median.

## The workflow for a change that can affect performance

1. **Propose** the change and say what you expect it to move.
2. **Branch** (`git switch -c ...`) — never benchmark in place.
3. **Build** both sides: the base is normally the last blessed compiler,
   `refs/ycc.ref`; `make ynew` builds the branch's `src/y` as `./ynew`.
   For another base, `make ycc` on it and save the binary.
4. **Bench**: `make check` measures as part of checking the change (see
   AGENTS.md, "Changing the compiler"); `make bench` alone runs
   `bench/compare.sh` on copies of the two under `/tmp`.
5. **Decide** from the score and the per-function tables, and say which in
   the merge request. Revert or rework when the score regresses; a
   deliberate trade (say, faster compile / bigger binary) belongs in the
   commit message with the numbers.

```sh
make check                             # verify, then compare + time vs refs/ycc.ref
make ynew && make bench                # refs/ycc.ref vs ./ynew, 5 pairs a row
make bench ROUNDS=9                    # more pairs = less noise
make bench-ir                          # exact compile instruction counts
make ycc && cp ycc /tmp/ycc-base       # another base: build it there
make bench BASE=/tmp/ycc-base NEW=./ycc
bench/compare.sh /tmp/ycc-base ./ycc 9 # the script itself
```

## What is measured

`bench/run.sh YCC [runs]` benchmarks one build and prints TSV
(`bench metric value`). `bench/compare.sh BASE NEW [runs]` measures the
two in **pairs** — a run of base and a run of new back to back, the order
flipping every pair — and compares each side's median. Load on a shared
machine comes in bursts of seconds: measured in separate passes, one side
caught a burst the other missed (two runs of the same binary differed by
up to 37% per row that way, still by 25% with ten samples per pass);
paired, a burst lands on both sides alike. A time row takes `runs` pairs
(default 5; 3 in `make check`), more while they add up to under 0.2 s (ten
at most), and always an even number, so each side goes first as often.
Sizes are exact and measured once. The compiles read a copy of `src/y`
and `bench/y` under `/tmp`, and the benchmarks run there: under WSL a
read from `/mnt/c` goes over 9P, slow and noisy (`std_io` ran 50x
slower there). Per program in `bench/y/`:

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

How much of it is noise, on a shared laptop (WSL, a hybrid-core CPU):
two copies of one build scored 99.7–100.6 in six runs, and one pair of
real builds 99.8 and 102.3 on two runs, so read a SCORE within 100 ± 2.5
as no change. A time row of 40 ms or more agrees to ~8%; a shorter one
(the small compiles, `hello`, `std_io`, `closures`, `strings` runs)
swings by 20% and more, whichever statistic — process start and the core
a run lands on dominate it. So `make check` shows only the long rows that
moved 10% or more, and a short row's real cost is its instruction count
(below).

Small programs all produce an 8312-byte binary (the ELF is page-aligned),
so `binary_bytes` only moves once code crosses a page; it is most
informative on `self`.

## Per-function profiles

`bench/profile.sh BASE NEW` — the last section of `compare.sh`
(`BENCH_PROFILE=0` leaves it out; `make check` runs it beside the tests)
— builds every benchmark with **`ycc -g`** (symbols and line info) on both sides,
runs each once under valgrind's **callgrind**, all side by side (`YJOBS`
at a time, default every CPU), and joins the two `callgrind_annotate
--auto=no` tables by function name — instructions executed in each function's own
body (self Ir):

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

## Compile instruction counts

`compile_us` is wall time: on a small program its noise (see above) is
larger than most changes in compile work.
`bench/compile_ir.sh BASE NEW` (`make bench-ir`) runs both compilers under
valgrind's cachegrind (`--cache-sim=no`: the instruction count alone) on
every `bench/y/` program and on `src/y/ycc.y`, and prints the
instructions each executed with the delta (here: the map read cache,
commit 9a07f3f):

```
program                Ir_base          Ir_new    delta
arrays.y              73405227        73433365   +0.04%
maps.y                94405068        96506463   +2.23%
ycc.y              17456984976     17458554313   +0.01%
```

The counts are exact, so a 0.1% change in compile work shows: two copies
of one build print equal counts (both run from one directory under names
of one length, as the compiler spends instructions on its own path and
on the output path). They do not depend on machine load, so the runs go
side by side, `YJOBS` at a time; `ycc.y` takes ~1 min under valgrind.

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
  explicit I/O benchmarks are exceptions: `lines.y` measures
  `readline()`, so it writes a pid-named input file, `dup2`s it onto fd 0,
  and unlinks it before reading; `std_io.y` writes a short-lived file in
  the benchmark's working directory and removes it after reading.

The standard-library benchmarks are:

- `std_struct.y` exercises `pack`, `unpack`, and fixed-width getters in a
  hot loop.
- `std_io.y` writes and reads a 2 MiB file in 4 KiB chunks, checks the
  byte checksum, and removes the file from the benchmark's working
  directory.

They are picked up automatically by both scripts — no registration.
