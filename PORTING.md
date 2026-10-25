# Bootstrap

The compiler is written in Y (`src/y/`). To build it from nothing but a C
compiler, the repository carries `bootstrap/ycc.c`: GNU99 C **generated** from
the Y sources, not a handwritten port and not an embedded binary. Never edit it
by hand; regenerate it with `make bootstrap-update`.

| path | contents |
|---|---|
| `bootstrap/ycc.c` | the generated compiler (the "C seed") |
| `bootstrap/sources.json` | the top-level Y modules the snapshot was generated from |
| `src/c/` | the seed's boxed value runtime (`yv.c`, `yv.h`, `ylong.h`) and host shim (`host.c`, `host.h`) |
| `tools/bootstrap/` | the generator (`cgen.py`, `yast.py`), closures and syscall buffers (`runtime.h`), the collector glue (`gc.h`) and its fixtures |

## Targets

- `make cycc` — GCC builds the seed. Needs `libgc.so.1` (Boehm GC); no Y
  executable is required. Build it at `-O1`: at `-O0` GCC keeps enough boxed
  temporaries per frame that deeply nested input can overflow the host stack
  before Y's own nesting guard runs.
- `make ycc` — the seed compiles current Y, attaches the pack stub and the std
  pack, and checks that the result reproduces itself byte for byte.
- `make ynew` — the blessed compiler (`BOOT`, default `refs/ycc.ref`) builds
  `src/y`, then the result builds itself twice; generations 2 and 3 must match.
  Self-hosted generations use checked `--gc=never`: a process arena owns
  compiler state until exit, with inner scratch regions.
- `make bootstrap-update` — generate C from current Y, compile it with the
  collector, verify three Y generations, compare them with the independent
  native build, then refresh `bootstrap/ycc.c` and `bootstrap/sources.json` and
  install the verified executable as `cycc`. Give it a deadline:
  `timeout -k 5s 120s make bootstrap-update </dev/null`.
- `make rebless` / `make rebless-full` — install a new reference compiler; the
  first is the native development path (60 s budget), the second adds the
  C-seed self-compile and the exhaustive Linux/PE C/Y port gates (120 s budget).
  The full bless compiles the std pack once with C, compares it byte for byte
  with the native pack, and reuses it for every corpus check.
- `make c-bootstrap`, `c-bootstrap-gc`, `c-bootstrap-test`,
  `c-bootstrap-smoke` — the generator on its own: emit `_check/bootstrap.c`,
  build it (without or with the collector), compare the generator's fixtures
  with native Y, and compile Hello World with the generated compiler.
- `make cycc.exe` — cross-build the seed for Windows with mingw (no collector,
  no meta execution; an 8 MiB stack, since MinGW's 1 MiB default overflows
  before the nesting guard).
- `make asan` / `make test-asan` — the seed under ASan+UBSan, without the
  collector; use bounded fixtures.

## How the generator works

`tools/bootstrap-c.py` exports a typed AST using the Y compiler's own resolver,
parser, renamer and checker, and `tools/bootstrap/cgen.py` emits C from it.
Globals and uncaptured locals become C variables; only shared captures use
reference-counted lexical environments. Small integers are tagged immediates;
large integers and closure pointers stay boxed and traced. Typed integer
operations bypass dynamic dispatch, other operators use numeric opcodes, record
literals share constant key arrays, and field accesses cache an index that is
validated against the record. `[byte]` buffers are packed, raw string and byte
allocations use Boehm's atomic allocator, and `y_copy_fwd` keeps overlapping
forward-copy semantics, so the seed decodes the same std pack as native Y.

A plain `cycc` has no std pack attached and reads `src/y/std` and
`src/y/arch` from disk, so it sees edits to them immediately.

Limits: no tail-call elimination, incomplete pointer operations, and not every
std API. Unsupported AST forms fail generation; unsupported dynamic calls fail
at run time.

## Compiler metadata

Several compiler tables are Y data expanded by meta blocks before ordinary
type checking, so the seed and the native compiler share one definition:

- `builtin_schema.y` — checker signatures, intrinsic result rules, native dispatch.
- `type_codec.y`, `unit_codec.y`, `ir_schema.y` — paired pack encoders and
  decoders generated from wire codes and field order.
- `dispatch_codegen.y` — typed AST dispatch for the checker, linter and emitter.
- `emit_recipes.y` — fixed instruction sequences as emitter helpers.
- `array_lower.y` (with `quote_codegen.y`) — array methods lowered to ordinary
  Y syntax trees, so a new architecture implements only ordinary operations.
- `type_rules.y` — container comparisons from field rules.
- `language_schema.y` — string-method signatures and the shared word
  vocabulary used by the checker, the language server and the TextMate grammar.

Refresh the seed after editing any of these schemas.

## AArch64

`make ycc-aarch64` builds a Linux AArch64 compiler that defaults to AArch64
output and accepts `--target=linux` for x86-64. Host syscalls live in
`src/y/host_linux.y`, selected by the running executable's machine, so meta
blocks always run on the host. `ytest aarch64` checks cross-host output,
source-free packed operation and two byte-identical self-compiles under
qemu-user. See `docs/TARGETS.md` for the ABI.
