# PERF.md — optimising `ycc` itself

No language features, no behaviour change. This is the record of one
investigation: where `ycc`'s own time and memory go, what was fixed, what was
tried and rejected **with numbers**, and what is still open — including a
**live miscompile** it turned up.

## Status

Three commits on `bench/ycc-perf`, cumulative against `refs/ycc.ref`:

| | base | now | |
|---|---|---|---|
| instructions compiling `ycc.y` | 22.47 G | 8.74 G | **−61.1%** |
| `compile_us` | 1,060,160 | 479,091 | **−54.8%** |
| peak heap (massif) | 921.9 MB | 820.4 MB | −11.0% |

`SCORE 105.24`. All suites green, 349 programs 0 different, instructions run
by compiled programs +0.00%, port gate 43/43, fuzz 0 findings.

**`make rebless` has not been run** — `refs/ycc.ref` is still the pre-change
compiler, so `make test`'s `cmp ycc refs/ycc.ref` gate fails until it is.

## Measuring

`yccd` = `./ycc -g -o yccd src/y/ycc.y` (the compiler with symbols), run on
`src/y/ycc.y` — the largest input (964 KB spliced, 209,316 tokens, 831 `def`s).
i5-14600KF, 20 threads.

```
./yccd --time -o /tmp/t src/y/ycc.y          # per-phase ms + heap KB
valgrind --tool=callgrind --cache-sim=no     # exact instruction counts
valgrind --tool=cachegrind --cache-sim=yes   # D1/LL misses
valgrind --tool=massif --pages-as-heap=yes --detailed-freq=1
perf record -F 4000 -e cycles:u ; perf stat -e cycles,instructions,...
```

Two traps that cost real time:

- **A `str` is `[len:8][bytes]`** — reading one in gdb needs `+8`, or you
  compare lengths and quietly measure nonsense.
- **`./ycc -g` bakes in `./ycc`'s own embedded `std/*.y`**, not the tree's.
  Profiling a runtime change with `./ycc -g` silently measures the *previous*
  runtime. Use `./ynew -g`.

Heap is a bump arena that never frees, so live heap == total allocated:
memory tracks allocation volume, and no scope can give it back.

## The baseline, and the one framing fact

22.4 G instructions, 5.56 G cycles, **IPC 4.03** — near the machine's issue
width. Branch misses 0.51%, dTLB misses ~29 k. So `ycc` is
**instruction-throughput bound, not stalled**: there is no latency to hide,
and the only lever is executing fewer instructions. Valgrind instruction
counts therefore predict wall time almost exactly (−42.5% instructions came
in at −40.6% time).

## Landed

| # | change | file |
|---|---|---|
| 1 | `lookup`/`env_find` scan **from the end, stop at first hit**; `name_in` stops at its first hit; four `label[:n] == "…"` tests become allocation-free `starts_with`; `split_ops` slices each operand **field** once instead of allocating a 1-byte string per character | `types.y`, `native.y`, `asm.y` |
| 2 | Tree shaker resolves names through **`asm.y`'s existing `labmap`** instead of scanning (no second hash map) | `native.y`, `asm.y` |
| 3 | `index_of`/`split` settle the needle on its **leading byte** before the inner loop | `std/rt.y` |

**1.** The scopes are the whole program: `check_program` builds one flat
`bindings` list (6,801 entries for `ycc.y`) and `emit_one_fn` re-inserts every
def of the unit into each function's `env` (~1,605 entries). Measured with
gdb: **81.7% of `lookup` hits and 85% of `env_find` hits are in the last
decile**, and both return the *last* match — so scanning backwards is
**exactly equivalent**, which is why it is safe. A forward scan with early
exit would have bought only 17%; backwards buys 83%.

```
Ir 22.44G -> 12.34G (-45.0%)   compile 1055 -> 584 ms   typecheck 381 -> 46 ms
```

**2.** `name_index` was **24.4% of all instructions** — 191,387 linear scans
from `shake_keep`. Reusing `labmap` (open addressing, linear probing) needed
one gotcha: `labmap`'s empty slot is `""` and an unnamed block's name *is*
`""`, so `""` is not inserted — safe because `tok_push` drops empty tokens, so
no key looked up is ever empty.

```
name_index 2.91G -> ~0   y_str_eq 5.00G -> 1.91G (-61.7%)
Ir 12.36G -> 9.40G (-24.0%)   asm_text 98.5 -> 17.4 ms (-82.3%)
```

**3.** Every needle `ycc` uses is one byte (`" "`, `"("`, `":"`, `"\t"`,
`"-"`, `"\n"`, `"/"`), yet both compared the whole needle at every position.

```
y_str_index 937.1M -> 543.5M (-42%)   y_str_split 671.9M -> 410.4M (-39%)
Ir 9.50G -> 8.84G (-6.95%)   assemble 194 -> 173 ms
```

## Rejected, with numbers

**Pointer fast path in `y_str_eq`** (`cmp %rbx,%r13; je eq` before the byte
walk) — the obvious way to make tag compares cheap:

```
HEAD  Ir 8,725,986,651  ->  +fast 8,845,933,954    +1.4%  REGRESSION
```

**Per-unit literal dedup** (`gen_str_const` reuses one `.rodata` label per
distinct content, so `node.k == "num"` compares the same object) plus the
fast path:

```
        Ir              out_bytes   time
HEAD    8,751,127,436   1,052,848   483 ms
+dedup  9,142,371,019     975,024   511 ms     +4.5% Ir, -7.4% size, +5.7% time
```

Dedup shrinks binaries 7.4% (a real win, wrong direction for a compiler) but
the fast path *still* never hits — `y_str_eq` went **up**, 1.599 G → 1.694 G.
Reason: **the hot tag comparisons are cross-unit.** `parser.y` builds
`node.k` from *its* `"num"`, `native.y`'s dispatch compares against *its*
`"num"`, and units compile independently with their own `.rodata`. Only a
program-wide literal table (unit B referencing unit A's label) would unify
them, and that crosses the unit/label boundaries `ycc build` and the object
cache depend on. Not worth it.

**The tag enum** (`"trec"` → `K_TREC`) — 1,690 `k: str` annotations and
~1,750 tag literals across `types/native/parser/rename`, applied mechanically;
errors fell 227 → 110 and then stopped, for the reason in the next section.

## The `{k: str}` backdoor

`{ k: str }` is not just an annotation. It is the checker's
**unknown-shape marker**, and it makes missing-field reads succeed silently:

| receiver shape | read a missing field | dot-**assign** |
|---|---|---|
| `{ k: str }` | **compiles** → runtime trap | compile error |
| `{ k: str, zzz: long }` | **compiles** → runtime trap | — |
| `{ k: bool }` | compile error | — |
| `{ z: str }` | compile error | — |

The trigger is exactly **a field named `k` whose type is `str`**. A plain user
record `{ k: "hello" }` compiles, and instead of a compile error you get
`runtime error: record has no field 'of'` at run time. It is a deferred
error, not a miscompile — the emitter still checks (`y_dot_lookup` traps) and
the write side is still caught statically — but a real usability wart.

It exists because of this, in `types.y`:

```y
} else if (teq(t, unk_shape())) {
    // unknown-shape ({k}-only) reads unify quietly (tcompat
    // law) — the missing annotation errors once at its own
    // site, not again at every enclosing read.
```

`unk_shape()` is a trec whose single field is `k` — its whole identity is
"**`k` is a `str`**". 1,690 annotations lean on it: `lookup` declares
`{typ: {k: str}}` and callers legitimately read `got.typ.of`.

## The shape rule underneath

Records must agree on field **count**, each field matching by name and type —
except a value whose only field is `k`, which matches anything:

| value | annotation | result |
|---|---|---|
| `{k, name, of}` | `{k, name, of}` | ok |
| `{k, name}` | `{k, name, of}` | **error** |
| `{k}` | `{k, name, of}` | **ok** ← the wildcard |
| `{k, yy}` | `{k, zz}` | **error** |

That is `teq`'s trec arm, verbatim: `if (len(af) != len(bf)) { if
(single_k(af)) … else if (single_k(bf)) … else { false } }`.

**So `single_k` is the only widening mechanism in the whole type system.**
That has two consequences:

- A `type Type = {…}` alias **cannot** express "a type node of any kind" —
  every kind has a different field count. Measured: the alias got 1,631
  annotations down to **4 errors**, all unfixable by aliasing. Recursive
  aliases parse but a self-referential `of: Type` **runs the compiler out of
  memory** at 265 uses, so they have to be hand-unrolled by depth anyway.
- Making `k` a `long` **deletes the marker**, which is why the tag enum
  stalled: it isn't an annotation problem, it is the shape model.

Unions are the right concept and do not rescue it: `TLeaf | TArr | TPtr`
accepts a member for assignment, but **no field of a union can be read at
all** — `t.k` errors even though all three members have `k`.

## Field access is a runtime string scan

```asm
y_dot_lookup:              ; arch_x64.y
    mov -8(%rbx), %r14     ; the record's own shape table (stored before it)
    mov 8(%r14), %r15      ; field count
    lea 16(%r14), %r14     ; the field-NAME array
ydl_cmp:
    movzbq 16(%r14,%rdx,8), %rax   ; shape's name, byte j
    movzbq (%r11,%rdx,1), %rcx     ; requested name, byte j
    cmp %rcx, %rax
```

Access is **name-resolved at run time**, not offset-based: every record
carries its own shape table, `[tag][count][name₀][len₀]…` — **two words per
field plus the name's bytes in `.rodata`**. Maps are records too (`{keys,
vals}`), so they pay it twice per operation.

**`y_dot_lookup`: 9,274,608 calls, 666,504,002 Ir — 7.5% of everything `ycc`
executes.** Top callers: `teq` 21.4%, `rn_decl_name_go` 9.1%, `enc_mov` 6.2%,
`teq_fields` 5.5%, `fv_walk` 5.1%.

**But the fast path already exists.** `gen_dot_rec` bakes the offset whenever
it can:

```y
let idx = rec_field_idx(t, dkey);
if (idx < 0) { … call y_dot_lookup … }
else { st = gen(st, dobj);
       st = emit(st, "    mov " + tostring(idx * 8) + "(%rax), %rax"); }
```

Verified: an annotated record param bakes every access (`mov 0/8(%rax)`),
a bare param falls back. **100% of the 9.27 M lookups are the `idx < 0`
fallback**, whose own comment names the cause — *"unknown static shape
({k}-holes, bare params)"*. So retiring the wildcard and inferring param
shapes delete the runtime string scan outright; no interning and no runtime
representation change are needed.

## BUG: the baked path is order-sensitive and miscompiles

A live miscompile in the shipped compiler, found while checking the above:

```y
def rd(p: { alpha: long, beta: long }) -> long { p.alpha * 10 + p.beta };
puts(tostring(rd({ beta: 2, alpha: 1 })));
```

```
12  matching literal order   (correct)
21  reversed literal order   WRONG — want 12
12  reversed, bare param     (correct: the dynamic path re-resolves by name)
```

`rec_field_idx` takes the index from the **annotation's** field order;
`gen_reclit` lays the value out in the **literal's** first-appearance order.
Nothing makes them agree, so a baked `mov 0(%rax)` for `.alpha` reads beta's
value. Reachable whenever a param is annotated *and* the call site's literal
key order differs. Nothing in `test/` covers it.

Root cause is the same missing thing: baking an offset needs **one canonical
field order the checker and emitter both agree on**, and today the checker
doesn't commit to shapes so there is none.

## Next steps, ranked

1. **Fix the miscompile** (correctness; it is shipping). Interim: refuse to
   bake unless the layout is provably the annotation's — costs a little speed,
   removes a wrong-answer bug today. Needs a `test/y/native/` fixture either
   way.
2. **Canonical layout + checker commitment** — union `Type` plus narrowing on
   a discriminant test (`got.typ.k == K_TARR` already precedes
   `got.typ.of` at the call sites; the checker is flow-insensitive and cannot
   see it). Retires `single_k`, `unk_shape` and `typeof_field`'s quiet arms,
   makes baking sound in general, and unblocks the tag enum. Biggest change
   of the three, and it moves diagnostics.
3. **Param shape inference** — replace `pt = t_unk()` (`types.y:3001`) with a
   scan of the body's own `dot` reads, synthesising `{name: tunk, …}`. Field
   *names* are all `rec_field_idx` needs. Purely additive (infer more, never
   less; anything missed keeps the sound dynamic path) and no checker change
   — but it multiplies bug (1) if done before 2, so it waits.
4. **`emit_fns` is still quadratic** — 81% of time and 8.7 GB at 6,400 defs,
   because `emit_one_fn` copies every unit def into each function's `env`.
   At `ycc.y`'s own scale it is only 1.12%, and the clean fix needs a field on
   the emit state (144 signatures in `native.y` + 40 record builds in
   `native.c`), so it is a poor trade for the common case.
5. **Smaller, still open:** `name_index` is gone but `y_str_eq` is now #1 at
   18.1% (65.1 M calls, 286 callers — 44.4% name comparisons, 55.6% tags, no
   dominant caller); `y_str_index` 6.1% and `y_str_split` 4.6% have the same
   one-byte-needle shape as commit 3 and would take the same fix;
   `rn_redefined_later` is quadratic; `env_define` allocates 140 MB rebuilding
   an 11-field state record when arrays being references means the rebuild is
   dead weight.