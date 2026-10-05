# `weather` — a weather client and renderer, hermetic by default

Five locations, a multi-day forecast, and unit conversion done in integers —
fetched over HTTP from a service this program starts itself, parsed by a
hand-rolled JSON reader, and rendered as an aligned report. No API key, no
internet and no clock in the default path.

```
$ ./weather
weather wx.v1 -- local canned forecast over loopback HTTP (forked, ephemeral port)
temperatures are served in whole degrees Celsius and converted to
Fahrenheit in integers (no float->long and no cast syntax exist)

Reykjavik -- Capital Region, Iceland
   64.14660 N    21.94260 W   tz Atlantic/Reykjavik
  now   2026-01-15T12:00  ❄ snow             -3 °C =   27 °F   feels   -7 °C = 19 °F
  wind      24 km/h = 14.9 mph   humidity  81%   pressure  1002 hPa

        date  wmo        condition  min C  max C  min F  max F   precip      wind
  2026-01-15   71  ❄ snow              -8     -1     18     30     2 mm  24 km/h = 14.9 mph
  2026-01-16   73  ❄ snow              -9     -2     16     28     4 mm  28 km/h = 17.4 mph
  2026-01-17    3  ☁ overcast          -6      0     21     32     1 mm  22 km/h = 13.7 mph
  2026-01-18   61  ☂ rain              -4      2     25     36     6 mm  19 km/h = 11.8 mph
… Nairobi, Quito, Ushuaia, Longyearbyen …
```

Look at **Longyearbyen**: its current temperature is exactly **−40 °C and
−40 °F**, the one point where the two scales coincide. It is in the canned
set on purpose, so the conversion a reader checks by eye is also a conversion
the property check asserts.

## Build and run

```
../../refs/ycc.ref weather.y -o weather      # the only build step
./weather                                    # the deterministic run (EXPECTED)
./weather --city nairobi --days 2            # one location, two forecast rows
./weather --list                             # what the service serves
./weather --city nowhere                     # the 404 path: exit 1, no report
./weather --city "reyk javik"                # the 400 path: exit 1, no report
./weather --check                            # the property checks
./weather --tls                              # the same report over real TLS 1.3
./weather --live --city quito                # the real open-meteo.com API
./weather --help                             # usage
```

Everything is inside the campaign's memory cap and is fed `</dev/null`.

**Exit codes.** `0` a report was printed, or `--check` passed. `1` the
service, the parser or a check failed — one line on **stderr**, a clean
stdout, and never a partially-filled report. `2` the command line was wrong.
`3` `--tls` was asked for and `openssl` could not provide it (see below).

**Flags.** `--city/-c` one location slug · `--days/-d` 1–4 forecast rows ·
`--list/-l` the location table · `--check` the property checks ·
`--tls` the TLS leg · `--live` the real API · `--verbose/-v` also report the
local service's exit status on stderr.

## The three legs

| leg | how | needs the internet? | in `EXPECTED`? |
|---|---|---|---|
| plain HTTP (default) | a forked local service on loopback | no | **yes** |
| `--tls` | `openssl s_server` + a certificate this run generated | no | no |
| `--live` | open-meteo.com | **yes** | no |

**Plain HTTP.** The service is a forked child serving five canned
locations on an **ephemeral** port (`bind(0)` then `local_port`), so two
copies of the program never collide and no port number appears in the
output — a printed port would make `EXPECTED` machine-dependent. The
default run issues **six** requests (the chunk-framed location list, then one
per location) and collects them all into one string; **nothing is printed
unless every request succeeded**, which is the strongest form of the "never
partially filled" property.

`net.listen_http` is not used, and the reason is in `wxsrv.y`: it binds the
port itself, so it cannot serve on a port the kernel picked, and calling it
on an inherited socket dies with `cannot serve on port N: errno -98`. The
accept loop here runs over the primitives `net` already exports
(`accept_tcp`, `http_read_head`, `send_str`, `close_fd`) on the socket the
parent inherited. The child is stopped with `syscall(62, pid, 15)` and then
reports **143**.

The service returns a **404** for a well-formed slug that names nothing and a
**400** for a malformed one (empty, upper-case, a space, a `.`, anything
outside `[a-z0-9_-]{1,32}`). Those are different failures and the property
check asserts they stay different. It also serves `/v1/broken` — a **200**
whose body is truncated — and `/v1/wrong-schema` — a **200** whose body
*parses* but carries `wx.v2` — so both halves of "never a partially-filled
report" are reachable over the wire and not only in `--check`.

`/v1/locations` is served **chunk-framed** (`Transfer-Encoding: chunked`, no
`Content-Length`) and everything else length-framed, so both of
`http.Response`'s framing paths are exercised. `Content-Length` is computed
from `len(body)` at the point the response is built, so it cannot drift from
the bytes that follow — and `--check` compares the header against the byte
count the *client* received.

**TLS.** `std/tls` is client-only: it has `client_hello`, `server_hello` and
`cert_list` but no accept, so a TLS server in Y is not possible. The leg
borrows `openssl s_server`, the same precedent `test/sh/test_net.sh` already
uses for `std/tls.y`. A self-signed certificate is generated at run time
into `/tmp/opencode/wx-tls/` and the client verifies it with
`anchors: <PEM text>` — **`anchors` is PEM text, not a file path**; it goes
straight to `x509.anchors_pem()`. Leaving `anchors` unset is what makes
`--live` use the *system* trust store.

The canned response is written to a file and `cat`-ed into `s_server`'s
stdin, which is how `s_server` serves fixed data (`-ign_eof` is required or
stdin EOF closes the listener). The child's pid comes back through a file,
because `exec()` is `/bin/sh -c` and blocks until the command finishes.
Readiness is `kill(pid, 0)` — deliberately **not** a probe connection: a
connect that sends no ClientHello is a broken handshake to `s_server`, and
doing one makes the *client's* real handshake fail.

One more x509 fact, worth its own note: `x509`'s name check reads only the
**dNSName** SANs, so a certificate whose SAN is the correct
`IP:127.0.0.1` is refused with `certificate is not valid for 127.0.0.1`. The
generated certificate therefore carries **both** `DNS:127.0.0.1` and
`IP:127.0.0.1`. Filed in `examples/SUGGESTIONS.md` §14, *"`x509` reads only
dNSName SANs, so a certificate that names an IP address cannot verify"*, with
a minimal reproduction and the verification that `openssl s_client` accepts
the same certificate.

**If `openssl` is missing, `--tls` skips with a clear message and exits 3.**
It never fails the gate: the default leg is plain HTTP and needs nothing.

**Live.** `open-meteo.com` is chosen because it needs **no API key**, and
**no key is bundled here and none will be.** It is a free service and it
**rate-limits**; `--live` may come back `429` and that is the service's
answer, not a defect in this program. `--live` is never in the default path
and never in `EXPECTED`. The response is rebuilt into the same `wx.v1` shape
the local service emits (`wxlive.adapt`), so the renderer and every
conversion are the same code on all three legs.

Captured runs of the two non-default legs are in `golden/tls_leg.txt` and
`golden/live_leg.txt` — for a human to look at, not for the gate, which
diffs only `EXPECTED`.

## What to look at

* **`json.y`** — the hand-rolled JSON reader and writer. One `Json` record
  type rather than a union, because a union member copied out of a union
  shares nothing and there is no cast back. Every accessor is *total*: it
  never traps and never unwraps a `none`, so a truncated document produces a
  message instead of a runtime error.
* **`wxfmt.y`** — `round_div`, `c_to_f`, `kmh_to_mph10`. The whole unit
  conversion, in integers, with the rounding rule written down once.
* **`selftest.y`** — the property checks (`--check`).
* **`wxsrv.y`** — routing, the query grammar, and the response framing.
* **`wxdata.y`** — the canned set, held as typed records: what the service
  *intends* to say, which is what makes round-trip identity checkable.

## Unit conversion, in integers

There is no `float` → `long` conversion and no cast syntax at all, so the
arithmetic is done at a finer scale and rounded **once**, explicitly:

```
round_div(n, d)  =  (2n + d) / (2d)   for n >= 0,  and its negation below 0
F  in tenths     =  C * 18 + 320       (that is exactly 10 * F)
C -> F           =  round_div(C * 18 + 320, 10)
mph in tenths    =  round_div(kmh * 10000000, 1609344)     1 mph = 1.609344 km/h
```

Rounding is **to nearest, ties away from zero**. It is written
`(2n + d) / (2d)` rather than `(n + d/2) / d` so that an *exact* division
does not creep up: `n = k·d` gives `k + ½`, which truncates back to `k`.

There is **no reachable half-way case** from an integer Celsius value, and
that is worth knowing rather than assuming: a tie needs
`C*18 + 320 ≡ 5 (mod 10)`, i.e. `8C ≡ 5 (mod 10)`, and `8C` is even. So the
tie rule is never exercised by real data; what *is* exercised is ordinary
rounding — `37 °C = 98.6 °F` becomes **99**, not the 98 a truncating
converter gives.

Exact values asserted by `--check` (`C` → `F`):

| °C | °F | why |
|---:|---:|---|
| 0 | 32 | the freezing point |
| 100 | 212 | the boiling point |
| **−40** | **−40** | **the boundary: the scales coincide exactly** |
| 37 | 99 | 98.6 °F; truncation would say 98 |
| −37 | −35 | −34.6 °F; truncation toward zero would say −34 |
| 22 | 72 | room temperature |
| −18 | 0 | −0.4 °F rounds to zero, not to −0 |
| −30 | −22 | an exact negative conversion |
| 8 | 46 | 46.4 °F |
| −1 | 30 | 30.2 °F |
| 1 | 34 | 33.8 °F |
| −3 | 27 | Reykjavik's current temperature |

and `round_div`: `(7,2)=4`, `(−7,2)=−4`, `(6,2)=3` (no creep),
`(−6,2)=−3`, `(5,10)=1`, `(−5,10)=−1`. Wind, in tenths of a mph:
`0→0`, `24→149` (14.9 mph), `41→255` (25.5), `100→621` (62.1),
`1609→9998` (999.8). Plus monotonicity over −60…+60 °C, and that the −40 °C
step is exactly −72 °F, the width of the two scales.

## The property check — `./weather --check`

A golden file proves determinism, not rightness: `examples/cube` cleared all
eight gate items while rendering faces as axis-aligned rectangles, because
its `EXPECTED` was generated from the broken output. So every claim here is
asserted against something other than a recorded answer. **421 checks, 0
failed** (7 318 160 B of arena, printed as `heap used:` so the figure is
measured rather than guessed, and it moves when the code does); the
captured output is `golden/property_check.txt`.

* **A — round-trip identity.** For each of the five locations: the bytes the
  service emits parse to **exactly** the values the service intended, field
  by field (every member of `location`, `current` and every row of `daily`),
  re-emitting the parsed tree is byte-identical, and a second parse is
  stable. Then: **every number in every document is an integer literal** —
  because a JSON number with a fraction keeps only its text, so a document
  carrying `-0.22985` as a latitude reads back as `0`. That check exists
  because it caught exactly that bug in the `--live` adapter, and it carries
  its own **negative controls** (a fractional literal, an exponent, a
  fraction nested in an array, and a fraction inside a *string*, which is not
  a number) so it is known to be able to fail.
* **B — the error paths are real.** 404 for an unknown slug; 400 for a slug
  with a space, an upper-case letter, an empty value, or no `city` parameter
  at all; 404 for an unknown resource; and the 400 and the 404 are shown to
  be different statuses. A **200** with an unparseable body must be refused
  with a message and must render **nothing at all** (`report_of` is 0 bytes).
  Then the whole client entry point, as a child process with both streams
  redirected, for its exit code: `0` for a good city and `--list`, `1` for a
  404 and for a malformed slug, `2` for `--days 9`, `--days abc`, an unknown
  flag, `--live` without `--city`, and `--city ''`, `0` for `--help`.
* **C — the integer conversions**, exactly the table above.
* **D — malformed JSON.** 18 broken documents, each rejected **with a
  message and a byte offset**, and each one's tree still safe to read (a
  refused parse returns a null node, so a caller that forgets to look gets
  zeros, never a trap): a truncated object, a trailing comma in an object and
  in an array, an unquoted key, single quotes, an unknown escape, a `\u` with
  too few hex digits, a lone high surrogate, an unbalanced bracket, an empty
  body, whitespace only, a missing colon, trailing bytes, a duplicate key, a
  leading zero, a leading plus, a truncated literal, a fraction with no
  digits, and nesting past the depth limit (with 32 and 33 levels shown to be
  *accepted*, so the limit is not just "reject everything"). The other half
  of the property is 22 documents that **must** be accepted, including `0`,
  `-0`, `0.5`, `3.25e2`, `{}`, `[]`, `null`, and a `\u` surrogate pair — a
  parser that rejected everything would pass every other line.
* **E — framing.** `Content-Length` equals the byte count the client
  received; the location list really is chunk-framed and carries no
  `Content-Length`; and the length the service declares equals the length of
  the body it put beside it.
* **F — the writer allocates linearly.** `heap_used()` is read around
  `json.esc()` for a string of *n* and of *4n* characters, and **4× the input
  must cost at most 5× the heap**. It is a ratio on purpose: linear is ~4×,
  quadratic is ~16×, and an absolute byte count would be a number about this
  machine rather than about the code. `json.emit()` gets the same treatment
  over 400 and 1600 keys, and the emitted document must still parse and
  re-emit byte-identically. This section exists because section F's defect was
  invisible in the output — `EXPECTED` reproduced byte for byte while a single
  1600-character string cost **1 456 032 B** to escape (see *The writer used
  to allocate quadratically* below).

Also asserted, because they are easy to get wrong and invisible in output: the
UTF-8 facts the report depends on (`\xHH` makes one byte; the snowflake is
three bytes and one cell; `rpad` pads by cells; `deg_c(37)` is six bytes).

### These checks were shown to be able to fail

A property that has never failed is a claim, not a check. Three defects were
injected on purpose, one per section, and reverted:

| injected defect | what the gate would have said | what `--check` said |
|---|---|---|
| `c_to_f` off by one (`+ 1`) | **PASS** — `EXPECTED` reproduces byte for byte | 13 FAILs in section C, including `-40 C is -40 F exactly` |
| `min_c` and `max_c` swapped in the emitter | **PASS** — and the report shows `-1` as the minimum and `-8` as the maximum, deterministically, for ever | 40 FAILs in section A, one per day per location |
| the client's `schema` check removed | **PASS** | 3 FAILs in section B: the parsed-but-wrong document is accepted, painted into **293 bytes**, and printed |
| `esc()`'s `;` moved back outside the braces (the quadratic form, restored) | **PASS** — `EXPECTED` is byte-identical, because the *output* never changed | 2 FAILs in section F: `ratio 14.5x` against the 5× bound, and the in-place/value-used comparison collapses to equal |
| `emit()`'s comma `;` moved back outside the braces | **PASS** | 1 FAIL in section F: `ratio 16.0x` over 400 → 1600 keys |

The last two rows are the reason section F is a *ratio* and not a byte count,
and the second one is the reason the same measurement is taken over `emit()` as
well as `esc()`: a separator append that dropped or duplicated a comma would
still parse and still re-emit byte-identically.

That second row is the whole argument for shipping this file. The third one
is why `/v1/wrong-schema` exists — a 200 whose body *parses* and is still not
this service's document, where the parser cannot help and only the client's
own refusal stands between the bytes and the screen.

One injected defect did **not** fail the check, which is worth knowing too:
allowing a trailing comma in an object. The document is still rejected — with
"an object key must be a double-quoted string" instead — so the property
(*malformed input is rejected*) held honestly; only the *reason* changed. The
check asserts rejection, a message and a byte offset, not a specific wording,
and this is the line along which those two differ.

## The writer used to allocate quadratically, and nothing said so

`json.esc()` appended with `+=` as the **last statement of each braced arm**,
which is a *value-used* position, so the compiler emitted `out = out + x` — a
fresh exact-size buffer per character (`examples/BUGS.md`, *"`str +=` in a
value-used position makes its whole loop O(n^2) in heap"*). The output was
byte-identical at every size, so `EXPECTED` reproduced perfectly and the only
symptom was heap. Measured with `heap_used()` around `json.esc()` alone:

| input chars | before | after | growth per doubling (before → after) |
|---|---|---|---|
| 200 | 42 032 B | 17 136 B | |
| 400 | 124 032 B | 34 128 B | 2.95× → 1.99× |
| 800 | 408 032 B | 68 088 B | 3.29× → 1.99× |
| 1600 | **1 456 032 B** | **135 984 B** | 3.57× → 2.00× |

Before: ~4× per doubling, i.e. quadratic. After: 2× per doubling, i.e. linear.
The default run barely noticed, which is the point: emitting all five canned
documents — ~600 bytes each — cost 301 608 B before and 208 120 B after. The
quadratic term only becomes visible when a string grows, and a payload of a few
thousand characters is where it would have met the campaign's 3.5 GiB cap and
reported `runtime error: out of memory` with nothing pointing at the cause.

**The rule, since it is subtler than "add a semicolon".** A `;` *after* a
braced block discards the block's value; it does **not** make the block's own
last statement a discarded position. So

```y
} else { out += chr(c) };      // slow: the arm's last statement is value-used
} else { out += chr(c); }      // fast: the append is emitted in place
```

differ by one character and by 10.7× the heap at 1600 characters. Every arm of
`esc()` now ends with its `;` inside the braces.

**Sites changed** (each one a `+=` in a value-used position, each verified by
the emitted assembly — a discarded append calls `y_str_app`, a value-used one
`y_str_cat` — so "fixed" means measured, not intended). 18 value-used appends
became in-place ones:

| file | function | arms | `y_str_cat` | `y_str_app` |
|---|---|---|---|---|
| `json.y` | `esc` | 9 | 13 → 4 | 0 → 9 |
| `json.y` | `put_cp` | 4 | 4 → 0 | 6 → 10 |
| `json.y` | `emit` | 2 (the separator comma) | 4 → 2 | 4 → 6 |
| `wxdata.y` | `ascii_lower` | 2 | 2 → 0 | 0 → 2 |
| `selftest.y` | `claim_after` | 1 | 1 → 0 | 0 → 1 |

Across those five functions `y_str_cat` goes **24 → 6** and `y_str_app`
**10 → 28**; the six left are ordinary `+` expressions (`"\\u00" + h[1:4]`,
`out + "\""`, `out + "}"`, `out + "]"`). `wxfmt.pct`, `wxfmt.rpad`,
`wxsrv.pct_decode`, `wxsrv.hex2`, `wxsrv.response_text`, `wxrep.table` and
`wxrep.render_locations` were checked and are already in the discarded form;
`json.pstring` is too (its arms end in `pos = pos + 1`).

**The whole audit in one list.** Every `+=` in this folder that has no trailing
`;` — the only candidates for a value-used append — is this, and nothing else:

```
std/args:463          s += " VALUE"                  value-used: left alone, see below
selftest.y:654      if (c == 34) { out += "\\\"" } value-used: the twin, on purpose
wxrep.y:37          out += table(...)              value-used: the return value
wxdata.y:225        items += json.obj_node(...)    an ARRAY append, not a string
wxlive.y:271        rows += json.obj_node(...)     an ARRAY append, not a string
wxrep.y:33/87/124   out += ...                     discarded: the `;` is the last line
```

Three value-used string appendes are left in the folder and each is accounted
for above; everything else already had its `;`.

**Two sites deliberately left alone.**

* `wxrep.render`'s last statement is `out += table(...)` with **no** `;` — it
  is the function's return value. Adding the semicolon does not slow anything
  down silently, it makes the function **void**: `wxrep.y:26:1: error:
  'wxrep.render' body: expected str, got void`. Verified by trying it. So the
  load-bearing case is a compile error, never a silent break, and that is the
  reason the audit could be done by measurement.
* `args.ar_left` has one value-used append (`s += " VALUE"`), and `args` is
  a **vendored, byte-identical copy** of `examples/_toolkit/args, which must
  not be edited. It is left as it is: `--help` builds one ~30-byte column per
  declared option (there are eight), so the quadratic term is a few hundred
  bytes once, at startup, on a path that prints the usage text. Trading
  vendored-copy integrity — the thing that keeps every example's toolkit the
  same revision — for that is not a trade worth making. Recorded here rather
  than left as a silent gap.

## Compiler facts this example had to route around

These are documented behaviours, visible in the code rather than worked
around silently — with one exception, item 1, which is a filed compiler bug and
says so.

1. **`Response.text()` is read-once.** Reading it twice silently yields `""`
   the second time, and `fs.write_file` then writes a 0-byte file and returns
   `true`. Filed in `examples/BUGS.md` as *"A second `Response.text()` is
   silently empty, and `fs.write_file` then writes a 0-byte file and returns
   true"*. So every response goes through one function, `take()`, which makes
   the single `text()` call structural rather than a promise, and every later
   read of the body is a read of that struct's field.
2. **`eputs()` does not append a newline**, although it mirrors `puts()` and
   reads like it. Every diagnostic here ends with an explicit `"\n"`; without
   it, messages run together on stderr and the exit code lands on the same
   line (`weather: ... [not_found]rc=1`).
3. **`ord()` takes a `str`, not a byte.** `ord(s[i])` is a compile error
   (`ord string: expected str, got byte`); it is `ord(s[i:i+1])`. Likewise
   `s[i]` is a `byte` and `str + byte` segfaults.
4. **`\xHH` is the only byte escape.** `"\360"` is a **formfeed** followed by
   the three characters `360`, because the lexer reads `\f` as a formfeed and
   leaves the digits as text. Write `"\xf0\x9f\x98\x80"`, or build bytes with
   `chr()` — which is what `wxfmt.g3()` does for every weather glyph, since
   `chr()` is byte-oriented and cannot make a non-ASCII glyph in one
   expression (`SUGGESTIONS.md` §11).
5. **`net.listen_http` binds the port itself**, so it cannot serve on a port
   the kernel picked; see the leg description above.
6. **`lpad`/`rpad` only ever pad.** A cell wider than its column pushes the
   whole row right, so every column width here is the longest value in that
   column, and widths are in **display cells**, counted by `wxfmt.dwidth`
   (non-continuation bytes), not bytes — otherwise the three-byte snowflake
   would skew every number.
7. **`args` only treats `--help` as help when it is *not* declared** in the
   option table; a declared one is an ordinary option and demands a value
   (`option '--help' needs a value`). The table therefore omits it.
8. **Exit codes from `exec()`** are the child's, and `exec()` is
   `/bin/sh -c`, so it blocks until the command finishes — hence the pid file
   for the backgrounded `s_server`.

## Toolkit

`args` comes from std. It used to be the frozen toolkit module, copied
byte-identical from `examples/_toolkit/` and never edited:

```
sha256  cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28
```

That sha is kept on purpose: it is the revision this example was verified
against, and it is the same bytes std ships today.

The other modules (`fx.y`, `tui`) are **not**
used: this program is a one-shot CLI with no animation and no frame
loop, so integer fixed-point trig, a terminal framebuffer and a pacer would
be dead weight. Everything else in the folder is this example's own code.

## Pinned compiler

Built with `refs/ycc.ref` and nothing else:

```
sha256  c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
```

`refs/` moves on every rebless, so this sha is part of the example's
identity: if it stops matching, rebuild and re-run rather than assuming.

## Notes for the next reader

* The heap is an arena and nothing is freed. The default run allocates a few
  hundred KB and the property check **about 7.3 MB** (it parses the same
  documents hundreds of times on purpose, and prints `heap used:` so the
  number is measured rather than guessed); both are far inside the 3.5 GiB
  cap. Section F spends about 4 MB of that deliberately: it measures the
  **quadratic** escaper as well, so that the linear guard is known to be able
  to fail. String building is `+=` on plain local variables, which is amortised
  O(1), and no loop body holds a literal array or record.
* **Every `+=` that builds a string in a loop must be a discarded statement**,
  which in practice means the `;` goes *inside* the braces — see *The writer
  used to allocate quadratically* above. The exception is a `def ... -> str`
  whose last statement is the append: that one must stay value-used, and the
  checker rejects the alternative outright.
* `openssl s_server` serves the canned response to **one** connection. That
  is why the TLS leg makes exactly one request and `--tls --city X` says so
  on stderr instead of quietly ignoring `--city`.
* `--check` runs the program as a child (`exec("./weather … >/dev/null
  2>&1")`) to assert exit codes. If you `kill` a `--check` run, the forked
  service child is orphaned and keeps the `weather` binary open, so the next
  build fails with `writing 'weather' failed` (ETXTBSY). `pkill -f ./weather`
  clears it.
* The wire format is `wx.v1` and the client **refuses** any other `schema`
  string, so a future service can change the shape without the renderer
  quietly reading zeroes.

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
