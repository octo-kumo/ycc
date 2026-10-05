# crypto-chat — an encrypted chat between two forked processes

Two processes — this one and a `fork(2)` child of it — agree a session key with
**X25519**, split it into a per-direction key schedule with **HKDF-SHA256**, and
then exchange ten chat messages over pipes. Every message is sealed with
**ChaCha20-Poly1305** under its own nonce, with an AAD that binds the
conversation label, the sequence number and the direction. Three of the ten are
deliberate forgeries — a flipped ciphertext byte, a wrong AAD, and the *other*
direction's key — and the receiver refuses all three.

There is no socket anywhere in this program, no terminal, no clock and no
argument in the default run. The only randomness is behind `--seed`, so the
whole transcript is a pure function of it.

The interesting part is not that the crypto works. It is the **property check**
in section 6 of the output: ten assertions about the run itself, with no
reference file behind them, because a golden file proves determinism and not
correctness. Section "Is the property check real?" below shows six mutations of
the crypto that each turn the right property red.

---

## Build

```
cd examples/crypto-chat
../../refs/ycc.ref crypto_chat.y -o crypto_chat
```

Compiles with **zero warnings** from seven modules plus one vendored file.

| | |
|---|---|
| pinned compiler | `../../refs/ycc.ref` |
| compiler sha256 | `c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631` |
| `crypto_chat` sha256 | `b9f5cc748a9a4e8670bea1de42e9f70477b888cd85e534cf4763681088e5d92e` |
| source total | 1999 lines across `crypto_chat.y` `chat.y` `session.y` `wire.y` `props.y` `bench.y` `fmt.y` |

Everything runs inside the campaign's memory cap:

```
(ulimit -S -v 3670016; ./crypto_chat) </dev/null
```

## Vendored toolkit

One module is vendored, copied in rather than imported across folders
(ORCHESTRATOR.md §4) and **unmodified** — byte-identical to the canonical copy:

| file | sha256 | source |
|---|---|---|
| `args.y` | `cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28` | `examples/_toolkit/args.y` |

`fx.y`, `term.y`, `fb.y` and `time.y` are **not** vendored: this example draws
no framebuffer, reads no key and uses no floating point, so a copy of them here
would be dead weight. The frozen `args.y` is the revision the campaign's Wave 0
gate blessed.

The rest are this example's own, listed with their own shas so a drift is
visible:

| file | sha256 | what it is |
|---|---|---|
| `wire.y` | `37e433d365c8170cb9d953cfaebd336e99a1e458c40c158bad91df5fdd95701b` | three `pipe2` pairs, a 5-byte frame header, and a log of every byte that crossed |
| `session.y` | `e11371ac26a9c39f8623784790dd3a1ff04119b49e92b7df4d294cba764eecaf` | X25519 agreement, the HKDF key schedule, counted ChaCha20-Poly1305 |
| `chat.y` | `7b67c1eb62a608a9aff90ce6197ca1be86a37179245af4995d63c366e9dbdacc` | the scripted conversation, both roles, the child's report |
| `props.y` | `0384e3814193e388a89fd37f6c20dceeaae42935bbbe70a337cedd9e9a586052` | the ten properties and the measurements behind them |
| `fmt.y` | `b2144073a3e75d97cfea2f82b70c8b60ca2f68ca3c907af1e6e4aa82096dd76b` | line output, and an accumulator so a property can scan what was printed |
| `crypto_chat.y` | `07742dec3181c4159c6fbdc8ec9ed67631bca25abb849a8dbe77635f353de8bd` | the CLI, the two roles, and the transcript |
| `bench.y` | `2b79926e8f36d96e14b6e271ba7102c8ed84077ff3a457d861222496deae9fe2` | the three-loop allocation measurement |

## Run

```
./crypto_chat                     # the deterministic transcript  == EXPECTED
./crypto_chat --bench 2000        # the allocation measurement
./crypto_chat --seed 4242         # different keys, different transcript
./crypto_chat --label "second"    # a different AAD and key schedule
./crypto_chat --live              # keys from getrandom(2); NOT reproducible
./crypto_chat --show-keys         # print the raw 32-byte shared secret too
./crypto_chat --show-pid          # print both process ids
./crypto_chat --show-report       # print bob's diagnostic report verbatim
./crypto_chat --check             # the default; accepted so a script can say so
./crypto_chat --no-check          # transcript without the property section
./crypto_chat --help
sh mutate_test.sh                 # the property check's own negative tests
```

Exit codes: `0` the exchange completed and every property held · `1` a property
failed or the child reported one · `2` a usage error (message on stderr) ·
`3` the protocol broke (a pipe, a short frame, or the child died).

Flags are parsed by the vendored `args.y`; `--seed abc` and `--seed
99999999999999999999` are both diagnosed rather than silently becoming a number.

## What to LOOK AT

**Section 1, the two independent copies of the shared secret.** Alice and Bob
each run `X25519(own scalar, peer's point)` in their own address space. Bob
sends the 32 bytes he got back to the parent on a third, diagnostic-only pipe,
and the parent compares them byte for byte — `compared 32 of 32 bytes:
IDENTICAL`. The `sha256` fingerprints are equal too, but they are printed as
*evidence*, not as the check; the check is the byte comparison.

**Section 3, one message in full.** The nonce, the AAD, the complete ciphertext
with its 16-byte Poly1305 tag, and the plaintext it hides. That is 162 hex
characters on one line and it is the only line in the transcript that long,
deliberately: it is the thing to look at.

**The `?` in the `pt` column.** A rejected message shows `?`, not a length. That
is not a formatting gap — an AEAD reveals nothing at all about the bytes it
refused, and the `-1` that travels in the child's report says so. Section 4
prints both sides' lists of what they learned, with `?` where a refusal taught
them nothing.

**Section 5, why each forgery was refused.** Each entry separates what the
*sender* did from what the *receiver* can know. The receiver's knowledge is one
bit: the Poly1305 tag did not verify. `chacha_open` returns `none` and does not
say whether the key was wrong, the AAD was wrong or a ciphertext byte was
flipped, and the forgery name in the table is the sender's own account of which
one it committed. The frame even carries that name — in `atk`, deliberately
**outside** the authenticated data, so the receiver's verdict cannot depend on
it.

**Section 6, the property check.** Ten `PASS` lines and what each measured.

## The protocol

```
frame   [kind=2(1) len(4)] [seq(4) dir(4) atk(1)] [sealed(len-9)]
sealed  ChaCha20-Poly1305 ciphertext || 16-byte Poly1305 tag
nonce   prefix[0..8] || le32(seq), 12 bytes
aad     "crypto-chat/v1|<label>|<seq>|<a->b|b->a>"
keys    HKDF-SHA256 over the shared secret, one expand per direction:
          a->b  info "crypto-chat/v1 key a->b"
          b->a  info "crypto-chat/v1 key b->a"
          salt  sha256("crypto-chat/v1 salt|<label>")
        plus one more expand, info "crypto-chat/v1 nonce", whose first 8 bytes
        are the nonce prefix
```

Three decisions are worth calling out, because each one is a property the check
asserts:

- **The key schedule is directional, and the send direction is a parameter.**
  `session.agree(sk, peer, label, dir)` derives `tx` from `dir` and `rx` from
  `1 - dir`. Both sides derive *both* keys — that is unavoidable once you hold
  the shared secret — so what stops a frame being read the wrong way round is
  that the two keys are not equal. Property **P10** asserts that; property
  **P4** is the live forgery.
- **The AAD is never transmitted.** Each side rebuilds it from the frame's own
  header and the session label. That is what makes a replay at another sequence
  number impossible without sending anything extra, and it is what property
  **P3** forges.
- **A counter is a safe nonce source only because the keys are directional.**
  That is stated in the transcript and repeated under limits below.

The conversation runs strictly alternately — alice sends, bob reads, bob sends,
alice reads — over five beats, which is what makes the sequence numbers 1..10
predictable on both sides without exchanging them and what keeps either side
from waiting on a pipe nobody is writing to. (An earlier version had both sides
read first, and deadlocked with no diagnostic: neither ever wrote.)

## Is the property check real?

A golden file cannot check itself. `examples/cube` passed all eight gate items
with a rendering defect baked into its `EXPECTED`. So this example ships
`mutate_test.sh`, which breaks one thing at a time in a scratch copy and checks
that the right property goes red, the exit status becomes 1, and nothing traps:

```
=== notamper     exit=1 traps=0 failed=[P2,P9] expected=P2,P9  ok
=== aadseq       exit=1 traps=0 failed=[P3,P9] expected=P3,P9  ok
=== onkey        exit=1 traps=0 failed=[P4,P9,P10] expected=P4,P9,P10  ok
=== leak         exit=1 traps=0 failed=[P6,P9] expected=P6,P9  ok
=== wrongsecret  exit=1 traps=0 failed=[P1,P9] expected=P1,P9  ok
=== badnonce     exit=1 traps=0 failed=[P9] expected=P9  ok
=== wrongpub     exit=1 traps=0 failed=[P7] expected=P7  ok
=== control      exit=0 traps=0 all ten PASS  ok

8 mutation cases, 0 not caught
```

What each one breaks, and what the properties are:

| id | property | what it asserts |
|---|---|---|
| P1 | both sides derive the same shared secret | the two 32-byte secrets are equal byte for byte, first difference reported; both `sha256` fingerprints agree |
| P2 | a tampered ciphertext is rejected | message #5, one ciphertext bit flipped after sealing, `chacha_open` → `none` |
| P3 | a wrong AAD is rejected | message #7, the AAD claims sequence 92 while the frame says 7, `chacha_open` → `none` |
| P4 | the other direction's key does not open it | message #6, sealed under a→b and sent as b→a, `chacha_open` → `none` |
| P5 | no rejected plaintext reaches the transcript | none of the three forged plaintexts is in the bytes this run printed — checked against `fmt`'s own accumulator, not against this README |
| P6 | no plaintext anywhere on either wire | 0 of 10 plaintexts in the b→a log **and** in the a→b log |
| P7 | both sides name the same public points | the peer's point is in each wire log (P6's control), **and** each side's report names the other's point as the one that was sent |
| P8 | the sealed bytes are never the plaintext | all 10 sealed blobs differ from their plaintext, and each is exactly plaintext + 16 |
| P9 | every accepted message round-trips exactly | **7 of 7** genuine messages opened across both sides, **3 of 3** forgeries refused, all 7 opened byte-identical to the sender's |
| P10 | the two directions use different keys | `a->b != b->a` |

P9 is the load-bearing one and it was **wrong the first time**. It originally
read "every message that opened, matched" — which passed *vacuously* when
nothing at all opened, and the `badnonce` mutation found exactly that: 10/10
properties passed with every genuine message rejected. It now takes the expected
counts from the conversation script itself (7 genuine, 3 forgeries) and requires
both sides' verdicts to add up to them, so "nothing opened" is a failure rather
than a pass. That is the whole reason the mutation script ships.

P7 exists for two reasons. P6 could otherwise pass by scanning an empty buffer,
and the `shared` bytes in bob's report are only *this process's* shared secret if
that report came from the child it exchanged keys with — so P7 checks that each
side names the other's public point correctly, and the `wrongpub` mutation is
the one that catches it.

`golden/transcript-show-report.txt` is what `--show-report` prints: bob's report
exactly as the parent received it, before any parsing. It is a line-oriented
text block because there is no JSON in Y (ORCHESTRATOR.md §2.4c); `lines()` and
a `split(" ")` field accessor is the whole of the parser.

`golden/property-check.txt` is section 6 on its own; `golden/EXPECTED`-equivalent
runs for the other modes are in `golden/`.

`EXPECTED` is 10 295 bytes, sha256
`e3aebd217374c89cb8abfd592e4aa22d6fdd65de675dd58f47b9eeb70a8748c0`, which is
also the sha256 of the program's stdout under **every** invocation tried:
`./crypto_chat`, `$(pwd)/crypto_chat`, `crypto-chat/crypto_chat` from the parent
directory, an absolute path with a different working directory, the same binary
copied to a 20-character filename in `/tmp`, and `./crypto_chat --seed 1`. That
last one matters: `argv[1]` adds bytes to the vector too, so the figure is
independent of the *whole* command line, not just of the program name.
`golden/transcript-live.txt` is a snapshot, not a golden — `--live` draws from
`getrandom(2)` — and is kept only so the mode's shape is on record.

## Allocation

`./crypto_chat --bench 2000`, the three controlled loops, `heap_used()` either
side of N calls. `golden/bench-2000.txt`:

| loop | delta | per message |
|---|---|---|
| full: aad, nonce, seal, frame, open | 10 616 008 | **5 308** |
| crypto only: `chacha_seal` + `chacha_open` | 9 280 000 | **4 640** |
| frame only: layout + payload slice | 240 000 | **120** |

- **This example's own per-message work is the "frame only" row: 120 bytes** —
  the frame layout writes into a module-level `[byte; 1024]` and is free, and
  the 120 B is the one unavoidable `buf[off:off+n]` slice needed to hand
  `[byte; 1024]` to `chacha_open` as a `[byte]`.
- **The other 5 188 B a message is `std/crypto.y`'s.** Each `chacha_seal` and
  each `chacha_open` builds its own temporaries — field elements, ChaCha
  keystream blocks, Poly1305 limbs — and the heap is an arena, so none of it
  comes back (ORCHESTRATOR.md §2.7). This is measured separately in the "crypto
  only" row rather than asserted.
- **It is a fixed stride, not compounding:** `full` at 2 000 and at 4 000 gives
  a ratio of exactly 2.00. At 5 308 B a message the 3.5 GiB cap arrives after
  about 707 872 messages, which the transcript states rather than leaves
  implicit.
- The chat itself is ten messages, so one run's exchange costs
  **2 756 736 B** of arena — the figure section 4 prints, and a delta (see
  below).

## The arena figure is a DELTA, and it has to be

Section 4 of the transcript prints

```
  arena this exchange cost: 2 756 736 B  (heap_used() either side of the work, not a process total)
```

`2 756 736` is `heap_used()` sampled at the top of `run_chat` and again just
before `report()` prints anything, and the difference printed. It used to be
`heap_used()` on its own — an absolute.

**An absolute is wrong here, because `heap_used()` counts the argument vector.**
The runtime has already copied the whole of `argv` onto the Y heap before the
first line of `main` runs: the `_start` prologue calls `y_argv_init`
(`src/y/arch/prelude.s:1499`), which `y_alloc`s the `[str]` array and then calls
`y_cstr_to_str` on **every** entry, `argv[0]` included. So the arena total
already contains a heap copy of however you spelled the path:

| how it was invoked | `argv[0]` | absolute `heap_used()` at the end |
|---|---|---|
| `./crypto_chat` | 13 B | **2 828 424 B** |
| `$(pwd)/crypto_chat` | 59 B | **2 828 472 B** |

46 more characters of `argv[0]`, 48 more bytes of arena (the allocator's block
rounding). Measured on a throwaway program that does nothing but print
`heap_used()` on its first line: 80 B at main entry for a 3-character `argv[0]`,
88 for 11, 96 for 15, 168 for 94 — about one byte per argument byte.

A delta cannot see any of it, because the vector predates both samples. It is
also the better number: it is the cost of the computation rather than the cost of
the process. `SUGGESTIONS.md` entry **#7** is the same pattern for the
per-iteration case (`h0 = heap_used()`, work, `h1 = heap_used()`, print
`h1 - h0`), and `bench.y` above already used it. The trap itself is filed as
**#24** (`heap_used()` counts the argument vector), with the toolchain-side
remedy — an accessor that excludes the pre-`main` arena, or at least a doc line
saying so.

**This was found by the orchestrator, not by this example's own check, and the
example's own check could not have found it.** Every invocation the check ever
performed started with `./`, so `argv[0]` was the same 13 bytes on every run and
for ever; the golden reproduced byte for byte and the ten properties all passed
while the transcript carried a number that moved with the invocation. Nothing in
a single-process property check can see this: it is a property of *how the
program is launched*, not of the program. It took the gate running the program
a third time by absolute path and requiring identical bytes.

Two things follow for a reader deciding how much to trust the battery:

- The figure is now checked for what it can be checked for — **determinism** —
  and the gate's second item is what tests it, twice plus by absolute path.
  There is deliberately **no** property asserting its value: an arena total is a
  measurement of the compiler's allocator, not a property of the crypto, and an
  assertion on it would be a ratchet on the compiler's internals. What a delta
  does buy is stated above.
- The delta covers the handshake, the exchange and the property measurements,
  and stops before the transcript is formatted, so the number is not "how much
  text was printed". It does **not** cover bob: he is a `fork(2)` child, and a
  child never gives arena bytes back to its parent.

## WhatThisDoesNotDo

Honest limits, so nobody reads more into this than is there:

- **No transcript binding on the handshake.** Alice sends her X25519 public
  point in the clear and Bob sends his, with nothing authenticating either. A
  real handshake hashes both points, both public keys and the negotiated
  parameters into the HKDF salt, which is what stops a man in the middle
  substituting its own point. Here the label in the salt is a stand-in.
- **No key confirmation and no forward secrecy.** One long-term key agreement,
  one session, and the derived keys live as long as the process. A real chat
  would do ephemeral X25519 per session (which this is) *and* ratchet, and
  would zero the secrets afterwards — which Y has no way to express.
- **The nonce prefix comes out of the key schedule**, so both sides rebuild it
  without exchanging anything. That is correct here, but a real deployment
  prepends 4 random bytes carried in the handshake, so that a state compromise
  after the handshake cannot predict earlier nonces. (An earlier version of this
  example gave each process its *own* prefix; every message then failed to open,
  because the receiver could not rebuild the nonce. The transcript and
  `session.nonce_base`'s comment both say why it has to be shared.)
- **`chacha_open` returns `none` and nothing else.** No error code, no
  "wrong key" versus "wrong AAD". The transcript's forgery labels are the
  sender's account, as section 5 says.
- **A counter, not a random nonce.** Safe only because the two directions hold
  different keys — which property P10 checks, and which is why P4 exists.
- **Ten messages, scripted, strictly alternating.** There is no read loop, no
  interactive input, no resynchronisation, and no framing recovery: a truncated
  frame is a protocol error and exit 3.
- **Nothing constant-time.** `std/crypto.y` says so about itself; this example
  adds no timing claims and makes none.
- **The child's diagnostic channel is not authenticated** and would not be safe
  to use for anything real. It exists so P1 can be a byte-for-byte comparison
  rather than a shared assertion.

## Compiler workarounds

Everything below is routed around in code, and every one is either correct
language behaviour or already filed. **No compiler bug was found while building
this example, and nothing is filed in `examples/BUGS.md` from it** — see the
report for the two false alarms that were investigated and dropped.

1. **A `[byte; N]` does not unify with `[byte]`, and there is no pointer
   arithmetic.** `def rd_all(fd, buf: [byte], …)` rejects a `[byte; 1024]` with
   `error: 'rd_all' arg 1: expected [byte], got [byte; 16]`, and `p + n` on a
   `*byte` is `error: '+' left operand: expected long, got *byte`. A read or
   write helper therefore cannot take a pointer and walk it; `wire.y` takes the
   fixed-size array *by name* and addresses bytes as `&buf[i]` with an index it
   owns. That is why there is exactly one pair of helpers rather than one per
   buffer size, and why `FRAME` is a single global constant every buffer obeys.
   Filed as a suggestion, not a bug — see `examples/SUGGESTIONS.md`.
2. **`pipe2(2)` writes two C `int`s.** Read back from a `[long; 2]`, element 0
   comes back holding *both* descriptors (`0x400000003`) and element 1 comes
   back 0 — which is stdin, so the "peer" is stdin and the program hangs with no
   error anywhere. `wire.mkpipe` assembles them from a `[byte; 8]` four bytes at
   a time. Documented in ORCHESTRATOR.md §2.13; not a bug.
3. **No `break` and no `continue`** (TODO.md §5, a known gap). Every early exit
   here is a guard flag with an explicit terminal assignment, and every
   "continue" is a positive condition wrapping the body. Visible in
   `chat.exchange`, `wire.log_find`, `props.measure`.
4. **A record or array literal inside a loop body allocates every iteration**
   (SUGGESTIONS.md §7 — 64 B per record, 72 B per array). The ten-message
   bookkeeping is therefore parallel arrays written in place, not ten record
   literals: `chat.SEQ`, `chat.PTB`, `chat.SLB`, … are fixed `[long; 16]` cells,
   and the string columns are appended once per message. The one record per
   iteration anywhere in the program is `props.Prop`, built by `props.add` —
   which runs ten times for the whole run, not once per message, and `props.y`'s
   own `LIST += p` is an array append (amortised), not a per-message cost.
5. **`print` puts a newline after every value**, so `print("a", n)` is two
   lines and a table column cannot be built by printing its cells. Every line in
   this program is assembled as one `str` first (`fmt.row`, `fmt.line`).
6. **A block's value is its last statement without a trailing `;`.** `def
   count(i: long) -> long { C[i]; }` is `error: 'session.count' body: expected
   long, got void`. Worth knowing because it is silent in the other direction:
   a stray `;` makes a function return void and the error surfaces at the call.
7. **`[bool; N]` cannot be built with `[0; N]`** — that is a `[long; N]`, and the
   error says so (`expected [bool; 16], got [long; 16]`). It wants
   `[false; N]`. Accurate diagnostic, not a bug.
8. **`str + byte` segfaults** (BUGS.md, filed from another example). This
   program never adds a byte to a string: string bytes go into buffers with
   `wire.put_str`, which copies `s[i]` directly, so the `bytes()` copy that
   would sit on a per-message path never happens either.
9. **A `def` is a first-class value** and this was worth knowing: its type is
   `(parameter type) -> return type`, and **the parentheses are the parameter
   list**, so `(long) -> long` is a function taking one `long` and
   `([long]) -> long` is a function taking an *array* of longs. `bench.measure`
   takes any of its three loops as an argument because of it. (I first read
   `([long]) -> long` as "a long in brackets" and filed a phantom misparse
   before checking; the brackets were the array type all along.)

## Reproducing the gate

```
cd examples/crypto-chat && python3 ../gate.py crypto-chat
```

`gate.conf` names the build and the deterministic run, so the gate needs no
arguments.
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
