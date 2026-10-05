# httpsrv — an HTTP server with a live dashboard, in Y

A real HTTP/1.1 server on loopback, a real dashboard page, a real JSON API,
and a terminal client that fetches both and draws the same data as a live
chart. The server keeps a live model behind it (a counter, a rate, a
32-sample window) so "live" is a fact about the program and not a caption:
the client's own copy of the model says what every sample must be, and
`--self-test` compares the two.

```
== httpsrv -- an HTTP server with a live dashboard, on loopback ==
   pin c53cc41524a7baa2  (full sha256 and toolkit shas in README.md)
   server 127.0.0.1:<ephemeral>  -- any free port, so two copies never collide
   model: seeded, no clock; the same requests give the same bytes
   forked: the server is a process, so SIGTERM is how it stops

-- routes ------------------------------------------------------------
   ok route               method status  declared   actual  content-type
   ok /                   GET        200      3527     3527  text/html; charset=utf-8
   ok /api/stats          GET        200       320      320  application/json
   ok /api/history        GET        200       248      248  application/json
   ok /healthz            GET        200         3        3  text/plain; charset=utf-8
   ok /nope               GET        404        49       49  application/json
   ok /api/stats          POST       405        63       63  application/json

-- the dashboard, as the client renders it ----------------------------
+------------------------------------------------------------------------------+
|  httpsrv  127.0.0.1:<ephemeral>   virtual clock, seeded   frame 12           |
+------------------------------------------------------------------------------+
|  served       12  rate    9000/s  avg    5571/s  peak    9700/s              |
|  arrived     2344  trough    1000/s  errors       2  bytes    7563           |
|  uptime      120 ms                                                          |
+------------------------------------------------------------------------------+
|  rate, the last 32 samples, one every 10 ms                                  |
|9700 |      #                                                                 |
|8314 |#  ## #    ##     #   # #                                               |
|6928 |## ## #    #### # #   ###                                               |
|5542 |## ## # #  #### # #   ###                                               |
|4157 |## ## # ####### # #   ###                                               |
|2771 |## ## # ####### # #   ####     #                                        |
|1385 |##### # ######### # ###### ## ##                                        |
|   0 |####### ########################                                        |
|    0 +----------------------------------------                               |
|        oldest                                                          newest|
+------------------------------------------------------------------------------+
|  spark %#:%#:@ *==%%##:#.%:::##%+.-:.:=| peak 9700  trough 1000  n 32        |
+------------------------------------------------------------------------------+
```

*(that is the real output; `EXPECTED` has all of it, byte for byte)*

## Build

```
cd examples/httpsrv
../../refs/ycc.ref httpsrv.y -o httpsrv
```

Zero warnings, no `-w`, nothing else needed. `gate.conf` carries the same
two commands plus `check=./httpsrv --self-test`.

**Pinned compiler.** Built and verified against `refs/ycc.ref` sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`.
The binary this produced is sha256
`a77d15f627f7ec75fd0d14d810736202cda44c3b7b7ec754c68af695e5fbf755`, and
rebuilding from the same sources with the same compiler reproduces it byte
for byte. The pin moves when the compiler is reblessed; if the sha above
stops matching, rebuild, re-run `./httpsrv --self-test` and the golden
check, and update this README (the transcript's `pin` line is a label for
the binary, so it is updated with it).

**A note on buffer typing**, because it explains a design choice that
looks odd. Each module's buffers are declared with an exact fixed size
(`let buf: [byte; 65536]`), and the helpers that take one name that exact
size (`def write(b: [byte; 65536], ...)`). That is deliberate: it makes
`json.y`'s parser and `httpc.y`'s response buffer **the same type**, so the
compiler refuses a mismatch instead of letting it become a misparse. The
price is that each module keeps its own small byte-writer rather than
sharing one; a `[byte]` parameter would allow a single shared writer (a
runtime-sized `let b: [byte] = [0; 65536]` does work, and unifies), so this
is a choice for the compile-time check, not a wall. Both facts are
verified here.

**The std units.** `args` and `tui` are std's, byte-identical
copies of `examples/_toolkit/`, vendored (not imported across folders):

`fx.y` and `tui` are **not** used: there is no trigonometry here, and
the renderer writes bytes into fixed buffers rather than into a cell grid
(see *No per-frame allocation* below for why that is the right call here).

## Run

| command | what it does |
|---|---|
| `./httpsrv` | the deterministic transcript — this is `EXPECTED` |
| `./httpsrv --self-test` | the property check: fork, exercise over loopback, assert, stop. Exit 0 only if every check passes |
| `./httpsrv --live` | the live dashboard in this terminal (needs a tty). `q` or ESC quits, space pauses, `+`/`-` change the poll period |
| `./httpsrv --serve` | just the server, in the foreground, until SIGTERM — for pointing `curl` at |

Flags: `--port N` (0 = any free port, the default), `--samples N`
(transcript polls, default 6), `--seed N` (0..2³¹−1, default 20260101),
`--poll-ms N` (live, 10..2000, default 100), `--no-tty` (accepted; the
transcript is already the default). Exit codes: **0** fine, **1** a
runtime failure (including a failed property check), **2** a usage error.

### Routes

| route | status | body |
|---|---|---|
| `GET /` | 200 `text/html` | the dashboard page, with the live numbers in it and a script that re-polls the API every 500 ms |
| `GET /api/stats` | 200 `application/json` | the whole model: `served ticks arrived rate peak trough avg load window[32] errors bytes conns uptime_ms` (+ `heap base_heap` with `?heap=1`) |
| `GET /api/history` | 200 `application/json` | the window and its summary on their own |
| `GET /healthz` | 200 `text/plain` | `ok` |
| any other path | 404 `application/json` | `{"error":"not found","status":404,"path":"..."}` |
| a known path, wrong method | 405 `application/json` | `{"error":"method not allowed",...}` plus `Allow: GET` |
| a request line that is not one | 400 `application/json` | `{"error":"bad request line",...}` |
| a head with no blank line in 8 KiB | 413 `application/json` | `{"error":"request head too long",...}` |

Every response carries `Content-Length`, and it is the number of bytes the
body really has — the server counts them as it writes them into its
response buffer, and the client counts what arrived. Neither trusts the
other, which is what makes the equality a check rather than a tautology.

## What to look at

* **The bar chart and the sparkline agree with the table.** In the
  transcript the six polled rows are the last six ticks; the frame's chart
  shows the 32-sample window and the same numbers as tiles. The first
  column of the chart is the *oldest* sample (`win` is a ring; the server
  emits it rotated so a client can read it as a series).
* **`errors 2` on the tiles** after the route table: the 404 and the 405
  were counted by the server, live, on the way past.
* **The counter moves on every poll.** Six polls, six increases, and the
  property check demands it over ten in a row.
* `--self-test`, in full.** It is the interesting output, not `EXPECTED`:
  26 assertions with their measured evidence (below).
* `--live` under a real pty: 10.00 fps at `--poll-ms 100`, 0 frames
  dropped, worst lag 0 ms, `polls that failed 0`, `heap over the loop:
  161984 -> 161984 (delta 0 for 50 frames)`, and `wait_pid 143` at the end. `golden/live-frame-ansi.txt` is a capture of that (with the
  escapes; `cat -v` it). `golden/dashboard-frame.txt` is the deterministic
  frame on its own.

## The property check, and why there is one

`EXPECTED` proves the default run is deterministic. It cannot tell a right
answer from a wrong one — a golden file with a defect in it reproduces
deterministically for ever (this campaign's `cube` passed every mechanical
gate while rendering filled wedges). So the checks live in the program,
and they are assertions about behaviour with **no reference file
involved**. `--self-test` forks the server, exercises it over loopback,
and exits 0 only if every line is `ok`:

```
ok   route GET /  status 200, Content-Type text/html; charset=utf-8, Content-Length 3527 = 3527 bytes received
ok   route GET /api/stats  status 200, Content-Type application/json, Content-Length 320 = 320 bytes received
ok   route GET /api/history  status 200, Content-Type application/json, Content-Length 248 = 248 bytes received
ok   route GET /healthz  status 200, Content-Type text/plain; charset=utf-8, Content-Length 3 = 3 bytes received
ok   route GET /nope  status 404, Content-Type application/json, Content-Length 49 = 49 bytes received
ok   route POST /api/stats  status 405, Content-Type application/json, Content-Length 63 = 63 bytes received
ok   a wrong path is never a 200  GET /nope/deeper -> 404, body starts {true and says "not found": true
ok   405 carries Allow: GET  PUT /api/stats -> 405, Allow: GET
ok   Content-Length is the length, on every route  24 requests over 4 routes, 0 short or long bodies
ok   all six routes answered as specified  200 200 200 200 404 405
ok   the JSON round-trips  peak 9700=9700, trough 1000=1000, avg 5959=5959, arrived 3585=3585, uptime 330=33*10
ok   every field parsed  served ticks arrived rate peak trough avg window errors bytes uptime
ok   load == sum(window)  server says 190700 req/s summed over the window, client says 190700
ok   the window is the seeded model, sample by sample  32 samples predicted independently from seed 20260101 at tick 33, 0 mismatched
ok   arrived is the model's running total  predicted 3585 requests over 65 draws, server says 3585
ok   the counter is alive  served 33 after the route sweep
ok   served strictly increases  10/10 successive fetches moved the counter forward, now 43
ok   the page and the JSON agree  /api/stats says served 44, the page one request later says 45 -- the +1 is that page request itself
ok   the page is the dashboard  3538 bytes, has a doctype and the live tiles
ok   the page's length is right too  declared 3538, received 3538
ok   ?heap=1 makes the server report its own heap  status 200, heap_used() 162520 with boot 161672 -- a missing field would have made the delta below read 0 == 0
ok   the server does not grow serving  50 requests: heap_used() 162520 -> 162520 (delta 0, boot 161672)
ok   the client does not grow polling  first 50 requests 180696 -> 180696 (delta 0, one-off), next 150 180696 -> 180696 (delta 0)
ok   std http.get agrees with this client  status 200, Content-Length 332 = 332 bytes read; this client got 332 bytes
ok   20 std requests, 20 non-empty bodies  0 came back empty; body read once into a variable each time
ok   the server stops cleanly  SIGTERM -> wait_pid 143 (128+15), not a crash
PASS 26 checks, 0 failed
```

Four of those are the ones the brief asks for, and they are worth reading
twice because each is an equation between numbers computed on **opposite
sides of the socket**:

1. **Every route answers with the status it must** — 200, 200, 200, 200,
   404, 405 — and a wrong path (`/nope/deeper?x=1`) comes back 404 with a
   body that starts `{` and says "not found", never a 200 body.
2. **`Content-Length` equals the actual byte length**, checked on every
   route and again over 24 requests spread across four routes. The number
   on the left was written by the server while building the body; the
   number on the right was counted by the client over the bytes that
   arrived.
3. **The JSON parses back to what the server intended.** `peak`, `trough`,
   `avg` and `uptime_ms` are compared against the client's own sums over
   the 32 samples; `load` (the server's running total over its window) is
   compared against the client's fresh sum of the same 32 numbers; and
   then the strongest one: **the client's own implementation of the model**
   (a second, independently written copy of the Lehmer generator) predicts
   all 32 samples from the seed and the tick count, and they match. A typo
   in either copy shows up as a disagreement instead of cancelling out.
4. **The counter strictly increases** — 10 of 10 successive fetches, plus
   `arrived`, the cumulative number of simulated requests, predicted
   exactly from the model.

(The two heap figures move by a few bytes from run to run — they are the
program's own `heap_used()` — and the std client's byte count moves by tens
of kilobytes. The *deltas* are what the check asserts, and they are 0.)

Plus the two allocation checks and a cross-check against the standard
library's client (see below).

### Three of these checks earned their keep

They are not decoration; each one caught a real defect in this folder while
it was being written, and each defect is the kind a golden file happily
reproduces:

* **The NUL body.** The first response was written with a single
  `write(2)` of `head + body` from offset 0, while the body had been built
  at offset 512 — so the bytes between the head and the body were sent as
  part of the response. Every `Content-Length` was *correct*; every byte
  after the head was NUL. The JSON validator caught it
  (`expected a number at byte 155`). Fixed by writing the head and the body
  as two writes, with a comment at the call site.
* **The page of zeros.** The dashboard page shipped literal `0`s in its
  tiles — the inline script updated them in a browser, but a `curl` saw a
  dead page. `--self-test` read `id=v-served` out of the bytes and compared
  it with `/api/stats` and found 0 ≠ 45.
* **`heap_used() 0 == 0`.** The allocation check asked the server for its
  own heap over `?heap=1`, and the query never arrived — a hardcoded `'k'`
  in the query matcher instead of the key it was given — so both numbers
  were *absent*, compared equal, and the check passed. There is now an
  explicit check that the fields are present and non-zero, so "absent"
  can never read as "flat" again.

## No per-frame or per-request allocation

Measured by `--self-test`, in both processes, over 200 requests:

| | heap before | after 200 requests | delta |
|---|---|---|---|
| the server (its own `heap_used()`, over `?heap=1`) | 162 448 | 162 448 | **0** |
| the client (`heap_used()` around the loop) | 180 624 | 180 624 | **0** |
| the live frame loop (50 frames, reported by the program itself) | 161 984 | 161 984 | **0** |
| std `http.get`, for comparison | — | — | **31 400–45 500 bytes a request** |

Three things buy the zeros, and all three are measured rather than assumed:

* **Fixed buffers, hoisted to module level.** The request head lands in
  `rbuf`, the response is built in `obuf`, the client's request and
  response live in `req`/`buf`, and the frame lives in `dash.out`. The
  digit scratch in every `w_num`-shaped helper (`srv.w`, `httpc.w_num`,
  `dash.n`, `dash.rpad`) is a module-level `[byte; 24]`, not a literal made
  per call: **a `[byte; 24]` literal inside a function that runs per
  request costs 64 bytes a call here** (measured: 2 000 calls grew
  `heap_used()` by 128 000, and the heap is an arena, so it is never
  given back).
* **No `net.addr_set` in the request path.** It does `split(host, ".")`
  internally, which allocates a `[str]` of four strings *per call*. The
  client and the server write the 16-byte `sockaddr_in` themselves (four
  lines, and the big-endian port is right there to be seen).
* **No `str` on the data path.** Every byte of every response and every
  frame is written into a fixed buffer; the numbers are formatted into it.
  `dash.render()` costs **zero** bytes of heap, which is what makes a frame
  loop possible at all here.

The standard library's client is not used for polling, and the reason is
measured rather than asserted: 20 `http.get` calls grew the heap by
628 016–909 776 bytes over five runs (it varies run to run; that is
31–45 KB a request), so a 10 fps dashboard on it would exhaust the 3.5 GiB
cap in a couple of hours. `httpc.y` is 320 lines of fixed-buffer HTTP/1.1 GET and costs
nothing, and `--self-test` fetches the same URL both ways and asserts the
status and the body agree.

## Compiler behaviour worked around (and where it is filed)

Nothing here needs a compiler fix to run. Two things are worked around, and
both are visible in the code:

* **`examples/BUGS.md`, "An apostrophe inside an f-string is charged to the
  enclosing call: `puts takes exactly 1 argument`"** — a `str` literal
  written `'like this'` inside an `f"..."` field ends the f-string at the
  apostrophe and the parser then blames the enclosing call for its arity.
  `puts(f"{'route':<20}")` reports `puts takes exactly 1 argument` while
  `puts` is being handed exactly one argument. **Worked around** in
  `httpsrv.y` by the `padl`/`padr` helpers (with a comment at the header
  of the transcript code saying why they exist): double quotes work
  (`f"[{"a"}]"`), and so does a variable.
* **Runtime traps go to stdout** (ORCHESTRATOR.md §2.6), so a trap would
  splice itself into the middle of a frame and of `EXPECTED`. Every
  index into a byte buffer is therefore either bounded by construction or
  guarded: `dash.spark` clamps its glyph level at *both* ends because
  `RAMP[lvl]` with a negative sample is an index-out-of-bounds trap, which
  is exactly how `--seed=-1` first killed the transcript before the seed
  was validated.

Also honoured, from the same document, and worth repeating because each
one is a silent failure rather than a crash:

* **`net.listen_http` never returns and has no shutdown.** The server is a
  `fork`, stopped with `syscall(62, pid, 15)`, and `wait_pid` answers
  **143** = 128 + SIGTERM — which `--self-test` asserts, because a server
  that crashed and one that stopped look the same to everything else.
* **`term.read_key_timeout(ms)` cannot be finer than 100 ms** (VTIME counts
  deciseconds), so a frame loop that polls a key with a timeout loses
  whole frame periods. The live loop polls with
  `read_key_timeout(0)` — a non-blocking read — and `tui`'s pacer owns
  the deadline: **10.00 fps, 0 dropped, worst lag 0 ms** at
  `--poll-ms 100`.
* **`term.size()` returns a fresh record every call** (~40 bytes), so a
  per-frame resize poll would leak. `dash.winsize()` does the TIOCGWINSZ
  ioctl into one module-level buffer and leaves `rows`/`cols` in module
  globals. (Remember `syscall(16, fd, REQUEST, arg)` — the request is the
  *third* argument, kernel register order.)
* **`pipe` writes two 32-bit ints**, so the port the kernel picked comes
  back through a `[byte; 8]` and is reassembled a byte at a time. Reading
  it from a `[long; 2]` would pack both fds into element 0 and leave the
  write end as 0 — stdin — and nothing anywhere would say so.
* **`http.Response.text()` is read-once** (the first entry in
  `examples/BUGS.md`). The std client is used exactly once per URL in the
  cross-check and the body is read into a variable, and `r.err`/`r.status`
  are checked before the body is touched.
* **No JSON module, so `json.y` is hand-rolled** (411 lines, over
  `split`/`index_of`/`ord` on a byte buffer): a recursive-descent
  validator with a depth bound, a key lookup, integer and string readers,
  and an array walker. A malformed document gets a position and a reason,
  not a wrong number. This is expected work rather than a workaround — a
  JSON module is already on the compiler's roadmap.
* **No `break`/`continue`**, so every early exit is a guard flag or a
  positive condition, and **every scan loop advances its cursor on every
  path** — a cursor that is only advanced on the matching branch is an
  infinite loop, and writing one cost me an afternoon during development.
* **`f"{x:>8}"` works for numbers** (and for variables), so the numeric
  columns of the tables are formatted with f-strings; only string *fields*
  have the filed problem above.
* **`str + byte` segfaults** (second entry in `examples/BUGS.md`), which
  is why the sparkline's glyph goes into the frame straight from the byte
  (`out[p] = RAMP[lvl]`) instead of through a string.

### Honest limits

* The server handles **one connection at a time** and closes it
  (`Connection: close`). That is what `net.listen_http` does too, and what
  makes "no per-request allocation" measurable; it is not a server for the
  internet, and this example never leaves loopback.
* A request head that never sends its blank line holds the connection
  (HTTP says to wait for it). There is no read timeout: one slow client
  would block the server. A real server would `setsockopt(SO_RCVTIMEO)`.
* `fork` + the heap means the server's `heap_used()` is its own; the
  client's is separate. Neither sees the other's.
* The forked child notices it has been reparented (`getppid() != pid`
  after each request) and exits, so an orphan cannot outlive the program
  by more than one request — but a *trap* in the parent leaves the child
  until its next request. Every exit path in `main` goes through
  `stop_server()` for exactly this reason, and `stop_server()` refuses to
  run when there is no pid (`kill(0, …)` is the process group).
* The **last expression's value is not the exit status** — measured, not
  assumed: a `main` that returned 1 left the program exiting 0. So the
  failure paths call `exit()` explicitly.
* `--live` shows a real measured rate in requests per second, which depends
  on the client's poll period; `--samples`/`--live` numbers in this README
  came from this machine.

## Layout

| file | lines | what |
|---|---|---|
| `httpsrv.y` | 814 | the driver: flags, the transcript, the property check, the live loop |
| `srv.y` | 777 | the server: the model, the accept loop, the routes, the dashboard page, the fork/stop |
| `json.y` | 411 | a hand-rolled JSON reader that works in place over bytes |
| `httpc.y` | 321 | a fixed-buffer HTTP/1.1 GET client (no allocation per request) |
| `dash.y` | 403 | the dashboard renderer, its own `winsize()`, row-diffed painting |
| `args`, `tui` | — | from std, unedited |
| `EXPECTED` | 3865 B | the default run's stdout, exact |
| `golden/dashboard-frame.txt` | 1701 B | the frame alone, a byte-identical slice of `EXPECTED` |
| `golden/live-frame-ansi.txt` | ~8 KB | a pty capture of `--live`, escapes included (numbers vary: real clock) |
| `pty_check.py` | — | drives `--live` under a pty, reports exit code, frames, restores |
| `pty_capture.py` | — | writes `golden/live-frame-ansi.txt` |
| `gate.conf` | 3 keys | `build=`, `run=`, `check=` |

## Checks run on this folder

* `python3 ../gate.py httpsrv` → 9/9 (item 8 runs `--self-test`).
* `EXPECTED` reproduced twice, byte for byte, and from a clean copy of the
  folder alone (`/tmp`, no sibling present): zero warnings, same bytes,
  `--self-test` 26/26.
* 22 command lines — every flag, every bad value, `--help`, `--live` with a
  piped stdout — **0 traps**, no leaked child processes, exit codes 0/1/2
  as documented.
* Hostile input against `--serve`: `DELETE /api/stats` → 405 with
  `Allow: GET`; `GET /../etc/passwd` → 404; a garbage request line → 400
  with a JSON body; an unterminated head → the server waits, as HTTP says.
* `--live` under a pty (`TIOCSWINSZ` set before `execv`, or the window is
  0×0): 10.00 fps, 0 dropped, worst lag 0 ms, alt screen entered and left,
  terminal restored, `wait_pid 143`.
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
