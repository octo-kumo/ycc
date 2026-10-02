# PERF.md — making `ycc` itself faster/smaller

No language features, no behaviour change. This file records where `ycc`'s
own time and memory go, what has been fixed, and what is next.

## How the numbers were taken

`yccd` = `./ycc -g -o yccd src/y/ycc.y` (the compiler with symbols), run on
`src/y/ycc.y` — the biggest input there is (964 KB spliced, 209,316 tokens,
831 `def`s). Machine: i5-14600KF, 20 threads.

```
./yccd --time -o /tmp/t src/y/ycc.y                      # per-phase ms + heap KB
valgrind --tool=callgrind --cache-sim=no ./yccd ...     # exact instruction counts
valgrind --tool=cachegrind --cache-sim=yes ...          # D1/LL misses
valgrind --tool=massif --pages-as-heap=yes --detailed-freq=1 ...   # by allocation site
perf record -F 4000 -e cycles:u ; perf stat -e cycles,instructions,branches,...
```

Heap figures are cumulative allocation: `y_alloc` is a bump arena that never
frees, so *live heap == total allocated* and memory is proportional to the
number of allocations, not to anything a scope could release.

## The finding that shapes everything

Baseline `ycc` compiling `ycc.y`: **22.4 G instructions, 5.56 G cycles,
IPC 4.03**. That IPC is near the machine's issue width: `ycc` is
**instruction-throughput bound, not stalled**. Branch misses are 0.51% and
dTLB misses are ~29 k, so there is no latency hiding to win back — *the only
lever is executing fewer instructions.* Instruction counts taken under
valgrind therefore predict wall time almost exactly (a change measured at
−42.5% instructions came in at −40.6% time).

## Root cause: scopes are the whole program, searched linearly

Four functions were **66% of all instructions and 96% of all L1 data read
misses**:

| function | Ir | share | calls x compares |
|---|---|---|---|
| `y_str_eq` | 5.00 G | 22.3% | **226.8 M calls** total |
| `lookup` (`types.y`) | 4.75 G | 21.2% | 28,679 x **3,942** |
| `name_index` (`native.y`) | 2.91 G | 13.0% | 191,414 x 274, **92.5% misses** |
| `env_find` (`native.y`) | 2.13 G | 9.5% | 53,509 x **924** |

Why the lists are so long — one design decision, documented in the source:

> *"The scope is pre-loaded with every known def (like the checker's
> fresh_func_scope)"* — `native.y`, `emit_one_fn`

- `check_program` (`types.y:3130`) builds **one flat, program-wide**
  `bindings` list: every def of every linked unit, plus every local and
  parameter, appended as the walk proceeds. It reaches **6,801 entries** for
  `ycc.y`, and `lookup` scanned **all** of it per identifier, with no early
  exit at all.
- `emit_one_fn`, `infer_fn_ret` and `global_entries` each build a fresh
  `env: []` and then re-insert **every def in the unit** — so `env` is ~1,605
  entries and `env_define` runs O(defs²) times.

Measured with gdb (note: a `str` is `[len:8][bytes]`, so reading a string in
a debugger needs `+8`):

- **81.7% of `lookup` hits and 85% of `env_find` hits are in the last decile**
  of the array — a reference almost always resolves to a binding added
  moments ago.
- Both functions **return the last match** (they overwrite `found` on every
  hit). So a scan from the end that stops at the first hit returns *exactly*
  the same entry. `rename.y`'s `rn_lookup` already uses that idiom.

### It is quadratic in program size

Synthetic programs of N top-level functions, total instructions:

| N | 400 | 1600 | ratio (4x source) |
|---|---|---|---|
| base | 1.56 G | 18.06 G | **11.55x** |
| `lookup` | 1.3% | 15.78x growth | **quadratic** |

At N=6400 the base compiler needs **9.2 s and 9.7 GB**.

## Fixed in this change

All six are semantics-preserving; `make check` reports **349 programs, 0
compiling to different code and 0 behaving differently**.

| # | change | file |
|---|---|---|
| 1 | `lookup`: scan `bindings` **from the end, stop at first hit** (was: full forward scan) | `types.y` |
| 2 | `env_find`: same | `native.y` |
| 3 | `name_in`: stop at first hit (result is a `bool`, so order is irrelevant) | `native.y` |
| 4 | `fns_kind`: `label[:3] == "yg_"` -> `label.starts_with("yg_")` — the slice allocated a throwaway string on every call, 836 k times | `native.y` |
| 5 | `check_program`, `is_sym_label`, `sym_name`: same prefix-test change | `types.y`, `asm.y` |
| 6 | `split_ops`: **one slice per field** instead of `s[i:i+1]` + append per character — was the single largest allocation site in the compiler | `asm.y` |

`starts_with` already existed (`std/str.y`, `types.y str_method`), so no new
language surface; the C twin gets `ys_at`/`ys_starts_with`/`ys_ends_with` in
`yv.c`, mirroring `y_str_at`.

### Result (`make check`, base `refs/ycc.ref`)

| | base | new | |
|---|---|---|---|
| instructions compiling `ycc.y` | 22,438,496,990 | 12,341,885,393 | **−45.00%** |
| `compile_us` | 1,060,390 | 586,424 | **−44.70%** |
| `heap_kb` | 938,571 | 829,961 | **−11.57%** |
| peak heap (massif) | 921.9 MB | 820.4 MB | −11.0% |
| instructions compiling the small `bench/y/*` | — | — | −0.4% .. −8.3% |
| instructions **running** compiled programs | — | — | **+0.00%** (all) |

Per phase: typecheck **381 -> 46 ms (−88%)**, emit_fns 212.5 -> 111.6 ms
(−48%), assemble 224.9 -> 197.1 ms (−12%), TOTAL 1055 -> 584 ms.

By allocation site: `y_str_slice` **312 -> 216 MB**, the sub-threshold bucket
184 -> 140 MB; `y_arr_push` rose 106 -> 136 MB, absorbing the per-field
pushes `split_ops` no longer does one character at a time.

### And it fixes the asymptotics

`typecheck`, ms, by number of top-level defs:

| defs | 400 | 1600 | 3200 | 6400 |
|---|---|---|---|---|
| base | 7.5 | 113 | 860 | 4,689 |
| new | **1.6** | **4.5** | **9.2** | **19.2** |

n^2.45 -> **n^1.05, i.e. linear**. A forward scan with early exit would only
have bought 17%; scanning backwards buys 83% because the hot names are at the
end.

### Verification

`make check`: cycc builds `./ynew` byte for byte, **every suite passes**,
349 programs identical. Plus `make port-check` (43/43), `test/fuzz/fuzz.sh`
(60 inputs, 0 findings) and valgrind memcheck clean.
`make asan` cannot run here — the machine has no `libubsan.so.1.0.0` (and no
`libasan`), which is pre-existing and unrelated.

Also fixed: `test/sh/test_pkg.sh`'s throwaway git repos are now created with
`-c commit.gpgsign=false -c tag.gpgsign=false`. Without it a developer whose
**global** git config signs commits gets a pinentry prompt per commit — and
with no tty, an empty repo and 10–16 bogus `pkg` failures that look like
compiler bugs. (The repo lives in `$TMPD`, so this project's own local
`commit.gpgsign=false` never reached it.)

## Next steps, ranked

**1. `emit_fns` is still quadratic — the biggest one left.**
`emit_one_fn` still inserts every def of the unit into `env` for every
function. At N=6400 that is **3,112 ms and 10 GB** of allocation.
*Fix:* keep a program-wide `defs` map (name -> label) consulted for calls and
globals, and put only the function's own locals/params in `env`. Then
`env_find` is O(locals) and `env_define` is O(locals), not O(defs) per
function. Expect this to remove most of the remaining growth; it is the only
superlinear term left.

**2. `name_index` — now the #1 function at 22.6% of instructions.**
191,414 calls from `shake_keep`, **92.5% of them misses**, each scanning all
274 fn names with a pointer chase per element (47 M L1 misses; ~55
instructions per iteration because each `len(nm)` is a dependent load).
*Fix, cheapest first:* hoist the lengths into a flat `[long]` once per
`shake_keep` so the inner loop touches a compact array. *Fix, best:* have
`refs` store **indices** instead of names — resolve at scan time — making it
O(1) with no hashing in the shaker at all.

**3. `rename` — now #2 at N=6400 (486 ms).**
`rn_redefined_later` measured 15.85x per 4x source. It scans all later
top-level statements for a duplicate name and, in the common case (no
duplicate), always scans everything. *Fix:* one name -> count map per unit.

**4. Memory, still ~820 MB.** By far the largest item is structural:
`env_define` allocates **136 MB (17%)** purely to rebuild an 11-field state
record when only an array changed; arrays are references, so
`st.env += e` already mutated in place and the rebuild is dead weight.
`emit` (`native.y:1443`) does the same for 35 MB. Needs care: it changes the
thread-by-value discipline the modules rely on. Also: `y_str_index`/`index_of`
(7.2% of instructions) is a naive O(n*m) scan, `y_dot_lookup` (5.1%) walks
field names per `.` access, and `enc64.y`'s `concat` pushes byte by byte.

**5. Smaller:** `is_id_b`-style byte predicates already exist, but `lexer.y`'s
`isdigit`/`islower`/`isalpha`/`isspace` take a **`str`** and compare it with
`>=`/`<=`, i.e. a full `y_str_cmp` per character. Switching the tokenize loop
to byte predicates would remove `y_str_cmp` and the 1-char slices; only
0.37% of instructions today, so low priority.