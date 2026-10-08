# Programs that grow the Y heap without bound

Small `.y` programs that are ordinary code in Go, Python, Java, Rust or JS,
but whose heap grows every iteration in Y and eventually prints
`runtime error: out of memory`.

The reason is the native heap, not a bug in any one program: `y_alloc`
(`src/y/arch/prelude.s`) is a bump pointer over mmap'd chunks and **nothing
is ever freed**. There is no collector, no refcount and no arena yet
(`ideas/lifetime_gc.md` is the design). So:

* an **allocation per iteration** is a leak per iteration, and
* a **copy per iteration** is quadratic, because every intermediate stays.

Only three things sidestep it: stack storage (numeric locals and pointers),
`.rodata` (literals), and the in-place mutations (`+=`, `*=`, `push`,
`shift`, `remove`, `sort`) that reuse capacity. Even a fixed `[T; N]` has
its elements in a heap cell (`docs/src/08-functions.tex`), so declaring one
per iteration allocates per iteration.

## Running

```sh
./ytest oom                       # every program, default size
./ytest oom s05_arr_concat 31000  # one program at one size
```

`ytest oom` compiles with the `ycc` in this tree and runs each program under
`ulimit -S -v 3670016` (AGENTS.md's 3.5 GiB cap), then prints the line the
program reports. Each program takes its size from `argv[1]` and reports
`heap` = `heap_used()` delta and `per_iter` = that over `n`.

Measured with `ycc` at `540f503`, cap 3.5 GiB. The cap leaves about
3.7e9 bytes; "OOM at" is where that is reached.

## The leaks

| program | idiom | other languages | bytes / iteration | OOM at |
|---|---|---|---|---|
| `s01_str_concat` | `s = s + "a"` | garbage, flat | 7.5e3 (grows: `0.502·n`) | ~86 000 |
| `s02_str_append_read` | `s += "a"` **plus a read of `s`** | builders are mutable | 7.5e3 (`0.502·n`) | ~86 000 |
| `s03_str_append_field` | `buf.s += "a"` (record field) | mutable field | 7.5e3 (`0.502·n`) | ~86 000 |
| `s04_str_append_captured` | `s += "a"`, `s` captured by a closure | idiomatic | 7.5e3 (`0.502·n`) | ~86 000 |
| `s05_arr_concat` | `a = a + [i]` | `append`, flat | 4.0e4 (`4.01·n`) | ~30 400 |
| `s06_arr_head_slice` | `q = q[1:]` (FIFO drain) | view / O(1) index | 4.0e4 (`4.00·n`) | ~30 400 |
| `s07_slice_view` | `buf[0:k]`, k = 1 MB, in a loop | view, O(1) | 1.0e6 | ~3 700 |
| `s08_json_loop` | `json.parse(s)` per round, 40-byte doc | garbage, flat | 3.0e3 | ~1 250 000 |
| `s09_regex_loop` | `regex.search(re, s)` per round | garbage, flat | 1.9e3 | ~2 000 000 |
| `s10a_record` | one record per iteration, dropped | garbage, flat | 40 | ~92 000 000 |
| `s10b_option` | `some(i)` per iteration | garbage, flat | 16 | ~230 000 000 |
| `s10c_closure` | closure capturing the loop variable | garbage, flat | 40 | ~92 000 000 |
| `s10d_tostring` | `tostring(i)` per iteration | garbage, flat | 32 | ~115 000 000 |
| `s10e_fixed_array` | `let a: [long; 4] = [0; 4]` per iteration | stack/scratch | 72 | ~51 000 000 |
| `s11a_bind` | `match s { Circle c => ... }` | tag test, no copy | 48 | ~77 000 000 |
| `s12_float_format` | `tostring(i * 1.5)` | small temp, flat | 1.0e3 | ~3 600 000 |

`s11b_destructure` is the same loop as `s11a_bind` with a destructuring arm
(`Circle { aaa: v }`) and allocates **0** — see below.

`s14_fork_isolate` is not a leak: it shows the escape hatch of running the
allocating work in a forked child, whose heap dies with it (64 bytes per
task in the parent).

## Mechanisms

### 1. Copy-on-derive: `+` and slices are allocations

`a + b` for arrays is `y_arr_cat`, which allocates a new array and copies
both operands. `s + t` is `y_str_cat`, likewise. A slice is `y_arr_slice`
/ `y_str_slice`, a fresh copy of the range. Folding any of these over a
growing value keeps every intermediate (`s01`, `s05`, `s06`, `s07`).

In Go, Rust and Java a slice/substring is a view; in JS and Python it is a
copy but the collector reclaims it, so the *live* set stays small even when
the allocated total is large. In Y the allocated total **is** the heap.

### 2. Ownership loss turns `+=` back into a copy

`docs/src/05-expressions.tex` (§Appending): a `str` local or global gets a
companion word, and `s += t` writes into its spare room only while `s` still
holds the buffer its own previous `+=` built. Any other use of `s` — a read,
a copy, an argument — ends that ownership, and the next append copies the
whole string (`s02`). A captured variable never qualifies (`s04`), and a
record field has no companion word at all (`s03`). All four are the same
`0.502·n` quadratic as `s = s + t`.

### 3. A slice is a copy, so a "view" loop is linear in the window size

`s07` takes a 1 MB slice 3 700 times in a loop and dies. The same program
with an index/offset pair, or with `buf.ptr` and pointer arithmetic, is
flat. This is the pattern that dies *fastest*, because `k` is large.

### 4. `match` with a binding can copy the record

A union lays its members out with the shared fields first; a standalone
record is laid out by field name. When the two orders differ, the cast a
`match`/`if let` binding performs **copies the record** (`s11a_bind`,
48 bytes a round). A destructuring pattern reads in place (`s11b`).

Because the trigger is the field *names*, the same program allocates or not
depending on the spelling. `Circle { aaa, id, tag }` against a union whose
shared fields are `id, tag` sorts to `aaa, id, tag` standalone but
`id, tag, aaa` in the union, so it copies; rename `aaa` to `zzz` (sorts
last) and the loop allocates nothing.

### 5. Everything the std library returns is permanent

`json.parse`, `regex.search`, `keys`, `lines`, `split`, `map`, `filter`,
`sorted`, `tostring(float)` — each builds a fresh graph per call and none of
it is reclaimed (`s08`, `s09`, `s12`). `tostring(float)` is the worst
constant found: ~1 KB per call, because the formatter builds and
concatenates a dozen intermediate strings.

## What stays flat (the controls)

`s13_controls` measures the shapes that do **not** grow, at `n = 200000`:

| shape | heap | per iteration |
|---|---|---|
| `for i in 0..n { acc += i * 3 }` | 0 | 0 |
| `s += "a"`, never read in the loop | 721 280 | 3 (amortized doubling) |
| `a += i` | 4 194 416 | 20 (the array's own live data) |
| `a.sort(cmp)` in place | 16 | 0 |
| helper appending to its `str` parameter | 3 008 | 3 |
| FIFO as `q[head]; head++` (also `q.shift()`, `q.remove(0)`) | 0 | 0 |
| `match` with a destructuring arm | 0 | 0 |

`foreach` over a 100 000-element array, 200 passes: 280 bytes total.
A 50 000 000-iteration arithmetic loop: 304 bytes total. A million map
reads, field writes, or `match`es whose cast needs no copy: 280 bytes.

## Working rules

1. Prefer in place: `s += t` over `s = s + t`; `a += x` over `a = a + [x]`;
   `a.sort(f)` over `a = a.sorted(f)`; `q[head]`/`q.shift()` over `q = q[1:]`.
2. Don't touch a string builder inside the loop that appends to it — no
   `s.length`, no `print(s)`, no passing it on. Read it after the loop, or
   flush into a `[str]` and `join` once.
3. Don't use `arr[i:i+k]` as a view: keep the base array and an index/offset
   pair, or use `.ptr` with pointer arithmetic.
4. Hoist per-iteration parsing/formatting out of hot loops, or memoize.
   A service that formats one float per request leaks ~1 MB per 1 000
   requests; at 1 kHz that is 3.6 GB in an hour.
5. For a genuinely long-running process, isolate the allocating work in a
   `fork` child (`s14_fork_isolate`); the parent stays flat.
6. In a `match`, destructure (`Circle { aaa: v }`) instead of binding
   (`Circle c`) where a record copy is possible.

The real fix is the arena/collector pass described in
`ideas/lifetime_gc.md`; these programs are the acceptance test for it —
each should fall to a few hundred bytes once its allocation is reclaimed at
the end of the block or the iteration.

## Acceptance: the collector bounds every program

The whole-heap conservative mark-sweep collector described in
`ideas/lifetime_gc.md` is now in `src/y/arch/prelude.s` and enabled. With it,
**every `s*.y` program here completes** (exit 0) under a **256 MiB**
`ulimit -v` cap — the cap that used to be 3.5 GiB, and several programs died
at the default sizes even there:

| program | exit | resident bound | what the collector reclaims |
|---|---|---|---|
| `s01_str_concat` | 0 | 256 MiB | every intermediate string |
| `s02_str_append_read` | 0 | " | the copy each read forces |
| `s03_str_append_field` | 0 | " | " |
| `s04_str_append_captured` | 0 | " | " |
| `s05_arr_concat` | 0 | " | the array grown so far |
| `s06_arr_head_slice` | 0 | " | every drained prefix |
| `s07_slice_view` | 0 | " | each 1 MB copy |
| `s08_json_loop` | 0 | " | the parsed graph per round |
| `s09_regex_loop` | 0 | " | the match structures |
| `s10a`–`s10e`, `s11a` | 0 | " | the per-iteration record/box/closure |
| `s12_float_format` | 0 | " | the formatter's dozen temporaries |
| `s13_controls` | 0 | " | nothing — the controls stay flat, as before |
| `s14_fork_isolate` | 0 | " | nothing — the child's heap still dies with it |

The `heap` column each program prints does **not** shrink: it is
`heap_used()`, the cumulative bytes handed out, and that accounting is
deliberately unchanged (`t101`/`t138`/`t139` are byte-for-byte identical), so
`per_iter` still reads as in the tables above. What is bounded now is the
*resident* set, which is the point of the exercise.

The buffer variants show the reuse policy working: `s01`/`s12` allocate a
slightly larger string every iteration and free the previous one, so the
sweep's coalescing plus largest-first splitting hands the space straight
back; exact-size free lists alone would leak as O(n^2) here.
