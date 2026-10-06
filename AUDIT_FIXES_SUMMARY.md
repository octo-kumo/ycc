# Audit Fixes Summary — y compiler

## Overview
This document summarizes the work done on the compiler audit fixes in the worktree `/tmp/opencode/auditfix` (branch `audit-fixes`). The goal was to fix legitimate open audit findings from `compiler-audit/agentN/REPORT.md` and work through `TODO.md` language-feature items, one commit each.

## Completed Work (28 commits, all green)

| Commit | Item | Description |
|--------|------|-------------|
| `18d6faa`... | Audit findings | 18 earlier commits fixing agent1 F4/F8, agent5 F1, agent7 a7-01/a7-03, agent10 A2, agent12 F5, agent13 F3, agent16 R1, agent2 A8/A9, agent18 P1-2/P1-3/P2-2/P1-5(half) |
| `9d8d61d` | TODO 10 | `.field` on a map (`m.k`), plus `values(m)` |
| `022e10a` | TODO 7 | Byte literals with `b` suffix (`129b`, `0b10001b`, `0bx1b`) |
| `9deb441` | TODO 3 | `json{ … }` JSON literal, desugaring into `std/json.y` constructors |
| `16d77eb` | TODO 14 | Presence test `\"k\" in m` (infix operator using existing `in` keyword) |
| `168d81c` | TODO 9 part 1 | Shared `radix_of`/`radix_start` factoring (retired `num_is_float`/`lit_is_float` duplication) |
| `155f451` | TODO 9 part 2 | Octal literal `0o644`, `0o7_5_5`, diagnostics for `0o8` |
| `b0d0fb4` | TODO 9 part 3 | `std/fs.y` modes as octal literals (byte-identical compiler) |
| `68fc457` | TODO 5 | Labelled `break L` / `continue L` with shadowing semantics |

### Current `refs/ycc.ref`
- SHA: `12653534af75911f` (after item 5)

## Key Technical Decisions

### Item 10: Map dot (`m.k`)
- `m.k` **traps** on missing entry (user chose trap over `none`)
- Dot types as `V` (the map's value type)
- `m.length` = entry count; `keys`/`values` are the map's API
- `values(m)` added as builtin; insertion order preserved

### Item 7: Byte literals
- Suffix `b`: `129b`, `0b10001b`, `0bx1b` (hex byte)
- `0x1b` stays `long` 27 (hex digit `b` takes precedence)
- Range/negation/whole-number refusals; `0b0b` for byte 0
- `byte_at` optimization saved ~1.2M Ir over slicing

### Item 3: JSON literals
- Sigil is **one lexer token** `json{` — brace MUST touch it
- `json {` is identifier + brace (match arm record body still parses)
- No `json[` sigil (would break `json` variable indexing)
- Desugars to `std/json.y` constructors: `json{ "a": 1 }` → `{ let j = json.obj(); j["a"] = json.num(1); j }`
- Nested containers wrapped (`json.jobj`/`json.jarr`); scalars use `num`/`numtext`/`str`/`boolean`/`nul`
- `null` and `none` both accepted; needs `import json;`

### Item 14: `in` operator
- Infix spelling `\"k\" in m` (reuses `in` keyword)
- Binds as comparison (level 4, looser than arithmetic, tighter than `&&`)
- Maps only; non-map operand → one diagnostic
- Reuses map read's "has" scan (same cost as a read)
- `m["k"] += 1` stays rejected (item 15 settled)

### Item 9: Octal literal
- Prefactor first: shared `radix_of(s: str) -> long` replaced 6 copies
- `0o644`, `0o7_5_5`, `0o8` → \"octal literal '0o8' has no digits\", `0o17b` byte
- Corrected item's stale line numbers in TODO.md
- Bootstrap constraint: `std/fs.y` couldn't use `0o` until compiler was blessed (3 commits)

### Item 5: Labelled break/continue
- `outer: for x in 0..n { break outer; }`
- Any of four loop kinds (`while`, `for..in`, `foreach`, C-style `for`)
- Shadowing: innermost label wins (like bindings)
- `TcSt.loops` now a stack of `{name, fd}` frames; `loop_fd` removed
- Emitter: `brk_label`/`cont_label` stay for bare forms; frame stack for named jumps
- Three refusals: bare messages unchanged + `'break name' names no enclosing loop`

## Still Open (from `compiler-audit/findings_inventory.md`)

29 open audit rows across 18 reports:
- agent2 A2b/A5/A6
- agent4 a4-02
- agent7 a7-02
- agent16 R2
- agent18 P0-1/P1-4/P1-5/P2-1/P2-4
- agent19 P0-1..P0-3/P1-4..P1-10/P2 bundle
- `ycc build` quadratic (A8's remainder)

## Next Items (from `TODO.md`, cheapest first)

1. **Item 11**: `with to_map, from_map` on records — blocked on item 2
2. **Item 2**: Primitive as union member (`long | str` in unions) — language-scale
3. **Item 6**: Tuples with type inference
4. **Item 8**: Parameter types inferred from context (narrow version exists)

### Item 2 Scope (decided: scalars only)
- Union members may be scalar primitives (`long`, `byte`, `float`, `bool`, `str`)
- Boxed in synthetic one-field records (`Long { v: long }`) so match-by-descriptor works
- Array/map members NOT included (different layouts, literal paths, recursive aliases)

## Bookkeeping
- Progress ledger: `compiler-audit/audit-fixes-progress.md` (gitignored)
- Findings inventory: `compiler-audit/findings_inventory.md` (29 open rows)
- Each commit: full gate loop (`make check` → `make rebless` → `make test`)
- Measured instruction counts in commit messages (bench-ir against parent)

## Commands
```bash
# Worktree
cd /tmp/opencode/auditfix

# Full gate loop
make check
make rebless
make test

# Benchmarks
make bench-ir BASE=/tmp/opencode/base-head/ynew NEW=./ynew
make ycc

# Fuzzing
test/fuzz/fuzz.sh 30

# Docs
make docs
```

## Key Invariants
- C twin 1:1 in `src/c/`; `make ycc` must print "verified: cycc output == refs/ycc.ref == ycc self-compile (byte-identical)"
- 3-generation fixpoint; no warnings from `src/y` or `src/y/std`
- Deterministic output; every suite green including coverage
- `ulimit -v 3670016` on everything run by hand; programs get `</dev/null`
- `TODO.md`: delete only completed item; correct stale line/cost only if needed
- Nothing pushed; worktree is separate