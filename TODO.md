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
- **`bench/` has no coverage for the std modules.** `io.y`, `net.y` and
  `struct.y` are exercised by one fixture each (`t10`/`t12`/`t20`, `t30`/`t31`,
  `t44`); the error paths, `listen_tcp`/`listen_http` (which block forever, so
  they have no test), `net`'s fd leak paths and most of `struct`'s writers are
  untested.
- remove profiling from ycc itself, instead add option to compile with debug symbols like ELF symbol table, symbols and other info, so we can use linux built in `perf` to do profiling. for microbenching use valgrind. also measure time spent in kernel space with strace. and heap expansion with brk & io. and for heap profiling with massif.
- remove py code
- move prelude into std
- readline is inefficient for large stdin
- determine project structure, dependency management, linking (with prebuilt dependencies so no rebuild needed) propose various methods pros and cons and ask the user
- replace `substr` with string slicing, and remove substr from built ins
- enforce `const` so they cant be reassigned values and will error at compilation
- template string with f"{x} {y:.2f}" (python style)
- string operations like trim, strip, pad etc shall be done like "str 1 2 3".split(' ')
- `arr.length` and `arr.ptr`
- optional arguments `def print(a: long, b?: long)`, b will appear as an option type, this is different from `b: long?` as `b: long?` requires you to supply an `long option` argument where `b?: long` require you to either supply or not a `long`. they must be at the end of arg list or type error is thrown.


## Done

Removed: items below were verified against the code and deleted rather than
kept as history. The decisions that still constrain the code live in
`AGENTS.md`, `PORTING.md` and `src/y/NATIVE.md`; the audit record (including
what was deliberately *not* changed) is in `audit.md`.

- Type aliasing — `type IntList = [long]; let a: IntList = [...]` and
  `type Pair = { x: long, y: long }` both check out (verified).
- **The memory spikes.** Self-compiling peaked at 32 GB and
  `test_all_imports.y` at >15 GB: the assembler re-copied the whole code
  buffer per patched item (O(n²)). It appends in place now (self-compile
  ~0.9 GB), and the suites run the compilers under a memory cap, so a spike
  fails a test instead of passing it (`edf4071`).
- **Fuzzing.** `test/fuzz/fuzz.sh` mutates the corpus and compiles each
  mutant with both compilers under a memory cap and a timeout; the parser
  findings (silently accepted garbage, guesses at malformed input) are fixed
  and each has an `e*` fixture (`d2ffa81`; see AGENTS.md "Fuzzing").
- **`ysh.y`** no longer uses driver flags that do not exist, and
  `test_ycc.sh` runs it (`4e9069f`).
- **`y_alloc` without `brk`.** Globals moving to `.bss` gave the allocator a
  writable home: it is a bump over 4 MB `mmap` chunks now, no syscall on the
  fast path (SCORE 176.73: compiles 60-70% faster, allocation-heavy programs
  up to 12x faster; valgrind no longer hits its 8 MB `brk` cap).
- **`join` is a byte mover again** (`y_str_join` in `arch_x64.y`): one
  sizing pass, one allocation, word copies — self-compile 9.9% faster,
  8.1% less peak heap.
- **`from_bytes` takes a fixed `[byte; N]`** (same header), which
  `y_str_chr` uses. Using it in `y_long_tostr` (`from_bytes(b)` then a
  string slice) measured 84% *slower* than the array slice, so
  `y_long_tostr` became an asm primitive instead: one `idiv` per digit and
  one allocation. `tostring`-heavy output got 27% faster. Programs also
  got much smaller (hello's asm 84% smaller), because the Y version used
  to ride along in every program via `y_float_tostr`.
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
