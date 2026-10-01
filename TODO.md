# TODO

## Not done

- **`s += x` is quadratic in memory.** Strings are immutable, so each
  append copies the whole string, and nothing is freed: 10,000 one-byte
  appends allocate ~50 MB. Collecting parts and calling `join` is linear.
- **Prepend is quadratic in time.** `a *= v` moves every element: 100,000
  prepends take ~4.5 s.
- **`-g` has no line information.** It writes a symbol table, so tools name
  functions; DWARF (`.debug_line` + a minimal `.debug_info`) would let
  `perf annotate`, gdb and addr2line show source lines too. The map from
  the spliced program's lines back to files exists (the origin map,
  `native_resolve_x`); what is missing is line markers from the emitter
  through the assembler.
- determine project structure, dependency management, linking (with prebuilt dependencies so no rebuild needed) propose various methods pros and cons and ask the user


## Done

Removed: items below were verified against the code and deleted rather than
kept as history. The decisions that still constrain the code live in
`AGENTS.md`, `PORTING.md` and `src/y/NATIVE.md`; the audit record (including
what was deliberately *not* changed) is in `audit.md`.

- **Float negation was `0.0 - x`.** Unary minus on a `float` subtracted
  from zero, so `-0.0` was `+0.0` and `1.0 / -0.0` was `+inf`. It now
  flips the sign bit (`mov $1, %rcx; shl $63, %rcx; xor %rcx, %rax`,
  three instructions instead of five), exact for every value (`t137`).

- **`==` on two options compared boxes**, so `some(1) == some(1)` was
  false, and so were `[[1, 2]] == [[1, 2]]` and `[some(1)] == [some(1)]`
  (array elements compared as words). Decided: structural. Two options
  are equal when both are none or both hold equal payloads; an array
  compares each pair of elements with the element type's own `==`, at
  any depth; records and maps stay identities. Floats inside arrays now
  compare as numbers (`[0.0]` equals an array holding a negative zero),
  where `y_arr_eq` compared bit patterns. `gen_eq_vals` dispatches,
  `gen_eq_opt` and `gen_eq_arr_deep` are inline; flat arrays of words
  and of strings keep `y_arr_eq` / `y_arr_eq_str`, and `x == none` stays a
  word test (`t136`). No program in the corpus compiled differently;
  compiling costs +0.01% instructions.

- **Map reads allocate.** A map read is an option, and an option is a
  heap box, so every `m[k]` cost 16 bytes, even `m[k] == none`; the bump
  allocator never frees, so a read-heavy loop grew the heap with every
  read. Maps are now `{keys, vals, boxes}`: `boxes[i]` caches the box of
  `vals[i]`, made by the first read after a write and shared by later
  reads; a write clears it, and a reader holding the old box keeps the
  old value. Reads whose option cannot escape box nothing: `m[k]!` and
  `unwrap(m[k])` read `vals[i]` (a miss traps like `unwrap(none)`), and
  `is_some(m[k])`, `m[k] == none` and `m[k] != none` (`none` on either
  side) test the scan's result. Per 1000 reads: `m[k]!` 16000 → 0 bytes,
  the counting idiom (`m[k] == none`, then `m[k] = m[k]! + 1`) 32000 → 0,
  an escaping read of an unchanged entry 16000 → 16 (`t101`, `t135`).
  - Fixed on the way: adding a key whose value is an array whose type
    unifies with `[V]` (`m["y"] = []`, or `[[]]` in a `{str => [[long]]}`)
    appended the array's *elements* to `vals` (the `+=` concatenation
    rule), so `keys` and `vals` fell out of step and printing the map
    failed with "index out of bounds". A new key is now pushed onto each
    array.
  - The key scan pulls its bound in on a hit (`while (i < j) { if
    (keys[i] == k) { j = i } else { i = i + 1 } }`, `keys` hoisted)
    rather than testing `i < n && keys[i] != k`, which materializes a
    bool every step.

  New benchmark `bench/y/maps.y` (counting, escaping lookups and misses
  over 64 string keys): run time −6.2% (71.3 → 66.9 ms), instructions
  −1.5% (786.4 → 774.6 M), heap 2.88 → 0.68 MB; asm +6.3% (the cache
  code), binary size unchanged, compiling it +2.2% instructions. Programs
  without maps compile to the same binaries, with +0.03–0.05% compile
  instructions (the peephole checks); the self-compile +0.01%.

- **Cross-file duplicate definitions.** Imported files share one
  namespace, where a later def replaces an earlier one. `find_dup`
  compared names after rename had made them unique, so it never fired.
  An importer's `def helper` silently replaced a module's own `helper`,
  for the module's callers too, and when two modules both defined
  `helper`, both got the second (`e132` compiled and printed `bb`). Now a
  top-level def that replaces one from another file is an error at the
  later def, naming the other (`m132/a.y:5 defines it too`).
  Redefinition within one file still means last wins (`t30`), and the std
  code the compiler splices in can still be replaced (`t134`: a
  program's `readline`, a module's `clear_eof`). To tell files apart,
  `native_resolve_x` builds an origin map (each spliced line → its file
  and line), and the driver prints error positions through it.
  - An error in an imported file reads `path:line:col`.
  - An error below an import is no longer pushed down by the module's
    length: `e133` used to report 10:23 and 13:1 for the module's 9:23 and
    the program's 9:1, and `e34` now reads 8:9, not 80:9.
  - `e*` fixtures compile from their own directory, so module paths in
    their messages do not depend on the machine.

  Every benchmark and test program compiles to the same binary. Compile
  instructions: single-file programs +0.1% (mapping the runtime chunk's
  lines); programs with imports −0.4 to −0.6%; the self-compile −0.8%
  (17.456 → 17.317 G), with peak RSS 810 → 808 MB.

- **Inferred return types.** Without `->`, the checker typed each
  `return e` against the unknown type and never related it to the type it
  inferred from the body's trailing value. The emitter then re-inferred
  the type from the tail expression alone, which cannot see the body's
  `let`s. So `def f(c: bool) { if (c) { return 1.5; }; 2 }` made
  `f(true)` print the double's bits, `def g() { let y = 0.5; y }` printed
  4602678819172646912, and `1 + s()` with a string-local tail printed an
  address. Now the checker notes every `return` of an inferred def and
  checks it against the inferred type once the body is done. A `return`
  converts like any store (`return 1` under a `2.5` tail gives 1.0), and a
  valued `return` in a def that ends in a statement (void) is an error
  (`e131`). When the tail is a `self` call, the first `return` with a
  value decides; an `if` arm of unknown type takes the other arm's. The
  checker records the inferred type in the def node, where `-> T` would
  be, so the emitter types calls, `self` and returns as the checker does.
  `t133` covers 19 cases; the old compiler got 14 of them wrong. Every
  other test program and benchmark compiles to the same binary as before.
  Two legacy `test/y/ycc` fixtures that were already rejected now list
  different follow-on errors. Self-compile: 17.3087 → 17.3089 G
  instructions (+0.001%), heap +37 KB of 809 MB.
- **Implicit numeric conversions.** The checker admitted long→float,
  byte→float, byte→long and long→byte at annotated positions, but the
  emitter converted only inside float arithmetic: `let g: float = 3`
  printed 0.000000 and `let b: byte = 258` kept 258. Every store under a
  known type now converts (`gen_as`/`gen_conv` in `native.y`): `let` and
  assignment; arguments to direct, indirect, `self` and tail calls;
  returns and trailing values under a declared return type; element,
  field, map and pointer stores; array literals, `[v; n]`, push, prepend
  and `::`; and `+`/`+=` between arrays of different element types,
  element by element. A byte store masks to 8 bits, and `{ b += 300 }`
  yields the stored value. A record field cannot convert, because the
  record is shared, so the checker now requires exact numeric field types
  (`e130`). `t132` covers 51 store paths. Bench: every benchmark's output
  is identical (asm, binary and instruction counts); the self-compile went
  2.26 → 2.28 s (+1.1%, within noise) and its heap grew 0.1%.
- **Exhaustive tests.** `test/COVERAGE.md` maps every section of the
  manual to the tests that check it, and `test_coverage.sh` (in
  `make test`) keeps it honest: each of the 286 diagnostic sites in the
  compiler sources is expected by a test (276) or excused with a reason
  (10); all 59 documented builtins and methods are called by a checked
  test; all 12 keywords are used; all 72 manual sections have rows (86
  rows, 269 test references, each of which must exist). The native corpus
  grew from 54 `t*` + 25 `e*` fixtures to 98 + 109. The new tests found
  five bugs, four fixed: an unterminated block comment was silently
  accepted (fatal now, `e113`), a missing record field's runtime trap
  segfaulted (`t130`), the import-depth error exited 0, and `cycc -S`
  ignored a failed write. The fifth, duplicate definitions, is fixed too
  (see above). The manual's Assignment section was wrong: `=` and `op=` are
  statement forms (`t131`, `e129`).
- **Memory-growth tests.** `t100`: tail calls (through `self`, through the
  function's own name with `return`, and a void body's last call) run 10
  million levels in one frame — a local's address never moves. `t101`: a
  million iterations over existing data allocate 0 bytes; growing an array
  with `+=` or `*=` (8-byte and packed elements) costs at most 4x the
  payload; `join` allocates once; options and map reads cost at most 16
  bytes each. UBSan is fatal in `make asan` now
  (`-fno-sanitize-recover=all`), which exposed a signed overflow in the C
  copy's assembler (`parse_num_go` wraps unsigned now); a sanitized sweep
  of all 349 test programs is clean.
- **std module tests.** `t102`–`t110` cover `io` (round trip, error
  returns), `struct` (every writer and reader, out of bounds, unknown
  names) and `net` (error returns, fd I/O, `http_head`, response parsing;
  2,000 refused connects leak no descriptor). `test_net.sh` runs
  `listen_tcp` and `listen_http` servers built by both compilers, including
  100 connections under `ulimit -n 32`. Benchmarks `bench/y/std_io.y`
  (median 98 ms) and `bench/y/std_struct.y` (154 ms).
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
- **`readline` is buffered**: one `read(2)` per 16 KB instead of one per
  byte, and lines are sliced out of the buffer. `bench/y/lines.y` (5 MB of
  short lines) went from 1.25 s to 0.10 s. `exec` gives the unread part
  back to a seekable stdin before it forks (`t58_readline_exec`). On a
  pipe, buffered bytes stay with the parent, as with C stdio. EOF is
  still not latched.
- **`--prof` is gone; `ycc -g` writes a symbol table instead.** Section
  headers and `.symtab` (functions, runtime helpers, globals, by source
  name) go past the loaded image, so a `-g` build runs the same code at
  the same addresses. With it, perf, gdb, nm/addr2line and valgrind name
  functions (callgrind for exact instruction counts, massif with
  `--pages-as-heap=yes` for the mmap heap, `strace -c` for syscall time).
  `bench/compare.sh` now ends with a callgrind table per function.
  `test_debug.sh` checks it all.
- **`TODO.y` compiles, and its examples are tests.** The one rejected
  case, `match c { A a => 1, ({bfield: 10}) b => 2 }` on `C = A | B`, is
  rejected by TODO.y's own rule (arms must cover every case): a value
  pattern matches only the values it names. The error now says that
  (`e55`). `t65` tours the rest; `t61`/`t64` are its array examples:
  `[[T]] + [T]` appends the row, `[T] + [[T]]` prepends it, `[[T]] +
  [[T]]` concatenates (sharing the rows), and `+=` reads the same way
  (`e21` now rejects a row of the wrong type instead).
- **`const`** cannot be rebound: `=`, `op=` and `++`/`--` on one are
  type errors, while what it names stays mutable (`+=` on a const array,
  element and field stores), as in JS (`t59`, `e45`–`e47`).
- **`arr.length`, `str.length`, `arr.ptr`** (`t60`, `e48`, `e49`). On the
  way: `*p` / `*p = v` through a `*byte` moved 8 bytes, reading the
  neighbours and clobbering them on a store; it moves one now (`t62`).
- **Optional parameters** `def f(a: long, b?: long)`: `b` is a `long?` in
  the body; a call passes a `long` or nothing. Passing an option, giving
  one a default, or a required parameter after one are errors (`t63`,
  `e50`–`e54`).
- **`substr` is gone; strings slice.** `s[a:b]`, `s[:b]`, `s[a:]` (clamped
  like array slices) replace it everywhere — the compiler's own ~170 call
  sites, both copies, the tests and benches. The slice is an asm primitive
  now (`y_str_slice` took over `y_str_substr`'s body), where it used to be
  a Y wrapper around `substr`. Calling `substr` says what to write instead
  (`e56`). The C copy's twin is `ys_slice`/`ys_slice_from`.
- **The runtime is plain std files; no Python left.** `std/rt.y`,
  `std/prelude.y` (readline) and the new `std/exec.y` are ordinary Y files
  now, where they used to be `def rt_lines() -> [str]` line arrays with a
  Python script (`tools/gen_std_lines.py`) generating their C twins. The
  compiler carries them through a new declaration, `embed NAME from
  "path";` (a str const with the file's bytes, read at compile time, line
  numbers kept: `t66`, `e57`, `e58`); the C copy embeds the same files with
  the assembler's `.incbin` (`Y_EMBED`). Programs compile to the same bytes
  as before.
- **String methods**: `"str 1 2 3".split(" ")`, `s.pad_left(5, "0")`,
  `", ".join(xs)` (`t67`, `e59`–`e63`). Any `str` takes the string
  builtins as methods, plus `trim_start`/`trim_end` (`lstrip`/`rstrip`),
  `pad_left`/`pad_right`/`center`, `starts_with`/`ends_with`/`contains`,
  `count`, `replace`, `upper`/`lower`, `repeat` and `lines`. Those are Y
  helpers in a fourth embedded file, `std/str.y`, spliced only when the
  program mentions one of their names. One table (`str_method` in types.y)
  feeds both the checker and the emitter. Method names stay usable as
  ordinary names. On the way, the splice-trigger scan became one
  lexer-faithful pass over whole words (`words_seen`). The old one stopped
  reading at the first `/* */` comment, so `readline()` after one failed
  with "undefined function". A `//` inside a string literal also hid the
  rest of its line (`t68`). The new scan also avoids 16 whole-text
  `index_of` scans, which had cost 10% of a self-compile.
- **F-strings**, Python style: `f"{name} is {age:>3} ({share:.1%})"`
  (`t69`, `e64`–`e73`). The lexer lowers one to a concatenation of its
  text and `#fmt(e, "spec")` calls; a field without a spec is
  `tostring(e)`. The spec is Python's mini-language (fill, align, sign,
  `#`, `0`, width, `,`/`_`, precision, `s d x X o b c f F e E %`), read
  and checked against the field's type at compile time, and formatted by
  `y_fmt_*` helpers in `std/str.y`. Floats print exactly, rounded half
  to even. `t69`'s 1139 Python-checked cases match `format()`
  byte for byte. Fields may hold any expression (strings, nested
  f-strings, calls), may span lines, and errors inside them point into
  them. The documented differences: no spec means `tostring`, a typeless
  float spec means `f`, `bool` is text, no `g`/`n` and no nested fields.
- Hex/binary literals, scientific notation, float literals. (`_` digit
  separators work in `0x`/`0b` literals only — a decimal literal stops at
  the first `_`, and `_` is a word character so the tail lexes as an
  identifier. Corrected in the docs on 2026-09-30; this list had claimed
  "any position".)
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
