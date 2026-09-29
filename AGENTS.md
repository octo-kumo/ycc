# AGENTS.md — y compiler

C (gnu99/gcc) compiler + tree-walking VM for the `.y` language, plus the self-hosted native `ycc`. No CI, no lint; `gcc -Wall -Wextra` is the typechecker.

## Build

- `make` → builds `./yboot` (the C toolchain compiler: VM + C emission only, no native backend). `CFLAGS` bakes `-DRUNTIME_DIR="$(CURDIR)/src/c"` into the binary — always rebuild via `make` after editing C, and run it from the repo root so `--compile` can find `src/c/runtime.c/h`.
- `make ycc` → full bootstrap chain: **[1]** gcc builds `yboot`; **[2]** `yboot` emits C for `src/y/ycc.y` → `cc`+runtime.c → `cycc`; **[3]** `cycc` compiles `ycc` natively (static ELF bytes); **[4]** `ycc` compiles `_ycc` — `cmp ycc _ycc` must be byte-identical, then `_ycc` is deleted. So the shipped `ycc` is compiled by ycc, natively.
- Do not commit build artifacts: `*.o`, `yboot`, `yboot-asan`, `cycc`, `ycc`, `_ycc`, `a.out`, `embedded_runtime.inc`, `ycc1` (all gitignored; `make clean` removes them).
- `make asan` builds `./yboot-asan` (ASan+UBSan); `make test-asan SUITES_ASAN="loops comprehensive"` runs suites against it (`YBOOT` is overridable). Do NOT put a `ulimit -v` on sanitized runs — ASan reserves terabytes of *virtual* address space. `make test-asan` must stay clean (no sanitizer report, no failure); `test/sh/lib.sh` scales its timeouts by 15× when `$YBOOT` names a sanitized binary.
- Crash hunting that has paid off before, worth repeating after parser/runtime changes: (1) run every corpus file through all three engines and flag exit codes above 128; (2) truncate each corpus file at a spread of offsets and feed the remainder to `yboot-asan`; (3) mutate a few random bytes per file into syntactically interesting ones and do the same. Each pass found a real bug (a stack-use-after-return, an out-of-bounds read on a trailing `\`, an unchecked call arity).

## Run / verify (use these exact forms)

- VM verbose (AST + typecheck + result): `./yboot test/y/examples/pi.y`
- Program output only (use for all output comparisons): `./yboot -q <file>`
- Compile: `./yboot --compile <file> -o /tmp/t_bin && /tmp/t_bin`
- Emit C: `./yboot -S <file> > /tmp/t.c`
- `make test` runs **everything**: the full bootstrap chain (`yboot → cycc → ycc`, ~2 min) + all `test/sh/*.sh` suites. `make test-fast` builds only `yboot` and skips the ycc/native suites; `make test-ycc` runs only the self-hosted check; `./test/sh/run_all.sh [suite ...]` runs a subset (`loops comprehensive examples audit ycc-units ycc fixpoint native native-examples`).
- Profiling: `./ycc --time` / `./yboot --time` print a per-phase table (elapsed ms + heap bytes + counters) to **stderr**. Use it before optimizing anything — it is how the O(n²) copy-on-store and the byte-at-a-time writer were found. Y-level builtins: `clock_us()`, `heap_used()`, `eputs(v)` (all three engines).
- Suites (all compare VM `-q` vs compiled binary — a change must pass in **both**):
  - `test/sh/test_loops.sh` — loops + precedence/audit regressions
  - `test/sh/test_comprehensive.sh` — builtins, operators, functions, error cases
  - `test/sh/test_examples.sh` — every `test/y/examples/*.y` (passes if outputs match, or differ only on signature-printing lines containing `<function` / `<inferred>`)
  - `test/sh/test_audit.sh` — all 65 `test/y/audit/t*.y`; strict parity except the `expect_for` allowlist (documents each known divergence with its reason — never extend it to hide a NEW divergence)
  - `test/sh/test_ycc_units.sh` — every `test/y/ycc/test_*.y` must exit 0 in the VM (3 documented SKIPs: `test_vm`, `test_partial`, `test_ast_debug`)
  - `test/sh/test_ycc.sh` — self-hosted `ycc` output matches `yboot` (skips if `./ycc` absent)
  - `test/sh/test_fixpoint.sh` — `ycc` rebuilds itself byte-identically (3 generations) and the self-built binary still compiles working programs (skips if `./ycc` absent)
  - `test/sh/test_native.sh` — `test/y/native/*.y` via real `ycc` → static ELF → run: `t*` assert stdout/exit (`.expected`/`.exit`, stdin from `.stdin`), `e*` assert rejection (first-line `// expect-error:` marker); needs `./ycc` (`run_all.sh` skips it with a warning if absent)
  - `test/sh/test_native_examples.sh` — every `test/y/examples/*.y` compiled by the real `ycc` and diffed against the VM. A ratchet: the `UNSUPPORTED` map lists the examples the native backend cannot take yet **with a reason each**, and fails as soon as one starts compiling. Lines where the VM prints `<inferred>`/`<function …>` are compared leniently (the VM has no return-type inference)
- Single focused check: `echo 'print(2 + 3 * 4);' > /tmp/t.y && ./yboot -q /tmp/t.y && ./yboot --compile /tmp/t.y -o /tmp/t_bin && /tmp/t_bin`
- If new flags (`-q`, `--no-exec`) seem ignored, the `./yboot` binary is stale — rebuild with `make`. Always feed `</dev/null` in scripts (some programs read stdin).

## Pipeline (main.c)

`module_preprocess` → parse (`parser.c`) → typecheck (advisory by default: prints the result and keeps going, because the checker is incomplete; `--strict` makes a type error fatal and emits nothing) → VM (`vm.c`) **or** C codegen (`codegen.c` → `gcc` + `runtime.c`).

## Y code portability (hard rules — the C toolchain is quirky)

All `src/y/*.y` (and test drivers) run on the C VM / compile under the C backend, so they must stay in the portable subset:

- **Never leave a block empty** in old sources — this is FIXED now (`if (x) { }` is legal and safe in both engines), but existing `0;` fillers are harmless.
- New syntax (`&x`, `*p`, `*T` types) is ycc-pipeline-only: the C `parser.c` can't parse it, so never use it in `src/y/*.y` sources themselves (bootstrap would break).
- The C VM has no early `return`… — FIXED: `return expr;` / `return;` work in all three engines now, and unwind out of blocks and loops. Existing tail-value style still works.

Fixed frontend bugs (the workaround comments in `src/y/*.y` are now stale, but harmless):

- `x.y[i]` used to misparse as `x.(y[i])`. Dot is a postfix suffix now, so `x.y[i]`, `x[i].y` and `x.y.z` all parse correctly.
- `!x.y` used to parse as `(!x).y`. Postfix binds tighter than unary now, so `!x.y` is `!(x.y)`.
- `&&` / `||` used to be EAGER in the C frontend. They short-circuit now, in all three engines, so guards like `if (i < len(a) && a[i] == x)` are safe.
- Dot-assign (`s.field = v`) was rejected by `parser.c`. It works now, as does `m["key"] = v`; records are reference values, so the write is visible through every binding.
- `self` used to be bound in every function scope, clobbering a parameter of that name. It is now only bound when no parameter is called `self`, so `def f(self: long)` works and recursion is unchanged.

## Gotchas

- Imports are source-to-source in `module.c`: `import m from "./x.y"` → `let m = {<preprocessed x.y>}`; `export {a, b}` must be the **last statement**; paths resolve relative to the importing file's dir. Same scheme is reimplemented in `src/y/ycc.y:resolve_imports`.
- Recursion uses `self`, not the function's own name: `def fact(n: long) -> long { ... self(n-1) ... }`.
- Closures capture entire scopes, not single variables.
- **Arrays, maps and records are references, in all three engines.** `let b = a` shares; `push`/`map_set`/`a[i] = v`/`s.f = v` are visible through every binding. Always rebind `push` (`a = push(a, v)`) — growing may move the array. Deep-copying instead (the old copy-on-write / copy-on-store) is what made compiles O(n²) and blocked self-hosting; do not reintroduce it.
- Known bugs (asserted as skips in `test_comprehensive.sh`, do not "fix" by changing tests): postfix/slice on array literals fails (`[1,2,3][0:2]`) — assign to a variable first; unclosed parens/brackets silently accepted.
- `--no-exec` strips the `exec()` builtin (no shell access), in both `yboot` and `ycc`. Generated C needs GCC statement expressions (`-std=gnu99`); not portable to strict C99.
- Style: `.clang-format` LLVM, 4-space indent, no tabs.

## Layout

- `src/c/` — the C compiler: `main.c` (CLI: `-c/--compile`, `-S/--emit-c`, `-o`, `-q/--quiet`, `-t/--time`, `--strict`, `--no-exec`, FILE-or-stdin), `parser.c`, `ast.c/h`, `typecheck.c`, `type.c`, `vm.c`, `codegen.c`, `runtime.c/h`, `module.c`, `lib.c` (builtins, incl. `exit(code)`), plus `map/list/ast_debug/parser_debug` helpers.
- `test/` — three layers: `test/sh/` (suite drivers + `lib.sh`), `test/y/` (Y programs: `native/` fixtures + expected/exit/stdin, `audit/` 65 edge cases, `examples/` regression corpus, `ycc/` ~40 unit fixtures + mini modules). `test/c/` is reserved for future C unit tests.
- `tools/{lsp,as}/build.sh`, `wasm/build.sh` — need `emcc` plus a bootstrapped `/tmp/ycc1`; skip unless touching those areas.

## Native backend (ycc → real x86_64 assembly, see `src/y/NATIVE.md`)

- `src/y/types.y` (static checker, errors fatal), `src/y/arch_x64.y` (Linux x86_64 emitters + prelude), `src/y/native.y` (splice imports + optional std modules → strip namespaces → check → hoist → tree shake → emit `.s`), `src/y/std/rt.y` (**runtime library written in Y**, spliced in front of every program; `readline()`/`exec()` live in `std/prelude.y` the same way). The rule is that arch_x64.y provides small general primitives (allocator, traps, record lookup, byte-moving string/array cores, float formatting, argv) and Y provides behaviour (print/format/string ops/time/files). `y_` is a **reserved prefix**: such a def is emitted under its bare name because generated code calls it by fixed label.
- Unboxed values (long/int/byte/bool/float/ptr/str/option/function = 8 bytes); **`[byte]` arrays are packed** (one byte per element — the element width flows from the static type into every access, the allocation size, and `push`/`slice`/`==`/`join`/`foreach`); `bytes(s)`/`from_bytes(b)` convert to and from `str`; stack + arena heap (`[v; n]` fixed with trapped OOB, `[v,...]` heap with `push`, options `T?`); closures as `[code, caps...]` records (capturing functions are emitted at their creation site, where capture types are known); `print`/`syscall`/`len`/`push`/`some`/`is_some`/`unwrap`/`range`/`readline` intrinsics; `&x`, `&a[i]`, `*p`, `*p = v`, `a[i]`, `a[lo:hi]`, `*T`/`[T; N]`/`[T]`/`T?`/`float`/`byte` types; `for`/`for..in`/`foreach`/`while`, block expressions; annotations required on `def` params (return types are inferred).
- `src/y/rename.y` uniquifies every binding (`x$1`) post-parse, so checker/emitter use flat envs (no scopes/shadowing); `src/y/{enc64,asm,elf}.y` assemble + write static ELFs (no cc/as/ld).
- **Optional std modules**: `import net;` (no `from`) splices a module by name and its functions are called as `net.xxx`. A module is a plain Y file in `src/y/std/` (add one by dropping the file there); `std_resolve` in native.y searches next to the importer first (vendor/shadow), then `std/` and `src/y/std/` from the cwd and from the `ycc` binary's directory. `src/y/std/net.y` (TCP + tiny HTTP) is the first one. Modules flatten into one namespace, so pick names that cannot collide (`close_fd`, `send_str`).
- **Tree shaking**: `prune_bodies` drops uncalled functions (rooted at `_start`) and `shake_refs` drops unreferenced arch-prelude/rodata blocks (plus fall-through tails), so a program ships only the runtime it reaches.
- Verify: `ycc -o /tmp/t_bin <file> && /tmp/t_bin` (writes static ELF directly — no cc/as/ld), or `ycc -S` for assembly text, or `make test` (suite `native`, 51 tests in `test/y/native/`). Rebuild the chain (`make ycc`: yboot → cycc → ycc + fixpoint check) after touching any `src/y/*.y`, `lib.c`, `runtime.c/h`, or `codegen.c`.

## Self-hosted ycc

- `ycc` is native-only (no C backend, no runtime): `ycc [-o OUT] [-S] [-t] [--no-exec] FILE`, cc-style. `--no-exec` omits the prelude's `exec()` so the binary cannot reach a shell. Built by `make ycc` (chain: `yboot` → `cycc` → `ycc` → `_ycc` fixpoint check); the shipped binary needs nothing at runtime — it is a static ELF invoking raw syscalls.
- Self-hosting is **verified**: `cmp ycc _ycc` is byte-identical, `ycc` compiles its own ~427 KB of spliced source in ~2.5 s using ~365 MB, and `test/sh/test_fixpoint.sh` checks three generations plus that the self-built compiler still produces working binaries.
