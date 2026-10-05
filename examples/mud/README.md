# `mud` — a threaded MUD over loopback TCP, with a reproducible transcript

A multi-user dungeon: a server with a fixed-size worker pool and a seeded
world, a client that renders the server's replies into a transcript, and a
property-check mode that measures four things a golden file cannot check.

```
../../refs/ycc.ref mud.y -o mud      # build (the pinned compiler, no -w)
./mud --frames 13 --seed 1           # the deterministic run; stdout == EXPECTED
./mud --check                        # five property checks, no reference file
./mud --bench 1000                   # throughput and heap, no golden file
./mud --live                         # interactive, needs a terminal
python3 pty_check.py                 # drives --live through a pty
```

**Pinned compiler** — `refs/ycc.ref`, sha256

```
c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

**This folder's binary**, built with exactly that compiler from the sources
beside it, sha256

```
3bcf646f92a8ace87da10c708c0f127df9ec116a67cec7cdaf371e5643224009  mud
```

`refs/` moves on every rebless. If that first sha no longer matches, rebuild,
re-run, and update both it and `EXPECTED` — the golden file is only meaningful
against the compiler that produced it.

**Vendored toolkit** — copied byte-identical from `examples/_toolkit/`, never
edited:

| file | sha256 |
|---|---|
| `term.y` | `07135b31109fcecdef5bddf7d0299c9194039d172396b49347630a93a286b6ee` |
| `args.y` | `cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28` |
| `time.y` | `6050605cfcfb35db17ff180f89b4229796a7616099afbe34e2d2f34cdf37784b` |

`fx.y` and `fb.y` are not used: there is no fixed-point math here, and the live
view draws with a handful of escapes rather than a framebuffer. No copy differs
from the toolkit.

---

## What it is

```
  client thread            server                       client thread
  ────────────            ───────                       ────────────
  login alice  ──TCP──▶  accept ─▶ slot 0 ─▶ worker 0
                          worker 1 ─▶ slot 1 ─▶ worker 1
  ◀── protocol blocks ──              (one worker per session, for life)
  transcript                                    transcript
```

* **A fixed pool.** `--workers N` threads, spawned once at start-up. A
  connection is handed to an idle worker through a semaphore and stays there
  until it closes. `--bench 1000` therefore costs eight threads and eight
  session slots, not a thousand of either.
* **A seeded world.** 16–24 rooms on a 7×5 lattice. A new room is only ever
  placed next to an existing one, and both directions of every exit are written
  together, so the graph *is* the map and every room is reachable by
  construction. `--seed` fixes it.
* **Verbs.** `login`, `look`, `go <dir>`, bare compass directions, `take`,
  `drop`, `attack`, `wait`, `say`, `who`, `map`, `sync <n>`, `help`, `quit`.
  Anything else is answered, not trapped.
* **One transcript renderer, two sinks.** The headless run prints the
  transcript; `--live` draws the same bytes in the terminal. The client never
  reads the world directly — it believes only what the server told it, so a
  wrong belief shows up in the transcript instead of being papered over.
* **A property check.** `--check` runs five checks and prints PASS/FAIL for
  each. No golden file is involved.

## What to look at

* `EXPECTED` — 6 249 bytes: two transcripts, 13 steps each, and a summary.
* `golden/check.txt` — the five property checks.
* `golden/bench-1000.txt` — 1 000 connections: heap growth **zero**.
* `golden/live-frame.txt` — the raw bytes `--live` drew into a 30×100 pty.
* `golden/help.txt` — every flag.

Read the `> say hello there` step in `EXPECTED`: alice's own reply echoes her
line, and the reply to the barrier *after* it carries bob's. That is the whole
determinism design, and the next section is why it looks like that.

## Reproducibility, and what it costs

The headless run is byte-identical over repeated runs, and `--frames` anywhere
from 0 to 400 with any `--seed`. Measured: 5 runs each of 27 frame counts and
21 seeds, all identical.

Getting there was most of the work, and the three things that had to be true
are worth stating plainly, because they are design decisions rather than
accidents:

1. **A session owns a private copy of the mutable world.** `MUT_ROOM`,
   `MUT_QTY` and `MUT_MHP` are per-slot copies written once at login. Nothing
   is shared, so nothing can interleave. The price is a real property, and it
   is what check (b) measures: two players *can* both pick up the same torch,
   and one dropping it does not empty the other's pack.
2. **`sync <n>` is a generation barrier, and chat is promoted by it.** A `say`
   is staged; the barrier whose arrival *opens* a round moves every session's
   staged chat into its deliverable bytes, inside the one critical section that
   opens the round. After that the set is frozen, so each session drains it
   whenever it likes. Chat therefore appears in the reply to the first barrier
   after the `say` — and in no other reply. Two earlier designs both drained
   "around" the barrier and both were measurably flaky (2 of 5 runs identical,
   then 3 of 14); the reasoning and the numbers are in `server.y`, under
   "CHAT: STAGED, THEN PROMOTED".
3. **The client's step table is checked, not trusted.** `props.y` check (e)
   walks the thirteen steps and fails if a `say` has no barrier before the next
   one. Edit `driver.build_cmd` carelessly and the run says so instead of going
   quietly flaky.

### Limits, stated rather than hidden

* **Three or more clients are not byte-reproducible.** With one other player,
  `+ROTH` and chat are in a fixed order. With several, the order *within* a
  block follows the order the sessions were assigned slot numbers — which
  follows accept order — so `also here:` lines and chat lines can be permuted.
  Nothing else changes: the values, the counts and the map are identical. The
  golden run uses two clients. Sorting those lines by name would fix it; it is
  not done because the default does not need it.
* **A session that never sends `sync` never sees chat**, because only a barrier
  promotes. `--live` pays that, and `--live` runs one client with nobody to
  talk to.
* **A barrier that times out promotes nothing.** `--clients` must be ≤
  `--workers` (a worker serves one session at a time) and `--check` needs ≥ 2;
  both are refused up front rather than left to time out.

## MEASUREMENTS

`--bench` runs N connections through the pool one at a time (that is the point:
connections per second through the pool, not the scheduler), 8 commands each,
and reports the heap. `heap_used()` reads `%fs`, so a worker's own growth can
only be sampled from inside that worker — which is why `server.worker` records
it there.

| connections | main heap delta | worker heap growth | worst worker | conns/s | cmds/s |
|---|---|---|---|---|---|
| 400 | 8 440 | **0** | **0** | 4 646 | 51 110 |
| 800 | 8 440 | **0** | **0** | 4 934 | 54 337 |
| 1 600 | 8 440 | **0** | **0** | 4 287 | 47 165 |
| 3 200 | 8 440 | **0** | **0** | 4 300 | 47 000 |

The main-thread figure is **flat** — the same 8 440 bytes at 400 connections
and at 3 200, i.e. it is a fixed start-up cost and not a per-connection leak.
The worker figure is **zero**: nothing on a serving thread's heap grows at all,
not by a byte, across three thousand connections. Timings are wall clock on a
shared machine; the heap numbers are exact.

The golden run reports `main heap delta 408`, `worker heap growth 0`,
`worst worker growth 0`.

Getting to zero took, in order of what they were worth:

| what | was | now |
|---|---|---|
| `lock` on a hot path | 136 B a command (the block is a closure) | 0 — the lock is a `sem(1)` |
| a name as `str` | ~80 B a login | 0 — `S_NAME: [byte; 256]` |
| `tostring(goal)` | 32 B × 2 a connection | 0 — written straight into the line |
| the line buffers in `run_client` | 8 208 B a call | 0 — the caller's |
| a timespec per barrier spin | 24 B an iteration | 0 — one per worker thread |
| `net.connect_addr`'s `split` | 248 B a connection | 0 — the sockaddr is the caller's |

## WORKAROUNDS

Every one of these is a Y-language or runtime consequence, worked around in this
folder, with the measurement that forced it. The first two are already filed;
the rest are in the ledgers' history.

**1. `lock m { ... }` allocates a closure, so a mutex costs heap on every use.**
The block is lowered to a closure record and called between
`y_mutex_lock`/`y_mutex_unlock`. Measured on the pinned compiler: 16 bytes for a
block that captures nothing, 40 for one, 64, 88, 112 for two, three, four —
and each captured local *also* becomes an 8-byte heap cell, because a cell has
to exist for the closure to point at. With captures, the closure is built even
when the guarded branch is not taken. A per-command lock is therefore a
per-command leak on an arena that never frees. **Worked around** by using
`sem(1)` and writing `wait LM; …; post LM;`: `wait`/`post` are builtins
(`call y_sem_wait` / `call y_sem_post`), their read-modify-write is a full
barrier, and 1 000 critical sections cost 0 bytes. The price is stated in
`server.y` next to `LM`: a semaphore has no owner, so a critical section that
took it twice would deadlock rather than trap.
→ filed as `SUGGESTIONS.md` §10 (`lock m { e }` allocates a closure).

**2. A local array literal is a heap allocation.** `let ts: [long; 2] =
[0; 2]` inside a loop is 24 bytes an iteration; `[byte; 4096]` is 4 136. This is
why every buffer in the program is either module-level or a parameter: the
line buffers, the sockaddr, the barrier's timespec, the name arena, the
transcripts. → `SUGGESTIONS.md` §7 (a record or array literal inside a loop body
allocates on every iteration).

**3. A `str` is a heap block, so `tostring(n)` allocates.** Measured 32 bytes a
call, twice a connection, on the client's own thread. `sockio.obn` and
`client.tn` write digits into a byte buffer instead; `driver.send_sync` exists
only to avoid one `tostring` on the per-connection path.

**4. `t.size()` returns a fresh record per call** (~40 bytes), and a live view
that polls it every frame leaks. `mud.y` does the `TIOCGWINSZ` ioctl into its
own `[byte; 64]` once, and reads the four little-endian 16-bit values out of it
— row first. → `examples/SUGGESTIONS.md` §3 (a `term` module whose `size()`
would be the whole fix).

**5. `term.read_key_timeout` counts DECISECONDS.** VTIME is in deciseconds, so
any non-zero argument rounds *up* to the next 100 ms — five
`read_key_timeout(1)` calls measured 518 ms. The live loop uses
`read_key_timeout(0)` and lets `time.pacer` own the deadline; the key poll is
non-blocking. → filed in `examples/SUGGESTIONS.md`.

**6. `term`'s 64-byte `ESC_BUF` is not a frame buffer, and its `sgr_*`
emitters are one-shot helpers** — each does `buf_reset()` + `flush()`. Drawing
a frame with them throws the frame away every time the colour changes, so
`--live` showed only the tail of each frame and never cleared the screen.
`mud.y` builds the frame in its own module-level `[byte; 8192]` and writes it
with one `write(2)`. Not a compiler issue — a toolkit API that reads like a
builder and is not one. Recorded here rather than filed, because the fix belongs
in the caller's own renderer.

**7. A thread handle cannot be collected.** A spawn's value is a closure, its
type is `() -> long`, and `[(long) -> long]` is a *different* type and is
rejected — so the worker handles cannot go into an array to be joined. They are
not joined: `driver.stop` releases them through `SHUTDOWN` and the process exits
through `exit_group(0)`, which reaps every thread. A `V_DONE` counter with a
bounded wait stands in for `join` on the client side.

**8. Fixed-size arrays cannot be written as nested literals,** and
`[0; N]` is `[long; N]` while a `[byte; N]` needs an annotated binding. Every
buffer here is a plain literal with an explicit type.

**9. `str + byte` segfaults.** Names and item names are copied byte-wise into
fixed buffers instead. → `BUGS.md`, "`str + byte` segfaults".

**10. A record type is exact** and a union member must be read through a cast, so
the compiler's own AST is held in unions with shared fields first. This folder
has no unions — the state is per-slot flat arrays, indexed `slot * MAXI + i`,
which is the same discipline without the cast.

## FILINGS

This folder filed nothing new. The two language findings it ran into hardest are
already in the ledgers:

* `SUGGESTIONS.md` §10 — `lock m { e }` allocates a closure (see WORKAROUNDS 1).
* `SUGGESTIONS.md` — the same entry's `post`/`wait`-are-free table, which is
  what this program uses instead.

`BUGS.md` was searched before every workaround above; each one names the entry
it belongs to, and where an entry already existed this folder used it rather
than filing a duplicate.

## Files

| file | what |
|---|---|
| `mud.y` | flags, the three modes, the live view, the frame buffer |
| `server.y` | the pool, the acceptor, the protocol, every verb, the barrier |
| `client.y` | the parsed view, the renderers, the transcripts |
| `driver.y` | `serve`, the step table, the scripted clients, `run_pair`, `run_chat_pair` |
| `props.y` | the five property checks and the tally |
| `world.y` | the seeded generator and the graph soundness predicates |
| `sockio.y` | the listener, the dial, the line reader, the byte appends |
| `rnd.y` | a seeded LCG, and a per-session one |
| `term.y`, `args.y`, `time.y` | vendored toolkit, byte-identical |
| `pty_check.py` | drives `--live` through a pseudo-terminal |
| `gate.conf` | build / run / check lines for `examples/gate.py` |
| `EXPECTED` | the exact stdout of `./mud --frames 13 --seed 1` |

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
