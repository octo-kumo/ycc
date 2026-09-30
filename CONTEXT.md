# CONTEXT.md — session state snapshot (2026-09-30, updated)

Working context for continuing the Y language / toolchain work. Read this
first, then `AGENTS.md` for build/test commands and `PORTING.md` for the
twin-copy contract.

## Architecture in one paragraph

C (gnu99/gcc) + Y for the `.y` language. `src/y/*.y` is the Y compiler
(10 modules + `std/`), `src/c/*.c` is its **1:1 copy** — same modules,
same functions, same semantics. There is no VM and no C backend. The
bootstrap: `make cycc` (gcc builds the C copy) → `./cycc -o ycc
src/y/ycc.y` → `make ycc` verifies `cmp ycc refs/ycc.ref` and a
self-compile fixpoint. **Both copies must always behave identically**
(the copy gate compiles every test with both and requires identical
output / byte-identical binaries).

**Bootstrapping rule (user's instruction):** when the Y side is stuck or
a change must land before the Y sources can compile, **update the C code
first** — `cycc` is built by gcc and does not rely on `ycc`. Then port
to `src/y` and re-verify.

## Goal (tracked in OpenCode goal, keep updated)

Target language state:
1. Operators: `x++/++x/x--/--x`, `+= -= *= /= %=` (exactly-once target
   evaluation); array `+` copy-concat, `+=` in-place push/append,
   `*=` in-place prepend, `::` cons (one element, right-assoc);
   homogeneous arrays; heap arrays with len/cap doubling.
2. Symbol ops only: `push`/`prepend`/`map_get`/`map_set` gone from the
   language; ycc's own source migrated to `arr += elem`.
3. Records vs maps (done): records static (`r.f`, fixed shape), maps
   dynamic `{K => V}` (hashable K, homogeneous V), keyed `m["k"]`,
   **read always yields `V?`**, literal `{"a": 1}`, `let m: {K => V} =
   {}` for empty maps; unannotated `{}` is the empty record. Lowered to
   a `{keys, vals}` record + synthetic AST (native.y "maps" section).
4. Byte strings `b"..."` / `b'...'` → `[byte]` (done).
5. Tail recursion: tail self-calls recycle the frame (done).
6. std/struct.y pack/unpack helpers (done).
7. Type redesign (done, both twins):
   - `void`: `if` arms that disagree make the `if` void (no more
     "'if' branches disagree"); void can't be bound / printed / passed
     (`'f' arg N: cannot pass a void value`) / returned as a value.
     `-> void` annotation discards the body tail; bare `return;` makes
     an unannotated def void (ret arm returns the value's type when the
     def's return type is being inferred).
   - `null` removed: no keyword, no `tnull`; `none` (predeclared id,
     type `topt<tunk>`, displayed "none") is the empty option; prints
     `none`. Internal "absent expression" AST placeholders are
     `{k: "void"}` (were `{k: "null"}`), typed `tvoid`.
   - Postfix `x!` = `unwrap(x)` (parser desugars to a call).
   - Map key types checked: `{foo => V}` is "not a native value type".
   - C value model renamed: `Y_NONE`/`yv_none`/`yv_is_none`,
     `Y_REC`/`yr`/`yr_get`/`yr_set`/`yr_has`.
8. Tests (done): native t46_maps, t47_none_void, e24–e28; comprehensive
   "Void" and "Options" sections; audit t23_none_eq, t51 now parity;
   ysh.y migrated (maps of functions, `h!(tokens)`) and dropped from
   native-examples UNSUPPORTED.
9. Docs updated (none/void/`!`/maps `{K => V}`); `tectonic -X build`
   in docs/ builds (tectonic 0.17 at ~/.local/bin in WSL).
10. Gates green: `make ycc` byte-identical, all suites pass.

## Environment note (Windows + WSL)

Work happens on Windows; build/test in WSL. The repo has local git
config `core.autocrlf=false`, `core.eol=lf` (the checkout must be LF —
CRLF breaks the shell scripts and the byte gates).

## refs/ (rebuilt on this machine)

`refs/` was absent here and was reconstructed: `refs/ycc-735f61c.ref` =
cycc@735f61c compiling src/y@735f61c (self-compile fixpoint verified);
`refs/ycc.ref` = the **Y-only bootstrap** of the current sources
(`ycc-735f61c.ref -o s1 src/y/ycc.y; s1 -o s2; s2 -o s3; cmp s2 s3`),
which the C copy must reproduce byte for byte. When the language
changes again, regenerate refs/ycc.ref the same way (a Y bootstrap
from the previous ref), never from cycc.

## Pending / ideas

- Maps are linear scans (fine for small tables); a hashed layout would
  need a bench run per AGENTS.md.
- Map literal keys are always `str` (no literal syntax for long keys;
  use an annotated `{}` + stores).
- test/y/ycc/{vm,partial,test_vm}.y are legacy snapshots (skipped /
  rejected by both compilers); they still mention `null`.

## Landmines / lessons (repeatedly hit)

- **Anchors must match exactly**, including em-dashes (`—` vs `--`) and
  indentation; `python3` heredoc scripts die on assert **before**
  writing — half-applied twins are the failure mode. After every edit
  script: `grep` the new marker in each claimed file.
- `str.replace(old, new)` in scripts asserts **count == 1**; long
  indented lines are substrings of deeper-indented lines (the `(only
  arrays)` message matched inside the `&`-arm at 20 spaces) — anchor
  with `\n` + exact indent.
- Y style in `src/y`: never empty blocks (`0;` fillers), if-arm tails
  must agree in type (`0;` idiom), params need annotations, `self` for
  recursion, bind `x.y[i]` chains once (C-parses-1:1 quirks), string
  comparisons on flow-inferred values need `:str`-annotated lets
  (pointer vs content compare — see teq note in types.y).
- Checker poison law: `tunk` unifies with everything; unannotated `[]`
  is `[<error>]`; single-`{k}` record shapes are holes (`single_k`) that
  unify with any record — this is how if-arms in `typeof_expr` agree.
- `refs/` is ground truth (gitignored, never overwrite `refs/ycc.ref`
  in place); stale `refs/cycc.ref` cannot compile migrated sources.
  If a copy divergence looks impossible, first verify the reference's
  self-consistency: `refs/ycc.ref -o self src/y/ycc.y && cmp`.
- Generated/embedded arrays in sources (e.g. std line arrays) sometimes
  need the same migration as real code.
- The `+=` wrap idiom: `X += [v]` pushes an array as ONE element; the
  checker catches wrong wraps when element types differ.
- Commits are unsigned (`git commit --no-gpg-sign`). Uncommitted work
  mid-stream is expected.

## Test suite layout (test/sh)

`test_port.sh` byte gate (cycc vs ycc vs refs), `test_native.sh`
(`t*` assert stdout/exit, `e*` assert compile rejection via
`// expect-error:` first-line marker), `test_comprehensive.sh` /
`test_loops.sh` inline cases, `test_examples.sh`, `test_audit.sh`
(65 edge cases), `test_ycc_units.sh`, `test_fixpoint.sh`,
`test_prof.sh`, `test_stdin_eof.sh`. Run subset:
`./test/sh/run_all.sh native audit ...`. Always `</dev/null` in scripts.
