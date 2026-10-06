# perft — chess perft, threaded

A complete legal chess move generator in Y, counting the leaf nodes of the
move tree to a fixed depth, over a bounded pool of worker threads started once.

    ../../refs/ycc.ref perft.y -o perft
    ./perft

- **Build**: `../../refs/ycc.ref perft.y -o perft` — nothing else, no compiler
  flags, **zero warnings**.
- **Run** (the `gate.conf` `run=` line, whose stdout is `EXPECTED`):
  `./perft` — the four built-in positions to their published depths, ~1 s.
- **The check**: `./perft --check` — 47 assertions, no reference file involved.
- **Throughput**: `./perft --bench [--threads N] [--name …] [--depth N]`.
- Everything else: `./perft --help`.

Pinned compiler: `refs/ycc.ref`,
sha256 **`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`**.
The pin moves; if `gate.py` reports item 0 failing, rebuild with whatever
`refs/ycc.ref` says at that moment, re-run, and put the new sha here.

The binary that pin produces, byte-reproducible across builds (built twice into
different paths, same bytes):

| file | sha256 | bytes |
|---|---|---|
| `perft` (from `perft.y`) | `59bd6d06d3b1b20f01418fb5e8af28eda287d04c0232bf46badba22f24d98221` | 70654 |
| `queue_test` | `6a4ba67d15f4770189c54b2c2da88453e6658eb68834310a0be9cae8986a9ec6` | 6212 |

Vendored toolkit, byte-identical to `test/std/`:

`ref_perft.py` and `queue_test.y` are development/test tools, not part of the
build; see *Cross-checks* and *The bug in the pool* below.

---

## What it does

`perft(pos, d)` counts the leaf nodes `d` moves below a position: at depth 1 it
is the number of legal moves, at depth 2 the sum of the legal-move counts of
every position one move down, and so on.

The generator implements all of it: every piece type, castling with its three
restrictions (right held, squares between empty, and no check on the origin,
the transit square or the destination), en passant including the pawn removed
from a square the mover never touched, promotion to all four pieces on both a
push and a capture, and pins and discovered checks — the last three by
generating pseudo-legally and filtering each candidate with *make it, look at
the king, put it back*, which is the only formulation that cannot get a pin and
an en-passant pin wrong in the same place.

`./perft --moves` prints the legal move list of any position, which is the thing
to look at first: `--moves --name=ep-pin` shows `d4d3` and **not** `d4c3`.

## The property check — published counts, no golden file

A golden file proves determinism, not rightness: `examples/cube` passed all
eight gate items while rendering a defect, because its `EXPECTED` had been
generated from the broken output. So the expectations here are **constants in
the program** — perft counts are published and authoritative, so the assertion
is the number itself and a wrong generator fails an integer, not a diff.

`./perft --check` asserts three things (47 checks, all reported):

1. **The published counts**, at every depth, for all three published positions:

   | position | 1 | 2 | 3 | 4 | 5 |
   |---|---|---|---|---|---|
   | start position | 20 | 400 | 8902 | 197281 | **4865609** |
   | Kiwipete | 48 | 2039 | 97862 | **4085603** | — |
   | position 3 | 14 | 191 | 2812 | 43238 | **674624** |

2. **threaded count == single-threaded count**, exactly, at *every* depth of
   *every* position including the trap — 19 more checks. The pool does the sum
   at depth 1 too (each worker claims a root move and counts its single leaf),
   so this compares the same decomposition at every depth rather than quietly
   falling back to one thread in the shallow ones.

3. **14 rule checks** that a count cannot localise: the en-passant pin is *not*
   in the move list and the quiet push beside it *is*; the same position with
   the rook off the rank differs by exactly that one capture; four promotions on
   b8 and two capturing promotions on a8 are legal; Kiwipete allows both
   castles; `e1g1` is *not* legal through an attacked f1 while `e1c1` is; a
   pinned rook has no sideways move.

The 14 rule checks go through **`std/test.y`**'s `test.ck(name, ok, detail)` —
the assertion this file used to write for itself as
`ck(ok, label, what) -> long`, which returned a *failure indicator* that every
caller accumulated into the run's total. The counts are unchanged (47); the other
two groups still print their own per-depth lines with their own tally, so the
summary line adds `test.checks()` to it rather than calling `test.report()` —
that would report only the rule group's 14 and silently drop the other 33.

Actual output, verbatim tail:

```
property check: threaded count == single-threaded count
  ok   startpos     depth 5: both 4865609
  ok   kiwipete     depth 4: both 4085603
  ok   position3    depth 5: both 674624
  ok   ep-pin       depth 1: both 5
  ...
property check: the rules that perft counts depend on
  ok    ep-pin
          5 moves, the en passant excluded
  ok    ep-pin
          d4c3 (the illegal en passant) is NOT in the list
  ok    ep-pin
          d4d3 (the quiet push) IS in the list
  ok    ep-ok
          6 moves, the en passant included
  ok    ep-ok
          d4c3 IS in the list here
  ok    promotion
          11 moves: 4 pushes + 4 captures + 3 king steps
  ok    promotion
          all four promotions on b8 are legal
  ok    promotion
          capturing promotions on a8 are legal
  ok    castling
          kiwipete allows e1g1 and e1c1
  ok    castle-through
          e1g1 is NOT legal through an attacked f1
  ok    castle-through
          e1c1 is still legal (d1 and c1 are not attacked)
  ok    castle-through
          23 moves in all
  ok    pin
          10 moves: the pinned rook has 6, the king 4
  ok    pin
          the pinned rook has no sideways move
  ...
property check: 47 checks, 0 failed
```

It exits non-zero if any check fails, and `gate.conf` points `check=` at it, so
the acceptance gate runs it.

### The trap position

`ep-pin` = `8/8/8/8/k1Pp3R/8/8/7K b - c3 0 1`. White has just played c2-c4, so
black's d4 pawn may take c3 **en passant** — and doing so vacates *both* c4 and
d4, opening the fourth rank from h4 onto the black king on a4. That would leave
the mover's own king in check, so the move is illegal: 5 legal moves, not 6.

The colours are the whole point and they are easy to get backwards. The first
version of this position had a *white* king on a4, the generator answered 14,
and the hand-written expectation said 9 — and the expectation was the thing
that was wrong: with the enemy king on a4 the same capture is perfectly legal,
because it simply gives check. Only after the position was fixed did the
generator's 5 agree with a second implementation.

## The threading

`perft(root, d) = Σ perft(one move down, d-1)` over the root's legal moves, so
the root moves are the work items and the count is their sum. Every worker owns
a `Pos` (its own board, its own move scratch) and copies the root into it, so
there is no board to lock: the only shared mutable state is a cursor under one
mutex.

- **The pool is started once**, at start-up, and the workers loop for the life of
  the program. A spawn leaks — each thread allocates from a heap of its own and
  nothing is ever freed, so 2000 spawn/join cycles grow the process by 256 000 B
  (ORCHESTRATOR.md §2.13) — and a thread per node would allocate gigabytes over
  a depth-5 search. `--threads 1` starts **no** thread at all: this thread does
  the work, which is also the honest `--bench` baseline.
- **The queue is a cursor, not a fixed band per worker.** A counting semaphore is
  not fair, so with static bands a fast worker takes every token and its band is
  simply never counted: an invisible worker, a total that is short, no
  diagnostic.
- **One token per worker per search**, then drain to the end, so the main thread
  waits with `wait(done)` N times — no spin, no lost-wakeup window.
- Measured (`--bench --name=startpos --depth=5`, 4 865 609 nodes, this 20-core
  box; single-thread 10.5–10.7 M nodes/s every run, and the pool figures are
  from one run each, so treat the last digit as noise): **20.6 M nodes/s** on
  two workers (**1.94×**), **31.7–34.5 M** on four (2.98–3.34×), **49.6 M** on
  eight (4.67×), **64–65 M** on sixteen (6.1×). Kiwipete depth 4 measures the
  same way: 10.5 M → 35.4 M (3.34×) on four.

### Allocation

| run | heap delta |
|---|---|
| start position depth 6, one thread, **119 060 324 nodes** | **0 bytes** |
| Kiwipete depth 5, eight workers, 193 690 690 nodes | 40 bytes |

The search allocates nothing: a `Pos` is one record of fixed arrays built once,
moves are packed longs, and there is no literal, string or record inside the
recursion. The 40 bytes of a threaded search is one `lock` block on the main
thread (a `lock m { … }` is a closure and costs 16–40 B on the calling thread's
heap, measured: 1000 lock blocks = 16 000 B), and the workers take one per work
item in their *own* per-thread heaps — bounded by the root branching factor
(≤ 218), never by the node count. `./perft --heap` prints the measurement rather
than asserting it, because `heap_used()` inside a spawned thread answers 0.

## Malformed FENs

Every position load goes through one `load()` that prints the reason on stderr
and returns a failure, so no error path is silent and no error path exits 0:

    $ ./perft --moves --fen='8/8/8/8/8/8/8/4K3 w - - 0 1'      # no black king
    perft: 8/8/8/8/8/8/8/4K3 w - - 0 1: no black king (k)
    $ echo $?
    1

The reader checks the field count (4 to 6), that the placement is 8 ranks of 8
squares with only piece letters and digits 1–8, exactly one king per side, no
pawn on the first or eighth rank, at most 8 pawns and 16 pieces a side, `w`/`b`,
a castling field that is `-` or distinct letters from `KQkq`, an en-passant
square that is well formed, empty, and on the rank the side to move implies, and
that the side which just moved is not in check. Usage mistakes (a bad `--depth`,
an unknown `--name`, `--threads 0`) exit 2; a refused position exits 1.

## What the counts caught

Six real bugs in this generator, every one of them found by a number disagreeing
and none of them by anything a golden file could see. Each is recorded in the
source beside the line that caused it, because that is where it will be read
next time:

| symptom | cause |
|---|---|
| depth 2 = 445, not 400 | `make()` never flipped the side to move; the generator produced the mover's moves twice, and only on the positions whose side alternated |
| 46 moves instead of 48 in Kiwipete | `unmake()` moved the castle rook with **make's** copy instead of its mirror, so castling deleted the h1 rook — from every position that could castle, and only from those |
| Kiwipete 18 nodes short at depth 2 | the castling-rights mask was a list of rights *destroyed* and then ANDed as if it were a list *kept*: after `Ra1-b1` the position held the white queenside right and no black rights at all. The start position hid it for hours, because its a1/h1 rooks are boxed in by their own knights |
| position 3 over-counted from depth 3 | the king-safety test read the king's square **before** `make()`, so it tested where the king came *from* and every move that walked it into check was legal. Only positions whose king can step somewhere notice — the start position agreed to depth 5 with its king frozen on e1 |
| 568 moves from the start position | `(pc & 8) == p.side` is **true for an empty square** when white is to move; a rewritten scan dropped the `pc != 0` test and read all 48 empty squares as white bishops |
| 400-node root, 0 counted | the split was *assigned* rather than accumulated (below) |

A seventh, in the pool rather than the engine: see below.

## The bug in the pool

A counting semaphore is unfair, so a worker that finishes early is handed a
**second** token, finds the cursor past the end, and takes nothing. The first
version reported its share by *assignment*, so that second turn **overwrote the
subtree it had already counted**. The totals came out short by an amount that
depended on the wake-up order: with 16 workers and 5 items, **2715 of 3000
rounds wrong, every one short, not one announced** — and `--threads 1` always
agreed with itself, so the default run reproduced perfectly.

`queue_test.y` is that harness with the chess engine taken out, and it is the
regression test for the fix (`split[w] = split[w] + mine`):

    $ ../../refs/ycc.ref queue_test.y -o queue_test && ./queue_test
    queue_test: 3000 rounds of 5..7 items over 16 workers
      mismatches: 0
      largest single share: 7 (an uneven split is fine; a missing item is not)
      pool stopped and joined

## Cross-checks

`ref_perft.py` is a second, independent perft — a dict of squares, no bitboards,
written from the rules — used to settle every disagreement above. It is a
development tool: **the property check asserts published counts, nothing from
it.** It agrees with `perft.y` move for move on every position tried, and its
`divide` is what turns "Kiwipete is 18 short" into "after `Ra1-b1`, black has 41
legal moves instead of 43". It also has its own bugs, which is the point of
having it: it castled out of check until the check was added, and it raised
`KeyError` on a FEN whose en-passant square no pawn could reach.

```
python3 ref_perft.py perft  "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1" 3
python3 ref_perft.py divide "8/8/8/8/k1Pp3R/8/8/7K b - c3 0 1" 3
```

## Compiler workarounds

Everything here is a property of Y as documented, not a bug and not filed:

- **`main()` does not set the exit status.** A Y program exits 0 whatever a
  called function returned unless it calls `exit()`, so `exit(main())` is the
  last line of `perft.y`. Two intermediate versions returned 1 from every error
  path and exited 0, which is worse than no check: a malformed FEN looked like a
  successful run that printed nothing. Related: every helper on the way to
  `exit()` returns a **status**, not a datum — `move_list` once returned the move
  count and the program exited 5.
- **Top-level `let`s do not hoist**, so every module binding lives above its
  first use. The diagnostic is "undefined variable", which reads like a typo.
- **A `let` written before a `while` loop is one shared capture cell**, so the
  spawn loop is `for w in 0..n`. With the `while` form every worker read the `n`
  the loop finished on and `POOL[n]` trapped *inside the thread*, printing
  "index out of bounds" and taking the whole program down. (Verified and
  measured in `queue_test.y`'s history: `for` gives each iteration a fresh
  variable, `let`+`while` gives one cell.)
- **`[c'\x00'; 120]`**, not `[0; 120]`, for a fixed `byte` array: `[v; n]` is n
  copies of v, and `0` is a `long`. The literal size must be a literal.
- **`lock m { … }` allocates a closure** (16–40 B, once per call, never freed).
  It is a per-*call* cost, so it is fine in a loop bounded by the root move
  count and fatal in a per-node one. This is `SUGGESTIONS.md` §10
  ("`lock m { e }` allocates a closure"), re-measured here: 1000 lock blocks =
  16 000 B.
- No `break`/`continue` (every early exit here is a guard flag or a positive
  condition), no character literals (`ord`/`chr`), no `float`→`long`
  (`ms_of`, `rate_of`, `group` and the speedup are all integer), no `sort` and
  no `push`.
- `time.now_us()` rather than `clock_us()`, which allocates two words per call —
  the reason this folder reaches for the whole of std `tui` for one function.

## Honest limits

- `--depth` is capped at 9 because the move buffer holds ten levels; the cap is
  a message and exit 2, never a trap. Depth 9 is legal and takes hours.
- The split is only as coarse as the root's move list, so a depth-1 or depth-2
  search parallelises over a handful of tiny subtrees and the pool's overhead
  dominates. `--bench` starts at depth 4 and says so.
- Scaling flattens past about eight workers (4.67× on eight, 6.11× on sixteen on
  a 20-core box) because the queue is only the root moves and the subtrees
  differ in size by an order of magnitude.
- `heap_used()` cannot see a worker's allocations (per-thread heaps), so the
  threaded delta of 40 bytes is the main thread's only. The workers' share is
  bounded by design, not measured.
- The published counts are asserted to depth 5 (start position), 4 (Kiwipete)
  and 5 (position 3) — the depths that are published *and* finish in seconds.
  The next two published depths were also run and agree: Kiwipete depth 5 =
  **193 690 690** and the start position depth 6 = **119 060 324**. They are
  simply too slow for a check that runs on every build (22 s each,
  single-threaded), so they are reported here rather than asserted.
### Pin re-verification

The compiler was reblessed mid-campaign to
`refs/ycc.ref` sha256
`6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`.
Rebuilt against it: **zero warnings**, the deterministic run still
reproduces `EXPECTED` byte for byte, no trap on any path, and this
folder's own property check still passes. No source change was needed.
Earlier pins stay listed above as history.

## Pin re-verification: `4a58dd5d` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `6dcd7071` -> **`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. The only thing that had fallen out of date was this sha
record, which is what gate item 0 caught.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `e55fa8d0` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `4a58dd5d` -> **`e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `9ce37629` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `5eba0d66` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`5eba0d66059520a9d28f5cdae57fd99835bb6ae62110bf4d2a794ae5fced484b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `625efd81` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `5eba0d66` -> **`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

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

## Pin re-verification: `289cf022002903a6` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`289cf022002903a695c1ca339816b0f8f478aa3ef9f00643a93c3a95947f979c`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `dad3564d3bcdf6df` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`dad3564d3bcdf6df889d017e88660dd8e7e0637a1e046acc45539f515e361d3e`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
