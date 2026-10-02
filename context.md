# context.md — handoff (uncommitted, delete when done)

## State

- On `master` (HEAD c52d942). Uncommitted, finished and blessed: bitwise
  operators, decimal `_` digit separators, the merged bench/ycc-perf work,
  fixtures e134–e139 and t140–t143, and docs. `make check` and `make rebless`
  passed. The new `refs/ycc.ref` sha256 starts with `a3dcb1a3`.
- The user's own files: TODO.md, the TODO.y deletion, future.y, PACKAGES.md
  and test/y/examples/tail.y. Leave them alone.
- Commit only when asked. Never push.

## Environment

- Build the docs with `cd docs && /home/yun/.local/bin/tectonic -X build`.
- Loop: edit src/y → port 1:1 to src/c → fixtures/docs/COVERAGE.md →
  `make check` (review every listed diff) → `make rebless`.
- Anything that affects performance goes on a `bench/*` branch, with the
  numbers in the commit message.

## Task queue

1. **Warning system (next; not started).**
2. Record/union redesign. Present the design to the user before coding.
3. http prerequisites, in order: optional record fields, a wall-clock
   builtin, DNS, pure-Y crypto + TLS 1.3, the http client, `http.session`.
   The style decisions are in memory `http-client-design.md`.

## 1. Warning system: the design

- New `src/y/lint.y` plus `src/c/lint.c`/`lint.h`.
  - Add lint.y to `YCC_SRCS` in the Makefile, and add a module row to
    PORTING.md.
  - Entry point: `lint_unit(ast, ast3) -> [{msg, line, col}]`.
  - lint.y uses `asm.labmap_*` for hash sets and `types.tstr` for display.
  - Prefix its type aliases with `Lint`; alias names are global.
- **Hook:** in `compile_unit` (native.y), on the success branch, as phase
  "lint".
  - Run it only for the user's unit and packages, not std units:
    `len(name) == 0 || pkg_base(base)`.
  - Add a `warnings` field to the results of `compile_unit`,
    `compile_package` and `emit_program`, in both copies.
- **Driver:** `print_native_warnings` mirrors `print_native_errors`
  (ycc.y). It prints `file:line:col: warning: msg` to stderr, only when
  compilation succeeds.
  - `-w` suppresses the output.
  - Add `-w` to the `ycc` flags, `ycc build`, the help text and AGENTS.md.
- **Port gotcha:** C `yr_get` on a missing field returns none, but Y traps.
  - Never read line/col from `void`/`optarg` nodes or from type nodes.
- **Simple rules.** Track whether a value is used:
  - a block's last statement inherits the block's flag; earlier statements
    are unused;
  - if-arms inherit only when the `if` has an else;
  - loop bodies and top-level statements are unused.
  1. Unused local variable/constant/function, and "assigned but never
     read". Skip top-level declarations, params, loop variables and
     `_`-prefixed names. The displayed name is the renamed name with its
     `$N` suffix removed.
  2. "unreachable code" after a statement that diverges (once per block).
     Lint keeps its own copy of `stmt_diverges`.
  3. "the result of 'OP' is not used" (add "did you mean '='?" for `==`),
     and "the value of 'x' is not used". Never warn on calls.
  4. "'x' is assigned to itself".
  5. `x < x` / `x > x` is always false. Do not warn on `==`/`!=`, because
     `x != x` is the NaN test.
  6. "division by zero" for `/`, `%`, `/=` and `%=` with a literal 0. A
     float `0.0` does not count.
  7. Duplicate key in a record or map literal (the last one wins).
  - Output: sort by (line, col, msg), then drop duplicates.
- **Duplicate-type rule.** It runs on the parse tree `ast`, which still has
  its typedefs.
  - What it compares:
    - record types with 2 or more fields, and union types, at any depth;
    - from let/const annotations, param and return annotations,
      rectest/narrow, and the subterms of typedefs.
  - How types are keyed:
    - by structure, interned through a labmap;
    - aliases are expanded, with a memo and cycle guard;
    - union members are flattened and sorted;
    - field order counts.
  - Skip any occurrence whose enclosing occurrence is already reported.
  - Messages:
    - "the type {…} is already declared as 'X'; use the alias"
    - "the type {…} is written out N times; name it with `type`"
    - "type 'B' is the same type as 'A'"
    - "type 'X' is declared more than once; the last declaration counts"
- **Tests:**
  - `test/sh/lib.sh` `run_parity`: also compare the compile stderr of the
    two compilers when both succeed.
  - `test_native.sh`: add `// expect-warning:` markers.
  - test_coverage.sh and coverage_diag.awk: warning sites need test
    expectations; add COVERAGE.md rows.
  - Expect `make corpus-diff` to flag every program that now prints
    warnings. That is the intended diff.
- **Then:**
  - Make std io/net/struct and ycc.y lint-clean, and enforce that with a
    test.
  - Replace the repeated inline record types in src/y with `type` aliases.
    The emitted code must stay identical. Targets: the `gen` emitter state,
    the rename state, the parser Tok, `{msg,line,col}`, the times row, and
    the inline Origin in `origin_at`, `find_dup` and `print_native_errors`.
  - `make check`, then rebless.

## 2. Record/union redesign (user direction)

- Dot access must use offsets fixed at compile time, with no runtime lookup
  tables. That removes `y_dot_lookup` and the per-literal `ytd_` tables.
- Remove the `{k: str}` shape-hole and dot access on unknown types
  entirely. Use unions instead:
  - every record carries a hidden type number;
  - dot on a union is allowed when every member has that field;
  - unions can be large and nested.
- Measured: `y_dot_lookup` is about 7.5% of a self-compile. Half of
  ycc.y's field reads are dynamic, from about 1,650 `{k: str}` uses.
- Staged plan:
  1. Add tags, union dot access and recursive aliases. Bless.
  2. Migrate src/y off `{k: str}`. Bless.
  3. Delete the shape-hole and lookup. Bump the pack/obj versions
     (`pack_version` also appears in test_link.sh, NATIVE.md and native.c).
- Open questions to ask the user, with recommendations:
  - type numbers: structural (recommended) or nominal;
  - union membership: exact (recommended) or by width;
  - unannotated params: should dot access on them be an error;
    recommended: yes.
- Repro of today's layout bug:
  `/mnt/Users/ZHAOYU/AppData/Local/Temp/probe_rec2.y`, run with
  `probe_run.sh`. Each line should print its "want" value.

## Known unfixed issues

- Decimal overflow wraps silently.
- A float literal with 20+ digits overflows.
- `p.a++` through a pointer is rejected.
- Rodata is not tree-shaken.
- The assembler can silently truncate an imm32.
