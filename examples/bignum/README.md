# bignum — arbitrary-precision integers on `long` limbs, in Y

A signed arbitrary-precision integer library and a worked demonstration of it,
in one self-contained folder. A number is a **slot index**, its state is three
module-level arrays, and **no operation in the arithmetic allocates at all** —
which is only possible because Y's heap is an arena and nothing is ever freed,
so every byte you ever allocate counts for ever.

```
cd examples/bignum
../../refs/ycc.ref bignum.y -o bignum    # the build, verbatim from gate.conf
./bignum demo                            # the golden run: 4017 bytes
./bignum check                           # the property battery, ~0.07 s
```

Pinned compiler: **`refs/ycc.ref`, sha256
`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b`**, and this
folder was built and re-gated with exactly that binary and nothing else.

## What it is, in my own words

Y's `long` is a signed 64-bit integer, so 2^63 is the largest number you can
name. This program computes with numbers far past that and hands them back as
decimal text: **2^1000** (302 digits), 2^128, 2^256, the 40-digit semiprime
that Pollard's rho splits, 2^(p-1) mod p for a prime `p` no `long` holds. It
exists because 28-bit limbs are the interesting fit for a 64-bit word, and the
whole program is a demonstration of that one decision.

The representation is **signed, base 2^28, little-endian**: `L[s][i]` is limb
`i` of slot `s` and always below 2^28, `NC[s]` is the number of significant
limbs (`0` means the value is zero), and `NG[s]` is 1 iff negative and always 0
when `NC[s] == 0`. Slots are named: `S_ZERO`, `S_ONE`, `S_TWO`, `S_TEN` are
the constants, `S_A`…`S_J` are the caller's nine working slots, `SL0`…`SL15`
are the algorithms' private scratch. There are 36 slots of 131 limbs each —
**37 728 bytes of limbs, allocated once at startup** by `bn_init`.

**Why 2^28 and not 2^32.** Schoolbook multiplication computes
`limb * limb + carry + accumulator`, and `long` is *signed*, so the base is
bounded by what one limb product costs:

```
base 2^32:  (2^32-1)^2 = 2^64 - 2^33 + 1   >  2^63-1   OVERFLOWS
base 2^31:  (2^31-1)^2 + 2*(2^31-1)       ~  2^62       fits, barely
base 2^28:  (2^28-1)^2 + 2*(2^28-1)       <  2^57       fits, 64x margin
```

A 2^32 base would **wrap silently** — no trap, just a wrong product — so 2^28
buys a 64× margin instead. 2^28 is also the largest power of two that keeps
Knuth's quotient estimate honest, because it divides a *two-limb* numerator by
a one-limb divisor and 2^56 is comfortably inside a `long`.

What is in it: **add/sub** (magnitude first, then the sign — more code than the
signed form, and it cannot go wrong in the one place signed code always goes
wrong, a zero result coming out negative); **mul** (schoolbook, both operands
staged through scratch so every call site is alias-safe); **div/mod**
(**Knuth Algorithm D**, TAOCP vol. 2 §4.3.1, with the normalisation shift and
the give-one-limb-back correction); **gcd** (Euclid on magnitudes, returning 0
or 1-when-`b`-is-zero so a caller needs no special case); **pow/powmod**
(square-and-multiply by hand — there is no `pow` and no `^` in the language);
**decimal** (`to_dec` divides by 10^7, the largest power of ten below the 2^28
limb base, so one round is a single-limb division in and a single-limb multiply
out, both exact in a `long`; `from_dec` is its exact inverse); and the **`calc`
evaluator**, a shunting yard so every operator is reachable from the command
line.

The budget: **128 limbs = 3584 bits = at most 1083 decimal digits**. A slot
holds `SLIMB = NLIMB + 3 = 131` limbs, and `bn_shl` refuses at 128 while a
multiply refuses at 131 — so `pow 2 3643` (131 limbs) works and `pow 2 3644`
prints `bignum: the result does not fit in 3668 bits` and exits 1.

## How to run it

| command | what it does |
|---|---|
| `./bignum demo` | the worked demonstration — **this is the golden run** |
| `./bignum check [--verbose]` | the property battery; no reference file is read |
| `./bignum check --inject N` | re-run the battery with a named defect compiled in |
| `./bignum calc EXPR` | one infix expression, e.g. `./bignum calc '-(3+4)*2'` → `-14` |
| `./bignum show N` | decimal text, sign, bit and limb and digit counts, whether it fits a `long`, and the limbs themselves |
| `./bignum OP A B` | one operation; `OP` is `add sub mul div mod gcd cmp pow` |
| `./bignum errorpaths` | just group (E), the 39 forked children, on its own |
| `./bignum help`, `./bignum version` | the interface |
| `./bignum --stats demo` \| `check` | timings, **on stderr**, so stdout stays byte-identical |

Numbers may be decimal, `0x` hex or `0b` binary (`add 0x10 0b1` → `17`).

**Exit codes are 0 / 1 / 2 and mean three different things**, which is worth
stating because `main()`'s return value is *not* the exit status (see the
workarounds) — the program is built as `def main() -> long { … }; exit(main())`
so every `return 1` and `return 2` really is the process's status:

| code | meaning | examples |
|---|---|---|
| 0 | it worked | `demo`, `check`, `add 1 2`, `help` |
| 1 | **bad input** | `div 1 0`, `calc '1/0'`, `show notanumber`, `pow 2 4000`, `cmp -9223372036854775808 0` |
| 2 | **bad usage** | no command, `nope`, `frobnicate 1 2`, `div 1`, `check --wat`, `pow 2 -1` |

## What to look at — where to start

In this order. Each does one thing worth understanding, and the comment above it
says what for.

1. **`bn_init`** (`bn.y`) — the whole allocation story in one function: grow 36
   arrays to 131 limbs each and *then nothing allocates again*. It also stamps
   `S_ONE = 1`, which is not cosmetic — an earlier version left every slot
   zeroed, so `S_ONE` was 0 and every `bn_add(d, a, S_ONE)` in the program,
   every increment, took the "right operand is zero, copy the left" path and
   silently did nothing.
2. **`bn_from_long`** (`bn.y`) — the one value a `long` cannot negate is
   -2^63: `0 - v` wraps back to -2^63, so a plain "m = 0 - v" reads a
   *negative* magnitude and every limb comes out wrong. It is special-cased by
   its exact factorisation `2^63 = 128 * (2^28)^2`, i.e. limbs `[0, 0, 128]`.
   Notice also that every limb is **written** and `n` only counts up to the last
   nonzero one: skip zero limbs without writing them and every higher limb
   slides down a place, so 2^28 becomes the single limb 1 and dividing 1 by
   2^28 answers 1 with remainder 0.
3. **`bn_divmod`** (`bn.y`) — Knuth D, the one place a wrong answer would be
   *silent* rather than obvious, because the intermediate is a two-limb
   numerator. The block comment derives every bound (`< 2^56` throughout) and
   then explains the correction loop with the exact input that punishes the
   textbook form: when `v[n-2]` is 0 — any power-of-two divisor — the version
   comparing `v[n-2]` against `u[j+n-2]` has loop condition `0 <= anything`,
   the remainder never moves, and **the loop spins for ever**.
4. **`bn_mul` and `mag_mul`** (`bn.y`) — two things. `mag_mul` stages both
   operands through scratch so `bn_mul(c, a, b)` is safe when `d` aliases an
   operand (zeroing the result limbs in place destroyed `b` and silently
   returned 0). And `bn_mul` reads both operand signs **before** calling
   `mag_mul`, because `mag_mul` finishes by stamping `d`'s sign to 0 — a later
   read would see a cleared sign and conclude `(-1) * (-1)` is negative.
5. **`to_dec` and `bn_str`** (`bn.y`) — the chunking. Digits come out LSB first,
   seven per division by 10^7, and every chunk but the last is **exactly** seven
   digits wide, zeros included, because those zeros are real digits in the
   middle of the number. Zero-padding every chunk prints `1000000*1000000` as
   `"10"`; suppressing every chunk's padding prints it as `"1"`. The two
   mistakes cancel on some inputs, which is why `--check` compares the digit
   **count** as well as the text.
6. **`demo`** (`bignum.y`) — the five sections you see when you run it: the same
   arithmetic done twice (once on `long`, once on limbs), the 64-bit boundary,
   real factoring work past it, modular exponentiation by two independent
   routes, and the shape of the heap.
7. **`calc`, `cprec`, `creduce`** (`bignum.y`) — the shunting yard. Unary minus
   is in the precedence table at a *higher* level than both binary levels:
   leaving it out made `-5+8` come out as -13, because the pending unary minus
   sat below the `+`, was reduced last, and negated the whole sum.
8. **`t_error_paths`** (`check.y`) — every error path driven **end to end**
   through a forked child with its output on a pipe. It exists because a Y trap
   prints to *stdout*, so `1/0` would splice `runtime error: division by zero`
   into the output and look like a passing run.

## The property battery (`./bignum check`)

**This is the part a golden file cannot do.** `EXPECTED` can be regenerated from
broken output and still match byte for byte, so the battery asserts behaviour
with **no reference file involved**, and every expected value comes from outside
the code under test:

* **(A) the native `long`.** Y's `long` is a real signed 64-bit integer, and the
  CPU's own arithmetic is an oracle of a completely different kind from a second
  implementation of the same idea. 50 values chosen to straddle every boundary a
  28-bit limb has and every boundary a signed `long` has (0, ±1, 2^27, 2^28,
  2^29, 2^31, 2^32, 2^62, 2^63, and the value that cannot be negated) give
  **2500 pairs**: add, sub, mul, cmp, div, mod, each against the machine. Values
  that would overflow a `long` are **skipped, not compared** — a wrapped product
  would "disagree" with a bignum that is right, and reporting that would train
  the reader to ignore the check.
* **(B) hand-written decimal constants** past the 64-bit line: 2^64, 2^128,
  2^256, 10^69 and the full 302 digits of 2^1000, written out from an external
  source (CPython), not from this program.
* **(C) algebraic identities**, which hold at every width and so are the only
  oracle available above 64 bits: `a-a == 0`, `x-y == -(y-x)`,
  `(a+b)+c == a+(b+c)`, commutativity of `+` and `*`, `a*(b+c) == a*b+a*c`,
  `sign(a*b) == sign(a) XOR sign(b)`, and the division identity
  `a == (a/b)*b + a%b` with `0 <= |a%b| < |b|` and "the remainder follows the
  **dividend**". Over 19 values of up to 78 digits.
* **(C2)** `a * 10^k` computed two ways — one multiply, and `k` multiplications
  by ten — up to a 101-digit result.
* **(D) real work past 64 bits**, checked by facts that hold independently of
  the code: trial division finds a factor of 2^64+1 and it multiplies back;
  Pollard's rho splits a 40-digit semiprime and **the same seed gives the same
  factor twice**; Fermat's test **passes** on a prime *and also* on 561, a
  Carmichael number, which is exactly why one Fermat test is not a primality
  test.
* **(E) every error path**, end to end through a forked child: 23 refusals that
  must exit non-zero, say something, print nothing that looks like a trap and
  keep stdout clean — plus 8 inputs that are merely unusual (`01`, ` 12`,
  `--3`, `-0`, `((1+2))`) and **must be accepted**, with the right answer. A list
  of refusals alone proves nothing: a validator that refuses everything passes.
* **(F) the harness can fail.** Before any of the above is trusted, `eq_str` is
  handed two different strings and must record a failure, two *empty* strings
  and must **refuse**, and a group that compared nothing must fail its floor.
  Those four lines print `deliberate (harness self-test)`, not `FAIL`, and the
  counters are put back — the word `FAIL` never appears in a run that passes.

### The numbers, as measured here

```
  assertions   18716
  comparisons  18240
  refused      1  (an absent value is never absent-compared)
  groups       7
  heap after   5180784 bytes
  heap delta   5026912 bytes
```

`heap before` is 154 008 bytes; the run is 0.07 s wall and about 6.1 MB peak
RSS. **`refused 1` is the harness self-test's deliberate "two empty strings"
case** — counted as a refusal *and* recorded, so a comparison of two absent
values can never pass silently. Every group that compares things also asserts a
**floor** on how many comparisons it made (10 000 for A, 3900 for C, 100 for C2,
12 for D), so a group that silently compares nothing fails rather than reports
success.

### Defect injection: 13 injected, 11 caught, 1 slow, 1 equivalent

`--inject N` sets one `INJECT` value, and each site below is a **real bug this
library actually had while being written** — there is no
`if (INJ == 7) return 1` that proves nothing. All thirteen measured on the pin;
`golden/inject_matrix.txt` is the raw run.

| # | the injected defect | result | first assertion to fail |
|---|---|---|---|
| 1 | `mag_sub` never sets the borrow | **caught**, 964 | `sub`: got -536870911, want -268435455 |
| 2 | `mag_mul` drops the final carry | **caught**, 849 | `mul`: got 0, want 268435456 |
| 3 | the remainder takes the divisor's sign | **caught**, 146 | `mod`: got -268435454, want 268435454 |
| 4 | `bn_from_long` negates with `>>> 1 >>> 1` | **caught**, 4824 | `add`: got -2305843009213693951, want -9223372036854775807 |
| 5 | `bn_from_long` skips a zero limb without writing it | **caught**, 3137 | `add`: got 1, want 268435456 |
| 6 | `mag_mul` does not stage the second operand | **caught**, 2503 | `mul`: got 0, want 1 |
| 7 | `bn_shl` ORs the carry into the wrong end | **caught, but not fast** | `mod`: got 3, want 1 |
| 8 | the divide's `owed` is never allowed to go negative | **caught**, 571 | `div`: got 2, want 1 |
| 9 | the Knuth give-back correction is removed | **NOT caught** | (below) |
| 10 | `to_dec` zero-pads the most significant chunk | **caught**, 34 | `2^boundary 1`: got `00000001`, want 1 |
| 11 | `from_dec` drops the sign | **caught**, 18 | round trip: got 9223372036854775807, want -9223372036854775807 |
| 12 | `bn_cmp` ignores the signs | **caught**, 648 | `cmp`: got -1, want 1 |
| 13 | the quotient clamp is `BASE-2` instead of `BASE-1` | **caught**, 46 | `div`: got 17179869182, want 17179869183 |

**Two of the thirteen are not clean, and I would rather say so than drop them.**

* **Injection 9 is an equivalent mutant.** Removing the quotient-estimate
  correction changes **0 of the 2450** oracle pairs that are legal to divide
  (measured with a probe that computes both ways and compares). `check.y`'s
  comment names the pair an *external* model of Algorithm D first disagreed on
  (`8742514861359412281 / 3641603982383516984`), and that pair **is** in the
  value pool — but this implementation gets it right with the correction
  removed too, because the multiply-and-subtract step's `left >= 0` test catches
  the over-estimate on its own for every operand in the pool. So the claim in
  `check.y`'s header that the battery fails for *every* injection is false for
  this one, and the honest count is 11 caught, 1 slow, 1 equivalent. Closing it
  needs a pair whose over-estimate survives `left >= 0`, which is a search, not
  a constant.
* **Injection 13 covers the same two lines anyway**, because the site is worth
  covering even where injection 9 shows the loop to be inert at this width: a
  one-off in the clamp on the line above it *is* distinguishable, and is caught
  46 times over.
* **Injection 7 fails, but not quickly.** It prints hundreds of correct-looking
  failures and then keeps running: a wrong `bn_shl` leaves a slot with a limb
  count the rest of the program does not expect, and group (D)'s trial division
  then walks a very long way. Measured: `timeout 280 ./bignum check --inject 7`
  exits **124** — it is bounded by `timeout`, not by the program. The gate does
  not run injections, so this costs nothing there, but `--inject 7` is a slow
  check, not a fast one.

## Determinism

**Nothing in the golden path depends on the terminal, the clock, a random source
or the network.** `demo` is a pure function of its arguments and the contents of
the three source files.

* No `clock_us()`, no `syscall(228)`, no `getrandom`, no `syscall(39)`, no
  terminal module, no framebuffer, and no file read at all.
* The only timing is `--stats`, which writes to **stderr**, so no
  time-dependent byte can reach stdout even if someone runs it.
* **Pollard's rho has no random source**: the seed is a parameter
  (`pollard(g, n, 2)`), so the battery asserts that the same seed gives the same
  factor twice.
* **No `--seed`, `--live` or `--bench` flags, and none are needed.** There is
  nothing random to seed, nothing remote to make live, and nothing slow enough
  to be worth timing — `demo` is 0.06 s and `check` is 0.07 s. Inventing flags
  to fill a template would be worse than not having them. `--stats` is the one
  flag, and it exists precisely so the timings can live *outside* the golden.

`demo` and `check` were each run repeatedly and are byte-identical every time,
and the gate's item 2 re-runs the golden twice.

**The heap figure in the golden is a DELTA, and it has to be.** The demo's last
figure, lines 83–84 of the 86-line golden, reads

```
    heap this demo allocated: 245408 bytes (a delta -- an absolute would also count argv, so it would
    move with the length of the path you ran this by)
```

`h0 = heap_used()` is the first statement of `demo` and the printed figure is
`heap_used() - h0`. It was an **absolute** for the first release, and that made
the golden depend on `argv[0]`, because `heap_used()` counts the argument vector
— which the kernel allocated at exec time, before any of this program's code
ran. The same input, the same bytes of arithmetic, three different answers:

```
./bignum                                        398888 bytes
./bignum-me                                           398896
/home/yun/Projects/compiler/examples/bignum/bignum   398936
```

**This was found by the orchestrator's gate, not by this example's own check**,
and it is worth saying why, because it bounds what the battery can see. Gate
item 2 runs the `run=` line verbatim from inside the folder, so `argv[0]` is
always `./bignum` — the same length on every run and for ever. Two runs of the
golden, the golden comparison, and the self-containment copy (item 5) all invoke
it the same way, so **nothing this example owns could ever have caught it**: the
defect lived in the space between two ways of typing the same command. The gate
now also runs the program by absolute path and demands the same bytes; the fix
is to report a delta, which is also the better number — it is the cost of the
computation rather than the cost of the process. Same pattern as
`SUGGESTIONS.md` #7.

The 245 408 bytes are what `demo` itself allocated after it was entered: the
decimal text `bn_str` builds one digit at a time, the demo's own `print` calls,
and the twelve-pair literal in §1. The 37 728-byte limb pool is **not** in that
figure — `main` calls `bn_init()` before dispatch, so the pool predates the first
sample — and neither is anything the runtime allocated at exec time. (Absolute
check: `./bignum demo` measured 398 888 with the old absolute line, and
398 888 − 245 408 = 153 480 at entry.)

**A delta excludes argv only if nothing between the two samples reads it
again**, and the check is the counter-example, measured rather than asserted.
`check` prints `heap before`, `heap after` *and* a delta now, and by absolute
path that delta moves by **137 888 bytes**: `self_path` is called once per
forked child — 31 times — and it calls `fs.cwd()`, which allocates a
`[byte; 4096]` **inside its own body** in `src/y/std/fs.y` and so costs
**4 296 bytes a call** here (4 248 in a shorter directory; only the returned
string moves), plus a 152-byte `cwd + "/" + argv[0]` concatenation. `./bignum`
pays both and an absolute `argv[0]` pays neither — 4 448 × 31 = 137 888 exactly.
So a delta is *not* automatically the safe form; it is safe when the measured
region does not re-read argv, which is true of `demo` — nothing in it touches
argv, and that is why its delta is identical by every path. Nothing
byte-compares the check's output, so its two absolutes stay: they are what the
"where the heap goes" table below is built from. `--stats demo` already reported
a delta and never had the problem.

## Where the heap goes, and where it does not

`heap after 5180784 bytes` is about 4.9 MB, and this campaign's thesis is that
the heap is an arena and nothing is ever freed, so it is worth saying exactly
where it goes. Measured group by group with a probe built outside this folder,
so the example itself is untouched:

| after | `heap_used()` | delta |
|---|---|---|
| `bn_init` — the pool | 153 392 | — |
| group (F) harness self-test | 157 688 | +4 296 |
| group (A) native-`long` oracle | 3 150 944 | **+2 993 256** |
| group (B) boundary constants | 3 162 840 | +11 896 |
| group (C) identities | 4 577 384 | **+1 414 544** |
| group (C2) times ten | 4 710 064 | +132 680 |
| group (D) real work | 4 711 320 | +1 256 |
| group (E) 39 forked children | 5 043 656 | **+332 336** |

So it is **not** the size of the numbers: it is the *assertions*.

* **Group (A), 3.0 MB — 60% of it — is `eq_long` building its failure message on
  every call.** `ok(label, got == want, "got " + tostring(got) + ", want " +
  tostring(want))` evaluates the detail string *before* `ok` is entered, so
  14 041 comparisons each allocate three exactly-sized buffers whether they pass
  or not. The `-S` audit says it plainly: `check.eq_long` compiles to **0
  `y_str_app` and 3 `y_str_cat`**.
* **Group (C), 1.4 MB** is the `|a%b| < |b|` assertion, which also builds its
  detail eagerly — and there the detail holds two `bn_str` calls, and `bn_str`
  appends **one digit at a time**.
* **Group (E), 0.33 MB** is the 39 forked children: each `run_child` allocates
  an 8 KiB read buffer plus a `[byte]` array that grows one byte per read.

**And the arena really is flat in the operand width.** Computing, squaring,
dividing and converting 2^64, 2^256 and 2^1000 in turn moves `heap_used()` by
5 240, 19 520 and 70 768 bytes — and all of that growth is the *decimal text* of
the result, which is inherently O(digits); past 2^1000 the curve is flat. The
pool is 36 slots × 131 limbs × 8 bytes = **37 728 bytes, allocated once**, and
the largest number anywhere in the program is 2^1000 at **36 limbs**, so the
arithmetic itself allocates nothing at all.

Timings, from `--stats`: a 36-limb squaring is **7 338 ns**, a 36-limb addition
**314 ns**, trial division to 274 177 is **24.3 ms** — which is why `--stats
demo` takes about 5 s (it does 200 of them) while plain `demo` takes 0.06 s.
`check` is 79.6 ms.

**No allocation in the arithmetic.** Every buffer is a literal-sized module-level
array allocated once: `L`/`NC`/`NG` (the pool), `DECBUF: [byte; 1300]` (decimal
digits, LSB first), the two `calc` stacks, and `run_child`'s `[byte; 8192]` read
buffer. There is no literal array or record inside any loop body, which is this
campaign's other recurring trap — it costs its bytes *per iteration* on an
arena.

## Compiler workarounds

Every one of these is visible in the code, at the place it applies.

**A real compiler bug, filed and worked around.** `argv().length` **segfaults
when the length is the only read of `argv`**: it compiles clean, then the
program dies on SIGSEGV with nothing on either stream. `main` binds it first
and reads the length off the binding (`let av = argv(); if (len(av) >= 2)`), and
`check.self_path` says why in a comment. Filed as `BUGS.md #Argv's \`.length\`
segfaults when the length is the only read of it`. Having this README is what
made the claim true: `bignum.y` already asserted the finding was filed when it
was not, and `self_path` still carries a comment about it.

**A filed bug that shaped the code.** A `str +=` in a **value-used** position
compiles to an exact-size copy instead of the amortised in-place append, which
makes its whole loop quadratic in heap — same output, orders of magnitude more
memory, no diagnostic, and a golden file passes for ever. Filed as `BUGS.md #A
\`str +=\` in a value-used position makes its whole loop O(n²) in heap`.
**Audited here rather than eyeballed:** compiling with `-S` and counting `call
y_str_app` (amortised) against `call y_str_cat` (exact-size copy) per function
gives `bn.bn_str` **1 app / 0 cat** — the 1083-digit conversion loop is
correctly a discarded position — and the same for `check.head`, `check.head_of`,
`calc` and `demo`'s limb row. The shape to grep for is `+=` as the **last
statement of a braced block**, and the only places it occurs here are one-line
`if` bodies: eight of them, all numeric accumulators (`t += L[a][i]`), all array
appends (`CV += v`), or in loops of **36 and 4** iterations. One is a `str`
append in a loop — `demo`'s limb row — and its cost is inside the golden, which
is the honest way to settle it.

**Language facts, each handled in the code rather than papered over. None of
these is a compiler bug, and none is filed here.**

* **`a / b` on two scaled values returns their RATIO, not a scaled quotient.**
  This program has no fixed point at all — a bignum limb *is* a `long` — so the
  trap never applies. The one scaled division that exists is the decimal digit
  bound, `(bn_bits(s) * 302) / 1000 + 1`, and it **multiplies before it
  divides**, the only correct order. Written the other way round,
  `(bits / 1000) * 302`, it would be wrong for every value below 1000 bits.
* **`long + str` coerces rather than erroring**, which makes a silent typo look
  like a feature. Grepped: there is **no** place in the three sources where a
  number reaches a string without an explicit `tostring` around it.
* **Division or modulo by zero traps, and a negative shift count traps.**
  Division: `bn_divmod` returns status 1 for a zero divisor and every caller
  turns that into a message — `do_op`, `capply` and group (E)'s 23 refusals all
  end at a diagnostic and a non-zero exit. Shifts: all 17 shift expressions in
  the three sources have non-negative counts *by construction* — `BITS` is 28,
  `k % BITS` is 0..27, `BITS - bits` appears only under `bits != 0`, and the
  two normalisation loops shift a value bounded by 2^27 — so the negative-count
  trap is unreachable.
* **`>>>` is a LOGICAL shift and is catastrophic on a possibly-negative value**,
  silently. Seven expressions use it and **every one has a non-negative left
  operand by construction**: `m` in `bn_from_long` is a magnitude, and `t` and
  `p` in the add, multiply and divide loops are bounded by 2^57 and 2^56. The
  other ten shifts use `>>`.
* **No `break` and no `continue`** — both are undefined names, and both are on
  the compiler's own `TODO.md` §5 roadmap, so this is a known gap and not a
  filing. There are **zero** occurrences of either in the three sources outside
  comments; every early exit is a guard flag recomputed at the bottom of its own
  loop (`go`, `more`, `done`, `again`, `adjust`, `find`, `jdone`, `take`), and
  "continue" is a positive condition around the body.
* **No `abs`** — `bn_abs` is `bn_sub(d, S_ZERO, a)` with a staging slot, because
  for a negative `a` that is `bn_add_s(d, S_ZERO, a, …)` whose short circuit
  would otherwise read `a` while writing `d`.
* **No `pow`** — `bn_pow` and `bn_powmod` are hand-written square-and-multiply;
  there is no `^` operator either.
* **No `floor`** — not needed, and the reason is the design: integer `/`
  truncates, and the only place a floor was wanted is `bn_digits`, where both
  operands are non-negative, so truncation *is* the floor. Its start value is a
  deliberate strict over-count (`digits <= floor(b·log10 2) + 1`,
  `log10 2 = 0.30103`), because an over-count costs one wasted division and an
  under-count would be a wrong answer.
* **No `sort`** — and none was needed: nothing in the program sorts. The oracle's
  value list is a hand-written literal in a chosen order.
* **No `float` → `long`, and no cast syntax.** Not needed either, and this is
  the one gap the design *benefits* from: an arbitrary-precision integer whose
  limb is a machine word never has to convert.
* **`main()`'s return value is not the exit status** — `main();` discards it and
  the process exits 0, so an error path that did `return 1` would look
  successful to anything reading only the exit code. Filed as
  `examples/SUGGESTIONS.md` #15. The shape here is
  `def main() -> long { … }; exit(main())`, and **every** `return 0/1/2` in
  `main` is therefore the real status. `def main()` is not called for you either,
  so the trailing `exit(main())` is load-bearing.
* **Scalars are passed by value, so there are no out-parameters.** Three places
  need one and all three route around it: `parse_int(text, out: [long])` takes
  an *array* (passed by reference) and returns a status; `bn_to_long_checked`
  and `bn_eq_dec` return a status and leave the value in a slot; and `calc`'s two
  stacks are module-level globals with an explicit top index, because a helper
  that "returns" a mutated scalar parameter changes nothing. The real fix is
  tuples, already filed as `examples/SUGGESTIONS.md` #5.
* **`[0; n]` takes an integer LITERAL size, not an expression**
  (`examples/SUGGESTIONS.md` #8). So `DECBUF` is `[byte; 1300]`, `run_child`'s
  pipe fds are `[byte; 8]`, its read buffer `[byte; 8192]`, and the `argv` array
  for the child `execve` is **grown with `+=`** rather than sized.
* **`pipe2` writes two 32-bit ints.** `run_child` reads them out of a `[byte; 8]`
  and assembles each fd from four bytes; reading them as two `long`s would pack
  both fds into element 0 and leave the write end 0 — that is, stdin — and the
  check would hang silently.
* **`chr()` is byte-oriented and cannot make a non-ASCII glyph**
  (`examples/SUGGESTIONS.md` #11). `bn_str` uses `chr` only on ASCII digits, so
  it is the right tool; a value needing a glyph would have to have its UTF-8
  bytes written into a fixed buffer instead.
* **A literal array or record inside a loop body allocates on every iteration**
  (`examples/SUGGESTIONS.md` #7) — hence the module-level buffers above.
* **Runtime traps print to stdout**, so a trap corrupts its own diff instead of
  announcing itself. That is why group (E) exists, and why it asserts per child
  that the output contains neither `runtime error:` nor a leading `runtime
  error`.
* **`split()`, `join()` and `.length()`** — not used; there is no text parsing
  in the program. `parse_int` and `from_dec` walk bytes directly, which is what
  lets them *refuse* `12x`, `1_0`, `--3`, ` 12` and the empty string instead of
  silently truncating.

## Toolkit: none vendored

**No file from `examples/_toolkit/` is present, and none is needed.** Confirmed
rather than assumed: the folder contains exactly three sources (`bignum.y`,
`bn.y`, `check.y`), the only imports in all three are `bn` and `check` (this
folder's own modules) plus `fs` — a **std** module from the compiler's own std
pack, not from the toolkit — and there is no `embed`.

Each of the five toolkit modules would have been dead weight:

| module | why it is not here |
|---|---|
| `fx.y` | no trig and no fixed point: a limb *is* a `long`, so the arithmetic is integer by construction and there is nothing for a fixed-point module to do |
| `term.y` | no terminal interaction: the program prints and exits |
| `fb.y` | no drawing: the output is text meant to be diffed |
| `args.y` | the one file it could have used — the CLI is six subcommands with **no flags** beyond `--stats`, `--verbose` and `--inject`, about 20 lines of hand-rolled dispatch in `main` |
| `time.y` | nothing is paced; the only timing is `--stats`, which is two `clock_us()` calls |

Because no toolkit file is present there is no frozen toolkit revision to record
and no shas to list. That is a real claim about self-containment, not a
shortcut: gate item 5 copies the whole folder to a temporary directory with no
sibling present, builds it with the pinned compiler, and requires the golden to
reproduce there — which it does.

## Files

| file | what |
|---|---|
| `bignum.y` | the CLI, the five demo sections, the `calc` evaluator, dispatch |
| `bn.y` | the library: limbs, add, sub, mul, Knuth D, shifts, decimal, gcd, pow |
| `check.y` | the property battery, the 39 forked error-path children, trial division and Pollard rho |
| `EXPECTED` | the exact stdout of `./bignum demo`, 4017 bytes |
| `gate.conf` | `build=`, `run=` and `check=` |
| `golden/` | captured `check` and `errorpaths` output, and a copy of `EXPECTED`, for a human to diff |
| `repro/` | the five standalone reproductions of the `argv().length` filing, plus the script that runs them |
| `bignum` | the built binary (gitignored) |

## The acceptance gate is not mine to claim

The gate is `./gate.py bignum`, run by the orchestrator from `examples/`. I ran
it; I did not write it, and every number above is in this README because I
measured it, not because the gate printed it. What the gate does **not** check,
and what this README therefore has to stand on its own: that the battery's
expected values are right, that the demonstration teaches anything, or that the
thirteen injected defects are the thirteen that matter — in particular that
injection 9 is an equivalent mutant, which no gate item can know.

## Pin re-verification: `1d28b3db` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `625efd81` -> **`1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `31808ddc21adfa31` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3` -> **`31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
