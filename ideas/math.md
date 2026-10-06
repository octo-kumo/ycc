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
ord byte_at chr tolong tostring typeof last_index_of join fork spawn wait_pid
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
| P2 | `enc64` mnemonics + `math.s` primitives (`y_sqrt`, `y_to_int`, `y_fbits`, `y_bitsf`) | **done** — `sqrtsd` was the only mnemonic missing; `movq`/`cvttsd2si`/`cvtsi2sd` were already there. `movsd` and SSE arithmetic with a memory source have since landed too (`f95398b`..this commit), and **P4 finished without needing `movapd`/`xorpd`/`andpd`/`unpcklpd`**, so those four are still absent from both encoders and that is the finished state rather than a remainder: they were to arrive only if a kernel wanted them, and what a kernel actually wants is SSE-register residency, which `movsd` plus `mulsd`/`addsd`/`subsd` with register sources already gives. The one thing none of them would have saved is a sign flip, and no kernel has one to do — `y_pow` takes its sign off in a GPR (`shl`, then the bits are a biased exponent), and `y_fmod` shows the GPR-only style needs zero new encodings at all |
| P3 | the transcendentals in Y on the primitives | **done** — `exp exp2 expm1 log log2 log10 log1p sin cos tan asin acos atan atan2 sinh cosh tanh pow`, all in plain Y on top of `poly_split`, `prod_err` and `two_sum`. The ulp table is now **2695 cases** (the pinned edges, a seeded 1500-case spread, a seeded 240-case spread over [-1, 1] for the only two functions with a bounded domain, and the exact layer's own 619) and **every one of them is within 1 ulp**, worst gap 1 — the number the gate enforces and the number the manual quotes, including for all five assembly kernels. It was four cases over it, at up to three ulps; §8 has what closed them, and it is one lesson three times. The exact layer's own share of the table is still exact. The table is generated from this platform's libm rather than mpmath: mpmath is not installed here, and a platform libm is the *relevant* reference anyway -- the promise is to match what C gives. `gen_kernel.py` fits and prints the coefficients and reports the split evaluation's error before they are pasted in |
| P4 | `exp`/`log`/`pow`/`sin`/`cos` moved into `math.s` | **the instruction work and `exp` are landed.** `y_exp` is **generated** by `test/math/gen_exp.py` from `math.y`'s own constants and walks the same operations in the same order, so it returns the same double: t311 checks **10,420 arguments bit for bit**, reaching every branch (the NaN test, both range edges, the reduction boundary at each end, the subnormal band, the top of the range). **1422 → 105.7 Ir/call** (ten Y functions collapse into one routine) and **69.6 → 31.9 ns/call** net of a 4.7 ns loop, on `bench/y/tmath.y --full` (run bare it is a fast smoke test — 20,000 calls a row and 15 exact assertions — because `make check` profiles every `bench/y` program under callgrind and the deep setting took 107 s of it against 5 s for the next-slowest). `y_log` has landed the same way (`test/math/gen_log.py`, t312: **10,317 arguments, 0 differing**, **1335 → 115.2 Ir/call**, 71.8 → 34.9 ns/call). `y_sin`/`y_cos` have landed the same way (`test/math/gen_sin.py`, one body for both: two two-instruction entries and the choice in a register, t313: **10,410 arguments each, 0 differing**, **1775 → 190 Ir/call**, 75.4 → 40.4 ns/call). `y_pow` has landed the same way (`test/math/gen_pow.py`, t315: **15,137 pairs, 0 differing**, **3004 → 472 Ir/call**, 159.3 → 69.2 ns/call) — the first routine in the file that calls, and therefore the first with a frame. **P4 is complete.** §8 has what each attempt found |
| P5 | the bulk kernels | **done** — `y_sum y_dot y_scale y_axpy y_min_of y_max_of` in `src/y/arch/math.s`, reached from `std/math.y` through `a.ptr` and `len(a)`, each **bit-identical** to the Y loop kept beside it as `*_y` (t310, over 64 corpora plus the edge values: ±0, both infinities, NaN in first/middle/last position, subnormals, one element, empty). The equal-length rule moved out of the loop, so `fdot`/`faxpy` stop on a mismatch (`y_len_stop`). `bench/y/fmath.y`: **0.37 ns/element against the Y loop's 1.26**, and the 1.27 baseline the plan quotes is the last row of that file |

## 6. Sequencing

Each phase ends green: `make ycc` byte-identical after `make rebless`, then
`make check`, then `make test`.

| phase | what | gate |
|---|---|---|
| **P0** | **the asm moves out of Y into `.s`** — `src/y/arch/prelude.s`, `threads.s`, embedded by both copies, split and `#`-stripped in `arch_prelude_lines()`; `make asm-check`; `ARCH_ASM` in the Makefile; PORTING.md rule 11 | `cmp ycc refs/ycc.ref` **byte-identical** — this phase changes no semantics at all, so every emitted byte must match — and `make test` green |
| **P1** | `native def` end to end, **no asm yet** — parser, AST, types, rename, native, lint, `src/c/`, docs, one fixture | `make ycc` byte-identical; a `t*.y` calls a native whose label exists; fuzz clean (R12) |
| **P2** | `enc64` mnemonics; `math.s` gains `y_sqrt y_to_int y_fbits y_bitsf`; math.y's portable half | every suite; `make asm-check`; size/time in `make check` |
| **P3** | the transcendentals in Y on the primitives | the ulp harness: max ulp per function against a **checked-in** `(input bits → expected bits)` table generated once from the platform's libm (checked in, so the suite needs no python at run time), and a seeded random spread on top of the hand-picked edges -- which is what found `cbrt`'s seed bug, a case no hand-picked list had; plus property checks (exp∘log ≈ id, sin²+cos² ≈ 1, `sqrt(x*x) == \|x\|` for normal x, monotonicity, ±0/±inf/NaN/subnormal/2^53/INT64 edges) |
| **P4** | `exp` (done), then `log`, `pow`, `sin`, `cos` moved into `math.s`, **one at a time** | **bit-identical to the Y version** over a 10k-case corpus (random + edge). The Y version stays in the tree as the oracle. **All five are done**: `t311` 10,420 arguments, `t312` 10,317, `t313` 10,410 each for sin and cos, `t315` 15,137 pow pairs — all 0 differing. Done for `exp`: `t311_math_exp_asm.y`, 10,420 arguments, 0 differing; `test/math/gen_exp.py` generates the routine from the Y so the table cannot drift; the three encoder bugs it needed are in `e123e2a` |
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

## 8. What P4's first attempt found (2026-10-05)

The assembly `y_exp` was written -- 193 lines, generated by a script so the
coefficient table is *read out of* `src/y/std/math.y` rather than copied, since
the whole constraint is bit-identity with the Y -- and it does not yet compute
`exp(1.0)`. What the attempt established, in the order it established it:

**The encoder could not spell a kernel at all.** Three gaps, all of which
assemble happily and fail later:

1. `movsd` had no encoding. F2 0F 10 /r for a load, 11 for a store.
2. `addsd`/`subsd`/`mulsd`/`divsd` took register operands only. A kernel is
   `mulsd %xmm0, c7(%rip)` over a coefficient table, and a separate load per
   term is a wasted instruction twelve times over.
3. Neither the *shaker* (`shake_refs`, which keeps the rodata a program
   reaches) nor `line_refs_b` (which finds what an asm text mentions) knew a
   label can appear in an SSE operand: they looked at `call`, `lea`, `mov` and
   nothing else. So the coefficient table was shaken away and the label came
   back undefined.

Two traps in that code that cost real time, and that a fixture should keep:

* The F2 prefix is **load-bearing**: without it these are the PACKED forms
  (`movups`, `mulps`), which read sixteen bytes and multiply twice as wide --
  and they assemble. The symptom was a routine that returned a plausible but
  wrong number, three instructions later.
* `.quad` rejected a negative value, which is *half* of every float's bit
  pattern (the sign bit). A table of IEEE-754 constants cannot be written as
  decimal `.quad`s until that is relaxed.

Also missing and needed: `jp`/`jnp` (how an SSE comparison says "unordered" --
the first test of every float function), and the above/above-or-equal/below-or-
equal family.

**And one bug in the routine itself, found by the floor-by-hand:** `cvttsd2si`
truncates, and the correction is "one less when the truncation rounded *up*",
which is when the truncated value is **greater than** the value it came from --
a negative argument, or `1.0..1.5`, where trunc gives 1 and floor gives 0. It
is written the other way round in the version that does not work.

The debugging method that actually moved it, for the record: return an
intermediate from a *variant* of the routine (`movq %xmm0, %rax; ret` inserted
after the point of interest) and compare against the Y version's own value at
that point. Four probes localised it from "the routine returns 0.0" to "k is 0
for every input". Single-stepping was a dead end, because the REX byte that
`put_rex` emits for every memory operand makes gdb misalign, and its subsequent
"rip jumped somewhere impossible" readings were an artifact of that.

### What the second attempt added (2026-10-05)

The instruction work is landed. Four things it cost that the first attempt did
not find, in the order they cost them.

**`src/y/arch/math.s` is EMBEDDED.** `ARCH_EMBEDS` in the Makefile lists it, so
editing it needs `make ynew`, not just a re-run. Half an hour went into
debugging a stale compiler that reported an error on a line I had already
fixed. The same is true of `arch_x64.y`, and `make check` had to be re-run
from a *clean* build before any of its verdicts could be believed: a `make
ynew` that fails its fixpoint check leaves the OLD binary in place, silently,
because `mv` is the last step.

**A trailing `#` comment in a `.s` file is an assembler error.** `arch_asm_lines`
drops a line only when its *first* byte is `#`, so `movq %rax, %xmm0  # xmm0 = a`
reaches the assembler, which reads `#` as an operand: `L501: bad operand`, on a
line whose opcode the prelude uses everywhere. `make asm-check` **passes** such a
file, because GNU as reads trailing comments and this assembler does not. Every
comment in the three arch `.s` files is now flush left, which is what the other
two already did (neither had a single indented `#`).

**The shaker's cost is per BYTE of rodata, and a label is not free either.**
`shake_refs` scans the whole `arch_consts` text on every compile whether or not
the program uses one byte of it, at ~27 instructions per byte — measured, by
bisecting the file. The four constants the form probes need cost +27.8K
instructions on hello.y as a fifth label, and +36.5K as four more. So:

* a coefficient table is **one label**, read as `tab+0`, `tab+8`, … — which is
  why `label+N(%rip)` exists at all (`asm.y`'s `label_addr` splits on `+`, and
  only on a miss, so the common path pays nothing);
* and the probes' table lives in **`math.s`, not `arch_consts`**: math.s is
  shaken block by block, so a program that calls no probe drops the table with
  the probes, where a table in arch_consts is carried by every program that
  reaches it. Measured: with the table in arch_consts, `t308` carried 32 dead
  bytes; in math.s it carries none.

Skipping directive lines in `refs_range` — no directive this assembler has names
a label, and the `.file` path that lives in a fixup's label *field* is not a code
reference — pays for the tables P4 is about to add: it took hello.y from +1.1%
back to +0.47%, against a base of 3.893M instructions.

**And one trap worth its own paragraph, because it cost the longest.** The
obvious way to carry a table offset is a fifth field on `Fixup`. Doing that makes
Y and C silently disagree about the `.debug_line` table — `cycc` and `ycc` emit
byte-identical binaries for every program except under `-g`, where the C
compiler's line table is 27 bytes of CU where the Y compiler's has the file
table and every `std/rt.y` row. **`make check` does not see it**: the port gate
builds `ycc.y` *without* `-g`, so the two copies agree on every byte it looks
at. Only `test_debug.sh`'s "cycc -g and ycc -g emit identical binaries" caught it,
which is a point in that suite's favour.

The cause is that `asm_loc`/`asm_file` build **four**-field records for the DWARF
markers and hand them back where a `Fixup` is expected; the C twin passes
records straight through and Y does something to them. So the offset rides in
`lbl` instead (`tab+8` reaches `label_addr` whole) and `Fixup` keeps four fields,
with a note on the type saying why. **Do not add a field to `Fixup`**: the
port gate will not catch it and nothing else will.

### What the trigonometry attempt found (2026-10-05)

`y_sin` and `y_cos` are one body: `y_sin` is two instructions that clear `%r11`,
`y_cos` two that set it, and both jump into `ysincos_go`, which computes `s` and
`c` together and picks by the quadrant at the end. cos's coefficient table is
sin's rotated left by one, so the selection is an index `(q + which) & 3`, a test
of bit 0 and a test of bit 1 — and `n & 3` is exactly the Y's `quadrant(n)` for
every n including the negative ones, which is why the sign handling costs
nothing. It is bit-identical to the Y over 10,410 arguments each (t313).

**Four bugs, and the shape of the last one is the useful part.**

**A label is global across the arch files, and `ysc_` was taken.** The prelude's
`y_str_cat` helper is `ysc_copy`/`ysc_skip2`, and the new kernel wanted `ysc_go`
and `ysc_done`; the assembler's answer is `duplicate label 'ysc_done'`, which
reads like a mistake in the *new* file and is really a collision with a file that
has nothing to do with trigonometry. Everything is `ysincos_*` now. Nothing in
the tree reserves a prefix per file, so this is a naming convention rather than a
check — and `y_` is the only prefix the language enforces.

**Folding `r` in early is not the same function.** `s = r*(1 + w*P)` and
`r*(1 + r*w*P)` agree to a mathematician and not to a bit. The generated sequence
multiplied by `r` first because it wanted `r*w` to hand to something, and
`sin(0.5)` came out at 0.48971277 against the Y's 0.47942554 — 2%, which no
6-term kernel can produce and which therefore says *the sequence*, not *the
coefficients*. The multiply by `r` is the last instruction now, and the comment
says why it looks harmless.

**Four values live at once in `prod_err`, and the register plan had three.** The
Y's expression is `((ah*bh - p) + ah*bl + al*bh) + al*bl`, so `ah`, `al`, `bh` and
`bl` are all live after the two splits — and the generator gave the b split the
register `ah` was in. It then computed `bh*bl` where the Y computes `ah*bh`, so
with `a = 0` (which is every argument below pi/4, where `n` is 0 and every
product is 0) the routine returned `bh*bl` instead of 0.

That one took the longest, and the reason is worth keeping: **the symptom was a
constant additive offset in `r`** — 4.388754271e-8, the same for `x = 0.5` and
for `x = 1.0`, and `sin(0.0)` returning exactly that. A constant offset in an
argument that was read correctly at `mov 8(%rsp), %rax` (verified in gdb) says
something *adds* to it, and the only additions after that point are the
reduction's four subtractions and `err`. Everything else had already been ruled
out by then: the table's 42 entries decode to their names, the fixups resolve to
`tab+N`, the listing is byte-identical to the source modulo comments, and `err`
is the only term that can be non-zero when every product is zero. "The offset is
constant" was the clue; "the offset is a plausible float" was a dead end.

**`test $imm, %reg` had to be added, and it has a trap in the obvious
direction.** The kernel asks which of four it has, so it needs to set flags from
a value without writing it back. The first version chose F6 (`test r/m8, imm8`)
whenever the immediate fit in a byte, on the assumption that the 83/81 rule the
other six ALU mnemonics follow would follow here. **F6 tests `%al`, and x86
ignores REX.W on it** — so `test $1, %rax` tested the low byte of the register.
Every reachable index is under 256, so it *worked*, and the bytes were wrong in a
way no test of `test $1` could ever see. The form now follows the operand's
width, and `t314` pins it with an immediate the 8-bit encoding cannot even hold.

The measurement that decided it is the one worth repeating, because the reasoning
was wrong first: `F2 48 0F 2A` reads as `CVTSI2SS` in objdump and looks exactly
like a missing mandatory prefix, and "add 0x66" is what the SDM's other opcodes
lead you to. It is **F2 that is the double form and F3 the single** on 0F 2A and
0F 2C, so the encoding was already right; objdump takes `F2 66` for a `cvtsi2sd`
and the CPU runs it, but it is not an encoding the instruction has. The change
was reverted, and the note on both encoders now says which way round it is and
why it looked the other way.

**`uses_math` is a gate, and a new arch entry point is invisible without it.**
`native.y` decides whether `math.s` is in the binary at all from a *length-first*
name list (it is a hot loop: ~50K references on the self-compile), and a name
that is not in the list does not reach the shaker as a root — so the answer is
not a missing block but `undefined label 'y_test_imm'`, from a probe whose own
text is right there in the file. Any new `y_` label in `src/y/arch/*.s` has to
be added to that list, and the list is the only place the tree records which
labels are entry points.

### What the power attempt found (2026-10-05)

`y_pow` is the first routine in `math.s` that **calls** anything, and that single
fact decided its shape before a single instruction was written. The dispatch, the
two-part logarithm, `exp2` of the pair and `ldexp` are four routines; every SSE
register is caller-saved, so anything that has to outlive a call has to live in
memory. Hence the frame, hence `y` being read into `-8(%rbp)` once and reloaded
after each call, and hence `log2_dd` answering a **pair in two registers** where
the Y leaves it in the module-level cells `log2_hi`/`log2_lo`/`ts_lo`/`z_lo`.

Two decisions worth recording as decisions rather than as accidents:

**`prod_err` is inlined here and called in the trigonometry, which is the
opposite of what the trigonometry does with the same routine.** In `pow_pos` the
first product's error is one of four terms the answer is summed from, so a call
would spill three live values and reload them around it — and a spill is the kind
of mistake that no test of the arithmetic catches. The trigonometry's two calls
feed an accumulator and nothing else, so it calls. Twenty-eight instructions
twice beats one call plus three spills.

**The exponent kernel is a second copy of `y_exp`'s polynomial, reading the same
`yexp_tab`.** Sharing it would mean `y_exp` calling a helper, and `y_exp`'s live
values at that point are `t` in `%xmm2`, `k` in `%rcx` and `f2` in `%xmm6` — all
caller-saved, so the call would cost a spill and two reloads in **exp's own hot
path** to save twenty-eight instructions of code that only a program using both
`exp` and `pow` carries twice. The tables are shared, so there is still one copy
of every coefficient.

**Six bugs, and three of them are the same mistake in three costumes.**

**`movq %gpr, %xmm` moves BITS on this machine.** The Dekker splitter
`134217729.0` was materialised as `mov $134217729, %rdx` followed by
`movq %rdx, %xmm2`, and the answer was a *bit* copy, so `xmm2` held the integer's
bit pattern and every product split into itself and a zero — `prod_err` returned
`0.0` for every argument, exactly, which is what a broken product looks like
rather than what a subtle one looks like. The fix is to read the splitter from a
table entry like the trigonometry always did. **The lesson is that "assembled,
ran, and moved the wrong thing" is a class of its own**, and the only reason this
one was found in an hour rather than a week is that a routine answering exactly
zero for every input is not a bug anybody rationalises.

**An unordered comparison sets ZF as well as PF.** `y == 0.0` was one `je` after
`ucomisd`, so a NaN exponent took that arm — `ucomisd` sets ZF on an unordered
result, and `je` does not care about PF — and `pow(2, nan)` answered `1.0`. The
fix is a second branch that skips the arm when the comparison was unordered, *not*
moving the NaN test up: the Y's order is what makes `pow(nan, 0.0)` come out
`1.0` rather than `nan`, and reordering to "tidy" the NaN test would have broken
that while fixing this.

**A two-argument native reads the LAST argument from `8(%rsp)`.** The emitter
pushes arguments in source order, so the first is at `16(%rsp)` and the second at
`8(%rsp)` — the reverse of the natural reading, and `y_sum` is the cross-check
(`sum_asm(a.ptr, len(a))`: its pointer, the first argument, is at `16(%rsp)`).
This was wrong twice in opposite directions before it was right, and the
symptom in both cases was `y == 0` answering `-0.0`: the kernel thought the base
was zero. Note what the evidence was — `y_sum`'s own reading, visible in the
source, contradicting the reading the arguments' names suggest.

**`trunc`'s guard was inverted.** `jbe` after the comparison against `2^63`
returns *small* values unchanged, so `trunc(0.5)` came back `0.5`, `is_int(0.5)`
came back true, and **every fractional exponent went down the integer path**.
The kernel answered `1.0` for `pow(2, 0.5)`. The guards also have to test the
NaN *first* and on its own: a NaN sets CF and ZF together, so one
below-or-equal covers "below", "equal" and "unordered" at once, and the conversion
of a NaN is the indefinite value — a very large number rather than no number at
all.

**A sign flag read after the instruction that clobbered it.** `ypow_int` decided
"reciprocate?" by testing the sign of `%rdi` *after* `neg %rdi` had put the
opposite sign there, so every positive exponent was reciprocated and
`pow(2, 3)` answered `0.125` — `pow(2, -3)`. The flag is a register now, and the
comment says why: the test has to survive the arithmetic that produced the value
it is testing.

**`0.0 - v` was assembled as `subsd %xmm0, %xmm0`.** The zero was loaded *into*
the answer register and then subtracted from itself, which is `+0.0` for any `v`.
So an odd exponent past 1024 answered `+inf` where the Y answers `-inf`, and
`pow(-2, -1025)` answered `+0.0` where the Y answers `-0.0`. The negation is
`0.0 - v` and the zero has to be somewhere else.

**The probes found everything, and the last one found nothing.** The generator's
`l`, `lo`, `p`, `q`, `e1`, `e2` and `e2a` stages each return one intermediate,
compared against the Y's own value at that point. `log2_dd`'s two halves and
`exp2_corr` were exact on the first run; `p` was exact; and `q` was the odd one
out — which is what pointed at `prod_err` and then at the splitter constant. The
stages are also how the *stage probes themselves* were debugged: `p` and `q` read
their two arguments out of the two slots the one-argument stages do not use, and
reading them the other way round swaps `p` and `q`, so the `exp2_corr` probe
measured nothing while looking entirely plausible.

### What closing the ulp exceptions found (2026-10-05)

The gate the harness *claims* is "nothing more than one ulp from the reference"
and the gate it *enforces* was three. That is the worst kind of test: a header
that says something the code does not check. So the numbers were wrong in three
places at once — the harness's own comment, the manual, and this file's status
table — and four cases sat over one ulp: `cosh` at two, `pow` at three and two.

**Three of the four were one rounding each, and none of them was where the code
looked wrong.** The lesson is the same one `prod_err` teaches in a different
guise: the question is never *which line* rounds, it is *at what size*.

**`cosh` summed two exponentials where one exponential and its reciprocal is
enough.** `(e^a + e^-a)/2` for `a >= 0.5` has `e^-a` at 1.2% of the answer, so its
own rounding is a hundredth of an ulp — while a second `exp()` call brings a
whole kernel's error along, and `exp` is a ulp out at some arguments. `t*0.5 +
0.5/t` is one divide instead of one kernel, and `cosh(-1.88)` stopped being two
ulps out. Scaling each term *before* the add (rather than the sum afterwards)
turned out to matter not at all on its own: with two exponentials it is still
exactly two ulps out, because the error was never in the summation.

**`pow` was two and three ulps out, and the logarithm's `z * (2.0 + w * P)` was
the whole of it.** That expression rounds *at the size of 2.0* — a whole ulp of
the logarithm — and pow multiplies the logarithm by the exponent, so a
half-ulp-sized rounding in a place that looks like a small correction is worth
three ulps of the answer at `pow(23.85, 5.6)`. Writing the term as
`two_sum(2.0 * z, (z * w) * P)` and carrying the residual into the log's second
part took `log2_dd`'s own residual down 2.3 times (6.25e-17 to 2.74e-17 on the
case that showed it) and both `pow` cases with it.

Measured, because the arithmetic is the deliverable here: the exponent's error
was 0.018 ulps from the log's low half, 0.043 from `inv_ln2`, and **0.142 from
`q`'s own summation** — and 0.142 × `ln 2` × `u` is the three ulps of the answer.
The fix was not in `q` at all, which is where both the symptom and two hours of
looking pointed.

**The fourth case is `asin`, and the floor argument for it was wrong — which is
the second lesson, and the more useful one.** Its large branch is the half-angle
identity `asin(a) = pi/2 - 2*asin(sqrt((1-a)/2))`, and `two = 2*asin(s)` has to
be a double before `pi/2 - two` can happen: that half-ulp is a *whole* ulp of
the answer, and the subtraction's is half more. Measured over the branch, a
kernel of any degree on the exact Taylor coefficients (`C(2k,k)/(4^k(2k+1)`,
which is what `sinh_k` is too) bottomed out at **2 ulps**, and it looked like a
property of the reduction: no fused multiply-add, no extended-precision
evaluator, nothing to carry `two` with. The tolerance was set to 2 on the
strength of that, and the arithmetic behind it went into the harness's own
header.

Then the measurement was re-checked, and the 2 ulps was a bug in the *probe*:
it added `two`'s low part **after** the 2-sum instead of folding it into a
compensated three-term subtraction. Done properly — `two_sum(pi/2, -two_hi)`,
then subtract `two_lo` from the *result*, which is where a few 1e-17s do not
cancel against an 0.8 and leave nothing — the same 24-term kernel with the
square root's own residual put back gives **1 ulp**, and the floor was never
there.

**Then the gate was made denser, and it found a fourth thing that no amount of
arithmetic would have.** `asin`'s rewritten branch was gated by **eight
arguments**. The table draws its interior cases from a uniform spread over
[-8, 8], and only about one value in eight lands inside `asin`'s and `acos`'s
domain [-1, 1] — so each of those two functions had 77 cases of which 59 were
the `|x| == 1` edge, which returns `pi/2` before any work happens. Eight cases
was the whole gate on a 24-term polynomial whose degree a 20,001-point sweep had
chosen. A grade-school observation and a two-line change to the generator, four
months of nothing.

It paid for itself three times over, and each fix exposed the next: **130 cases
over 1 ulp**, then 15, then 0.

- `acos` was `pi/2 - asin(x)`, and near `x = 1` that answer is 3e-8 against a
  `pi/2`: eight digits cancel before the answer exists. `acos(1 - 4e-17)` was
  **forty ulps** out, and the case below it four. `acos` cannot go that way round
  at all — its large half now takes the half-angle `2*asin(sqrt((1-x)/2))` that
  `asin`'s kernel already computes, and forms the small answer directly.
- Rewriting it dropped `acos`'s **sign**: `acos(-0.461)` came back with the value
  for `+0.461`, which 130 cases caught at once.
- Then it read `asin_half`'s result cell *inside* the expression that uses it —
  where the order the two operands are evaluated in decides the answer. Fifteen
  cases.
- Then `acos(1.0)` divided `0/0` for the square root's residual, which `asin`
  never reaches because it answers ±1 before arriving.

**What it cost: nothing.** Both halves measured in one program, the same loop
over the same arguments, the old implementation and the new one verbatim (two
copies of `std/math.y` cannot both be imported — their `native def`s collide,
which is that rule doing its job — so the arithmetic under test is a local copy
fed by the module's own unchanged primitives):

```
acos OLD, |x| > 0.5    93.25 ns/call    1975 Ir/call
acos NEW, |x| > 0.5    77.28 ns/call    1255 Ir/call
```

The new one is **16 ns a call FASTER** on the branch it changed, and 720
instructions lighter. The old path paid `acos_old` (445 Ir), then `math.asin`'s
own 765, then the kernel's 765; the new one pays `acos_new` (490 Ir) and the
kernel's 765 and stops — it skips asin's sign and branch logic and the
`pi/2 - asin(x)` subtraction entirely, which is most of what it was doing. So the
commit that landed it quoted "+13 ns" and that was the wrong comparison: it
compared the new implementation's two branches against each other instead of
the old implementation's.

**And the same audit, run again, found nine more functions with no cases at
all** — `fmin`, `fmax`, `fabs`, `fsign`, `lerp` and the three predicates, plus
`ldexp`, which is gated only as the other half of `frexp`'s identity. The table
had only ever carried the functions with rounding in them, so the exact layer had
no gate whatsoever.

`fmin` and `fmax` were the ones that mattered, and their bug was not a rounding
at all:

```
fmax(0.0, -0.0)  ->  -0.0        so 1.0/fmax(0.0, -0.0)  ->  -inf
fmin(-0.0, 0.0)  ->  +0.0        so 1.0/fmin(-0.0, 0.0)  ->  +inf
```

A strict `<` and a strict `>` settle a tie by falling through to "return the
second operand", so the two zeros' signs came out decided by **argument order**.
The module's comment said the sign was "not specified", which C99 genuinely does
allow — and IEEE 754-2019's `minNum`/`maxNum`, this platform's libm, and any
caller that divides the answer all do not. A tie now goes to the
negative-signed operand for `fmin` and the positive-signed one for `fmax`, and
all four orderings are in the table. The cost is two comparisons on a path that
was already a comparison.

Which is the third lesson, and it is the one about the *gate* rather than the
arithmetic: a check that passes is not the same as a check that can fail. Eight
arguments is a check that reads as one, and *no* arguments is not a check at all.
The forty-ulp answer was sitting in a committed table waiting for a spread wide
enough to look at it; the minus-infinity was sitting in the module waiting for a
case to exist.

So the tolerance is back to **1**, which is what the harness's header claimed all
along and what C promises, and all 1596 cases are inside it — which is when the
gate was found to be too narrow to mean anything, and the fourth fix was waiting
behind it. The header carries the three fixes rather than an excuse, and §8 has
the fourth.
