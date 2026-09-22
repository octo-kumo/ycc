# AGENTS.md — y compiler

C (gnu99/gcc) compiler + tree-walking VM for the `.y` language, plus the self-hosted native `ycc`. No CI, no lint; `gcc -Wall -Wextra` is the typechecker.

## Build

- `make` → builds `./yboot` (the C toolchain compiler: VM + C emission only, no native backend). `CFLAGS` bakes `-DRUNTIME_DIR="$(CURDIR)/src/c"` into the binary — always rebuild via `make` after editing C, and run it from the repo root so `--compile` can find `src/c/runtime.c/h`.
- `make ycc` → full bootstrap chain: **[1]** gcc builds `yboot`; **[2]** `yboot` emits C for `src/y/ycc.y` → `cc`+runtime.c → `cycc`; **[3]** `cycc` compiles `ycc` natively (static ELF bytes); **[4]** `ycc` compiles `_ycc` — `cmp ycc _ycc` must be byte-identical, then `_ycc` is deleted. So the shipped `ycc` is compiled by ycc, natively.
- Do not commit build artifacts: `*.o`, `yboot`, `cycc`, `ycc`, `_ycc`, `a.out`, `embedded_runtime.inc`, `ycc1` (all gitignored; `make clean` removes them).

## Run / verify (use these exact forms)

- VM verbose (AST + typecheck + result): `./yboot test/y/examples/pi.y`
- Program output only (use for all output comparisons): `./yboot -q <file>`
- Compile: `./yboot --compile <file> -o /tmp/t_bin && /tmp/t_bin`
- Emit C: `./yboot -S <file> > /tmp/t.c`
- `make test` runs **everything**: the full bootstrap chain (`yboot → cycc → ycc`, ~1 min) + all `test/sh/*.sh` suites. `make test-fast` builds only `yboot` and skips the ycc/native suites; `make test-ycc` runs only the self-hosted check; `./test/sh/run_all.sh [suite ...]` runs a subset (`loops comprehensive examples audit ycc-units ycc native`).
- Suites (all compare VM `-q` vs compiled binary — a change must pass in **both**):
  - `test/sh/test_loops.sh` — loops + precedence/audit regressions
  - `test/sh/test_comprehensive.sh` — builtins, operators, functions, error cases
  - `test/sh/test_examples.sh` — every `test/y/examples/*.y` (passes if outputs match, or differ only on signature-printing lines containing `<function` / `<inferred>`)
  - `test/sh/test_audit.sh` — all 65 `test/y/audit/t*.y`; strict parity except the `expect_for` allowlist (documents each known divergence with its reason — never extend it to hide a NEW divergence)
  - `test/sh/test_ycc_units.sh` — every `test/y/ycc/test_*.y` must exit 0 in the VM (3 documented SKIPs: `test_vm`, `test_partial`, `test_ast_debug`)
  - `test/sh/test_ycc.sh` — self-hosted `ycc` output matches `yboot` (skips if `./ycc` absent)
  - `test/sh/test_native.sh` — `test/y/native/*.y` via real `ycc` → static ELF → run: `t*` assert stdout/exit (`.expected`/`.exit`, stdin from `.stdin`), `e*` assert rejection (first-line `// expect-error:` marker); needs `./ycc` (`run_all.sh` skips it with a warning if absent)
- Single focused check: `echo 'print(2 + 3 * 4);' > /tmp/t.y && ./yboot -q /tmp/t.y && ./yboot --compile /tmp/t.y -o /tmp/t_bin && /tmp/t_bin`
- If new flags (`-q`, `--no-exec`) seem ignored, the `./yboot` binary is stale — rebuild with `make`. Always feed `</dev/null` in scripts (some programs read stdin).

## Pipeline (main.c)

`module_preprocess` → parse (`parser.c`) → typecheck (advisory: prints result, does **not** block codegen; errors also exit 0 — known limitation) → VM (`vm.c`) **or** C codegen (`codegen.c` → `gcc` + `runtime.c`).

## Y code portability (hard rules — the C toolchain is quirky)

All `src/y/*.y` (and test drivers) run on the C VM / compile under the C backend, so they must stay in the portable subset:

- **Never chain `x.y[i]`** (dot-then-index): `parser.c` misparses it as `x.(y[i])` → runtime dot error. Always bind first: `let t = x.y; ... t[i]`. (`x.y.z`, `x[i].y`, `x[i][j]` are fine.)
- **Never leave a block empty** (`if (x) { }`): the C backend corrupts the heap on empty blocks (audit t01). Put a dummy `0;` inside or restructure.
- **Parenthesize unary-on-postfix**: `!x.y` parses as `(!x).y` (same for `-x.y`, `*x.y`). Always write `!(x.y)`, `-(x.y)`.
- **No dot-assign** (`s.field = v`): `parser.c` rejects it. Rebuild maps functionally.
- **`&&` / `||` are EAGER** (both sides always evaluated, VM and C backend): never guard a possibly-crashing field access — use nested `if`s.
- **Never name a variable/param `self`**: the C VM binds `self` to the enclosing function in every scope, shadowing your binding.
- New syntax (`&x`, `*p`, `*T` types) is ycc-pipeline-only: the C `parser.c` can't parse it, so never use it in `src/y/*.y` sources themselves (bootstrap would break).
- The C VM has no early `return`: a bare `res(x)` mid-function does NOT return — only the tail value matters. In if/else chains, always assign (`node = ...; pos = ...`), never rely on a branch's value unless it's the tail.

## Gotchas

- Imports are source-to-source in `module.c`: `import m from "./x.y"` → `let m = {<preprocessed x.y>}`; `export {a, b}` must be the **last statement**; paths resolve relative to the importing file's dir. Same scheme is reimplemented in `src/y/ycc.y:resolve_imports`.
- Recursion uses `self`, not the function's own name: `def fact(n: long) -> long { ... self(n-1) ... }`.
- Closures capture entire scopes, not single variables.
- Known bugs (asserted as skips in `test_comprehensive.sh`, do not "fix" by changing tests): `map_set` mutation broken (VM clones args, compiled runtime double-frees); postfix/slice on array literals fails (`[1,2,3][0:2]`) — assign to a variable first; unclosed parens/brackets silently accepted.
- `--no-exec` strips the `exec()` builtin (no shell access). Generated C needs GCC statement expressions (`-std=gnu99`); not portable to strict C99.
- Style: `.clang-format` LLVM, 4-space indent, no tabs.

## Layout

- `src/c/` — the C compiler: `main.c` (CLI: `-c/--compile`, `-S/--emit-c`, `-o`, `-q/--quiet`, `--no-exec`, FILE-or-stdin), `parser.c`, `ast.c/h`, `typecheck.c`, `type.c`, `vm.c`, `codegen.c`, `runtime.c/h`, `module.c`, `lib.c` (builtins, incl. `exit(code)`), plus `map/list/ast_debug/parser_debug` helpers.
- `test/` — three layers: `test/sh/` (suite drivers + `lib.sh`), `test/y/` (Y programs: `native/` fixtures + expected/exit/stdin, `audit/` 65 edge cases, `examples/` regression corpus, `ycc/` ~40 unit fixtures + mini modules). `test/c/` is reserved for future C unit tests.
- `tools/{lsp,as}/build.sh`, `wasm/build.sh` — need `emcc` plus a bootstrapped `/tmp/ycc1`; skip unless touching those areas.

## Native backend (ycc → real x86_64 assembly, see `src/y/NATIVE.md`)

- `src/y/types.y` (static checker, errors fatal), `src/y/arch_x64.y` (Linux x86_64 emitters + prelude), `src/y/native.y` (splice imports → strip namespaces → check → hoist → emit `.s`), `src/y/std/io.y` (file I/O in Y over raw syscalls).
- Unboxed values (long/int/bool/ptr/str/option = 8 bytes); stack + arena heap (`[v; n]` fixed with trapped OOB, `[v,...]` heap with `push`, options `T?`); top-level `def` + capture-free hoisting; `print`/`syscall`/`len`/`push`/`some`/`is_some`/`unwrap` intrinsics; `&x`, `&a[i]`, `*p`, `*p = v`, `a[i]`, `*T`/`[T; N]`/`[T]`/`T?` types; annotations required on `def` params/returns.
- `src/y/rename.y` uniquifies every binding (`x$1`) post-parse, so checker/emitter use flat envs (no scopes/shadowing); `src/y/{enc64,asm,elf}.y` assemble + write static ELFs (no cc/as/ld).
- Verify: `ycc -o /tmp/t_bin <file> && /tmp/t_bin` (writes static ELF directly — no cc/as/ld), or `ycc -S` for assembly text, or `make test` (suite `native`, 33 tests in `test/y/native/`). Rebuild the chain (`make ycc`: yboot → cycc → ycc + fixpoint check) after touching any `src/y/*.y`, `lib.c`, `runtime.c/h`, or `codegen.c`.

## Self-hosted ycc

- `ycc` is native-only (no C backend, no runtime): `ycc [-o OUT] [-S] [-c] FILE`, cc-style. Built by `make ycc` (chain: `yboot` → `cycc` → `ycc` → `_ycc` fixpoint check); the shipped binary needs nothing at runtime — it is a static ELF invoking raw syscalls.
