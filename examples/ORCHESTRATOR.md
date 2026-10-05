# `examples/` — agent orchestrator plan

A plan for building a large corpus of Y example programs under
`examples/`, one folder per example, mostly terminal programs,
produced by parallel subagents that never touch the compiler.

This file is the contract between the orchestrator and every
subagent it spawns. Section 5 is the briefing template: the
orchestrator fills it in and hands the result to a subagent.
Sections 1–4 are what the orchestrator enforces.

**Nothing in this plan authorises editing the compiler.** See
[§1](#1-hard-boundaries).

---

## Contents

1. [Hard boundaries](#1-hard-boundaries)
2. [Verified environment facts](#2-verified-environment-facts)
3. [Invoking the compiler](#3-invoking-the-compiler)
4. [The folder contract](#4-the-folder-contract)
5. [The briefing template](#5-the-briefing-template)
6. [The wave plan](#6-the-wave-plan)
7. [The acceptance gate](#7-the-acceptance-gate)
8. [Issue protocol: BUGS.md and SUGGESTIONS.md](#8-issue-protocol)
9. [Review rubric](#9-review-rubric)
10. [The idea backlog](#10-the-idea-backlog)

---

## 1. Hard boundaries

These apply to the orchestrator and to every subagent it spawns,
without exception.

**B1 — The compiler is read-only.** Never modify, create, delete or
regenerate anything under `src/`, `src/y/`, `src/c/`, `refs/`, or
`Makefile`. Never edit `ycc`, `cycc`, `ynew`, or any file in
`refs/`. Never run `make`, `make ycc`, `make rebless`, or anything
else that rewrites them. The examples are a *consumer* of the
compiler, never a contributor to it.

**B2 — Two files outside your folder are writable.** `BUGS.md` and
`SUGGESTIONS.md` at the root of `examples/`. Append only, per
[§8](#8-issue-protocol). Nothing else outside your own folder is
writable.

**B3 — The root `BUGS.md` and `TODO.md` are off limits.** Those are
the compiler's own ledgers. Compiler findings go in
`examples/BUGS.md` and `examples/SUGGESTIONS.md` only.

**B4 — One folder per example.** No folder may contain two
unrelated examples. Shared code is *vendored* (§4), never reached
across folders at run time.

**B5 — Every process runs under the memory cap.** This machine goes
down past 4 GB. Anything you run — compiler, program, verifier —
goes inside `(ulimit -S -v 3670016; ...)`. A run that hits the cap
is a bug in your code, never a reason to raise the cap.

**B6 — Feed `</dev/null`.** Any program you run that could read
stdin must be run with `</dev/null` unless you are deliberately
testing stdin. See [§2.6](#26-traps-print-to-stdout).

**B7 — Deterministic by default.** Every example must be
reproducible from its folder with no network and no arguments.
Anything time-, randomness- or network-dependent goes behind an
explicit flag (`--seed`, `--live`, `--bench`), and the default path
must be deterministic.

---

## 2. Verified environment facts

Everything in this section was checked against this tree, not
inferred. **Subagents get this section verbatim** — it is the part
they would otherwise rediscover the hard way.

### 2.1 `syscall` takes arguments in kernel register order

`syscall(n, a1, a2, a3, a4, a5, a6)` binds:

| source arg | register |
|---|---|
| `n` | `%rax` |
| `a1` | `%rdi` |
| `a2` | `%rsi` |
| `a3` | `%rdx` |
| `a4` | `%r10` |
| `a5` | `%r8` |
| `a6` | `%r9` |

This is the *kernel's* order, **not** the order of the C function's
source signature. `src/y/native.y:5078-5095`.

The trap this sets: C's `ioctl(fd, request, arg)` therefore becomes
`syscall(16, fd, request, arg)` — the request is `a2`, the pointer
is `a3`. Written the other way round it returns `-25` (`ENOTTY`)
and looks exactly like a compiler bug. It is not. Do not file it.

A `str` argument is passed as a pointer to its bytes, header skipped
(`native.y:5086-5091`), so `syscall(1, 1, "hi\n", 3)` is
`write(1, "hi\n", 3)`.

Known numbers (x86-64): `read`=0, `write`=1, `close`=3, `lseek`=8,
`nanosleep`=35, `getpid`=39, `socket`=41, `connect`=42, `accept`=43,
`bind`=49, `listen`=50, `setsockopt`=54, `fork`=57, `wait4`=61,
`clock_gettime`=228, `exit_group`=231, `openat`=257, `getrandom`=318.

### 2.2 There is no terminal module at all

No termios helper, no raw mode, no `getch`, no window-size query, no
`isatty`, no key decoder. **Every interactive example writes its
own.** `examples/_toolkit/term.y` is the shared, tested version.

### 2.3 Raw mode, verified end to end

Verified under a real pty. This is the whole recipe:

```
TCGETS = 0x5401      TCSETS = 0x5402
TIOCGWINSZ = 0x5413  TIOCSWINSZ = 0x5414

// get, patch, set — all ioctl, all in kernel order
syscall(16, 0, 0x5401, &t[0])            // read termios into a [byte; 64]
let lf = t[12] + t[13]*256 + t[14]*65536 + t[15]*16777216;
let nf = lf & ~32859;                    // clear ISIG|ICANON|ECHO|ECHOE|ECHONL|IEXTEN
t[12] = nf % 256; t[13] = (nf/256)%256; t[14] = (nf/65536)%256; t[15] = (nf/16777216)%256;
let ifg = t[0] + t[1]*256 + t[2]*65536 + t[3]*16777216;
let nif = ifg & ~1364;                   // clear ISTRIP(0x20)|ICRNL(0x100)|IXON(0x400)
t[0] = nif % 256; t[1] = (nif/256)%256; t[2] = (nif/65536)%256; t[3] = (nif/16777216)%256;
t[22] = 0; t[23] = 1;                    // VTIME=0, VMIN=1 -> blocking one byte
syscall(16, 0, 0x5402, &t[0])            // install
```

`struct termios` offsets: `c_iflag` 0–3, `c_oflag` 4–7, `c_cflag`
8–11, `c_lflag` 12–15, `c_line` 16, `c_cc[32]` **17–48**. Inside
`c_cc`, **`VTIME` is 22 and `VMIN` is 23** — not the other way round.
A swap gives you a 100 ms timeout instead of a blocking read, which
reads as "the keyboard does not work".

**A timed read cannot be finer than 100 ms, so a frame loop must
never use one.** `VTIME` counts *deciseconds*, so any non-zero
timeout is rounded up to the next 100 ms. Measured on the pinned
compiler: **five `term.read_key_timeout(1)` calls took 518 ms**, not
5 ms — about 104 ms each. `term.y` rounds deliberately
(`let ds = (ms + 99) / 100;`), because the kernel gives it no
choice. The consequence is a trap that never announces itself: a
renderer with a 33 ms frame period that polls for a key with
`read_key_timeout(1)` spends 100 ms per frame, so **every frame is a
whole period late, the pacer drops every frame, and the program
reports ~0.6 fps with its frame counter stuck**. It reads as "the
animation is slow", not as a timing bug. The fix is to poll with
**`read_key_timeout(0)`** (non-blocking, returns `KEY_NONE` at once)
and let `time.y`'s pacer own the frame deadline. Do this in any
example with a live view.

The `32859` mask is six bits, not the four the flags suggest:
`ISIG` 0x1, `ICANON` 0x2, `ECHO` 0x8, `ECHOE` 0x10, `ECHONL` 0x40,
`IEXTEN` 0x8000 — and `IEXTEN` is **32768, not 16** (16 is `ECHOE`).
Clearing the `c_iflag` bits matters as much: without it Enter arrives
as CR (10) instead of LF, and **Ctrl-S freezes the terminal** because
`IXON` is still doing software flow control.

Window size: `syscall(16, 1, 0x5413, &ws[0])` fills a `[byte; 64]`
with `{ws_row, ws_col, ws_xpixel, ws_ypixel}` as four 16-bit
little-endian values — **row first**, at bytes 0–1.

One keypress: `syscall(0, 0, &b[0], 1)`. `readline()` does not work
in raw mode (its buffer assumes canonical mode).

`examples/_toolkit/term.y` handles the whole sequence **including
restoring the terminal on every exit path** — that is the hard part,
and the reason it is shared rather than rewritten 15 times. It is
verified: 111 checks, including SIGKILL of the program with the
terminal restored correctly afterwards.

**A forked restore-watchdog must call `setsid(2)` (syscall 112).**
Otherwise it is in the terminal's foreground process group, the
parent's death sends it `SIGHUP`, and it dies *before* restoring —
the symptom is a watchdog that appears not to exist at all. This and
two related traps cost the most time in Wave 0b and are worth not
relearning:

- **`wait4` on your own parent returns `-ECHILD`.** Correct —
  `wait4` waits for *children*. Do not poll your parent that way.
- **`pipe()` writes two 32-bit ints** (see §2.13); read as `long` you
  get `0x400000003` and a `close()` that fails `EBADF`, so anything
  watching the pipe silently never fires. No error anywhere.

**Not guaranteed**, and callers must know it: signals while the
watchdog is disarmed, `kill -9` on the watchdog too, a machine crash,
and the alt-screen/cursor themselves — that is emulator state, and
only writes to fd 1 can restore it.

### 2.4 Three gaps that shape every example

**(a) No `float` → `long`.** There is no cast syntax at all
(`types.y:1490-1505`). `let n: long = 3.7;` is a hard compile error:
`error: let 'n': expected long, got float`. The complete conversion
list is `long→float`, `long→byte` (annotated sites only),
`byte→long`, `byte→float`, `str→*T`, `none` unification.

Consequence: **do your arithmetic in integers.** The shipped
`examples/badapple` players do all their colour fitting in `long`
fixed point for exactly this reason. `examples/_toolkit/fx.y` is
the shared integer-math module.

Escape hatch when a float genuinely arises:
`tonum(tostring(f))` truncates toward zero (`3.7`→`3`, `-3.7`→`-3`),
but carries only 6 decimals of precision.

**(b) No math functions.** No `sin cos tan asin acos atan atan2
sqrt exp log log2 log10 pow abs floor ceil round trunc fmod hypot`,
and no `PI`. They do not exist anywhere in the tree — the only
float examples (`test/y/examples/math.y`, `pi.y`) use only
`+ - * / %`. **Write them yourself**, in integer fixed point, via
`examples/_toolkit/fx.y`. Do not file this as a bug; it is a known,
deliberate gap and belongs in a *todo*, not a bug report.

**(c) No JSON.** There is no `src/y/std/json.y`, and no JSON
anywhere in the tests. A web example that wants JSON must hand-roll
a parser over `split` / `index_of` / `ord`. Budget for it.

This one is on the roadmap already — `TODO.md` §3 asks for JSON
literal syntax. Check `TODO.md` before filing it as a suggestion;
if it is merely restating a known roadmap item, do not file it.

### 2.5 `float` facts worth knowing

`float` is IEEE-754 binary64. Operators: `+ - * / %`, unary `-`, and
the comparisons. That is all — bitwise ops reject floats. `%` is
C's `fmod` (truncated toward zero). Comparisons are IEEE-ordered, so
NaN compares false to everything and `x != x` is the NaN test.

`tostring` of a float is fixed 6-decimal. Use an f-string spec to
change it: `f"{x:.2f}"`, `f"{x:>10.4f}"`, `f"{x:.3%}"`. A magnitude
above 2^63 prints as `<float magnitude >2^63>`.

### 2.6 Traps print to **stdout**

Runtime traps exit 1 with the message on **stdout**, not stderr:

```
runtime error: index out of bounds
runtime error: division by zero
runtime error: negative shift count
runtime error: unwrap of none
runtime error: slice assignment out of bounds
runtime error: slice assignment length mismatch
runtime error: no match arm matched
runtime error: a union value cast to a member it does not hold
runtime error: out of memory
```

An example whose expected output is diffed must therefore **never
trap** — a trap corrupts its own diff. `test/sh/lib.sh` merges stdout
and stderr when comparing fixtures, but a *user* watching the program
will see the trap spliced into the middle of a frame.

Other traps to design around: indexing is bounds-checked (use
slices, which clamp); `div`/`mod` by zero traps; a **negative shift
count** traps; `unwrap`/`!` of `none` traps.

### 2.7 Nothing is ever freed

The heap is an arena. Long-running loops that allocate per frame
will exhaust the 3.5 GiB cap. Render and simulation loops must
**reuse fixed buffers** — `let buf: [byte; 8192] = [0; 8192];` and
overwrite in place. `examples/_toolkit/fb.y` is written this way;
copy that discipline.

`s += t` on a `str` *variable* that owns its buffer is amortised
O(1), so string building in a loop is fine (`t139_string_append.y`:
10,000 one-byte appends, 50 MB → 23 KB). But the fast path is
conditional: the string must be a plain variable, never
address-taken, never captured by a closure, and must still hold the
buffer its own last `+=` built.

### 2.8 There is no `sort`

No `sort` builtin and no `push` / `prepend` / `map_get` / `map_set`.
`+=` and `*=` *are* the array interface. Sorting is insertion sort
by hand (`bench/y/arrays.y:12-37`) or merge sort by hand
(`src/y/std/fs.y:265-280`). Maps are a **linear scan** — O(n) per
lookup — so a hot loop over a big map will show it.

### 2.9 Loops: four forms, and no `break`

All four forms work:

```
while (cond) { }                      // cond first
for (let i = 0; i < n; i++) { }       // C-style head; i survives the loop
for i in lo..hi { }                   // lo inclusive, hi EXCLUSIVE
foreach (x in arr) { }
```

**There is no `break` and no `continue`.** Both are undefined names
today:

```
error: undefined variable 'break'
error: undefined variable 'continue'
```

This is on the roadmap (`TODO.md` §5), so it is a known gap, not a
bug — and it means **every early exit in an example has to be
written out.** Two idioms, both verified:

*Early exit* — a guard flag plus an explicit terminal assignment:

```
def find(hay: [long], needle: long) -> long {
    let i = 0;
    let go = true;
    let at = -1;
    while (i < len(hay) && go) {
        if (hay[i] == needle) { at = i; go = false; } else { i = i + 1; };
    };
    at
};
```

*Continue* — wrap the body in a positive condition instead of
skipping it:

```
for i in 0..6 { if (i % 2 == 0) { out += i }; };   // no `continue` needed
```

Budget for this when planning an algorithm: it makes every
search loop more verbose than the C you would write, so leave room
in the brief.

### 2.10 Language rules that bite

Each of these is a compile error except where marked, and
subagents hit them all:

- **No unknown types.** Every `def` parameter must be annotated or
  have a *literal* default. `[]` and `{}` must be annotated at the
  binding: `let xs: [str] = [];`, `let m: {long => long} = {};`.
  A `def` called before its body needs a written return type.
- **Records are exact.** `{a: long, b: str}` is not `{a: long}`.
  There is no prefix view of a bigger record and no runtime field
  growth.
- **Arrays are homogeneous.** `[1, "two"]` is rejected. So is
  `[[1], 2]`.
- **A map literal only ever makes a map with `str` keys.** `{1: 5}`
  does *not* make a `{long => long}` — it parses as a **record**
  literal with integer field names, and then indexing it fails:
  `error: cannot index { 1: long } (only arrays and maps)`, and
  `keys` on it fails too. For non-`str` keys annotate the binding:
  `let m: {long => long} = {};`
- **Disagreeing `if` arms make the `if` void**, and `void` cannot be
  bound, printed or returned.
- **`if` takes a `bool`.** `if (flags & 4 != 0)`, never `if (flags & 4)`
  (`error: 'if' condition: expected bool, got long`). `&&` and `||`
  take any non-zero value.
- **`s += n` with a number is a type error** (`'+=' string: expected
  str, got long`). Write `s += tostring(n)`.
- **Fixed `[T; N]` cannot grow** — `+=` on it is a type error.
- **Nesting limit is 1000**, and a long `1+1+1+…` chain counts.
- **Bitwise binds tighter than comparison**: `x & 1 == 0` is
  `(x & 1) == 0` (verified: `print(3 & 1 == 0)` prints `false`; C
  would read it the same way here, but `1 | 2 :: xs` is `[3, 9]`
  because `::` binds looser). Bitwise rejects floats:
  `'&' left operand: expected long, got float`. A shift of 64+ is
  zero; a **negative** count is a *runtime* trap, not a diagnostic.
- **`?.` is one token** and propagates. `x ? a : b` is the ternary
  and needs the spaces — written bare, `1 ? "a" : "b"` parses the
  `?` as option-type syntax and fails on the condition.
- A record literal built where no type is declared gets *its own*
  type, so a later `match` on a union holding it finds no member.
  Write the literal where the type is declared, or annotate.
- A `match` arm binding (`T x =>`) **copies**; a destructuring
  pattern (`T { f } =>`) reads in place. Without a `_` arm, every
  union member needs a type arm.

### 2.11 Warnings

Warnings go to stderr as `FILE:LINE:COL: warning: MSG`, never
change the output bytes (verified: byte-identical binary with and
without `-w`), and are fatal to nothing — but **an example that
compiles with warnings has not met the bar.**

The two that will actually bite are
`warning: unused variable 'x'` and
`warning: the value of 'x' is not used` (a bare identifier or a
discarded call result as a statement). Also watch for
`unreachable code`, `division by zero` (a literal integer zero),
`duplicate field 'a' in a record literal`, and
`the type { ... } is written out N times; name it with \`type\``.

**Exempt** — these do *not* warn, so do not write code hunting for
them: parameters, loop variables, top-level bindings, top-level
`def`s, and any name starting with `_`.

The repo's own rule is stricter still: `src/y` and `src/y/std`
compile with **zero** warnings. Aim for the same in an example.

`-w` silences warnings and changes nothing else. `-W 1` adds three
optional checks: a dropped call result, a dropped read or literal
used as a statement, and an empty `else`.

### 2.12 String and asset footguns

**`split` drops exactly one trailing empty field.** Verified:

| expression | result |
|---|---|
| `"a,b".split(",")` | `[a, b]` |
| `"a,".split(",")` | `[a]` — the trailing empty is gone |
| `"a,,".split(",")` | `[a, ]` |
| `"".split(",")` | `[]` |

So `join(s.split(sep), sep)` does **not** round-trip a string that
ends in the separator. For line-based text use `s.lines()` instead,
which drops the CR of a CRLF and no trailing empty line.

**`join` puts the separator first.** It is
`sep.join(xs)`, not `xs.join(sep)` — `"a".join(["x","y"])` is
`xay`.

**`.length` is a property, not a method.** `s.length` is right;
`s.length()` is `error: str has no method 'length' ('.length' is a
property: no parentheses)`. The same goes for `arr.length`. Every
other string method *is* a method, and method names are not reserved
— a `def`, variable or record field may legally be called `trim`.

**`embed` must be its own statement**, terminated with `;`, and its
path is resolved at compile time relative to the importing file:

```
embed MASK from "termblocks_masks";    // own line, ends with ;
```

It turns the file's bytes into a `const` string, which is how an
example ships a binary asset. Any bytes are allowed, NULs included.

### 2.13 Concurrency, servers, crypto and pipes

Verified with the pinned compiler while setting up Waves 2–4, so
the examples that need these do not each rediscover them.

**Threads work, and a mutex really does serialise.** Five threads
each adding a distinct value under `lock` gives exactly the sum.

**But a spawn leaks ~128 bytes.** Nothing is ever freed, and each
thread allocates from a heap of its own, so 2000 spawn/join cycles
grew `heap_used()` by 256 000. **Spawn a bounded pool of workers and
feed them, never one spawn per work item** — this is the difference
between a threaded renderer that fits the cap and one that does not.

**`for i in lo..hi` is half-open.** `for i in 1..5` is four
iterations. This reads as a lost-update race the first time you see
it; it is not.

**`net.listen_http` never returns and has no shutdown.** Serving in
a thread and then `join`ing it **hangs forever** — the kernel has no
way to break that loop, and Y has no signal handlers. The pattern
that works is to **fork the server and kill it**:

```
let pid = fork { net.listen_http(PORT, handler); 0 };
... do the requests ...
syscall(62, pid, 15);          // kill(pid, SIGTERM)
wait_pid(pid);                 // -> 143 = 128 + SIGTERM
```

Verified: serves requests, shuts down, parent exits 0. A forked
server is a *process*, so it also gives the example a clean way to
stop. Prefer this to a server thread everywhere.

**The HTTP client works on loopback.** `http.get` against
`net.listen_http` returns the right status and body, including 404.
Outbound `https` to a real site works too.

**`fork` is clean** — the child runs its block, `exit(n)` sets the
code, `wait_pid` returns it (143 for a signalled child). Do not mix
`fork` with threads: a threaded program traps if it locks or joins an
inherited lock.

**The std crypto is complete enough for a real handshake.** Verified
round trips: `x25519_base` + `x25519` agree on a shared secret,
`chacha_seal`/`chacha_open` round-trip and reject a wrong AAD,
`gcm_seal`/`gcm_open` round-trip, and `sha256(bytes("abc"))` is the
correct `ba7816bf…`.

**`pipe`/`pipe2` write two 32-bit ints — read them as such.** This is
a real trap:

```
let fds: [long; 2] = [0; 2];
syscall(293, &fds[0], 0);        // rc = 0, success!
// fds[0] is now 0x400000003 and fds[1] is 0 — NOT the two fds
```

The kernel wrote `int fds[2]` = 8 bytes; reading them back as two
64-bit `long`s gives you both fds packed into the first element and
zero in the second. `wr` becomes `0`, which is **stdin**, and the
program hangs or corrupts a stream. Use a byte buffer and assemble:

```
let fds: [byte; 8] = [0; 8];
syscall(293, &fds[0], 0);                            // pipe2, flags 0
let rd = fds[0] + fds[1]*256 + fds[2]*65536 + fds[3]*16777216;
let wr = fds[4] + fds[5]*256 + fds[6]*65536 + fds[7]*16777216;
```

`pipe2` is syscall 293, `pipe` is 22; both take (fds_ptr, flags).
With that, bidirectional IPC between a forked pair works.

**A `[byte]` array is not a valid `syscall` argument** — only
`long`, `bool`, `str` and `*T`. Pass `&arr[0]`, or pass a `str`
literal directly (`syscall(1, 1, "hi\n", 3)`), since a `str`
argument already arrives as a pointer to its bytes. And **the length
argument is yours to compute**: `syscall(1, 1, s, 0)` writes nothing
and fails silently.

### 2.14 What the std library does and does not give a systems example

Verified, so the Wave 3 examples do not each rediscover it.

**There is no base64 *encoder*.** `x509.b64_decode(s) -> [byte]`
exists and works — it skips characters outside the alphabet and
handles `=` padding, so `"aGVs bG8="` decodes to `hello` and stray
punctuation is ignored. But nothing encodes. Anything that must
*emit* base64 writes the encoder itself.

**There is no JSON and no CSV.** No module, no helper. A JSON parser
has to be hand-rolled over `split` / `index_of` / `ord`, and it is
already on the roadmap (`TODO.md` §3), so a hand-rolled one in an
example is expected rather than a workaround.

**`net` gives a blocking server and `http` a client, and they do not
share a lifecycle.** `net.listen_http(port, handler)` **never
returns and has no shutdown path** — `join`ing it hangs for ever.
Serve in a `fork` and `syscall(62, pid, 15)` to stop. A client
`http.get` against it on loopback returns the right status and body,
including 404.

**A `fork`ed server is a process, which is what makes it stoppable.**
`fork { net.listen_http(P, h); 0 }`, then `kill` and `wait_pid`
(the child reports 143 = 128 + SIGTERM). Mixing `fork` with threads
is the thing to avoid: a threaded program traps if it locks or joins
an inherited lock.

**`wait4` on your own parent returns `-ECHILD`.** It waits for
*children*. Polling a parent that way looks like a hang.

**The std crypto is complete enough for a real handshake, verified by
round trip:** `x25519_base` + `x25519` agree on a shared secret;
`chacha_seal`/`chacha_open` round-trip and **reject a wrong AAD**;
`gcm_seal`/`gcm_open` round-trip; `sha256(bytes("abc"))` is the
correct `ba7816bf…`. `crypto.random_bytes(n)` uses `getrandom(2)`.

**Bidirectional pipe IPC between a forked pair works** — see the
32-bit `pipe` warning above, which is the only trap. Child exit codes
come back through `wait_pid`.

---

### 2.15 Four language facts, each verified on the pinned compiler

Found by subagents and confirmed by direct measurement, because all four
are silent-wrong-answer traps and none was in this document.

**A `def` is a first-class value, typed `(parameter type) -> return
type`.** The parentheses are the parameter *list*, so a one-argument
function is `(long) -> long` — this is not a tuple and not a cast:

```y
type Op = (long) -> long;
def double(x: long) -> long { x * 2 };
def triple(x: long) -> long { x * 3 };
def apply(f: Op, v: long) -> long { f(v) };
let ops: [Op] = [double, triple];       // functions in an array
print(apply(ops[1], 5));                // 15
```

Verified end to end. This gives dispatch tables, strategy parameters
and generic passes **without closures** — which matters, because
AGENTS.md tells the compiler's own source to avoid new closures (the C
twin's value model cannot store a function value). An example may still
use them; the compiler's `src/y` may not.

**`>>>` is a LOGICAL shift and `>>` is arithmetic.** Measured:

```
-16 >> 2   = -4
-16 >>> 2  = 4611686018427387900      (zero-extended, ~2^62 - 4)
```

`>>>` on a possibly-negative value is catastrophic and **completely
silent**: no trap, no diagnostic, just a plausible wrong number. One
subagent lost three separate bugs to this — an inverted gradient sign,
a camera a million units away rendering a plausible all-sky frame, and a
palette channel pure white for half its length. **Use `>>` unless you
specifically want zero-extension, and audit every `>>>` for a possibly
negative left operand.**

**`chr()` is byte-oriented and cannot produce a non-ASCII glyph.**
`ord()` is documented as "the code of the first **byte**", so `chr()` is
its inverse and also byte-wide:

```
chr(9608).length  = 1        (U+2588 FULL BLOCK)
ord(chr(9608))   = 136      = 9608 & 255 = 0x88
```

So there is **no** one-expression way to build a `str` from a codepoint:
`str + byte` segfaults, `+=` on a byte is a compile error, and `chr()`
truncates. Emitting a non-ASCII glyph means writing UTF-8 bytes yourself
into a fixed buffer (`fb.utf8_len` / `fb.utf8_byte`) and leaving through
one `write(2)` — which is the right answer on an arena heap anyway.
Filed as SUGGESTIONS §11.

**`main()`'s return value is NOT the exit status — and both obvious
alternatives are wrong.** Measured on the pinned compiler:

| you write | what happens |
|---|---|
| `def main() -> long { return 3 }; main();` | prints, then **exit 0** — the value is discarded |
| `def main() -> long { exit(3) }; main();` | **compile error**: `'main' body: expected long, got void` — `exit()` is void, so the block has no value |
| `def main() -> long { return 3 }; exit(main())` | **exit 3** — this is the idiom |

So the exit status comes only from an explicit `exit()`, and `main` must
*return* its code rather than call `exit()` itself. The trap is silent and
runs the wrong way: a program whose error path does `return 1` from `main`
**exits 0 and looks successful** to any caller, and a golden-file gate
records the success. One agent shipped two intermediate versions of a
chess perft in which a **malformed FEN printed nothing and exited 0**
because of exactly this. Filed as SUGGESTIONS §15; the `main` -> `-> void`
plus `exit(code)` shape is the other common workaround.

**`a / b` on two fixed-point values returns their RATIO, not a
fixed-point quotient.** There is no division operator that knows the
scale, so a Q16 ÷ Q16 comes back as a plain small number:

```
a = 2.0 in Q16 (131072),  b = 1.0 in Q16 (65536)
a / b        = 2              <- the ratio 2/1, a scalar
(a * 65536) / b = 131072     <- the Q16 quotient you wanted
```

This is arithmetic, not a compiler bug, and it is the single most
expensive mistake in the campaign: **`fractal` lost SIX separate defects
to it**, all of the same shape — `ODEPTH = num / uu` returned a constant
`2` for every ray instead of a depth of 1.86–2.45; the `2q` term was
divided again so both conic roots truncated to 0; a `cells_v` that was
added where it should be subtracted, which combined with a factor-of-two
scale error to read as *exactly* twice the right row, so the analytic
column reported `0..63` where the marcher reported `0..31`; and a
missing lift before `isqrt` that returned `0.0027` for a tangent ray's
`r = 0.7`. **When a hand-rolled fixed-point quotient comes out as a
suspiciously small constant, this is why.** `fx.mul` and `fx.fdiv` do
handle the scale, so anything built on `fx.y` is fine; this bites code
that rolls its own Q16 — which is what a hot inner loop usually does for
speed.

The nastiest variant is an **under**-estimate, because it always looks
like better conditioning: a too-small miss distance quietly populates a
tolerance check with exactly the grazing rays the tolerance exists to
exclude.

**There is a `regex` module: `import regex;`.** A Pike VM (Thompson NFA
with priority-ordered thread lists) over **bytes**, linear time, and
**no backreferences** — `(a)\1` is a compile error, so the classic
exponential hang cannot happen. Verified working:

```y
let re = regex.compile("(?<host>\\S+?) port=(?<port>\\d+)")!;   // none on failure
let m  = regex.search_at(re, text, at);
print(regex.named(m!, "host")!);        // named group
regex.split(re, "a,b,c");                // -> [a, b, c]
regex.check("([unclosed");               // "unterminated character class at byte 10"
```

It is a **module**, not a std unit — `import regex;` is the only way in,
so it is parsed only by a program that asks for it. It **never prints
and never exits**: a pattern is data, not a caller bug, so a bad one is
`none` from `compile` and a message from `check`. Note `Re` is a plain
data record with no methods (`pattern`, `prog`, `classes`, …) and
`Match` exposes `start`/`end`/`text`/`caps` as **fields**; `regex.end`
takes a group index, so prefer `m.end`. This is the tool to reach for
instead of hand-rolling tokenisers — relevant to `toolkit-cli`, the
Wave 4 JSON work, and every AoC day that parses text.

**`spawn` inside a `while` loop shares the loop variable — use `for …
in` instead.** AGENTS.md states the rule ("one declared before a loop is
shared by all of the loop's closures"); what is *not* written down is
how quietly it breaks a thread pool. Measured on `c53cc415`:

```y
let k = 0;
while (k < 4) { spawn { worker(k) }; k = k + 1 };   // WRONG
```

`k` is **one shared heap cell**, so each closure reads it at whatever
moment the scheduler runs it. The four workers were handed indices
**1, 2, 3 and 4** — the last one read `k` after the loop had finished.
With an 8-slot array the damage is invisible-but-wrong (three slots
increment and a fourth, unintended one increments instead); with an
array sized exactly to the loop count, the shared read of `4` is an
**out-of-bounds index and the program traps**:

```
A[8], `let k` + while :  0=0 1=1 2=1 3=1 4=1 5=0 6=0 7=0   <- slot 4!
A[8], `for k in 0..4`  :  0=1 1=1 2=1 3=1 4=0 5=0 6=0 7=0   <- correct
```

`for k in 0..4` gives a **fresh variable per iteration**, so each closure
captures its own, and three consecutive runs gave identical output. Use
`for … in` for any per-worker index, or pass the value as a parameter
from a literal, or hand out work through a mutex-guarded cursor (what
`mandelbrot` does) — never a pre-loop `let` as a thread identity.

**A counting semaphore is a COUNT, not a signal, and it is NOT fair.**
`post` before a `wait` is not lost — but a token goes to whoever asks
first with no queue behind it, so a worker returning early can take a
second token, and with static per-worker bands that produces an
**invisible worker**: its band is never rendered and the picture is
silently somebody else's, with no trap and a stable digest. Measured by
`mandelbrot` at 8 workers × 3000 rounds: the total was always exactly
24000 while the split came out `2664/3047/3680/2755/3039/3095/2925/2795`
instead of 3000 apiece. Its count also **carries over**, so a "finished"
post can arrive twice and stop the main thread waiting (23 mismatches in
75 runs). Model hand-off as a **mutex-guarded queue**, not as tokens.

**`lock m { e }` builds a closure and a closure is 16 bytes of arena.**
`post` and `wait` measured **0 bytes**, `lock`/`try_lock` **16 each**. A
`lock` block on a frame path is a per-frame allocation; one subagent
measured 22 KB a frame from a spin loop before restructuring the hand-off
to two words of semaphore state.

**`str +=` in a block's value position is quadratic in a loop — and the
trailing `;` that people reach for does NOT always fix it.** The
compiler emits the amortised in-place append (`gen_sappend`) only in a
**discarded** position; a value-used `{ s += t }` stays `s = s + t`,
which allocates a fresh exactly-sized buffer, so a loop of them sums
every intermediate length. Measured, all on the pinned compiler, all
with **identical output**:

```
discarded += only        n=500/1000/2000 →     3 952 /   7 560 /  14 752   (linear)
value-used += only       n=500/1000/2000 →   264 192 / 1 028 192 / 4 056 192   (4x per doubling)
```

The subtlety, which I got wrong myself before measuring it: **a `;`
after the block discards the block's value; it does not turn the
block's own last statement into a discarded position.** So

```y
} else { out += chr(c) };      // SLOW: the block's value is still value-used
} else { out += chr(c); }      // fast: the statement inside is discarded
```

Those differ by **one character and 96x in heap** at 1600 iterations
(129 760 136 → 1 345 568), and the fast version is linear where the
slow one is 3.9x per doubling. When auditing, the shape to grep for is
`+=` as the **last statement of a braced block**, whether or not a `;`
follows the closing brace — and the fix goes **inside** the braces.

Two corollaries worth knowing: the cost is invisible in the output, so a
golden-file gate passes for ever; and at 1600 characters this one
string escaper had already allocated **129 MB**, so a program with a
moderately large string and a naive escaper will hit the campaign's
3.5 GiB cap and report `runtime error: out of memory` with no hint as
to why.

## 3. Invoking the compiler

Examples build against the **blessed** compiler, pinned:

```
$YCC = /home/yun/Projects/compiler/refs/ycc.ref     # sha256 d459af4f08cfffc7…
```

As of this writing `./ycc` happens to be byte-identical to
`refs/ycc.ref`, but the tree is mid-refactor (`src/y/native.y` has
uncommitted changes, and `ynew` is already a different build).
`./ycc` moves every time the compiler is rebuilt or reblessed;
`refs/ycc.ref` only moves on purpose. So pin `refs/ycc.ref`, record
its full sha256 in your README, and treat the pin as part of the
example's identity. If `refs/` is absent, stop and say so — do not
substitute a local build.

### The pin moves — here is what happened, and the rule

**`refs/ycc.ref` is not stable across a session.** During this
campaign the pin was `d459af4f08cfffc7…` and was then reblessed to
`fcdae3ccbd587794…`, with the old binary deleted. That happened
while five subagents were running. `refs/` holds only the current
binary, so a pin is not something you can go and re-fetch later.

**The rule, then:**

1. Build with `refs/ycc.ref` **in place**. Never copy the binary
   elsewhere: it resolves `std/` relative to its own path, so a copy
   in `/tmp` compiles fine until a program does `import fs;`, and
   then fails with `error: cannot find module 'fs'`.
2. **Record the sha256 you actually built with** in your README.
3. Re-check the sha at the end of your task, not just the start. If
   it moved, rebuild and re-run your determinism check before
   reporting.
4. The orchestrator re-runs the whole gate after any rebless. On the
   `d459af4f → fcdae3cc` move, all five toolkit modules and all
   three test suites still compiled with zero warnings and still
   passed unchanged (fx 292 checks, args/time 57, term 111), and the
   filed `Response.text()` bug still reproduced. So a rebless is
   survivable — but it has to be *checked*, not assumed.

```bash
# compile and run
$YCC prog.y -o prog && ./prog
# assembly only
$YCC -S prog.y > prog.s
# under the cap
(ulimit -S -v 3670016; $YCC prog.y -o prog && ./prog) </dev/null
```

`-g` adds symbols, section headers and DWARF line info without
changing code or data — use it when a program needs `gdb`,
`addr2line` or `perf`. `-S -g` assembles with GNU `as`. `--no-exec`
strips `exec()`.

There is no libc, no `cc`/`as`/`ld` in the pipeline, and the output
is a static ELF.

`tmux` is **not** installed on this machine. To capture a terminal
program's real output, allocate a pty from Python:

```python
import pty, os
pid, fd = pty.fork()
if pid == 0:
    os.execv("./prog", ["./prog"]); os._exit(1)
out = b""
while True:
    try: d = os.read(fd, 65536)
    except OSError: break
    if not d: break
    out += d
```

A pty from `pty.fork()` has a window size of 0×0. Set one before
`execv` with `fcntl.ioctl(1, termios.TIOCSWINSZ, struct.pack('HHHH',
rows, cols, 0, 0))` or the program will compute a degenerate frame.

---

## 4. The folder contract

Every example is one self-contained, runnable folder:

```
examples/<name>/
  README.md        what it is, how to build and run, what to look at,
                   the frozen toolkit revision, the compiler sha, and
                   every compiler workaround with a link to its filing
  gate.conf        build= and run= lines, so ./gate.py can check this
                   folder without being told how (see below)
  *.y              the sources, including the vendored toolkit
  data/            any binary assets (embed from here)
  golden/          captured frames or output a human can look at
  EXPECTED         exact stdout of the documented deterministic run
```

**`gate.conf` is required.** It is two lines, no shell quoting, values
used verbatim:

```
build=../../refs/ycc.ref donut.y -o donut
run=./donut --frames 60 --no-tty
```

`./gate.py <folder>` then runs the whole seven-item gate with no
arguments from the orchestrator. Paths are relative to the folder.
The `run=` line is the **deterministic** invocation — it must not
depend on the terminal size, the clock or the network, because that
is the line whose output is diffed against `EXPECTED`.

**Self-contained means vendored.** A shared helper is *copied* into
your folder, not imported from `../_toolkit/`. Two reasons: the
example keeps working when the toolkit moves on, and it matches the
`examples/badapple` precedent, which ships its own `tbrender.y` and
its own copy of `ycc`.

The canonical, tested toolkit lives in `examples/_toolkit/`:

| file | what |
|---|---|
| `fx.y` | integer fixed-point math: `sin cos tan sqrt atan2 floor abs` (no floats — §2.4a) |
| `term.y` | termios raw mode, window size, key + escape-sequence decode, alt screen, restore on every exit path (§2.3) |
| `fb.y` | ANSI framebuffer: SGR + truecolor, glyph ramp, UTF-8 emit, per-row diffing, double buffering (§2.7) |
| `args.y` | flag parsing (`--color=x`, `-v`, `--`), usage text, exit codes |
| `time.y` | sub-millisecond pacing (`clock_gettime`/`nanosleep`), fps meter |

**Vendoring rules.** Copy the file in; do not import across folders.
Record which toolkit revision you froze in your README. **Do not
edit the copy** — if you need different behaviour, add your own file
next to it. If you find a genuine bug in the toolkit, fix it in
`examples/_toolkit/` *and* note in your README that your copy
differs and why. Two examples freezing different revisions is
acceptable and expected; drift should be deliberate, never silent.

**Import a vendored module by bare name.** `import fb;` — not
`import fb from "./fb.y";`. The path form parses but the qualified
type reference then fails: `error: unknown type 'fb.Surface'`.
With the bare form `fb.Surface` works. So an example's entry file
says `import fx; import fb; import term; import args; import time;`
and finds them beside it, with no `from` clause anywhere.

---

## 5. The briefing template

The orchestrator fills this in per subagent and hands it over whole.
Every section is required. A subagent that cannot fill one in should
say so rather than guess.

```markdown
## TASK
<one paragraph: the program, in the user's words>

## YOUR FOLDER
examples/<name>/     — the ONLY path you may write to, except
examples/BUGS.md and examples/SUGGESTIONS.md (§8)

## HARD BOUNDARIES
- Never modify the compiler: not src/, refs/, Makefile, ycc, cycc,
  ynew. Never run make. (§1)
- Never edit the root BUGS.md or TODO.md. (§1 B3)
- Every process under `ulimit -S -v 3670016`; always `</dev/null`.
- Deterministic by default; randomness/time/network behind a flag.
- If you find a compiler bug or a missing feature: FILE it (§8),
  work around it, and keep going. Do not stop, do not patch.

## ENVIRONMENT
$YCC = /home/yun/Projects/compiler/refs/ycc.ref   (sha256 d459af4f…)
(ulimit -S -v 3670016; $YCC prog.y -o prog && ./prog) </dev/null
FIRST ACTION: read /home/yun/Projects/compiler/examples/ORCHESTRATOR.md
§2 (verified environment facts) and §3 (invoking the compiler) in
full, before writing any code. Everything there was checked against
this tree — do not re-derive it. In particular do not file the
syscall argument order, the ioctl constants, the termios VTIME/VMIN
offsets or traps-on-stdout as compiler bugs; each is correct
behaviour with a known cause.
These are the ones that waste the most time if rediscovered:
  - syscall args go in KERNEL REGISTER order, so ioctl is
    syscall(16, fd, REQUEST, arg) — the other order gives -25/ENOTTY
  - TCGETS=0x5401 TCSETS=0x5402 TIOCGWINSZ=0x5413; in struct
    termios VTIME is byte 22 and VMIN is byte 23
  - there is no float->long and no cast syntax; do the maths in ints
  - there is no break and no continue
  - pipe/pipe2 write two 32-bit ints: read them from a [byte; 8], a
    [long; 2] packs both into element 0 and leaves wr = 0 = stdin
  - net.listen_http never returns and cannot be shut down; fork the
    server and SIGTERM it, never join it

## TOOLKIT
Vendor these frozen copies into your folder (§4): fx.y, term.y, fb.y
Do not edit them. Add your own files alongside.
Toolkit revision frozen: <sha or date>

## WHAT TO BUILD
- Behaviour, in enough detail that you do not need to ask.
- CLI: the flags, the defaults, the exit codes.
- The deterministic default run: exact command, exact expected
  output shape.

## ACCEPTANCE GATE (§7) — all must hold before you report back
 1. Compiles with the pinned $YCC and ZERO warnings.
 2. Deterministic run produces output byte-identical to EXPECTED.
 3. No runtime trap, ever, on any path (§2.6).
 4. Runs inside the cap; no per-frame allocation (§2.7).
 5. README.md complete: build, run, what to look at, frozen toolkit
    revision, any compiler workarounds.
 6. Anything you filed in BUGS.md is linked from the README.

## REPORT BACK (this exact shape)
STATUS: done | blocked | partial
FOLDER: examples/<name>/
VERIFIED: <each gate item, with the command you ran and its result>
FILES: <what you wrote>
FILED: <BUGS.md / SUGGESTIONS.md entries you added, or "none">
WORKAROUNDS: <compiler behaviour you had to route around>
NOTES: <anything the next agent should know>
```

**You must also write `gate.conf`** (§4), two lines:

```
build=../../refs/ycc.ref <name>.y -o <name>
run=./<name> <the deterministic flags>
```

Without it the orchestrator has to guess how to build and run your
example, and a guessed build is not evidence. The `run=` line is the
exact invocation whose stdout must equal `EXPECTED`.

**Briefing rules for the orchestrator.**

- The brief must be self-contained about the *task*. A subagent
  starts with a clean context: it cannot see this conversation, your
  earlier messages, or what any other example did.
- **Point at §2 and §3 by path; do not paste them.** Subagents have
  file access, and §2 is long. Make *reading them first* the brief's
  first action, then inline the four traps above as a fallback for a
  subagent that skips the read. This is the highest-leverage part of
  the brief: it is what stops each subagent rediscovering the
  syscall register order, the ioctl constants, the float→long gap and
  traps-on-stdout.
- Say what the example must **not** rediscover. The list changes as
  the campaign goes on; keep it current.
- State the acceptance gate as a checklist, not prose.
- Name the exit criteria for *blocked*: the subagent must say what
  it tried and exactly where it stopped, not go quiet.
- One subagent, one folder. Do not batch two examples into one
  subagent — they will not both get attention.
- **Fill in `WHAT TO BUILD` properly.** An under-specified brief is
  the single most common cause of a subagent drifting into something
  it has to redo.

---

## 6. The wave plan

Wave 0 is a **gate**: nothing else starts until the toolkit modules
pass their self-tests. Waves 1+ fan out in parallel; the wave only
advances when every example in it clears [§7](#7-the-acceptance-gate).

### Wave 0 — Foundation (serial, gated)

| step | module | gate |
|---|---|---|
| 0a | `fx.y` — integer sin/cos/tan/sqrt/atan2/floor/abs | numeric self-test passes: known values, edge cases, monotonicity, no drift over a full turn |
| 0b | `term.y` — raw mode, winsize, key decode, alt screen | pty self-test: modes set, keypress decoded, **terminal restored on every exit path** |
| 0c | `fb.y` — SGR/truecolor framebuffer, row diffing | golden-frame diff: a synthetic scene renders byte-identical twice |
| 0d | `args.y` + `time.y` — flags, usage, sub-ms pacing | self-test: flag table, unknown-flag exit code, pacing holds N fps |

0a runs first and alone: it is the long pole and the most delicate
(integer maths, no floats to check against). 0b–0d are independent
of it and may run in parallel once 0a is stable.

`term.y` and `fb.y` are the two that pay for themselves most — they
are what every interactive example would otherwise rewrite.

### Wave 1 — Prove the toolkit (parallel, 3)

`donut`, `cube`, `life`. Small, visual, and they stress the whole
stack at once. If these are not clean, no later visual example will
be. Gate: `donut` holds 30 fps and its frames diff clean against a
golden capture.

### Wave 2 — Algorithmic (parallel, 6)

`fluid`, `mandelbrot` (threaded), `fractal` (raymarched SDF),
`maze` + A\*, `roguelike`, `bmpview`.

Each runs headless with a deterministic seed and diffable output.

### Wave 3 — Systems (parallel, 6)

`mud` (TCP + threads), `httpsrv` (dashboard), `crypto-chat`
(x25519 + ChaCha over forked pipes), `editor` (Vi-style),
`perft` (chess, threads), `toolkit-cli` (JSON/CSV/base64).

Loopback only — no internet required.

### Wave 4 — Web / API (parallel, 2)

`weather`, `rest-client`. **Hermetic by default**: each starts its
own local server and talks to it, with a `--live` flag for the real
API. Verifiable offline, still exercises real TLS and real JSON
parsing.

### Wave 5 — Advent of Code (parallel, 25)

One subagent per day, 2025. Each day is a self-contained folder with
its own `EXPECTED`, no shared mutable state, no cross-day imports.
The natural fit for parallel dispatch — and the reason AoC lives in
its own top-level folder rather than inside one example.

**Prerequisite: the puzzle inputs are per-user and need a session
cookie.** Verified: `https://adventofcode.com/2025/day/1/input`
returns `status=400` and *"Puzzle inputs differ by user. Please log
in to get your puzzle input."* The puzzle **statement** page is
public (`day/1` returns 200, ~8 KB), so a subagent can always read
the problem — but it cannot compute a verified answer without an
input file.

**Input source: the user's AoC session cookie** (decided). The
orchestrator fetches all 25 inputs up front into
`examples/aoc/inputs/dayNN.txt` before dispatching the wave, and
each day's folder vendors the one file it needs so it stays
self-contained. Fetch with `http.get` and the `Cookie` header:

```
http.get("https://adventofcode.com/2025/day/1/input",
         { headers: { "Cookie": "session=<value>" }, timeout: 20 })
```

A `status` other than 200 means the cookie has expired — ask for a
fresh one rather than falling back silently. Fall back to the
user's own saved inputs if the cookie stops working, and only then
to the sample-input route below.

If neither is available, a day may be built against a **hand-written
sample input** taken from the puzzle statement, with its `EXPECTED`
clearly labelled as a sample answer rather than the user's real one.
The program is still correct and still tested; it just is not
answering *their* puzzle. What is **not** acceptable is an
`EXPECTED` that asserts an answer nobody computed.

### Orchestrator duties per wave

1. Fill the brief (§5) per example; dispatch in parallel.
2. Collect reports; run the acceptance gate (§7) yourself.
3. Re-dispatch with a *specific* correction for anything that fails
   — not the original brief plus a complaint.
4. File a wave summary: what landed, what is blocked, what the
   toolkit needs next.
5. Before advancing: dedup `BUGS.md`, and check whether any finding
   is now reproducible against the pinned compiler.

**Escalation.** A subagent that hits the same compile error three
times stops and reports, rather than looping. Two subagents needing
the same toolkit change are serialised: land it in `_toolkit/`, then
re-vendor.

---

## 7. The acceptance gate

The orchestrator runs these. A subagent claiming success does not
substitute for them.

1. **Clean compile, zero warnings**, with the pinned `$YCC`.
   `-w` is for hiding warnings, not for passing this gate.
2. **Deterministic output.** The documented default run reproduces
   `EXPECTED` byte for byte. Re-run it twice to catch nondeterminism
   from map iteration order or uninitialised buffers. The run is the
   one in `gate.conf`'s `run=` line, and it must not depend on the
   terminal size, the clock or the network.

   **This proves determinism, not correctness.** A golden file that
   encodes a defect is deterministically reproduced and passes this
   item for ever — which is exactly how `examples/cube` shipped a
   wireframe that *fills* regions, and faces that render as
   axis-aligned rectangles instead of trapezoids, through a clean
   8/8. **So: every visual example is rendered and looked at**, by a
   human or by the agent reading the frame. And ask what *property*
   would have caught it — for cube that is "in wireframe mode, no cell
   is drawn that is not on a projected edge", which tests the
   behaviour without a golden file. A golden file cannot check
   itself.
3. **No trap on any path**, including the error paths and the
   argument-validation paths (§2.6). Traps land on stdout, so they
   corrupt the diff rather than announcing themselves.
4. **Inside the cap**, with no per-frame allocation (§2.7).
5. **Self-contained**: builds from a clean checkout of its folder
   with no sibling folder present.
6. **README complete**: what it is, how to build, how to run, what to
   look at, the frozen toolkit revision, and every compiler
   workaround with a pointer to its `BUGS.md` entry.
7. **Filed findings are reproducible**: each has a minimal repro
   that still fails against the pinned compiler.

---

## 8. Issue protocol

Two ledgers, both at the root of `examples/`, both append-only:
`BUGS.md` for things that are wrong, `SUGGESTIONS.md` for things
that are missing. Both already exist and carry their own
house instruction — remove an item when it is completed. Both are
currently **empty**, so the first entry sets the precedent: keep it
short, factual and reproducible, and follow the templates below
exactly.

Do not confuse them with the compiler's own ledgers at the repo
root, `BUGS.md` and `TODO.md`. Those are the compiler's; leave them
alone (boundary B3). Read `TODO.md` though — it lists known wanted
language features, and filing a suggestion that merely restates a
roadmap item is noise.

**A subagent that finds a compiler bug files it and keeps going.**
It does not patch the compiler, and it does not abandon the example.
A workaround is a legitimate outcome.

### When is it a bug, and when is it a suggestion?

- **BUGS.md** — Y is *wrong*: a wrong code path, a spurious
  rejection, a diagnostic that misdescribes the source, a codegen
  error, a miscompilation, a crash. The program is valid Y or the
  compiler misjudges it.
- **SUGGESTIONS.md** — Y is *missing* something: no `sqrt`, no
  `sort`, no cast, no JSON module, no termios helper, no
  interpolation form. Syntax sugar and ergonomics belong here too.

If you are unsure, it is a suggestion. **The absence of a feature
is never a bug** — §2.4 lists three such gaps. Two of them (no math
functions, no JSON module) are on the roadmap in the root `TODO.md`,
so check there before filing: restating a known roadmap item is
noise. The third, no `float` → `long`, is a direct consequence of
there being no cast syntax at all.

### Before you append

1. `grep` both files for the diagnostic text or the feature name.
   Duplicates are noise.
2. Re-read the entry — it may already be fixed.
3. Append at the end. Never renumber or edit existing entries.

### BUGS.md entry template

````markdown
## <short title: symptom, not cause>

<what is wrong, in one or two sentences, and why it is a bug>

### Minimal reproduction

```y
<the smallest program that shows it>
```

```
$ refs/ycc.ref bug.y -o bug
<exact output>
```

### Verified matrix

<which forms fail and which pass, as separate standalone snippets>

### Environment

`refs/ycc.ref` sha256 d459af4f08cfffc7fd89a60c6b27fa67e2f3a02fa773fc4d3130120667203cc3
· deterministic across N runs
````

Requirements: **minimal** reproduction (strip it until removing
anything stops the failure), exact compiler output, the forms that
*pass* as well as those that fail, and the pinned compiler's
sha256. No bug enters the file without a repro someone else can run.

### SUGGESTIONS.md entry template

````markdown
## <short title>

**Useful because** <what it buys — the problem it removes today>

Today:

```y
<what you have to write instead, and what that costs>
```

Wanted:

```y
<the syntax or signature>
```

**Costs** <what it would take in the compiler, honestly>
````

State the benefit concretely and the cost honestly. A suggestion
that reads like a bug report will be rejected; so will one that
proposes a feature with no example of what it replaces.

### Workarounds

A filed bug gets worked around in the example, not in the compiler.
Note it in the example's README with a pointer to the entry, so the
next reader knows why the odd-looking code is there and what would
change when the bug is fixed.

---

## 9. Review rubric

The orchestrator's own read-through before a wave advances. Anything
scoring 0 on a hard item goes back with a **specific** correction.

**Correctness**
- Golden output reproduces twice, byte for byte.
- No nondeterminism leaking from map iteration order, uninitialised
  buffers, `clock_us()`, or `syscall(39)` temp names.
- Error paths do not trap; bad input is diagnosed, not crashed on.
- Indices and slices cannot go out of bounds on adversarial input.

**Language craft**
- Compiles with zero warnings.
- Annotations are present and honest; no `unknown`-leaning
  annotations papering over a real type problem.
- Records have `type` aliases where a shape is used more than once.
- No `+` where `+=` was meant (or the reverse) in a hot loop.
- Fixed buffers reused in any per-frame path.

**Presentation**
- `README.md` explains the idea to someone who has not seen it, and
  says what to look at when running it.
- The program's own output is legible: aligned columns, units,
  labels, sane defaults.
- CLI flags have a usage text and sensible exit codes.

**Honesty**
- Every `BUGS.md` entry has a repro that still fails.
- Workarounds are visible in the code or the README, not silent.
- The example does not claim a feature Y lacks. If something is
  approximated, the README says so.

---

## 10. The idea backlog

The full list. §6 gives each wave its **first batch** and a count;
this section is everything in that wave plus the overflow, so a wave
may dispatch in more than one round. Anything not listed here is
welcome if it fits the folder contract.

Order within a wave is a suggestion, not a rule — but each wave's
gates still apply to everything in it.

### Wave 1 — toolkit proof
- **`donut`** — spinning ASCII torus. Classic, and it exercises
  `fx` + `fb` + `term` end to end.
- **`cube`** — rotating wireframe/solid cube, perspective divide,
  face shading.
- **`life`** — cellular automaton. Cheapest possible check that the
  framebuffer and pacing are sound.

### Wave 2 — algorithmic
- **`fluid`** — fluid simulation (Stam-style stable fluids or a
  grid-based shallow-water solver). Force one of these into the
  examples: the head asked for it.
- **`mandelbrot`** — threaded renderer; embarrassingly parallel, so
  it shows `spawn`/`join` doing real work.
- **`fractal`** — raymarched SDF, or a flame fractal with a palette
  editor.
- **`maze`** — recursive-backtracker generator plus A\* and a
  BFS cross-check.
- **`roguelike`** — dungeon generation, field of view, turn loop.
  The engine under a small RPG.
- **`bmpview`** — BMP/PNG decode into a terminal image viewer, via
  `embed` and `struct`.
- **`boids`** — flocking; a fixed-point `sqrt` stress test.
- **`raytracer`** — reflective raytracer in a framebuffer.
- **`wavefunction`** — wave function collapse by constraint
  propagation.
- **`sandfall`** — falling-sand cellular automaton.

### Wave 3 — systems
- **`mud`** — MUD server and client over TCP, with threads.
- **`httpsrv`** — HTTP server with a live dashboard, `net.listen_http`
  plus threads.
- **`crypto-chat`** — X25519 key agreement and ChaCha20-Poly1305
  between two forked processes. The std crypto is right there
  (`x25519_base`, `chacha_seal`, `gcm_seal`).
- **`editor`** — Vi-style terminal editor. Raw mode, keys, redraw.
- **`perft`** — chess perft, threaded per-move-count.
- **`toolkit-cli`** — JSON / CSV / base64 conversion utilities.
- **`hexview`** — hex editor and file inspector.
- **`turtle`** — turtle-graphics interpreter.
- **`bignum`** — arbitrary-precision arithmetic; shows off `long`.
- **`indexer`** — a file indexer over `fs`, maps and sorting.

### Wave 4 — web / API
- **`weather`** — weather by API, hermetic local server by default,
  `--live` for the real thing.
- **`rest-client`** — REST client with sessions, headers, retries.

### Wave 5 — Advent of Code
- **`aoc/`** — 2025, days 1–25, one subagent per day, one folder
  each, each with its own `EXPECTED`.

### Considered and parked
- **Audio** — `/dev/snd` exists with ALSA control devices, so raw
  PCM is plausible, but there is no PCM device path confirmed and no
  `/dev/dsp`. Needs a feasibility spike before it earns a folder.
- **GPU / compute** — no GPU access; everything is CPU and terminal.
- **Windowed GUI** — Y emits a static ELF with no X11/wayland story.
  The terminal is the display.