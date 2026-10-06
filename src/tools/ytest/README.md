# ytest — this repo's tests and their numbers, written in Y

`ytest.y` is a small test runner and metrics collector for the compiler. It
exists because the suites in `test/sh/` each print their own PASS/FAIL lines
and none of them puts the numbers in one place: this runs them, times them, and
— with `coverage` — measures how much of the compiler the corpus actually
executes.

It is a Y program, and it is a customer of the compiler's own features: the
`popen`/`pread`/`pclose` session in `std/exec.y` (added for exactly this kind of
tool), `std/fs` to walk `src/c`, and `clock_us()` for the times.

## Usage

```
make ytest                      # ./ycc src/tools/ytest/ytest.y -o ytest
./ytest suites                  # every test/sh suite, timed
./ytest suites native math      # just these
./ytest coverage                # gcov line coverage of src/c over a corpus
./ytest coverage a.y b.y        # over these programs
./ytest report                  # both, and writes ytest-report.md
```

## What `coverage` measures, and why `src/c`

Line coverage comes from **gcov**, which needs ordinary C: the framework builds
`gcc --coverage`'s version of the C copy, runs a corpus through it, and reads
the per-file `Lines executed: P% of N` gcov prints. The corpus defaults to the
self-compile (`src/y/ycc.y`, the heaviest workload the compiler has) plus a few
fixtures chosen to reach what one self-compile does not (the driver's errors,
the PE writer's target switch, the std modules).

The numbers are the **C copy's** lines. `src/c` is the 1:1 twin of `src/y`
(`PORTING.md`), so a Y source line and its C twin are the same line in the same
function; the honest caveats are that the CLI shims and `yv.c` have no Y twin,
and that the mapping is by construction rather than checked line by line.

## Notes

- `exec()` forks with `envp` NULL (`std/exec.y`), so every command here runs
  with an empty environment; `sh()` exports `PATH=/usr/bin:/bin` for the whole
  shell, or `gcc` cannot find its own `cc1`.
- gcov writes `.gcov` files next to the build, not in the tree: the build and
  every `gcov` call run in `/tmp/ytest-cov`.
- It is deliberately NOT in `make test`: a coverage run rebuilds the compiler
  with `--coverage` and runs a corpus under instrumentation, which is a
  measurement, not a gate. The gate for coverage is `test_coverage.sh` (the
  static diagnostic/builtin map) and `test/COVERAGE.md`.
