# `rest-client` — a REST client, hermetic by default

A REST client written in Y that talks to **its own forked loopback server**.
Nothing reads the clock, nothing touches the network, and the port is
whatever the kernel hands out — so the default run is byte-for-byte
reproducible and offline, while still exercising real HTTP framing, real
sockets, real `fork`, real JSON parsing and real `SIGTERM`.

```
$ ../../refs/ycc.ref rest-client.y -o rest-client
$ ./rest-client
```

The default run is a scripted **status matrix**: 17 requests covering
`GET`, `POST`, `PUT`, `DELETE` and the seven statuses the example claims —
`200`, **`201` with a `Location`**, **`204` with a 0-byte body**, `400`,
`404`, **`405` with an `Allow`**, `409` — and it prints what the server
actually said, including a **byte count of the body taken from the socket
rather than believed from the `Content-Length` header**.

`./rest-client --self-test` runs a **310-assertion property check** over
**110 responses**, and is wired into `gate.conf` as `check=`, so the
acceptance gate runs it and fails on a non-zero exit, on a
`runtime error:` trap, or on the word `FAIL` anywhere in its output.

---

## What is in here

| file | what |
|---|---|
| `rest-client.y` | the client, the scripted demo, the property check (`--self-test`), the TLS stage (`--tls-selftest`) and `--live` |
| `server.y` | the loopback server: request parsing, routing, the JSON bodies, the accept loop |
| `jint.y` | one function: a JSON number that has to *be* an integer, because `json.as_long` truncates |
| `store.y` | the item store (fixed `[long; 16]` table) and its own counters, which the property check reads back over `X-Store` |
| `json` | from std — this folder's own 626-line hand-rolled parser is gone |
| `audit-str-append.py` | the `-S` audit described below; run it, do not eyeball the quadratic |
| `gate.conf` | `build=`, `run=`, `check=` |
| `EXPECTED` | the exact stdout of `run=` (5242 bytes) |

## Build and run

```
(ulimit -S -v 3670016; ../../refs/ycc.ref rest-client.y -o rest-client)
(ulimit -S -v 3670016; ./rest-client </dev/null)              # -> EXPECTED
(ulimit -S -v 3670016; ./rest-client --self-test </dev/null)  # 310 assertions
(ulimit -S -v 3670016; ./rest-client --tls-selftest </dev/null)   # optional
python3 ../gate.py rest-client                                # -> 9/9
```

Every command takes `</dev/null`: traps print to **stdout**, so an
unexpected one would corrupt `EXPECTED` rather than announce itself.

## The CLI

| invocation | what it does | exit |
|---|---|---|
| `./rest-client` | the scripted status matrix (the `run=` line) | 0 |
| `./rest-client --self-test` | the property check | 0 on success, 1 on any failure |
| `./rest-client --tls-selftest` | the TLS stage against `openssl s_server` (see below) | 0, or 0 with a SKIP |
| `./rest-client --live URL [METHOD] [--body JSON] [--insecure]` | one request to a real endpoint | 0 on 2xx |
| `./rest-client list` | one `GET /items` against a fresh server | 0 on 2xx |
| `./rest-client read ID` | one `GET /items/ID` | 0 on 2xx |
| `./rest-client create [-t TITLE] [-q N] [-i ID] [-d] [--body JSON]` | one `POST /items` | 0 on 2xx |
| `./rest-client update ID [-t TITLE] [-q N] [-d] [--body JSON]` | one `PUT /items/ID` | 0 on 2xx |
| `./rest-client delete ID` | one `DELETE /items/ID` | 0 on 2xx |
| `./rest-client shell` | a tiny line-oriented REPL over the same verbs | 0 |
| `./rest-client help` | the usage text | 0 |

**The exit status follows the HTTP status** on the one-shot commands: 0 for
a 2xx, 1 for anything the server refused or for a transport error, 2 for an
argument error, and 1 if the server could not be stopped cleanly. A command
that printed a 404 and exited 0 would be indistinguishable from one that
worked — and `--body=notjson` is exactly how a shell reaches the 400 path:

```
$ ./rest-client create --body=notjson ; echo $?
-- POST /items   (7 bytes sent)
   HTTP/1.1 400 Bad Request
   ...
1
```

Every argument-validation path prints a message to **stderr** and exits
**2** — never a trap. `main() -> long` alone does not set the exit status;
the entry point is `}; exit(main())`.

## What to LOOK AT

1. **The `X-Store` header.** It is the store's own account of itself —
   `live=`, `created=`, `updated=`, `deleted=`, `rejected=` — and it is a
   *second, independent* count of what happened. The property check compares
   the client's view against these numbers rather than against its own
   arithmetic twice, which is what makes `eq_int(...)` non-vacuous.
2. **`body N bytes counted, N declared -- framing agrees`** on every
   response. The count comes from what actually arrived; the header is
   printed beside it so a mismatch would be visible. `check=` asserts
   `counted == declared` on **every one** of the check's 110 responses, and
   additionally that a `204` has a body of 0 bytes.
3. **`-- GET /items/1` returning 404 twice** after the delete — once for the
   read and once for the second delete. That is the state machine's
   "the resource exists exactly when it should" claim, made visible.
4. **`PATCH /items/2` → 405 `allow: GET, PUT, DELETE`** next to
   `DELETE /items` → 405 `allow: GET, POST`. The two `Allow` sets differ,
   and each is checked against both the header *and* the body, which the
   server wrote independently.
5. **The title `he said \"hi\"`** in the last create. The client escapes it,
   the server escapes it, and the check asserts that a title containing a
   quote decodes back to the exact original **through the listing as well**
   as through the create — so the server cannot silently unescape on the
   way out.
6. **`SIGTERM -> child 143 (128 + 15)`** at the end. Y has no signal
   handlers, so the kernel is asked directly; the child's `wait4` status is
   the proof the server was stopped rather than crashed.
7. **`rest-client.y:1290` onwards — `self_test()`**, the property check.
   Read `present()` and `check_harness()` first; they are the two guards
   against a vacuous pass.
8. **`-- the same listing, walked by show_fields() —`** inside
   `check_full()`. It dumps all 16 items one field per line, through the
   same function the default run uses, and then measures the arena around it.
   It is the only place the display loop runs more than once.

## The property check, and why it is not vacuous

A golden file proves determinism, not rightness — `cube` passed every gate
item while rendering filled wedges, because its `EXPECTED` had been
generated from the broken output. `--self-test` therefore asserts
*behaviour*, with no reference file involved:

* **the CRUD state machine against a fresh server** — create → read →
  update → delete; the resource exists exactly when it should; a read
  after a delete is 404; a second delete is 404, not another 204; `PUT`
  is idempotent and a read after the update returns the updated body.
* **every verb × situation returns exactly the status claimed**, with the
  `Allow` set correct on both 405s (an item: `GET, PUT, DELETE`; the
  collection: `GET, POST`; `/healthz`: `GET` alone) and each `Allow`
  cross-checked against the body. `400` for a bad id, an empty id, a
  negative id, a missing field, a non-JSON body, a fraction, a string where
  an integer belongs, an empty body; `404` for a missing item and a missing
  route; `409` on a duplicate create, with the store's own `rejected`
  counter checked.
* **`Content-Length` equals the actual counted body length** on all 110
  responses, and a `204` has a body of 0 bytes.
* **a full 16-item collection**: filled, one create past the slot count
  refused with `507`, listed, walked element by element against the id each
  create answered in its own `Location`, then a delete that removes exactly
  one. This is the only pass where the listing loop runs more than once, so
  it is where a dropped, duplicated or reordered element would show.
* **the JSON parser** round-trips the exact payloads — including
  parse, rebuild, compare: re-emitting the parsed values must reproduce the
  bytes that arrived — and **rejects the malformed set**: truncated object,
  trailing comma (object and array), unquoted key, single quotes, unknown
  escape, bad hex in a `\u`, unbalanced bracket, unterminated string, a
  leading zero, a leading `+`, a bare fraction, a missing comma, two
  values in one body, an empty body and a whitespace-only body. A refusal
  has to name a reason *and* a position inside the document, so "rejected"
  cannot quietly mean "gave up in silence".
* **`Response.text()` is read exactly once per response**, counted against
  the responses received.

**Guards against a vacuous pass**, because two agents in this campaign
shipped one each:

* `present(v, what)` asserts an observed value is **present and non-zero**
  before anything compares it, and returns it so a caller can use it either
  way. Sentinels for a field that never arrived are `0-999997`-style
  numbers a real value cannot equal.
* Expected counts come from **outside** the value being checked: the
  script's own tally (`c_replies`) and the **server's own `X-Store`
  counters**, compared as a *difference* taken from the header before and
  after — never as an absolute that assumes nothing else touched the store.
* No id is assumed. `check_full()` records the id each create answered in
  its `Location` and compares the listing against **those**, because
  "element 2 has id 3" is an assumption about the server, and an assumption
  is what makes a comparison vacuous.
* Every response the check receives goes through one function, `ask()`, so
  the framing assertion and the one-read-per-response count cannot be
  dodged by using the other entry point. The totals at the end prove it:
  `text_reads == c_replies == c_framed == 110`.
* `check_harness()` makes one assertion false on purpose and requires the
  failure tally to move, so a check whose comparisons were all vacuous
  cannot look identical to one that passed. That deliberate line is printed
  with a `----` marker, not the word `FAIL`, because the gate greps the
  whole output for `FAIL` and would read a self-test *of* the harness as a
  failed self-test.

**And the checks were shown to fail.** Seven defects were injected into a
copy of the folder, one at a time; every one was caught, and every one
exited non-zero:

| injected defect | result |
|---|---|
| a duplicate create answers `201` instead of `409` | 3 failures, exit 1 |
| `ALLOW_ITEM` drops `DELETE` from the 405 | 5 failures, exit 1 |
| `Content-Length` one byte more than the body | 44 failures, exit 1 |
| a `DELETE` of a missing id answers `204` | 3 failures, exit 1 |
| a `PUT` of a missing item answers `200` | 2 failures, exit 1 |
| the parser accepts a trailing comma in an object | 3 failures, exit 1 |
| the listing skips one element | 8 failures, exit 1 |

The last one also taught the harness something: with the server wedged the
check hung rather than failing, so **every request now carries a 5-second
timeout**. A check that hangs tells nobody anything; one that reports a
status of 0 and an error string says exactly what happened.

## The `-S` append audit (`y_str_app` vs `y_str_cat`)

`str +=` in a **value-used** position makes the whole enclosing loop O(n²)
in heap. You do not have to eyeball this:

* `call y_str_app` is the **in-place, amortised** append (a *discarded*
  position).
* `call y_str_cat` is the **exact-size copy** (a *value-used* position) —
  a fresh string on every iteration.

`audit-str-append.py` builds a real control-flow graph per function from
`refs/ycc.ref -S rest-client.y` (basic blocks, Tarjan SCC) and reports every
`y_str_app`/`y_str_cat` call site that sits **on a cycle**:

```
$ ../../refs/ycc.ref -S rest-client.y > /tmp/rest.s
$ python3 audit-str-append.py /tmp/rest.s
```

**The auditor was validated against an injected defect before being
trusted.** A scratch program with two deliberate `out = out + "x"` loops
and two `out += "x"` loops is flagged on exactly the first two — the `cat`
sites — and silent on the two `app` sites. Getting that right needed two
things the first version got wrong, both worth knowing:

* block labels in this assembly are **indented**, so a label regex anchored
  at column 0 finds nothing and the audit silently reports "none";
* a leader must also be **the instruction after any jump**. A conditional
  `jge exit` comes *before* the `jmp top` that closes a loop, so a block
  that ends at the first jump loses every back edge — and then reports
  "none" on a program that is known to be quadratic. Conversely, with that
  rule in place, a call that merely shares a block with a loop's back edge
  (it runs once, *after* the loop) is correctly not reported.

**The result for this example** — 75 sites on a cycle, of which 66 are
`y_str_cat`:

| function | kind | what it is |
|---|---|---|
| `args.ar_short`, `args.usage` | cat/app | **vendored, unedited**; the loops are over `argv` and the 9-entry option table |
| `http.request_bytes`, `http.read_head`, `http.cookie_header`, `http.take_cookies` | cat | **std**; the loops are over ≤5 header names |
| `net.resolve`, `net.dns_answers`, `fs.remove_all` | cat | **std** |
| `tls.handshake`, `tls.post_handshake` | cat | **std**; not reached from the default path |
| `rest-client.jstr` | **app** | this example — the correct amortised form |
| `rest-client.check_roundtrip` | **app** | this example — the correct amortised form |
| `rest-client.show_fields` | cat | this example — 15 sites, see below |
| `rest-client.check_full`, `rest-client.tls_selftest` | cat | this example — 19 sites, see below |

The audit found **three real defects**, all fixed:

* `jstr` (the JSON string escaper) used `out = out + "\\"` inside its
  loop — four value-used `y_str_cat` sites on the cycle, i.e. the exact
  shape the campaign measured at 129 MB for a 1600-character string. Now
  `out += "\\"`, which is `y_str_app`.
* `check_roundtrip` accumulated `seen = seen + name + " "`. Now
  `seen += name; seen += " ";`.
* `cmd_shell` built its request bodies with `+` inside the read loop. Those
  were bounded per-command strings that never grew — but a warning a
  reader has to adjudicate is a warning that will eventually be ignored, so
  they moved into `req_body()`, `item_path()` and `unknown_verb()`, and the
  audit now reads clean instead of "five, all fine".

**On the remaining `cat` sites in this example's own code** — `show_fields`,
`check_full`, `tls_selftest` — none of them is an *accumulator*: each builds
a fresh bounded string that goes straight to `puts()` or to `http.get()`,
and nothing grows across iterations. Their trip counts are bounded by
construction (`store.y` has 16 slots; the TLS retry loop is 40 attempts).
That is an argument, so the property check **measures it instead**:
`check_full()` puts all 16 items through `show_fields()` with
`heap_used()` read either side and requires the arena to grow by less than
96 KB. A per-iteration copy that grew would be quadratic and would go
straight through that ceiling. Both the parse and the display measurement
pass with room to spare.

The response body is parsed with **std's `json`** into a `json.Val` and
printed with `puts`, so no string is grown inside a loop anywhere in the
client. The parse itself allocates a tree now, where the old in-place reader
allocated nothing; the property check still measures it, and the ceiling
still holds with room to spare (see the 96 KB measurement above).

## TLS (`--tls-selftest`, optional)

Opt-in, never in the default path, and never in `EXPECTED` or `check=`:

```
(ulimit -S -v 3670016; ./rest-client --tls-selftest </dev/null)
```

It generates a self-signed certificate with `openssl`, starts
`openssl s_server -WWW` on loopback, and fetches over **TLS 1.3** through
`std/http` with `anchors:` set to the certificate's **PEM text** — not a
path, which is the documented form. `-WWW`, not `-HTTP`: `-HTTP` answers
HTTP/0.9 with no status line at all. The ten assertions are:

1. a handshake completes, and answers `200`;
2. the body is **not empty** — checked before anything compares it, so a
   zero-byte read cannot make every later comparison pass;
3. **the bytes over TLS are byte-for-byte the bytes written**;
4. the content type came back over TLS;
5. a missing path really answered, with a non-empty body;
6. …and that body is **not** the payload, so the 200 above proves
   something (`s_server -WWW` answers `200` even for a file it does not
   have — asserting "not 200" there would be asserting something false
   about openssl);
7. **the same request without anchors is refused**, so the chain really is
   verified and `anchors:` really reaches `x509`;
8. …and that refused fetch returned no body at all;
9. the `s_server` child stopped on `SIGTERM` (`wait4` says 143);
10. **and nothing is listening on that port any more.**

Point 10 is not decoration. `exec()` is `/bin/sh -c`, so the child `fork()`
returns is the *shell* and `openssl` is *its* child: `SIGTERM` to the shell
killed the shell, `wait4` reported a tidy 143, **and every
`openssl s_server` survived** — seven of them were still listening when this
was found. The fix is `setsid` (syscall 112) in the child so it leads its
own process group, then `kill(-pgid, SIGTERM)`. Point 10 is the assertion
that would catch it going wrong again: the kill is asynchronous, so it
*probes* — a refused `connect()` is the evidence, not the shell's exit
status.

**If `openssl` is not on `PATH` the stage prints a clear SKIP message and
exits 0.** Verified by pointing the probe at a binary that does not exist.
It never fails the gate over it, because it is not in `check=`.

## `--live`, optional and last

```
$ ./rest-client --live https://api.github.com/zen
-- GET https://api.github.com/zen
   HTTP/1.1 200 OK
   33 bytes of body
Avoid administrative distraction.

$ ./rest-client --live https://httpbingo.org/post POST --body='{"a":1}'
-- POST https://httpbingo.org/post
   HTTP/1.1 200 OK
   726 bytes of body
{ "args": {}, "headers": { "Accept": [ "application/json" ...
```

`--live` is the only path that reaches off this machine. It is never in the
default run, never in `EXPECTED`, never in `check=`. It reports what the
endpoint said and nothing more — no store, no matrix, no assertion about a
body this program does not own — and it carries a 20-second timeout and
`--insecure` for an endpoint with a certificate this machine does not trust.
When the network is not there, or the peer will not complete a TLS 1.3
handshake, it prints the reason to stderr and exits **1**. Never a trap:

```
$ ./rest-client --live http://127.0.0.1:1/x
-- GET http://127.0.0.1:1/x
   HTTP/1.1 0
rest-client: cannot connect to 127.0.0.1:1          # exit 1
```

## Compiler workarounds, and where they are filed

Every one of these is visible in the code at the point it applies.

| what | what this example does | filing |
|---|---|---|
| **`Response.text()` is read-once.** A second read answers `""` silently — no error, no trap — and `fs.write_file` then writes a 0-byte file and returns true. | Exactly **one** `res.text()` call per response, and the answer is kept in `Reply.body`. `--self-test` counts the calls against the responses received, and **reproduces the bug on purpose** to prove it is still there on the pinned compiler. | `examples/BUGS.md` — *A second `Response.text()` is silently empty…* |
| **`str +=` in a value-used position makes its loop O(n²)** in heap. | `+=` everywhere an accumulator grows; the `-S` audit above proves it and `check_full()` measures it. | `examples/BUGS.md` — *A `str +=` in a value-used position makes its whole loop O(n²)…* |
| **`x509` reads only dNSName SANs**, so a certificate that names an IP address cannot verify. | The generated certificate carries **`DNS:127.0.0.1`** alongside the IP SAN. | `examples/SUGGESTIONS.md` §14 |
| **`main()`'s return value is not the exit status**, and `def main() -> long { exit(3) }` does not compile (`exit()` is void, so the block has no value). | The entry point is `}; exit(main())`. | `examples/SUGGESTIONS.md` §15 |
| **A `def` called as a discarded statement whose body is only assignments has void as its block value**, so `def note(status: long) -> long { … }` is `error: 'note' body: expected long, got void`. | `note` is declared `-> void`. It tallies; it returns nothing. | a documented rule, not a bug |
| **`exec()` is `/bin/sh -c` with `envp = NULL`**, so the parent's environment is not inherited and a `kill` to the child leaves the grandchild alive. | `setsid` in the child, `kill(-pgid, …)`, and a port probe as the assertion. See the TLS section. | a documented property of `std/exec.y` |
| **Traps print to stdout**, so one corrupts `EXPECTED` instead of failing. | Every error and argument-validation path prints to stderr and exits non-zero. | known (§2.6 of `ORCHESTRATOR.md`) |
| **No `float` → `long`, no casts, no math functions.** | All arithmetic is integer; nothing in this example needs a float. | `examples/SUGGESTIONS.md` §2 |
| **`[byte; 65536]` does not unify with `[byte]`**, so every buffer-taking helper needs the exact fixed size written out. | `server.y`'s own helpers (`def write(b: [byte; 65536], …)`) take the exact size and every caller says so. This used to be argued from the JSON parser's parameter type; std's `parse_bytes` takes a plain `[byte]`, which a slice of the fixed buffer is, so the exact size is now checked by the slice bounds rather than by a parameter's declared type. | `examples/SUGGESTIONS.md` §12 |

There **is** a `json` module in the std library now, and this folder uses
it. `import json;` resolves to `std/json.y`; the local `json.y` (626 lines,
22 KB) has been deleted. Three things are worth knowing about the swap:

* **`json.as_long` truncates.** It answers 1 for `1.5` and 1 for `1e3`,
  because Y has no float-to-long conversion and `as_long` reaches for
  `tonum`, which reads the leading integer and stops. The old `json.int_at`
  *refused* both, and refusing is the point here: a body that says
  `qty` is `3.5` must not read back as `3`, or the server and its client
  disagree about the data with nothing on the wire to show it. `jint.y` is
  that refusal, re-implemented on the number's literal text (which is what a
  `json.Val` keeps), with the old 13-digit bound so a value that would wrap a
  long is an error rather than a wrapped lie. Both `server.y`'s
  `parse_body()` and the client's `field_int()` go through it.
* **Member order.** The old reader walked members in source order because it
  walked the bytes. std's object is a map, and a Y map's `keys()` come back
  in insertion order — which is the order the parser assigned them in. So a
  document still walks out the way it came in, and `check_roundtrip()`
  asserts it (`and the walk visited them in that order`).
* **`show_body` re-emits instead of slicing bytes.** It prints
  `json.stringify_val` rather than the bytes between two offsets. For a
  server that writes canonical JSON — and this one does, with `jstr`'s
  escapes — the two are the same bytes, which is why `EXPECTED` did not move.

Two behaviours were checked and are *not* the same, both recorded rather
than worked around:

* **A duplicate key resolves to the LAST occurrence, not the first.** The
  old `member()` returned the offset of the first match; a map assignment
  overwrites. Nothing in this example sends a duplicate key, and JSON's own
  guidance is that names SHOULD be unique, so this is a difference rather
  than a regression — but a document with `{"a":1,"a":2}` now reads `a` as
  2 where it read 1 before.
* **The refusal positions differ by a byte or two on two inputs.** `[1,]`
  reported the `]` (byte 4) and now reports byte 3; `{"a":1` reported byte
  0 (`object never closed`, anchored at the `{`) and now reports byte 6,
  where the input actually ran out. The reason text is std's rather than
  this folder's — `unexpected '}'` instead of `expected , or } in an
  object` — and it always names both the reason and the byte, which is what
  `check_parser()`'s malformed set asserts.

## Bugs found *in this example's own code* while finishing it

Recorded because a golden file regenerated after a fix proves nothing about
whether the fix was needed. Each of these produced a wrong answer that a
green gate would have hidden:

* `server.y` computed the request path's length as `stop - sp2 - 1`,
  measured from the CR at the end of the request line — so every path came
  out `len("HTTP/1.1") + 1` bytes long, `"/items"` read as `"/items "`, and
  every collection request took the item branch and answered 404 for a route
  that exists.
* `server.y` started its header scan at `head_end`, which is four bytes
  *past* the last header line and therefore already at (or beyond) the loop
  bound — so `while (h < lines_end)` never ran once and every
  `Content-Length` came out 0, i.e. every request with a body was read as an
  empty one and every `POST` answered 400.
* `server.y` read a header's digits from the colon itself, without skipping
  the optional whitespace after it, so `Content-Length: 24` found no digits
  and returned -1, which the caller's "a negative is really zero" guard
  turned back into an empty body.
* `server.y` called `json.doc(rbuf, body_at + body_len)` — handing the
  *request head* to a JSON parser. `json.doc_at(b, at, end)` existed for
  exactly that; std's `parse` takes a `str`, so `parse_body()` now slices
  the body out of `rbuf` first, which is the same job one step earlier.
* the local `json.y`'s `nmembers` / `nelems` / `elem` / `nth_member` did not
  clear `err` on entry, so a *stale* message from an earlier legitimate
  failure made a later successful parse report `-1`.
* that `json.y`'s `nth_member` never incremented its member counter, so it
  compared the first member against every `want` and returned `-1` for
  anything past member 0.
* that `json.y` matched `done` with `text_is`, which only recognises a
  *quoted* word, so a real JSON boolean was unreadable and a body carrying
  `"done": true` was refused. `json.as_bool` matches the literal.
* The check itself had three wrong expectations: a "consumed all of it"
  comparison that did not allow for trailing whitespace, a store counter
  asserted as an absolute when the store was not fresh, and a "last element"
  assertion that was reading element 0.

The first two are recorded because the code they describe no longer exists —
it was std's `json` that replaced it. `json.as_bool`, `json.parse_err` and
`json.get_arr` are the shapes that answer those three cases.

## Frozen toolkit

Vendored from `examples/_toolkit/`, byte-identical, **not edited**:

```
cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28
cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28
```

Toolkit revision frozen: `examples/_toolkit` at tree commit `a42992c`.
`jint.y`, `server.y` and `store.y` are this example's own.

## The pinned compiler

```
refs/ycc.ref  sha256 6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e
```

This pin moved **once while this example was being finished** — it was
`c53cc415…` at the start. The binary was rebuilt, `EXPECTED` was re-verified
byte-for-byte and the property check was re-run against the new one (310
checks, 0 failures); nothing about the output changed.

The pin moves on every rebless. If `EXPECTED` stops reproducing under a
new pin, rebuild, re-run, and record the new sha — never fake a match.
`gate.py` item 0 re-reads this sha at gate time and fails if the README
disagrees with the binary on disk.

## Hermetic by default

* The server is a `fork` of this process on `127.0.0.1`, bound to port **0**,
  so two copies can share a machine; the port is printed as `<ephemeral>`
  and never as a number.
* It is stopped with `SIGTERM` before the program leaves, and the child's
  `wait4` status (143) is printed and checked.
* The accept loop also leaves if `getppid()` changes, so an orphaned server
  cannot outlive the program that started it on a shared box.
* No clock, no randomness, no network, no terminal size. `EXPECTED` is
  reproducible, twice, byte for byte.
* `--live` is the only path that reaches off the machine, it is opt-in, and
  it is not part of `EXPECTED` or `check=`.
* Every request carries a 5-second timeout, so a wedged server cannot hang
  the gate; a hang would burn its 300-second budget to say nothing.
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
