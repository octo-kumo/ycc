# context.md — handoff (uncommitted, delete when done)

## State

- On `master`. Everything is committed and BLESSED: `refs/ycc.ref` =
  `58cfffb5` (4659fbf: the unknown-type runtime removed, descriptors one
  byte, ycc-std-pack 4 / ycc-unit 3; previous `c5dc23f0` backed up as
  `ycc.ref.pre-desc`). make test, ASan (native audit examples pkg,
  RSS-capped) and fuzz (1500, seeds 4242/4243) green. Before that,
  `c5dc23f0` (no unknown types; f3a5a9a). Since 02651975 (backed up as
  `ycc.ref.pre-nounk`): cycc and
  src/y have no unknown types (cb89e46, 7eec451, f1b147f, de7fc24,
  35a3a2d, dcaf4e9: `{k: str}` exact, no `..`, parameters annotated,
  `[]`/`none` free placeholders, forward calls need `-> T`, sound
  self-recursion inference, union -> member casts where the type is
  written; src/y annotated with the Node/Type unions by a gpt-6-luna
  sub-agent); the C copy's value model allocates 72% less (79cdce6:
  self-compile 6.6 GB -> 1.9 GB, 12.3 s -> 5.1 s); rename and ty_desc
  hotspots fixed (f3a5a9a).
  Older backups in the session's files folder:
  `ycc.ref.pre-open` (`297b2bb3`),
  `ycc.ref.pre-e145` (`ef862701`), `ycc.ref.pre-enc` (`f697b225`),
  `ycc.ref.pre-shadow` (`392d7a25`), `ycc.ref.pre-fs` (`aaece322`),
  `ycc.ref.pre-records` (`a7ab6a4e`), `ycc.ref.pre-lint` (`a3dcb1a3`).
- **MEMORY: every process runs under a cap below 4 GB** (the machine went
  down twice today: a partly annotated parser.y blew teq up, then
  valgrind of the old reference on the new ycc.y reached 9 GB). The
  Makefile's SHELL is test/sh/capped.sh; lib.sh, check.sh and the bench
  scripts cap themselves; run anything by hand as `(ulimit -v 3670016;
  timeout N cmd)`. ASan: `ASAN_OPTIONS=hard_rss_limit_mb=3500`. Hitting
  the cap means fix what allocates, never raise it (the user). The old
  reference cannot compile the new ycc.y (its teq blows up): under the
  cap it fails cleanly; compile_ir.sh shows "-" for it.
- CHOICES_MADE.md 25 (the user's model) is IMPLEMENTED and committed
  (e70fcdb), NOT blessed yet: a member held in a union is laid out with
  the union's shared fields first; casts (gen_as, match bindings) copy
  where the layouts differ (gen_convert); pattern field reads are in
  place (gen_narrow_field); my "binding is a view" refinement was dropped
  (CHOICES 25 says why). 376 programs: 15 compile differently (unions),
  none behave differently; make ynew, every suite with ynew green.
  Next: measure (check.sh), bless (back up refs as ycc.ref.pre-layout),
  make test, ASan, fuzz.
- The user REJECTED making field order part of a record type: `{a, b}`
  and `{b, a}` are one type, always.
- The user's own files: TODO.md, the TODO.y deletion, future.y, PACKAGES.md
  and test/y/examples/tail.y. Leave them alone.
- The user wants frequent commits now. Never push. No sed (edit tool).
- The user's note (2026-10-02, in README_AND_DELETE_WHEN_YOU_SEE_THIS.md,
  deleted after reading as it asked): do not ask questions until told
  otherwise; where a question would come up, choose (going for: less code
  overall, general, performance, smaller binary, less code for the Y user
  to write, an intuitive language, syntax sugar) and record the options,
  the assumptions and the choice in CHOICES_MADE.md (repo root).

## Environment

- Build the docs with `cd docs && /home/yun/.local/bin/tectonic -X build`.
- Loop: edit src/y → port 1:1 to src/c → fixtures/docs/COVERAGE.md →
  `make check` (review every listed diff) → `make rebless`.
- A change that affects performance gets a thorough bench + profiling at
  the end (`make bench`, `make bench-ir`, callgrind/perf), with the
  numbers in the commit message. No bench branch.

## Task queue

1. Warning system: **done** (uncommitted, blessed).
2. Record/union redesign: design **approved** (2026-10-02); stage 1
   in progress (uncommitted, NOT blessed yet -- `make ynew` + suites green
   after each sub-step):
   - 1a done: exact, order-free records (types.y teq/tcompat; width and
     void->record holes closed; src/y fixed: asm.y `[AsmItem]`,
     native.y gen_bin_rest else arm).
   - 1b done: canonical layout (sorted by name), `ytt_<fnv64>`
     descriptors (koff, shape31, field table) deduped per unit
     (`ty_seen`) and at link (rodata_pieces), `.k` of `{k: str}` via
     koff, y_rec_cast/gen_union_cast run-time checks in gen_as, pack 3 /
     unit 2. Prefix idioms fixed: set_inferred_ret, RnFunc (+defs),
     rn_func_body, rn_index, rn_decl (now `{k: str}`). Fixtures t145,
     t146, e140; t72 rewritten over a union.
   - 1c done: match/print by tag (gen_tag_in), union dot read/write
     (union_field, gen_union_slot), `{f: v}` patterns narrow to the
     sub-union, exact type patterns/coverage. Fixtures t147, t148, e141.
   - 1d done: recursive aliases. rename.y: every reference to a
     recursive alias is ONE shared tref node {k: "tref", name, tmp, to}
     (rn_tref, rn_reaches); a cycle outside every record field/function
     type is an error at the `type` (and the unknown type). types.y:
     unfold/members/union_parts/pat_members, teq_ref (canonical forms;
     unfold vs written-out types, 64 deep), tcanon moved here (back-refs
     `^N`), typeof_expr/infer unfold their results. Bidirectional record
     literals (typeof_want/lit_target/typeof_lit at let, args, returns,
     def tails, assignment, field/element/map stores, +=/*=, *p): a
     literal is created as the declared type or the union member with
     its field names (so `{x: 1}` into `{x: float}` converts now; e130
     updated). native.y: gen_decl's record literal goes through gen_as
     (it never did), tcode "Q"/"q" for trefs. Fixtures t149, e142, e87
     updated, test_pkg.sh 3b. The match-pattern "unknown type" error was
     dead and is gone.
   - 1e done: manual (04-types Records/Unions/Type aliases, 03-grammar,
     07-references, 10-errors), NATIVE.md, AGENTS.md, PORTING.md,
     COVERAGE.md; fuzz 1500/4242 clean; make test-asan (native, audit,
     examples, pkg) clean; make check, make bench, rebless.
   - Stage 1 numbers (make check / make bench ROUNDS=7 vs a7ab6a4e):
     compiled code differs for 61 of 369 programs (layout), behavior
     only for the new fixtures (+ two tests that print heap addresses);
     run instructions of every benchmark +0.00%; compile instructions
     +1.6..2.8% on the small benchmarks (most of it: tree shaking scans
     a 1.6% longer arch prelude -- y_rec_cast, its trap, two `add $16`),
     -1.22% on ycc.y (one descriptor per type instead of a field table
     per literal: asm lines -7.15%); self binary -13.0% (1134768 ->
     987312), heap -1.6%; SCORE 101.10 (check) / 100.09 (bench): no
     change in time. The new and changed functions cost 56M of the
     9.88G self-compile instructions (callgrind, self).
   - Stage 3 progress (blessed): rename.y's rn_shadow_dups finds
     redefinitions in one pass (rn_later: an open-addressing set from the
     back) instead of comparing every def with every later statement:
     ycc.y compile instructions -2.72%, outputs identical, bench SCORE
     99.98 (self compile_us -2.5%). Where y_dot_lookup (8.7% of the
     self-compile) comes from now, by caller (callgrind): the encoder's
     untyped operands (enc_mov 84M, op_size 82M, mem_tail 39M, rex_rm
     22M, enc_push 18M, ... ~280M), native.y's closure analysis (fv_walk
     42M, fv_binds 25M, app_walk 25M), types.y's type nodes (teq 37M,
     teq_fields 20M, field_pos 11M), typeof_expr_go 27M, strip_ns 22M.
     Typing those parameters (`o: Opnd`, ...) turns each read into a
     load behind one cast check at the call.
     Then (blessed): enc64.y's 44 operand parameters typed `Operand`
     (the alias moved there from asm.y; asm.y already built every
     operand with all 13 fields): ycc.y compile instructions -3.14%,
     benchmarks -0.3..-4.6%, outputs identical, SCORE 101.82, self
     binary 987312 -> 983216. y_dot_lookup is now 4.3% of the
     self-compile (407M); its callers are the AST/type walkers: fv_walk
     42M, teq 37M, typeof_expr_go 27M, fv_binds 25M, app_walk 25M,
     strip_ns 22M, teq_fields 20M, rn_node 12M, uses_scan_node 12M,
     lint_tw 12M, field_pos 11M -- the node unions of stage 3 proper.
     Then (blessed): a checker hole found on the way -- typeof_field
     tested for the {k: str} marker with teq, which lets every record of
     another width meet it, so reading a field a record type lacks
     (`{a: 1, b: 2}.c`, or `p.z` with `p: P`) compiled and trapped at
     run time. Now single_k: a compile error (e145); the self-compile
     never relied on it; unk_shape removed.
   - Open records (`{f: T, ..}`, step 1, blessed 02651975) were REJECTED
     by the user (the same backdoor as the hole); the step-2 rewrite was
     reverted unblessed. The plan now: no unknown type at all (State
     above; CHOICES_MADE.md 18-25). After the bless: remove the dead
     unknown-type machinery (y_dot_lookup, y_rec_has, y_rec_cast,
     gen_union_cast, layout_unknown, descriptor field tables/koff/shape31;
     pack/unit versions bump), then CHOICES 25 (written order is the
     layout) once the user has seen it.
   - Stage 2 (inference): a first cut (2a) was built and SHELVED, not
     blessed (CHOICES_MADE.md 11). The patch is in the session files
     folder, `stage2a-inference.patch` (types.y only, no C port):
     inference variables per def/param (hash table `inf_*`), argument
     types joined at direct calls (equal, numeric widening, `none` with
     T?), a param with an unknown argument / a conflict / an escaping
     def stays unknown, check_program re-run while solutions change
     (cap 4), solutions written into ptypes (inf_write), inferred
     returns reset between passes (inf_rets). It works (`def scale(x,
     f)` called with (2, 1.5) and (3, 2) types f float), but on src/y
     it types 14 of 604 unannotated params after one pass and 25 after
     four -- their arguments are holes/unknown -- while typecheck goes
     97 -> 467 ms (+28% self-compile). Superseded by the user's ruling
     ("if type cannot be inferred just ANNOTATE"): parameters are
     annotated; only returns and lets are inferred (CHOICES_MADE.md 18).
3. http prerequisites, in order: optional record fields, a wall-clock
   builtin, DNS, pure-Y crypto + TLS 1.3, the http client, `http.session`.
   The style decisions are in memory `http-client-design.md`.
4. (user's note) Move all file-system operations into `std/fs.y`: the
   global file builtins (read_file etc.) too, and every standard fs
   operation other languages provide; read/write as str or [byte], with
   modes. DONE and blessed (see "4. std/fs.y" below and CHOICES_MADE.md
   12-15).
5. (user's note) After everything else: read future.y, decide how best
   to implement multithreading and multiprocessing, and the http client;
   implement them.
6. (user's note) Profile ycc after adding all the features and optimize.
   Found so far: `y_arr_slice` (arch prelude) copies element by element,
   ~17 instructions a byte; a `rep movsb` path for [byte] would speed up
   every slice and fs.read_file (192M instructions of the self-compile,
   against 162M for the old byte-by-byte builtin).

## 4. std/fs.y and module scope: what was delivered

- `src/y/std/fs.y`: whole files (read_file/read_bytes/read_lines,
  write_file/write_bytes with a mode, append_*, copy_file), paths
  (exists, is_file, is_dir, file_size, rename, remove_file, set_mode),
  directories (make_dir, make_dirs, list_dir sorted, remove_dir,
  remove_all, cwd, chdir), fds with mode strings (open_file, read_some,
  read_all, read_all_bytes, write_text, write_data, seek, close_file).
  Manual 09-builtins "Files (the fs module)"; t150, t102 (fds), e143.
- The builtins read_file/write_file/write_bytes are gone (types, native,
  rt.y; the C twins). The compiler imports fs; the C copy keeps yv.c's
  helpers (PORTING.md rule 8). std/io.y is deleted (folded into fs).
- `import NAME;` modules keep their own scope (rename.y rn_top /
  rn_qualify / rn_lookup / rn_qualified; the origin map's `mods`;
  find_dup and unit_dfl qualify; export_name drops dotted names;
  is_id_b reads `.` in labels). Path imports still flatten. t151, e144,
  manual 03-grammar "Structure and modules", NATIVE.md "Optional std
  modules".
- Numbers (make check / make bench ROUNDS=7 / callgrind): 0 of 374
  programs compile to different code, run instructions +0.00% on every
  benchmark, binary sizes unchanged; compile instructions -2.5% to -12.7%
  per benchmark (hello -12.72%), ycc.y -1.14%, from rewriting `is_id_b`
  as a decision chain (241M -> 88M on the self-compile; the `.` check had
  cost +2.4% on hello). Rename +11M (+1.4%), reading sources +30M
  (fs.read_file vs the old builtin). SCORE 101.03; self heap +0.34%.
  Fuzz 1500/4343 clean; ASan native/audit/examples/pkg clean.

## 1. Warning system: what was delivered

- `src/y/lint.y` + `src/c/lint.c`/`lint.h`, run by `compile_unit` as the
  "lint" phase on the program's unit and packages (never a std unit);
  printed by `print_native_warnings` (ycc.y) as `FILE:LINE:COL: warning:
  MSG` on stderr; `-w` drops them; the bytes never change. The design is
  documented in the manual (10-errors.tex, "Warnings"), NATIVE.md,
  PORTING.md and AGENTS.md.
- Tests: `t144_warnings.y` and `// expect-warning:` markers in seven
  native fixtures; stderr parity in `run_parity`/test_port.sh; warning
  sections in test_ycc.sh and test_pkg.sh; coverage of every warning
  message; test_fixpoint.sh requires src/y/ycc.y and every src/y/std
  file (and `import io; import net; import struct;`) to compile with
  no warning.
- src/y is lint-clean: repeated record types became `type` aliases (Tok,
  Cursor, Parsed, Diag, Sym, TcSt, RnSt, EmitSt, Slot, Encoded, ElfSec,
  AsmSt, PkHash, ...), declared in the owning module and imported where
  used. Emitted code identical (verified before the 7 unused locals were
  removed); C mirrors them as `typedef Yv *` only in pkg.c and lint.c.
- `test/y/examples/pi.y`: `v;` → `v` (the lambda body was void, see the
  known issue below; the output is unchanged).
- Numbers (`make check`): compiled code identical for all 361 programs;
  run instructions unchanged; compile instructions +0.1% to +1.3%
  (ycc.y +1.25%, 9.305G → 9.421G); self-compile 1.275 s → 1.292 s;
  SCORE 98.59 (noise band). The 15 corpus diffs are warnings only.
- Checked too: `make test-asan` (native, audit, examples, pkg pass);
  `test/fuzz/fuzz.sh 1500 4242`: no findings.

## 2. Record/union redesign: design (approved 2026-10-02)

User direction: dot access at offsets fixed at compile time; no
`y_dot_lookup`, no per-literal `ytd_` tables, no `{k: str}` shape-hole,
no dot on unknown types; unions instead (a hidden type number per record,
dot on a union when every member has the field, unions large and
nested). Answers (2026-10-02): type numbers **structural**; union
membership **exact**; unannotated params **inferred**, an error only when
inference finds no solution.

Measured for this design:
- Layout bug (`/mnt/c/Users/ZHAOYU/AppData/Local/Temp/probe_rec2.y`, run
  with `probe_run.sh` next to it): all 11 cases print the wrong value,
  in both compilers. Reads use the static type's field order, a record
  is laid out in its literal's order, and width/order-free
  compatibility lets the two differ.
- `type L = {head: long, tail: L?}` "works" only because rename.y expands
  32 levels and leaves the innermost `L` a `tname`, i.e. a hole.
- `{a: 1, c: 2}` is accepted as member `A = {a: long}` of a union (width).
- Unannotated params: src/y 565 of 2,404 (455 of 983 defs); std 0;
  tests/examples 8 of 280 defs, each called with one type. src/y has
  314 written `{k: str}` holes. Typecheck ~110 ms of a self-compile;
  `y_dot_lookup` ~7.5%.

### Records
- A record type is its set of fields (name -> type); field order is not
  part of it. Layout is canonical: fields sorted by name, field i at 8i.
  A literal evaluates its fields in written order, stores each in its
  sorted slot. Printing keeps the static type's written order (a union
  member: as the union writes it).
- No width subtyping: a record goes only where its exact type, or a
  union containing it, is expected (with fixed offsets and records as
  references there is no other sound rule; today's width acceptance is
  what probe case 2 miscompiles). A language change: fixtures relying
  on it change in stage 1.
- Literals are checked against the expected type (bidirectional): into a
  union, a literal becomes the member with its field names, its values
  checked against that member's field types.

### Type numbers
- The word at -8 (now the `ytd_` table pointer) holds the address of the
  type's descriptor: one per structural type, label `ytt_<64-bit hash of
  the canonical form>`. Each unit (program, packages, std pack) emits the
  descriptors it uses; the linker keeps one per label. Descriptors carry
  the canonical form, so a hash collision is a link error, not a merge.
- Canonical form: fields sorted by name with their types' forms; unions
  as sorted, de-duplicated members; recursion as back-references.

### Unions
- `A | B` holds records whose type is exactly A or B; flattened, deduped.
- `match` type arms compare the tag (one compare, not `y_rec_has` per
  field name). Printing a union dispatches on the tag.
- `u.f` / `u.f = v` on a union: allowed when every member has `f` with
  one type. One offset in all members: one load; otherwise a branch on
  the tag per distinct offset. Other fields need a `match`.

### Recursive aliases
- An alias may refer to itself or to others cyclically when every cycle
  passes through a field, array, option, map or function
  (`type T = T | {a: long}` is rejected).
- Alias references stay named in the type tree, unfolded on demand;
  equality on cycles is coinductive. Printers of recursive types become
  per-type functions instead of unrolled code.
- Limitation: types equal only after unrolling differently
  (`{x: {x: A?}?}` vs `{x: B?}`) get different canonical forms: a type
  error, never a miscompile.

### Inference
- Inferred: def and lambda params without annotations; returns (as
  now, without tunk); the element type of `[]` and the payload of `none`
  in unannotated lets. A `let` keeps its initializer's type; only the
  unknown parts are inferred.
- Each unknown is a type variable. The checker runs as now and records
  what flows into each one (lower bounds): arguments into params (direct
  calls, calls through function values, defaults), values assigned or
  pushed, a function type expected where a lambda goes. Inside arrays,
  maps and function types the two sides must be equal, so variables
  there are merged (union-find).
- Solution = join of the lower bounds: equal types -> it; byte < long <
  float -> the widest; different records/unions -> their union; T? with
  none -> T?; (interim) a hole absorbs records. Anything else (long and
  str, [long] and [str], record and array) has no join.
- The checker repeats until no solution changes (they only grow;
  capped). Bodies are checked callers before callees (call-graph order,
  a cycle iterated), and a later pass re-checks only the defs whose
  inputs changed. A final pass with every variable replaced by its solution
  reports the errors: it is today's checker on a fully annotated
  program, so the solver cannot let an unsound program through.
- Solutions are written into the tree where annotations go (as inferred
  returns are now): the emitter sees a fully annotated program.
- Monomorphic: one type per param; a helper called with long and str is
  an error (split it). Generics stay "later" (per-call specialization
  would only accept more programs, so it can be added afterwards).
- Errors: nothing flows in ("cannot infer the type of parameter 'x' of
  'f': 'f' is never called; annotate it"; also a lambda never called or
  passed where a function type is expected, an empty array nothing is
  added to); no join ("...: it is passed long (line 3) and str (line
  7)"). Until stage 4, values of unknown type still exist (holes,
  tunk): a param that only ever receives those stays unknown, as today.
  A package's top-level def is typed from calls inside the package
  only (importers compile separately), so one not called there needs
  annotations.
- Cost: typecheck is ~110 ms of a ~1.85 s self-compile; with the order
  and the incremental passes the target is a few %, benched and profiled
  at the end.

### Stages (each: make check, review, make rebless)
1. Records and unions: canonical layout, order-free identity, exact
   membership, descriptor tags, tag match, union dot, recursive aliases.
   Interim: holes keep working (`.k` via k's offset in the descriptor,
   other fields via `y_dot_lookup`); a value of unknown type (tunk or
   hole) flowing into a precise record or union type is tag-checked at
   run time (trap), so the prefix idiom (`set_inferred_ret`'s `fnode`)
   traps instead of corrupting, and gets fixed. Fixes the probe. Bump
   obj/pack versions.
2. Inference engine. src/y changes only where it reports conflicts or
   uncalled defs.
3. Migrate src/y off `{k: str}`: union aliases for AST/type nodes,
   `match` where member-only fields are read. The C copy keeps its
   dynamic reads and mirrors split/renamed functions.
4. Delete holes (`{k: str}` becomes an ordinary record), tunk as a value
   (error poison only), `y_dot_lookup`, `y_rec_has`, the descriptors'
   field tables, the run-time casts. Bump obj/pack versions
   (`pack_version` also in test_link.sh, NATIVE.md, native.c).
- Every stage: the C port, fixtures (the probe as a t-fixture, an
  e-fixture per new error), COVERAGE.md, manual (types, unions,
  inference), NATIVE.md.
- Expected: stage 1 a few % slower on the self-compile (a hole's `.k`
  sits at offset 0 today; in canonical layout it goes through the
  descriptor, two more loads), `match` faster. Stages 3-4 are where the
  gain is: a self-compile spends ~23% in `y_str_eq` (much of it `k ==
  "..."` dispatch) and ~8% in `y_dot_lookup` (perf), which become tag
  compares and plain loads. Later, if profiles show union dot: dense link-time
  numbers with per-field offset tables (two loads).

## Known unfixed issues

- The checker accepts a void-bodied lambda where a function returning a
  value is expected: `apply(def(x: long) { x + 41; })` with `apply(f:
  (long) -> long)` compiles, and the call returns whatever is left in
  %rax. Lint warns on the dropped value; the type hole stays.
- The import splicer (`native_resolve_seen`) reads an `import` line
  whole: a trailing `// comment` becomes part of the path ("cannot open
  import"). Put the comment on the line above.
- A module's type aliases are not scoped (they join the program's), and
  a file imported both by path and by name keeps the mode of its first
  import.
- `make test-asan SUITES_ASAN=ycc`: "ysh eval" fails under LeakSanitizer,
  because std `exec` passes a NULL envp, so the spawned cycc-asan loses
  `ASAN_OPTIONS=detect_leaks=0`. Pre-existing; not a real leak.
- Decimal overflow wraps silently.
- A float literal with 20+ digits overflows.
- `p.a++` through a pointer is rejected.
- Rodata is not tree-shaken.
- The assembler can silently truncate an imm32.
