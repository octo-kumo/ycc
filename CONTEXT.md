# CONTEXT.md — session state snapshot (2026-09-30)

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
3. **Records vs maps (in progress)**: records static (`r.f`, fixed
   shape), maps dynamic `{K => V}` (hashable K, homogeneous V), keyed
   `m['key']`, **read always yields `V?` (option) even when the map type
   says `{K => V}`** (user's explicit rule), literal `{"a": 1}`.
   Terminology: record AST kinds say `"rec"`, "map" = dynamic type.
4. Byte strings `b"..."` / `b'...'` → `[byte]`, Python-style repr
   `b'...'` when printed (done).
5. Tail recursion: tail self-calls recycle the frame (done).
6. std/struct.y pack/unpack helpers (done).
7. **NEW — type-system redesign (just specified by user, NOT started):**
   - `void`: when no value should be returned. **When `if` arms don't
     agree on a type, the whole `if` becomes `void`** — it is then not
     usable as a value (no more hard "if' branches disagree" error;
     disagreement poisons to void instead).
   - `none`: the empty case of the option type (`T?` = `some(T)` |
     `none`). **Remove the concept of `null` entirely** unless a very
     good reason appears — `null` literal, `tnull` type, `== null`
     checks, `print(null)`, `typeof(null)`, bare `return` semantics all
     fold into `none`/`void`.
   - **Postfix unwrap shorthand: `var!`** ≡ `unwrap(var)` (unwraps an
     option). `unwrap` builtin stays.
   - Language surface to migrate: `test/y/**` uses `null` in t35
     (readline EOF), t43, e14, and `test_comprehensive.sh` expectations
     (`typeof: null`, `tostring: null`, `map: get missing` → `null`,
     `return: bare return is null`).
8. Tests for all of the above (in progress) — see below.
9. Docs (`docs/src/`, Tectonic v2 LaTeX) record everything and build.
10. Toolchain gates stay green (copy gate, fixpoint, all suites).

## Done and committed (recent, all unsigned commits)

- `735f61c` tests batch: t43_spread_cons, t44_struct_roundtrip,
  t45_byte_repr, e23_spread_nonrecord; fixed-array growth `a += 1` on
  `[T; N]` is a type error again (the types.y side had silently never
  landed — lesson: an edit-tool/python failure can leave the twin
  half-applied; always `grep` for the new message in BOTH files);
  t37 expected regenerated for byte reprs.
- Earlier: operators + `::` cons + record spread + TCO + byte strings +
  std/struct + print/tostring forms + symbol-ops removal + ycc source
  migration + docs (10 chapters, `tectonic -X build`).
- Suites were green **before the map work**: native 61/61, audit 65/65,
  loops 49/49, ycc-units 32/32; comprehensive 230/235 and examples
  13/14 — the only failures anywhere were the map-type feature (5
  comprehensive map tests + ysh.y).

## In flight: map type `{K => V}` (uncommitted)

### Y side (`src/y`) — COMPLETE and building
- `lexer.y`: `=>` two-char op.
- `parser.y`: map type `{ K => V }` in `parse_type_record` (separator
  `=>` vs `:` disambiguates from record shapes); map literal with
  quoted keys → node kind `"map"` (`maplit_node`); `map_key_type`
  (str/long/byte/bool/float, anything else stays `tname` for the
  checker to reject).
- `types.y`: `tmap` type (`{k: "tmap", key: K, of: V}`); map-literal
  arm (str keys, homogeneous values, `...` spread rejected); index read
  → `topt(of: V)` always; `idxassign` → writes `V`; `len` accepts maps;
  `print`/`tostring` accept maps; empty `{}` is an empty record, and
  under `let m: {K => V} = {}` the decl adoption makes it the map
  (`typeof_decl` + `gen_decl` lower it to the `{keys, vals}` shape).
- `native.y`: walkers (strip_ns/uses_scan/fv_ids/fv_binds) know
  `"map"`; `infer` types map literals and `tmap` dot-shape; dispatch
  routes `index`/`idxassign` to `gen_map_get`/`gen_map_set`; `print`/
  `tostring`/`len` handle `tmap`. **Lowering = synthetic AST over a
  `{keys: [K], vals: [V]}` record — zero new assembly** (see the
  "maps" section at the end of native.y: `gen_maplit` dedupes keys
  emit-time, `gen_map_get` scans and returns `some(v)`/`0`,
  `gen_map_set` scans and overwrites-or-appends, `gen_map_repr` builds
  `{"k": v, ...}` with quoted keys).
- **Branch-type trick (important):** `typeof_expr`'s if-arms must agree
  via `teq`; concrete record shapes only unify through the `single_k`
  hole law. `map_type_of(v) -> {k: str}` returns the tmap node through
  a `{k: str}` annotation so its flow type is the hole — without it the
  map arm disagrees with the rec arm (`'if' branches disagree` at
  ~6035 in the spliced build). Same idiom as `t_unk()`.

### Verified smoke
`let m = {"a": 1}; print(m["a"]);` → `1`; `print(m["b"])` → `null`
(null = today's empty option; becomes `none` after the redesign).

### C twin (`src/c`) — NOT STARTED (out of sync!)
Needs the same map work **plus** the terminology rename the Y side
already got (record nodes `"map"`→`"rec"`, `gen_map`→`gen_reclit`,
`rn_map`→`rn_reclit`) and, per the user, `yv.h`/`yv.c` renames
(`Y_MAP`→`Y_REC`, `ym*`→`yr*`). Doing the C side first is fine per the
bootstrapping rule.

## Pending next steps (in order)

1. **Type redesign, C first** (`src/c/types.c`, `parser.c`, `native.c`):
   - `if` arms disagree → result type `void` (tvoid), not an error;
     void not usable as a value (binding/returning/arguing it errors).
   - `none` replaces `null` everywhere (lexer kw, literal node, type
     `tnull`→none-case, comparisons, print/tostring/typeof output,
     bare `return`).
   - Postfix `!` = unwrap (parser postfix chain + emitter call
     `unwrap`-equivalent); `unwrap` builtin stays.
   - Keep `tnone` (missing-annotation marker) semantics intact — do
     not confuse it with the new `none` value.
2. **Port the same to `src/y`** (`types.y`, `parser.y`, `native.y`,
   `lexer.y`), keeping the twins 1:1 (same function names/structure).
3. **C twin map work + `"rec"` rename + `yv` rename** so the copy gate
   passes again.
4. **Migrate tests**: `null`→`none` in test/y/native/{t35,t43,e14},
   `test_comprehensive.sh` expectations; add fixtures for `!` postfix
   and void-if-arms (disagreeing arms legal as statements, error when
   used as values); map fixtures (t46+) for get/set/overwrite/new key/
   homogeneous/empty/literal; `dot-assign: string key form` test.
5. Fix comprehensive's 5 map-pending tests + examples `ysh.y`.
6. Rebuild docs (map section exists in draft: `{K => V}`, read `V?`;
   add `none`/`void`/`!`); `tectonic -X build`.
7. Full suites: `YREF="$(pwd)/cycc" ./test/sh/run_all.sh`, then `make
   ycc` gates (byte-identical vs refs + fixpoint), then commit
   (`git commit --no-gpg-sign`).

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
