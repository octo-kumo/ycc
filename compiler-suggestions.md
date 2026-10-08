# ycc — hiccups, unexpected behaviour, suggestions and bugs

Found while porting `barricade` (a tick-based block-pushing game with an optimal
solver, an objective difficulty metric and two difficulty-targeting level
generators) from TypeScript to Y. Roughly 2500 lines of Y plus ~35 probe
programs.

Every number below was measured on this machine, on the pinned compiler, with the
memory cap the project requires (`ulimit -S -v 3670016`).

```
refs/ycc.ref   sha256 9ef1931c2723a54c9ae0e131c42d13af114dd672f3dababa6e4727f233c48f63
./ycc          sha256 9ef1931c2723a54c9ae0e131c42d13af114dd672f3dababa6e4727f233c48f63
./cycc         sha256 6ff3c415908f2ec219587bc23cfc2562320532fcd7c01f859e5b0b89fe85e15a
```

`refs/ycc.ref` and `./ycc` are the same bytes; `cycc` is the C copy and differs
as expected. Nothing in `../compiler` was edited and no `make` was run there.

**The pin moved once while this document was being written** — `b70c7ab7…` to
`9ef1931c…` (a rebless, commit `ca00f43` in that repo). Everything below was
re-measured afterwards and **every finding reproduced exactly**, including the
full 256-channel and 32 768-pair `tui` sweep. Two numbers moved and are now
stated at their new values:

| quantity | on `b70c7ab7` | on `9ef1931c` |
|---|---:|---:|
| one 13x9 BFS distance field | 950 ns | **1336 ns** |
| interning a 64-byte node | ~180 ns | **~173 ns** |

A ~40% swing in one microbenchmark across a rebless is worth noting on its own:
**single measurements from this compiler need re-taking after a pin move**, and a
number quoted without its pin is not a result.

---

## Contents

3. [Suggestions](#3-suggestions) — Y is missing something
4. [Hiccups and things that cost time](#4-hiccups-and-things-that-cost-time)
5. [Measurements worth keeping](#5-measurements-worth-keeping)
6. [Stale workarounds in `examples/`](#6-stale-workarounds-in-examples)

---

## 3. Suggestions

### 3.1 `+=` on a `str` with a numeric right-hand side

`docs/src/04-types.tex`'s compound-assignment table is normative — `str` takes
`+=` with `U = str` — and `test/y/native/e90_compound_assign.y` pins
`concat += 1` as a rejection, so the current behaviour is deliberate and
consistent. But `+` on a string auto-stringifies the non-string side, so the two
siblings disagree in a way that costs an afternoon:

```y
let RAMP = "abc";
let line = "x";
line += RAMP[0];      // error: '+=' string: expected str, got byte
print("x" + RAMP[0]); // x98 — the NUMBER, not 'a'
```

Today, building a string one character at a time needs `chr(b)` (which allocates,
and masks to one byte, so `chr(9608)` is `0x88` and not `█`) or `utf8.chr(cp)`,
or a slice `RAMP[0:1]`, which copies. The gap that actually costs is `+=`: the
accumulator pattern in a render loop is the natural way to build a frame, and it
is the one spelling that refuses.

Wanted, matching `+` exactly:

```y
line += RAMP[0];      // appends the string form of the byte, as + does
line += 48 + n % 10;  // the HUD digit loop, with no chr() and no allocation
```

**Costs.** One row in the compound-assign typing rule (`str` takes `+=` with any
scalar that `+` already accepts), one arm in the emitter's `gen_opassign_cat`, and
a manual update. `e90_compound_assign.y` changes from pinning the rejection to
pinning the acceptance, which is the honest thing for it to do once the rule
changes. Low risk: the string-concat helper already takes the auto-stringified
form, because that is what `+` passes it.

### 3.3 `heap_used()` in a loop is the only allocation meter, and it works

Not a request — a note that the answer is good. Measured:

| in a 20 000-iteration loop | heap delta |
|---|---:|
| writes into a fixed array | **0 bytes** |
| `let t = [i, i + 1, i + 2]` (array literal) | 1 440 000 (72 B/iter) |
| `let r = { n: i, tag: "x" }` (record literal) | 800 000 (40 B/iter) |
| `let s = f"{i}"` | 640 000 (32 B/iter) |
| `let s = tostring(i)` | 640 000 (32 B/iter) |
| `s = "a"` (string rebind) | **0 bytes** |

The fixed `[T; N]` form allocates nothing, which is what makes the whole
"solver arena, allocated once, nothing in the loop" design possible, and
`heap_used()` before/after is enough to prove it. It is worth a worked example in
`docs/src/09-builtins.tex` at the `heap_used` entry, because "the heap is an
arena that never frees" is in `examples/SUGGESTIONS.md` and the natural reaction
is to assume any loop allocates.

### 3.4 A record array in a fixed array literal

`let v: [Spawn; 4] = [ {pos: 0, speed: 1}; 4 ]` works, and so does
`let v: [Spawn; 4] = [a, b, c, d]` when all four are the same record type. What
does not work is a *nested* fixed array written by hand:

```y
let fg: [[long; 3]; 2] = [[0; 3]; 2];        // fine
let g: [[long; 3]; 2] = [[1, 2, 3], [4, 5, 6]];  // ?
```

The `[v; n]` repeat form is the documented way to build a fixed array, and it
works for any `v` including a fixed array, so this is already expressible. Filing
only because the two-dimensional case is worth a manual example — a 2D grid is
the most common fixed-array shape in this tree (`life`, `sandfall`, `roguelike`,
`maze` all use one) and every one of them spells it out.

### 3.5 `[Mut; N] = [f1, f2, …]` for a function array

Works, and is worth knowing because a table of behaviour is how the hill-climbing
generator dispatches its nine mutations:

```y
type Lvl = { n: long, tag: str };
type Mut = (Lvl) -> Lvl;
def m1(l: Lvl) -> Lvl { { n: l.n + 1, tag: "m1" } }
def m2(l: Lvl) -> Lvl { { n: l.n * 2, tag: "m2" } }
let MUT: [Mut; 2] = [m1, m2];
print(MUT[0]({ n: 5, tag: "s" }).tag);   // m1
```

Not a request — this compiled first time and is noted only because
`examples/roguelike/rules.y` builds its tables one member at a time and a reader
may assume a literal table is harder than it is. No action needed.

---

## 4. Hiccups and things that cost time

### 4.1 Package `lib` does not carry type aliases — this is the big one

A `y.toml` with `[package] lib = "src/lib.y"` and `[bin]` entries cannot share
record types with its binaries. Five layouts were probed; this is the result:

```y
// src/lib.y
import board;                                  // bare-name import
export { make, describe, Spawn, Level };       // re-export the names
```

```y
// src/bin/gen.y
import barricade;
let l = barricade.make(13, 9);
let s: barricade.Spawn = { pos: 1, speed: 2, spawnTick: 0 };   // error
```

```
error: unknown type 'barricade.Spawn'
```

and with the alias spelled bare, `error: unknown type 'Spawn'`. A path import
(`import board from "./core/board.y";`) fixes the *functions* but the type is
still not reachable from the bin. The only arrangement that works is for the bin
to import the type's own module itself:

```y
// src/bin/gen.y — both, and it works
import barricade;
import board from "../core/board.y";
let s: Spawn = { pos: 1, speed: 2, spawnTick: 0 };   // compiles
```

This is the trap that costs the most, because the natural design is a `lib` plus
bins, and it fails in a way that looks like a typo. It is also *load-bearing* for
the design that results: if a bin imports a stateful module directly **and**
through the `lib`, the binary gets two copies of every global in it, and with a
solver arena that is 122 MiB twice and two divergent hash tables. The working
layout is therefore **no `lib` at all** — every bin bare-imports what it needs, so
each gets exactly one copy of every global and native type access. Verified with a
two-bin package that builds and runs.

`docs/src/03-grammar.tex` says of a package's aliases: "its type aliases are its
own (an importer spells the type out)". "Spells the type out" reads as *write the
record type again at the use site*; it does not mention that this is the **only**
way to reach it, and that re-exporting one from the `lib` is silently ignored.

### 4.2 `for x in arr` is an error with a good message; use `foreach`

```y
for v in xs { print(v) };
// error: 'for ... in' walks an integer range (for x in lo..hi); to walk an
// array, a str or keys(m), use 'foreach (x in expr)'
foreach (v in xs) { print(v) };
```

The diagnostic is excellent and cost nothing. Noting it because the error text
alone is the whole lesson, and grep for `for .* in` will find it if it is ever
lost.

### 4.3 Character literals must be one byte

`{'a': 5}` is fine. `f"{'ab':>5}"` gives `error: character literal must be
exactly one byte, got 2`. Two-character literals in a format spec are an easy
thing to type and the error says exactly what is wrong.

### 4.4 `chr` masks to one byte, so a code point above 255 is not a glyph

`chr(9608)` is one byte `0x88`, not `█`. `utf8.chr(9608)` is `█`. The manual says
this (`chr(n)`: "One-byte string of `n` (masked to 8 bits)"; `utf8.chr`: "The
UTF-8 encoding of `cp`"), and `tui.put` wants the code point itself rather than
either. Three spellings for "a glyph" is the only real cost here, and all three
are documented.

### 4.5 No `abs`/`min`/`max` as builtins — they are `math.abs` etc.

`abs(-5)`, `min(3,7)`, `max(3,7)`, `clamp` and `sign` are in `math`, not the
prelude, and `docs/src/09-builtins.tex`'s math section says so ("Y has no
overloading, so `min`, `max`, `abs`, `clamp` and `sign` take `long`s and their
float counterparts carry an `f`"). Three errors in a row on the first program
that wants an absolute value. Cost: one import line.

### 4.6 `let x = { a; b; c; }` as a one-liner is not parseable

Wrapping a statement in a block to bind its value has to be multi-line:

```y
let c: byte = { a - 100 };   // error: expected ')', got 'c'  (etc.)
let c: byte = a - 100;
```

Fine — just not a spelling to reach for.

### 4.7 `sort_by` is stable but the comparator must be a strict order

`sort.sort_by(xs, def (p: long, q: long) -> bool { p % 2 < q % 2 })` returns
`[5, 3, 9, 1, 7]` **unchanged**, because `p % 2 < q % 2` is not a strict weak
ordering. `docs/src/09-builtins.tex` warns about exactly this ("It must be a
strict order — never true of equal elements"), and the behaviour is safe (no
crash, no wrong order, just the input back), but the silent no-op is the kind of
thing that reads as a compiler bug at 11pm. A diagnostic when the comparator is
not a strict order is not statically checkable, so this is a documentation note
rather than a request — the warning belongs in the `sort_by` entry.

### 4.8 `heap_used()` does not count the argument vector

`docs/src/09-builtins.tex` says so explicitly. Confirmed: the figure does not
move with a longer command line. Worth knowing when diffing two runs.

---

## 5. Measurements worth keeping

All on `refs/ycc.ref` `b70c7ab7…`, under `ulimit -S -v 3670016`.

**A hand-rolled open-addressing hash set over a fixed `byte` arena.** The thing
this rewrite turned on. 400 000 distinct 64-byte keys, interned in
**77 ms**; 400 000 nodes with 80-byte records and a 4 194 304-slot table,
**134 MB** total. Compare the alternatives for the same job:

| structure | operation | cost |
|---|---|---|
| `{str => long}` map | 100 000 inserts | 8.0 s, 33 MB |
| `{str => long}` map | 400 000 inserts | does not finish in 2 min |
| `{long => long}` map | 200 000 inserts | 16 s (80 ns/insert at 200k) |
| hand-rolled byte arena | 400 000 distinct 64-byte keys | **69 ms** |

A `long`-keyed map cannot express a 64-byte key at all, so the arena is not a
stylistic preference — it is the only structure that does the job.

**A 13×9 stamped BFS distance field: ~1336 ns** (950 ns on the earlier pin).
200 000 fields in 267 ms, with
a `heap_used` delta of 0. Stamping (increment a counter, mark as you enqueue) is
what avoids clearing the buffer between runs; membership has to go through the
stamp or a stale distance reads as valid.

**A complete game tick with 4 enemies: ~6.4 µs** — four BFS descents plus the
separation field. The single largest lever found was replacing an
"is there a spawned enemy at this cell" scan over the enemy slots with an
occupancy byte array rebuilt per tick: **8.9 µs → 6.4 µs**, a 28% cut, for one
byte per cell and a loop over 8 enemies.

**Fixed arrays cost nothing and traps are cheap.** A 100 000-iteration loop
writing into a `[long; 100000]` has a `heap_used` delta of exactly 0. Indexing
out of bounds is a checked trap, not a crash: `runtime error: index out of
bounds`, exit 1, on **stdout**.

---

## 6. Stale workarounds in `examples/`

Two workarounds in `examples/` are for bugs this compiler no longer has. Both cost
real time if followed, so they are here rather than filed, since neither is
actionable by the compiler author.

### 6.1 `tui`'s `emit_num` zero-tens-digit bug — not reproducible

`examples/maze/README.md` works around "`tui`'s `emit_num` drops a zero digit":
`205` is emitted as `25`, `104` as `14`, column 101 as `11`. It carries a
`safe_rgb()` helper that nudges offending channels to the next value with no zero
digit, and caps its interactive surface at 99×99 because "`1..99` is exactly the
range `emit_num` gets right".

Measured on this pin, drawing to a file and comparing the byte stream:

| what | extent | wrong |
|---|---|---:|
| SGR foreground channel triples | **all 256 values** | **0** |
| `tui.cursor_to` row/column pairs | **all 32 768 pairs** over 128×256 | **0** |
| `tui.put_num` alone, after `put_csi` | 44 values incl. every zero-tens-digit case | **0** |

`104` arrives as `104`, `205` as `205`, `120;250` as `E[120;250H`. `safe_rgb` is
not needed and the 99×99 cap is a self-imposed limitation. Following the example's
README here would have meant shipping a workaround for a bug that does not exist,
and colouring the palette wrong to suit it.

### 6.2 `str + byte` "segfaults" — fixed, and documented

`examples/maze/README.md`, `examples/fluid/README.md`, `examples/bmpview/README.md`
and `examples/crypto-chat/README.md` all work around "`str + byte` segfaults"
(`examples/BUGS.md` is now empty of it; commit `7c4b43f` fixed it on 2026-10-05).
Current behaviour:

```
$ ./v4
str+byte:x98        <- the NUMBER, not 'a'
byte+str:98x
str+long:x65
str+float:x1.500000
```

Not a crash — the auto-stringification the manual documents, applied to a `byte`.
The examples' advice is still *good* (`chr()` or a codepoint, never `"x" + s[i]`),
because writing a frame wants the character, not `98`. But it is no longer
working around a segfault, and the phrasing sends a reader looking for a crash
that is not there.

### 6.3 The pinned state, and a note on how it is recorded

`examples/maze/README.md` records pins going
`e27f83e4` → `c53cc415` → `fcdae3cc` → `e55fa8d0` → `9ce37629` → `5eba0d66` →
`625efd81` → `1d28b3db` → `31808ddc` → `289cf022` → `dad3564d`, each with a
"pin re-verification" section appended. The current pin is `b70c7ab7`, and every
one of those re-verification sections says the same thing: *"all 39 folders at
once, which is the signature of a pin move rather than of a regression."* The
append-a-new-section-per-pin pattern has produced eleven sections in one README
and none of the older ones change the reader's decision. **A single table with
the current pin and a one-line history is the better shape** — the number moves
every time the compiler is rebuilt, and what a reader needs is *the current
number* plus enough history to know it has moved before.

---

## 7. What was checked and found correct

Recorded so the next person does not re-measure it.

- **Overflow wraps**, as documented: `9223372036854775807 + 1` is `-9223372036854775808`,
  `4611686018427387904 * 4` is `0`.
- **Traps**: division by zero, negative shift count, index out of bounds each
  print `runtime error: …` on **stdout** and exit 1. The stdout part is the one to
  remember for anything that diffs output.
- **Byte arithmetic is `long` arithmetic** and masks on store: `let c: byte = 200 - 100`
  stores `100`; `(200 + 100) > 250` is `true`.
- **Fixed arrays of records** work: `[v; n]`, literal lists, and field writes
  through the index.
- **Function values** are first-class, storable in a fixed array literal, and
  callable through the index.
- **`match` with record arms** works on a union, and `match` with scalar arms is
  fine as a block's value (the asymmetry `examples/roguelike/rules.y` documents
  is real: a record-arm `match` cannot be a block's value).
- **`self` recursion** works; `typeof`, `keys`/`values`, `f"{x:.3f}"` and
  `f"{x:.2%}"` all behave as the format-spec section documents.
- **`math.to_int`** is the float→`long` route; `tolong` returns `long?` as the
  manual now says, so `*` on its result is a type error — `math.to_int` is the one
  to reach for.
- **`tui`** verified: surface put/get, `grid_text`, `grid_digest`, cell-diffed
  `flush`, `pacer`, `read_key_timeout(0)` returns `KEY_NONE` (-1) with no tty,
  `is_tty` false on a pipe, `MAX_CELLS` 32768, `MAX_ROWS` 128, `MAX_COLS` 256.
- **`fs`** verified: `read_file`/`read_lines`/`write_file`/`make_dirs`/`list_dir`
  and the four `path_*` helpers, including `path_stem("a/b.tar.gz")` = `a.tar`.
- **`json`** verified: `parse` → `jobj` → `get_long`/`get_str`/`get_arr`,
  `field`, `as_str`/`as_long`, `pretty(v, indent, sorted)`, and that
  `as_long("3.9")` is `none` rather than `3` as documented.
- **`args`** verified: an `[args.Opt]` table, `parse_or_exit`, `get_long`,
  `positional`, generated `--help`, exit 2 on a usage error. Note
  `args.parse_or_exit` returns **void** — `let st = args.parse_or_exit(argv())` is
  a compile error ("cannot bind a void value"), so use `args.parse` if you want the
  status, and it is `void` for the `_or_exit` form by design.
- **Warnings.** An unused local inside a function **is** warned
  (`warning: unused variable 'unused'`), matching `AGENTS.md`'s "an unused local
  is not [fine]". An unused **top-level** `let` is not warned — which is right,
  since another module spliced beside this one may read it. Every module written
  for this port compiles warning-free, so the lint rules did their job rather than
  being switched off.
