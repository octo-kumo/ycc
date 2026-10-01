# TODO

## Not done

- **Match coverage is still not checked.** `match` requires a catch-all arm
  or arms covering every member of the subject's union. Verified still true:
  `match c { A a => 1, ({bfield: 10}) b => 2 }` on a `C = A | B` is rejected —
  a literal-value arm does not count as coverage. (The rest of `TODO.y` is
  likewise a list of things the checker still rejects.)
- **Exhaustive tests for every feature.** The audit corpus is 65 cases; the
  native corpus is 54 `t*` plus 25 `e*` fixtures. There is no coverage matrix,
  so "every feature has a test" is not currently a checkable claim.
- **Memory-growth tests.** Nothing asserts that memory does not grow for tail
  recursion (the frame-recycling path in `emit_one_fn`), and there is no leak
  test at all. `make test-asan` now works again (it exported `YCC`, which no
  suite read, so the sanitized build was never exercised) — that is the place
  to hang one.
- **Adversarial audit of ycc.** Bad input has not been fuzzed for crashes.
  Related, found during the 2026-09-30 audit and still open:
  - **`make test` hides a ~31 GB spike.** Self-compiling `src/y/ycc.y` peaks
    at 32.2 GB RSS (measured twice), and `make test` does it twice (the `port`
    and `fixpoint` suites). It passes on a quiet 64 GB box and OOM-kills
    anything else running. Nine parallel agents exhausted the machine twice
    this way and killed two agents mid-run.
  - **`test/y/ycc/test_all_imports.y` needs >6 GB** to compile (it imports the
    whole compiler); capped at 6 GB it dies with `out of memory` after 5.8 s,
    uncapped it reached 15.7 GB in 11 s. `test_ycc_units.sh` runs it under
    `timeout 20`, the compile finishes inside the window, and the suite logs
    a **pass** — so a 20 GB spike is invisible. Fix the fixture's timeout to
    be a memory limit, and look at the O(n²) `concat` path it stresses.
- **Performance, from the optimizer loop** (open levers, in measured order):
  - `y_alloc` costs two `brk` syscalls per allocation and sits under every
    string/array operation. Caching the break needs a home: `%r12` was
    rejected (the prelude helpers push/pop it, which would rewind the cache and
    hand out overlapping blocks) and the ELF has no writable segment — so this
    wants either a `.data` segment in `asm.y`/`elf.y` or a helper rework that
    frees a callee-saved register. Largest remaining lever.
  - `y_str_join` builds with push-per-byte (the `asm_text` joins move MBs per
    self-compile); either it returns to being a byte mover in `arch_x64.y` or
    the emit path stops joining into one string at all.
  - `from_bytes` could accept a fixed `[byte; N]` (the runtime already reads
    the same header), dropping an allocation from `y_long_tostr` and
    `y_str_chr`.
- **`bench/` has no coverage for the std modules.** `io.y`, `net.y` and
  `struct.y` are exercised by one fixture each (`t10`/`t12`/`t20`, `t30`/`t31`,
  `t44`); the error paths, `listen_tcp`/`listen_http` (which block forever, so
  they have no test), `net`'s fd leak paths and most of `struct`'s writers are
  untested.
- **`test/y/examples/ysh.y` uses flags that do not exist**:
  `exec("... --no-io --compile ...")` — `ycc` accepts `-o -S -t/--time
  --no-exec --prof -h` only. It is reachable solely through `eval`, so no suite
  ever runs it. Either give the driver those flags or fix the fixture.
- **`wasm/build.sh` is unverified.** It was rewritten to the current source
  list during the audit (it referenced 12 deleted pre-rewrite files and could
  not run), but emcc is not installed on this machine, so the command has
  never been executed.

## Done

Removed: items below were verified against the code and deleted rather than
kept as history. The decisions that still constrain the code live in
`AGENTS.md`, `PORTING.md` and `src/y/NATIVE.md`; the audit record (including
what was deliberately *not* changed) is in `audit.md`.

- Type aliasing — `type IntList = [long]; let a: IntList = [...]` and
  `type Pair = { x: long, y: long }` both check out (verified).
- Hex/binary literals with `_` separators, scientific notation, float literals.
- The `byte` type, with `[byte]` arrays packed (one byte per element).
- The runtime in Y (`src/y/std/rt.y` spliced into every program, tree-shaken),
  with `arch_x64.y` reduced to primitives; `readline`/`exec` moved too.
- Tree shaking (`prune_bodies`, `shake_refs`): a hello world is an 8 KB binary.
- Optional std modules imported by name (`import net;`, `net.xxx`).
- Return-type inference for unannotated `def`s.
- Reference semantics for arrays/maps/records; explicit-copy `+`; in-place
  `+=`/`*=`; `x op= e` with exactly-once target evaluation.
- JS/TS spread in record literals; lexicographic `str` ordering.
- Early `return`; short-circuit `&&`/`||`; postfix `x.y[i]`; `!x.y` meaning
  `!(x.y)`; empty blocks; dot-assign; `self` no longer shadowed.
- Closures with shared captured cells; `for`, `for x in lo..hi`, `foreach`,
  `range()`, slicing, structural array equality, anonymous `def` literals,
  calling an arbitrary expression, block expressions, `float`.
- **The "workarounds due to language limitations" question is answered.** The
  audit found that the ~60 "you must bind `x.y` once / `x.y[i]` misparses /
  the C VM evaluates `&&` eagerly" comments described a *bootstrap parser that
  no longer exists*. `src/c/parser.c` is a 1:1 copy of `src/y/parser.y`
  (one `parse_postfix` loop folding `(`, `[`, `.` into a node rebind), proven
  by compiling `o.x[1]`, `deep.a.b[2]`, `f.m.x[0]`, `mk(2).x[1]`, `!r.ok` and
  dot-assign under both compilers and getting byte-identical binaries. The
  root of the rot was a single wrong note at `src/y/parser.y:22-23` that cited
  AGENTS.md for the exact opposite of what AGENTS.md says; all copies are gone.
  What remains is the genuine cost: every workaround needs the same shape in
  the C twin, and a Y closure has no spelling in `yv.h`, so new closures in
  `src/y` should still be avoided.
