# std/math.y — a fast math module, and the `native def` it needs

A proposal, measured on this tree. Two pieces:

1. **`native def`** — a declaration in Y with no body whose implementation is an
   assembly label. This is the enabling feature; it is general (any std module can
   reach machine code) and it is small.
2. **`std/math.y`** — the math library, built on it. One file. No compiler flag,
   no builtins, no second module.

Why it needs (1) at all: **most of a math library is not expressible in Y today.**
There is no `float`→`long` conversion and no access to a float's bits, so there is
no seed for a Newton iteration and no way to pull out an exponent. `sqrt`, `exp`,
`log`, `pow`, `sin`, `floor`, `to_int`, `ldexp` cannot be written. Only
`+ - * / %` (with `%` already lowering to the prelude's `y_fmod`) and the six
comparisons exist. Details and evidence in [§2](#2-the-hard-constraint).

Everything below is a proposal. Numbers in [§1](#1-what-y-costs) are measured;
recipes are in the [appendix](#appendix-measuring).

---

## Requirements and constraints

Repo rules, not preferences. Any implementation must satisfy all of them.

| # | Requirement | Where it is enforced |
|---|---|---|
| R1 | **The C twin is 1:1.** `src/c/` mirrors `src/y/`; both compilers must emit byte-identical programs. Assembly is the exception in *representation* only: it lives once in `src/y/arch/*.s`, embedded by both (`embed` / `.incbin`). | `PORTING.md`, `make ycc` (`cmp ycc refs/ycc.ref`) |
| R2 | **The fixpoint holds.** Three generations of self-compilation byte-identical. | `test_fixpoint.sh` |
| R3 | **`make check` before `make rebless`.** verify → compare → time. | `AGENTS.md`, `test/sh/check.sh` |
| R4 | **No warnings** from `src/y` or `src/y/std`. | `test_fixpoint.sh` |
| R5 | **Deterministic output** — no hash-map iteration order in the emitter. | `test_port.sh` |
| R6 | **`ycc -g` keeps `.text`/`.rodata` identical to the plain build.** | `test_debug.sh` |
| R7 | **The std pack and tree shaking keep working**: `math.y` is an optional unit, resolved from `std/` next to the binary, shaken per def, and packs nothing. | `NATIVE.md` "Compilation units and the std pack", `test_link.sh` |
| R8 | **Every process under `ulimit -v 3670016`.** | `AGENTS.md`, `test/sh/capped.sh` |
| R9 | **Bench at the end**; numbers in the commit message. | `AGENTS.md` |
| R10 | **Y code style** — no unknown types, exact records, a `type` alias for anything used twice, no unused locals, `self` for recursion. | `AGENTS.md` "Y code style" |
| R11 | **Coverage gates**: every diagnostic has an `e*.y` marker, every keyword appears in a `t*.y`, every manual section has a `test/COVERAGE.md` row. | `test_coverage.sh` |
| R12 | **Every 4th call is fuzzed** once the lexer/parser/checker/emitter are touched: `test/fuzz/fuzz.sh` must exit 0, and each finding becomes an `e*.y` fixture. | `AGENTS.md` "Fuzzing" |

### What already exists (do not rebuild it)

| Need | Already there |
|---|---|
| asm blocks in the program | `arch_prelude_lines()` (asm text moves to `src/y/arch/*.s` in P0, still shaken block-by-block by `shake_prelude`, `native.y:1249`) |
| a bare asm label behind a Y name | `fn_label_of` → `runtime_base` (`native.y:1402`): a `y_`-prefixed name *is* its own label, `$N` suffix stripped |
| a module's `y_` name staying global | `rename.y`'s `rn_qualify` (verified: a module's `def y_foo` is callable as `y_foo`, un-qualified) |
| an extern record `{name, label, type}` | `types.y:37` (`Sym`) — used today for package globals |
| float `%`, float formatting, `str`↔`[byte]` | `y_fmod`, `y_float_tostr` in the prelude |
| SSE double arithmetic, `movq`, `cvtsi2sd`, `cvttsd2si` | `enc64.y` |
| an undefined label at asm time | `asm_link`: `undefined label 'y_nope'` |

---

## 1. What Y costs

Measured on this box (i5-14600KF), `./ycc`, µs over 1–2 M iterations, best of 5
(`best()` in the appendix takes the minimum of 5 runs; the harness itself costs
~1.2 ns/iteration and is included in the totals below, so marginal costs are
subtracted from a `p0`-baseline rather than from zero).

| construct | cost | marginal |
|---|---|---|
| `while` iteration (counter, `cmp`, branch) | 0.99 ns | — |
| float `def` call + return (through a function value) | 1.26 ns | 0.3 ns over the loop |
| float `*` in a called def | — | **~1.2 ns** (0.9–1.4) |
| `[float]` element read (bounds check + load) | 1.27 ns/element | — |
| `[long]` element read | 1.00 ns/element | — |
| float table read + add | 1.53 ns | — |
| asm leaf call via `%` (`y_fmod`) | 2.69 ns | — |
| integer `(s * K + C) & M` + loop | 1.08 ns | — |

For reference, the same work in machine code: `mulsd`/`addsd` 4-cycle latency,
0.5/cycle throughput; `sqrtsd` ~15–20 cycles; an L1 load 4–5 cycles. **A float
multiply costs ~4 cycles in Y and 0.5 in hardware**, because each one is
`movq %rax,%xmm1` / `movq %xmm0,%rax` around the instruction, plus a spill of the
local. That ratio is the whole reason asm is worth reaching for, and the reason
it is worth reaching for *per operation* rather than per function.

Two further measurements shape the algorithm choices:

- **Float literals used as operands are free** — one `mov $bits, %rax`.
- **A float literal inside an array is built at run time**, in `_start`, before
  the program body: ~5 instructions per element (64 entries → 335 lines of asm,
  256 → 1295, 1024 → 5135, over a 212-line hello world). So a table-driven
  routine pays a fixed startup cost and a code-size cost that a
  coefficient-inlined polynomial does not. In this backend **inline immediates
  beat tables** until a table is small (~64 entries) or the polynomial is long.
  This inverts normal practice and belongs in the file header as a rule.

---

## 2. The hard constraint

The complete set of names `typeof_call` recognises as intrinsics (`types.y`,
`typeof_call` + the `name ==` chain): `print keys len some is_some unwrap trim
ord byte_at chr tonum tostring typeof last_index_of join fork spawn wait_pid
mutex sem try_lock lock wait split range eputs clock_us time_us heap_used sleep
puts exit argv bytes from_bytes ptr_addr syscall substr`. Float support is
exactly: `+ - * /` (`%` lowers to `y_fmod`), the six comparisons, `tostring` and
f-strings, and `long`→`float` widening.

Missing, and each one is load-bearing:

| missing | consequence |
|---|---|
| `float`→`long` | no `to_int`, `trunc`, `floor`, `ceil`, `round`, `fract`; no way to get an exponent |
| float↔bits | no `ldexp`/`frexp`, no `is_nan` by bits, **no seed for a Newton iteration**, no `nextafter`, no bit-level constants |
| so, transitively | `sqrt`, `exp`, `log`, `log2`, `log10`, `log1p`, `expm1`, `pow`, `sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `sinh`, `cosh`, `tanh`, `cbrt`, `hypot` (exact), `erf`, `lgamma` — none of them |

Also relevant, all verified:

- **No pointer arithmetic** (`p + 1` is a type error), so there is no
  bounds-check-free iteration; `a.ptr` buys element 0 only.
- **No overloading, no generics.** One name, one signature. So the float and
  long flavours of `min`/`abs` cannot share a name — but they *can* live in
  different modules (`math.min` for longs, `math.fmin`… or, better, `fmath`-style
  separate namespaces, which is moot now that there is one module: see §5).
- **The intrinsic dispatch is by name and shadows user defs.** A program's own
  `def len(x: [long])` loses to the builtin at every call site.
- **Duplicate defs are legal and last wins** (verified: two `def bar`, the call
  prints the second). Combined with the missing definition-site duplicate scan in
  the assembler, two bodies under one bare `y_sqrt` label would be a *silent*
  miscompile — hence diagnostic 3 in §3.
- Float `/` by zero does **not** trap: `0.0/0.0` is `nan`, `1.0/0.0` is `inf`,
  `print` renders them, and `x != x` detects NaN. So the portable tier can name
  `nan` and `inf` with no primitive at all.

---

## 3. `native def`

### Syntax

```y
// src/y/std/math.y — the machine-dependent layer, at the top of the file
native def sqrt(x: float) -> float;                             // label y_sqrt
native def dot(a: [float], b: [float]) -> float;                // label y_dot
native def dot_pairs(a: [float], b: [float]) -> float = "y_dot4";  // explicit label
```

A **declaration**: no body, no parameters to check beyond the signature, nothing
emitted at the declaration site. It is a top-level `def` in every other respect —
it hoists, it participates in mutual recursion, it is module-qualified
(`math.sqrt` from a program, `sqrt` inside `math.y`), and it can be called
through a function value.

### Rules (all six settled — see §7)

- `native` is a **reserved keyword** (`02-lexical.tex`): a program can no longer
  bind it as an identifier. Nothing in this repo does — all 16 occurrences of
  "native" under `test/`, `bench/`, `examples/` and `src/y/std/` are comments
  about `native.y`.
- The label may be **omitted** (derived) or given explicitly with
  `= "label"`, and either way it **must start with `y_`**.
- The **return type must be written** — there is no body to infer it from.
- Top level only.
- A native whose name a `def` in the same unit also defines is **rejected**:
  duplicate defs are last-wins today and the assembler has no definition-site
  duplicate scan, so both bodies would land under one bare `y_sqrt` label with
  the second silently dead (§2).
- A native **may be used as a value** (`let f = math.sqrt;`) — it has no
  captures, so it is the ordinary code-pointer closure.

### The label

`"y_" + the declared name`, computed at rename time from the name **as written**
— before module qualification, so `math.sqrt` never becomes `y_math.sqrt`. An
explicit `= "label"` overrides.

The name is *not* taken from the arch: `arch_prelude_lines()` writes the label
text by hand, so the derivation must be the one both sides already agree on.

### Shaking: no new code

`shake_prelude` keeps a prelude block when a kept body's emitted text references
its label. A native def's call site emits `call y_exp`, which is exactly that
reference. So an unused native costs nothing: no body is emitted, and the arch
block is dropped. This is the same mechanism that keeps `y_float_tostr` out of
programs that never print a float.

### Compiler changes

| File | Change |
|---|---|
| `parser.y` | `native def`, no body, optional `= "label"`. Today `def foo(x: long) -> long;` is `expected '{', got ';'` — one alternative in one production. |
| `parser.y` (AST) | `Func` gains `label: str` (`""` = an ordinary def). Cheaper than a new node kind; `def_sig` and `rn_top` need no change, since a native def already has a signature. |
| `lexer.y` | `native` into the keyword table. |
| `types.y` | The pre-pass binds it as usual. `typeof_def` skips the body when `label != ""`. New diagnostics: a native def with no written return type; a label that does not start with `y_`; a native and a `def` of one name in a unit. |
| `rename.y` | Set `label` from the declared name; no body to walk. Nothing else — a top-level def is already registered. |
| `native.y` | A per-unit index of native decls (`name → label`), filled from the top-level defs before emission (~15 entries; it holds only natives). The call path consults it, so `f(x)` emits `call y_exp` instead of the derived `yfn_…` label. `emit_fns` emits no body for a native def. |
| `lint.y` | Nothing. A top-level declaration is not an unused local. |
| `dwarf.y` | The call site keeps its `.loc`; the callee has no line info. `test_debug.sh` must confirm `nm`/`addr2line` still name the label and gdb/callgrind do not choke on a bodyless function. |
| `src/c/*` | The same changes, mechanically (R1). |

### Alternatives considered

- **Builtins + a `--fast-math` flag.** Works, but it puts ~15 machine-specific
  names into the language permanently, needs the flag threaded through the
  driver, the checker (`check_program`'s signature) and the package object cache
  key, and forces a second module so the portable half is not needlessly gated.
  Rejected.
- **A `y_`-prefixed def whose body the emitter replaces.** Cheapest of all, and a
  trap: `rt.y` is spliced into *every* program *and* compiled into the C twin, so
  the C binary would need a real Y `sqrt`. Rejected.
- **Inline `asm { }` in the language.** A new syntactic form end to end — lexer,
  parser, checker, emitter, lint and the 1:1 C twin — with values living in stack
  slots and results in `%rax`, so operands would have to be pinned to slots by
  hand. And `enc64` encodes ~50 mnemonics, so it is not "any assembly" anyway. It
  also bakes x86 into the *language*: a block is unportable by construction, so
  every future backend needs the same escape hatch plus its own duplication.
  Rejected — a declaration carries the same information with none of that.
- **Keeping the transcendentals in Y and only asm-ing the primitives.** Cheapest
  path to a working module, ~5x slower per call on the hot five. Not what was
  asked for, but a valid stopping point (§6, P3) if P4 stalls.

### New diagnostics (each needs an `e*.y` marker and a `COVERAGE.md` row)

1. a native def with no written return type;
2. a native label that does not start with `y_`;
3. a native def whose name a `def` in the same unit also defines (the silent
   double-body trap of §2).

---

## 4. The arch layer

### `enc64.y`

`sqrtsd` (SSE2: `F2 0F 51 /r`), plus `movsd`, `movapd`, `xorpd`, `andpd`,
`unpcklpd`. Each follows `enc_cvtsi2sd`'s ~10-line shape, and each is mirrored
into `enc64.c`.

Note what is *not* needed: `y_fmod` proves the GPR-only style (integer arithmetic
on the bits, `movq` to move a double in and out of an SSE register) needs **zero**
new encodings. The five above buy SSE-register residency, which is what makes an
assembly polynomial beat the Y one — with the GPR style each float op would cost
the same two `movq` the Y code pays.

### `arch_x64.y` — and where the asm actually lives

The assembly stops being Y string literals. It moves to **`.s` files that both
compilers embed**, which is possible because an embed is not a copy:

- Y: `embed PRELUDE_ASM from "./arch/prelude.s";` in `arch_x64.y` (the path is
  relative to the file that says it).
- C: `Y_EMBED(PRELUDE_ASM, "src/y/arch/prelude.s")` in `arch_x64.c` — `.incbin`
  (`yv.h:70`), read by gcc at build time, path relative to the repo root. Same
  asymmetry PORTING.md rule 10 already documents for the std sources.

`embed_decl` (`native.y:678`) turns the file into one str const, and the
precedent says that is fine at this size: `str.y` is already a single
19,868-byte embedded constant. The asm text needs no escaping — checked: no
`#`, no quotes, no backslashes, no non-ASCII.

Then `arch_prelude_lines()` splits it into lines, because `prelude_blocks`
(`native.y:1181`) needs **one line per array element** to find the block
boundaries that shaking works on. `split("\n")` on a file that ends in a newline
yields a trailing empty element, which must be dropped; `make ycc`'s `cmp` is the
check that the round trip is byte-exact.

**What this pays down.** The asm exists twice today:

| | `src/y/arch_x64.y` | `src/c/arch_x64.c` |
|---|---|---|
| lines | 2181 | 2185 |
| asm | 1869 string-literal lines | 1873 `ys("…")` calls |
| asm bytes | 32,780 | the same, hand-copied |
| labels | 207 | 207 |

Migrating it makes the asm **one shared file**: ~1870 duplicated lines leave each
copy, and R1 then applies to the ~310 lines of glue rather than to 86% of both
files. The byte-identity gate stays, but it stops being the only thing holding the
two copies together.

**Comments.** `#` comments are allowed in the `.s` files (GNU as's spelling, not
`//`) and stripped where the embedded text is split — ~10 lines, mirrored. That
keeps the in-tree assembler's invariant intact (it never sees a comment: a
leading `#` is *"unexpected comment (backend bug)"*, `asm.y:626`) while letting a
700-line hand-written `y_exp` carry the prose it needs.

**`make asm-check`** assembles `src/y/arch/*.s` with GNU `as` and fails on a
syntax error. `test_debug.sh:249` already runs `as` over a program's `-S -g`
text, so the assembler is available and the common path is proven — but only over
the blocks a test program happens to keep. `asm-check` is the first *exhaustive*
check, which is what 700 lines of new hand-written asm wants. ycc's own assembler
stays the authority; GNU `as` accepts a superset of what `enc64` encodes.

Files: `src/y/arch/prelude.s` (allocator, traps, string/array cores, `y_fmod`,
`y_float_tostr`, argv), `threads.s` (already a separate function), `math.s` (all
the new work). A new `ARCH_ASM` prerequisite goes next to `STD_EMBEDS` in the
Makefile's `cycc`, `cycc-asan`, `ycc` and `ynew` rules — the `.s` is read when
the *compiler* is built, so every rule that compiles a `.y` embedding one needs it.

`enc64.y` stays Y (its tables are `bytes: [byte]`, not text), and the one-line asm
snippets inside the emitter (`"    addsd %xmm1, %xmm0"`) stay inline — they are
in context there.

### New asm

In `src/y/arch/math.s`:

- primitives: `y_sqrt`, `y_to_int`, `y_fbits`, `y_bitsf`
- transcendentals (P4): `y_exp`, `y_log`, `y_pow`, `y_sin`, `y_cos`
- bulk kernels (P5): `y_dot`, `y_sum`, `y_scale`, `y_axpy`, `y_min_of`, `y_max_of`

Calling convention, unchanged from `y_float_tostr`/`y_fmod`: arguments pushed
left to right and cleaned by the caller, result in `%rax`; a float argument
arrives as its bits on the stack, and a float *binary* op takes `%xmm0`/`%xmm1`
and returns in `%xmm0`.

Array arguments: the header is `{len@0, cap@8, data@16, front@24}`, and `data`
**already points at element 0** — that is what the emitter's `a[i]` uses — so a
kernel loads it once and walks it linearly, with no bounds checks and four
accumulators. The caller does the length check.

---

## 5. `src/y/std/math.y`

One optional module, `import math;`, resolved from `std/` next to the binary
exactly like `fs`/`net`. Not embedded, not packed, shaken per def.

### The portable half — no native needed

- **long**: `min max abs clamp sign gcd lcm isqrt popcount ctz clz next_pow2
  mul_mod pow_mod inv_mod`. `mul_mod`/`pow_mod` need a 128-bit product, which
  `a * b` cannot give (longs wrap): a 32-bit limb split, exact, ~20 ops.
- **float, expressible as-is**: `fmin fmax fabs fsign lerp` (`fabs` as
  `if x <= 0.0 { 0.0 - x } else { x }`, which maps `-0.0` to `+0.0` correctly),
  `is_nan` (`x != x`), `is_finite` (`x - x == 0.0`), `is_inf`
  (`x - x != 0.0 && x == x`), `nan` (`0.0/0.0`), `inf` (`1.0/0.0`).
- **RNG**: xoshiro256\*\* and xoshiro256+ with SplitMix64 seeding;
  `rand_f01` = `(x >> 11) * 2^-53`, exact in Y; `rand_range` by unbiased rejection.
- **constants**: `pi e tau ln2 ln10 sqrt2 phi`.

### The machine-dependent half

Natives (a declaration each, pointing at a label):

| natives | notes |
|---|---|
| `sqrt` | `sqrtsd`: one instruction, and **correctly rounded by hardware**, so it is the 0.5-ulp reference the rest are measured against |
| `to_int` | `cvttsd2si` + the policy below; the base for `floor`/`ceil`/`trunc`/`round`/`fract`, each of which is `to_int` plus one comparison (exact) |
| `f_bits`, `bits_f` | `movq`; a float in `%rax` *is* its bits, so these need no special emission at all. `frexp`, `ldexp`, `nextafter`, `cbrt`'s seed and `is_signed_zero` are pure bit work on top |
| `exp log log2 log10 pow sin cos` | P4; Y first, moved one at a time |
| `dot sum scale axpy min_of max_of` | P5 bulk kernels over `[float]` |

Y functions built on them: `floor ceil trunc round fract expm1 log1p cbrt hypot
sinh cosh tanh asin acos atan atan2 ldexp frexp nextafter is_signed_zero`.

`fma` **cannot** be a real FMA — FMA3 is not baseline SSE2 — so `fma` is `a*b+c`,
documented as unfused.

### Policies to fix, once

- **`to_int`**: trap on NaN/±inf (consistent with the other `runtime error:`
  traps) and saturate on an out-of-range magnitude, rather than x86's silent
  `LONG_MIN`. To confirm with whoever owns the language.
- **Accuracy**: ≤1 ulp, fdlibm-grade. `sqrt` gets there for free from hardware;
  everything else is range reduction (Cody-Waite in two terms) plus a short
  polynomial with coefficient immediates, not a table (§1).
- **Tables**: ≤ ~64 entries, because of the run-time initialisation cost.

---

## Status

| phase | what | state |
|---|---|---|
| P0 | the asm moves to `src/y/arch/*.s` | **done**, merged (`0f24376`) |
| — | the portable tier: integers/bits, float comparisons and constants, RNGs, `[float]` array work (`src/y/std/math.y`) | **done** (`85403df`) — no compiler change needed; tests `t300`–`t304` |
| P1 | `native def` | **done** — nine users' worth of tests, no std user yet |
| P2 | `enc64` mnemonics + `math.s` primitives (`y_sqrt`, `y_to_int`, `y_fbits`, `y_bitsf`) | **done** — `sqrtsd` was the only mnemonic missing; `movq`/`cvttsd2si`/`cvtsi2sd` were already there. The other five (`movsd`, `movapd`, `xorpd`, `andpd`, `unpcklpd`) arrive with P4, which is the first code that emits them |
| P3 | the transcendentals in Y, gated by the ulp harness | |
| P4 | `exp`/`log`/`pow`/`sin`/`cos` moved into `math.s` | |
| P5 | the bulk kernels | |

## 6. Sequencing

Each phase ends green: `make ycc` byte-identical after `make rebless`, then
`make check`, then `make test`.

| phase | what | gate |
|---|---|---|
| **P0** | **the asm moves out of Y into `.s`** — `src/y/arch/prelude.s`, `threads.s`, embedded by both copies, split and `#`-stripped in `arch_prelude_lines()`; `make asm-check`; `ARCH_ASM` in the Makefile; PORTING.md rule 11 | `cmp ycc refs/ycc.ref` **byte-identical** — this phase changes no semantics at all, so every emitted byte must match — and `make test` green |
| **P1** | `native def` end to end, **no asm yet** — parser, AST, types, rename, native, lint, `src/c/`, docs, one fixture | `make ycc` byte-identical; a `t*.y` calls a native whose label exists; fuzz clean (R12) |
| **P2** | `enc64` mnemonics; `math.s` gains `y_sqrt y_to_int y_fbits y_bitsf`; math.y's portable half | every suite; `make asm-check`; size/time in `make check` |
| **P3** | the transcendentals in Y on the primitives | the ulp harness: max ulp per function against a **checked-in** `(input bits → expected bits)` table generated once from mpmath, so the suite needs no python at run time; plus property checks (exp∘log ≈ id, sin²+cos² ≈ 1, `sqrt(x*x) == \|x\|` for normal x, monotonicity, ±0/±inf/NaN/subnormal/2^53/INT64 edges) |
| **P4** | `exp`, then `log`, `pow`, `sin`, `cos` moved into `math.s`, **one at a time** | **bit-identical to the Y version** over a 10k-case corpus (random + edge). The Y version stays in the tree as the oracle. |
| **P5** | the bulk kernels | `make bench` on `bench/y/fmath.y`: the ns/element numbers vs the measured 1.27 ns/element Y baseline |

P0 is independent of everything else and worth doing first on its own merits: it
is a pure refactor whose only gate is that not one emitted byte changes, and it
gives the new asm a home before there is any new asm. P1 likewise lands the
language feature with zero users.

The Y-first-as-oracle order is what makes P4 safe: the assembly version is
validated against a correct implementation that is already in the tree, not
against a table of expected values. If P4 stalls, P3 ships a module that is
useful and fast, and the assembly is a follow-up.

### Tests and docs

- `test/y/native/t_math_*.y` — the portable half and every native (R11 requires
  each one called by a checked test), with ±0, ±inf, NaN, subnormals and the
  2^53 / INT64 boundaries; `e_native*.y` for the three new diagnostics.
- `test/y/native/t_native*.y` — the feature itself, independent of math: the
  three forms (derived label, explicit label, a label in another module), a
  native taken as a value and called through it, a native whose label is
  referenced but unused elsewhere (the shaking case, checked with `nm`),
  `-g` (`test_debug.sh` covers the DWARF side).
- **New `test/sh/test_math.sh`** (suite 16 → 17: `run_all.sh`, `lib.sh`,
  Makefile, `AGENTS.md`) for the ulp harness.
- For P0 specifically: `PORTING.md` gets a rule for an embedded **assembly**
  file next to rule 10 (same `.incbin` mechanism, different file kind), and
  `AGENTS.md`'s build section documents `ARCH_EMBEDS`/`make asm-check` and that
  `src/y/arch/*.s` is where assembly lives.
- `docs/src/02-lexical.tex` (the `native` keyword), `03-grammar.tex`
  (Declarations), a new module section in `09-builtins.tex` naming every
  function and which of them are native, `test/COVERAGE.md` rows, `NATIVE.md`
  (optional-modules paragraph, the *Limits* float paragraph, the `y_` rule),
  `AGENTS.md` (layout, pipeline paragraph).
- `bench/y/fmath.y` so `make check`/`make bench` score the new code (R9).

---

## 7. Decisions

All closed.

| # | Decision | Resolution | Why |
|---|---|---|---|
| D1 | `native` reserved or contextual keyword? | **reserved** | Uniform in the parser, `find_dup` and coverage.sh's keyword check. Nothing in the repo binds `native` — all 16 occurrences under `test/`, `bench/`, `examples/`, `src/y/std/` are comments about `native.y`. |
| D2 | Explicit `= "label"` form? | **keep it** | ~3 lines of parser; covers one assembly body with several Y signatures, and makes D3 a policy rather than a structural consequence. |
| D3 | Must a label start with `y_`? | **yes, always** | Keeps the reserved-prefix rule meaningful and confines a native to arch/runtime labels, so it cannot reach an internal helper or arbitrary program label. |
| D4 | `native def` and `def` of one name in a unit? | **reject it** | Otherwise two bodies land under one bare label with no duplicate scan — a *silent* miscompile, not a diagnosable one. |
| D5 | A native with no assembly on the target backend? | **accept the asm error** | `undefined label 'y_exp'` from `asm_link` — an error on that backend only, naming the exact label, fixed by one entry in `arch_prelude_lines`. The alternative ("use the label if defined, else this body") pushes the decision into the emitter and makes the bytes backend-dependent by design. |
| D6 | May a native be used as a value? | **yes** | No captures, so it is the ordinary code-pointer closure — free, and it keeps natives interchangeable with defs at call sites. |
| D7 | How much asm moves to `.s`? | **the existing prelude too** | The asm is 1869 of arch_x64.y's 2181 lines and is hand-duplicated in arch_x64.c; moving it deletes ~1870 lines from each copy and makes R1 apply to the glue instead. Verified byte-identical by `make ycc`, so the phase carries no semantic risk. |
| D8 | May the `.s` files carry comments? | **`#` comments, stripped at split** | The in-tree assembler treats a comment as a backend bug, and that invariant should stay; stripping in `arch_prelude_lines()` (~10 lines, mirrored) means a 700-line hand-written `y_exp` can still carry its prose, and `#` is also GNU as's spelling. |
| D9 | Does GNU `as` validate the `.s` files? | **a `make asm-check` target** | Catches a typo in the new asm at build time rather than when a program first calls it. ycc's assembler stays the authority — GNU `as` accepts a superset of what `enc64` encodes. |

Two policies remain to fix while writing the module (not structural, and both
belong with whoever owns the language): the `to_int` edge-case rule and the
accuracy target — see §5.

---

## Appendix: measuring

All of it on this box with `./ycc`, best of 5 runs of 1–2 M iterations, whole-loop
averages including loop overhead and the harness:

```y
def p0(x: float) -> float { x };
def p1(x: float) -> float { x * 1.5 };
def p5(x: float) -> float {
    let a = x * 1.5; let b = a * 1.5; let c = b * 1.5; let d = c * 1.5;
    d * 1.5
};
def loop(n: long, f: (float) -> float) -> float {
    let s = 1.0; let i = 0;
    while (i < n) { s = f(s); i = i + 1; };
    s
};
def best(f: () -> long) -> long {
    let b = 1000000000; let r = 0;
    while (r < 5) { let t = clock_us(); f(); let d = clock_us() - t; if (d < b) { b = d; }; r = r + 1; };
    b
};
let N = 1000000;
print(best(def () -> long { loop(N, p0); 0 }));   //  986  -> loop + call
print(best(def () -> long { loop(N, p1); 0 }));   // 1437  -> + 1 mul
print(best(def () -> long { loop(N, p5); 0 }));   // 7180  -> + 5 muls
```

Other figures quoted above, and how: `[float]` element read, a 2 M-element
`while (i < n) { s = s + a[i]; i = i + 1 }` at 2543 µs → 1.27 ns/element; the
table-initialisation cost, `let T: [float] = [...]` compiled with `-S` and the
total line count compared against a 212-line `print(1)` program (64 → 547, 256 →
1507, 1024 → 5347); `y_fmod` at 2691 µs/1e6 = 2.69 ns.

The `valgrind --tool=callgrind` instruction counts from `bench/profile.sh` are
the exact version of this table, and are the right tool for the P4/P5 numbers —
wall clock on a shared machine will not resolve a 2x on a 40 µs row.