# List of LANGUAGE features to add to YCC
Language features to be added, insert a reason why it is useful, a snippet of how it looks like

This ledger is for the **examples** campaign: findings made while
writing programs under `examples/`. It is separate from the
compiler's own ledger at the repo root, `TODO.md`. The protocol —
when a finding is a bug versus a suggestion, the entry template,
the dedup rule — is in `examples/ORCHESTRATOR.md` §8.

**Check the root `TODO.md` before adding anything here.** It
already carries nine wanted language features. Restating one of
them is noise, not a contribution. Each entry says what it buys and
what it costs today.

***INSTRUCTIONS WHEN FINISH*** remove the SUGGESTION item from this file when it has been completed

---

## 2. A way to convert `float` to `long`

**Useful because** there is no cast syntax at all. The complete
conversion list is `long→float`, `long→byte` (at an annotated site
only), `byte→long`, `byte→float`, `str→*T` and `none` unification.
`float` → `long` is not on it, and it cannot be written down:

```y
let f = 3.7;
let n: long = f;
```

```
error: let 'n': expected long, got float
```

This is the single most limiting gap in the language for numeric
work. A program cannot truncate a float, cannot index an array with
one, and cannot turn a computed pixel coordinate or a hash into an
index. It also forces every renderer to do its arithmetic in
integers, which is the reason the shipped
`examples/badapple` players carry all their colour fitting in `long`
fixed point — a real cost in both clarity and accuracy, taken purely
to route around the missing conversion.

The escape hatch today is `tolong(f)`, which truncates toward zero
(`3.7` → `3`, `-3.7` → `-3`) and traps on a NaN or a magnitude at or
past 2^63 — exact and fast, unlike the `tolong(tostring(f))` this
item was written against, which went through a 6-decimal string.
What is still missing is the IMPLICIT form below: a float in a
`long` position is still `expected long, got float`.

Wanted:

```y
let n: long = f;          // truncate toward zero, as C does
let m: long = f * 0.5;    // in an expression, not just a binding
```

**Costs** A conversion rule in the checker, and an instruction
sequence in the emitter. Truncation toward zero is
`cvttsd2si` — one instruction, already needed by nothing else, so
there is no register-pressure or codegen-size argument against it.
The design question is only whether `f * 0.5` should convert
implicitly anywhere a `long` is wanted, or whether it should require
an explicit `long(f)` form.

### Status (round 63, 2026-10-06) — NARROWED: `tolong(f)` closed the FLOAT half; the IMPLICIT form is what is left

Re-probed on this tree. `tolong(3.7)` is 3 and `tolong(-3.7)` is -3, so the
"a program cannot truncate a float" half of this entry is answered by the
escape hatch now that it has a fast path. What is still missing is exactly what
the **Wanted** block shows: a float in a `long` position is still
`error: let 'n': expected long, got float`, so `let n: long = f;` and
`let m: long = f * 0.5;` remain unwritable. That is a checker-and-emitter
change (`cvttsd2si`) and nothing about it has been started; the entry stays
open, one paragraph narrower than it was.

### Status (orchestrator, 2026-10-05) — STILL OPEN, and independently corroborated

Re-read per the protocol while checking #1. This entry is **not** fixed, and
the strongest evidence is not mine: the `std/math.y` being written on the
`math-portable` branch names this exact gap as the reason it cannot finish.

Its header, verbatim:

> Y has no `float` -> `long` conversion and no way to read a float's bits, so
> there is no seed for a Newton iteration and no …

That is a second party independently hitting this wall from the opposite
direction — not from an example that wanted to print a number, but from a
library author who wanted `sqrt`. It also explains the shape of the fix: it
is a **language** change (a conversion, or a cast syntax), not a library
change, so no amount of std work can route around it. That is why this entry
says what it costs and why the campaign's own escape hatch
(`tolong(tostring(f))`, 6 decimals, truncation toward zero) is the worst
available answer rather than a good one.
## 5. A typed syscall-wrapper unit, so out-parameters stop being a width guess

**Useful because** `syscall(n, a1..a6)` gives you a number in and a pointer
out, and nothing tells you how wide the kernel's writes at that pointer are.
Most syscalls write C `long`s (8 bytes) and are fine read as Y `long`s. Some
write C `int`s, and those are read wrong in a way that is completely silent
and looks like a compiler bug. `pipe(2)` is the one that bites hardest,
because it is the natural way to build a self-pipe watchdog, which is the
natural way to make sure a terminal program restores the terminal when it is
`kill -9`ed:

```
let pf: [long; 2] = [-1; 2];
if (syscall(22, &pf[0], 0, 0, 0, 0, 0) != 0) { ... };
// pf[0] == 3  works by luck: the fd is in the low 32 bits and the high 32
// bits are zero, because it is the FIRST of the pair.
let wfd = pf[1];        // WRONG. This is 0x0000000400000004 -- 17179869188.
                        // close(wfd) then fails with EBADF, the child's read
                        // never sees EOF, and the watchdog silently never
                        // fires. There is no error anywhere.
```

Three more of the same shape that a program meets immediately afterwards:
`dup2`/`dup3` write one `int`; `socketpair`/`pipe2` write two; `uname`,
`getrusage`, `sysinfo` and `times` write structs whose fields are `long`
followed by `int`s at unaligned offsets, so even a `long`-typed copy is
misaligned relative to the C declaration. `struct termios` itself has the
same character — `c_cc[32]` sits at byte 17 of a struct where every element
before it is 4 bytes wide — so every termios program is a `[byte; 64]` with
hand-computed byte offsets, and `VTIME` at byte 22 versus `VMIN` at byte 23
is exactly the kind of transposition that reads as "the keyboard does not
work" with nothing printed.

Today — every out-parameter buffer is a hand-rolled `[byte; 64]` plus manual
little-endian packing, and `test/std/term.y` carries ~40 lines of
`rd16`/`rd32`/`wr32` helpers and a comment block about which offsets are
right precisely so that forty example folders do not each rediscover them.
`poll(2)`/`select(2)` cannot be used for a millisecond-resolution timed read
for the same reason: there is no way to fill a `struct pollfd` except as
three separate byte stores.

Wanted:

```
import io;

let (rfd, wfd) = io.pipe();          // two fds, correctly typed
io.close(rfd);

let (rows, cols, xpx, ypx) = io.winsize(0);
let mode = io.tcgetattr(0);
io.tcsetattr(0, { iflag: mode.iflag & ~io.ICANON,
                   lflag: mode.lflag & ~io.LFLAG_RAW,
                   cc:    mode.cc.with(VMIN, 1).with(VTIME, 0) });

let ev = io.poll([{ fd: 0, events: io.POLLIN }], timeout_ms: 120);
```

**Costs** One more std unit in the shape of `std/struct.y`: byte-level
read/write helpers that know C widths, plus a `termios`/`winsize`/`pollfd`
shape built with them. No compiler work is needed — `struct.y` already knows
how to lay out and decode a byte buffer. The design questions are only
whether `pipe` returns a pair (and Y has no tuples yet — see TODO.md §6 — so
it would have to return a fixed `[long; 2]` with `IO_R_PIPE`/`IO_W_PIPE`
accessors, or take a caller-supplied buffer), and whether the `cc` array
wants a real `[byte; 32]` or accessor functions. Nothing here is blocked on
the compiler, which is what makes it cheap.

## 7. A record or array literal inside a loop body allocates on every iteration

### Independently measured

Confirmed on `refs/ycc.ref` sha256 `e27f83e4801f9436`, 2000
iterations each, with `heap_used()` either side of the loop:

| loop body | heap delta |
|---|---|
| `let a = [1, 2, 3];` | **128 000 B** (64 B/iteration) |
| `let r = { a: 1, b: 2 };` | **80 000 B** (40 B/iteration) |
| the same array hoisted above the loop | **0 B** |
| `xs += i` (the array growing) | 32 776 B for 2000 elements — amortised doubling, not a per-iteration leak |

So it is a **fixed per-iteration stride**: 64 bytes for a 3-element
array, 40 for a 2-field record. At 30 fps that is ~1.9 KB/frame, so a
program doing this dies under the campaign's 3.5 GiB cap in roughly
half an hour of running, with no warning and no diagnostic. The last
row matters too: growing an array with `+=` is *not* this bug — that
is ordinary amortised doubling and it is fine.

**Useful because** the heap is an arena and nothing is ever freed
(`ORCHESTRATOR.md` §2.7), so a literal written inside a loop is a leak with a
fixed stride — and a literal is the natural way to write a small record or a
scratch array. A renderer, a parser or a protocol loop that builds one per
iteration loses 64 or 72 bytes *per iteration* with no diagnostic at all. The
workaround is to hoist every such literal to a module-level binding by hand, and
nothing tells you that: there is no warning, and the heap total moves, so it
shows up as a mysterious slow leak or as a program that dies under the memory
cap hours in.

Today — a palette rebuilt every frame:

```y
type Pal = { lo: long, hi: long, bg: long, flat: long, mono_fg: long };

def pal() -> Pal { { lo: 0, hi: 1, bg: 2, flat: 0, mono_fg: 3 } };

def render(s: Surface) -> void {
    torus_draw(s, gm, pal())          // +64 bytes, every frame, forever
};
```

Wanted — one of these, cheapest first:

1. **Escape analysis in `native.y`**, so a literal that provably does not
   escape its frame is stack-allocated. This is the real fix: none of the forms
   below need to change.
2. **A stack-scoped binding form**, so the intent is written rather than
   inferred:

   ```y
   def render(s: Surface) -> void {
       stack p: Pal = { lo: 0, hi: 1, bg: 2, flat: 0, mono_fg: 3 };
       torus_draw(s, gm, p)           // nothing on the heap
   };
   ```
3. **A lint warning** for a literal in a loop body whose address is never
   taken, which is the case `examples/donut` hit three times.

Option 1 alone fixes every current case, because records already go by reference
when passed to a `def` — see the matrix — so a literal that never escapes *could*
stay off the heap. It does not, and it costs the same whether the literal is
used, ignored, returned or passed on.

### Minimal reproduction

```y
type Pal = { a: long, b: long, c: long, d: long, e: long };

let P: Pal = { a: 1, b: 2, c: 3, d: 4, e: 5 };
let D: [long; 12] = [48; 12];

def f1(n: long) -> long {            // local literal, read, never leaves the frame
    let i = 0; let s = 0;
    while (i < n) { let p: Pal = { a: 1, b: 2, c: 3, d: 4, e: 5 };
                    s = s + p.a; i = i + 1; };
    s
};
def f2(n: long) -> long {            // the same, but p is never read
    let i = 0; let s = 0;
    while (i < n) { let p: Pal = { a: 1, b: 2, c: 3, d: 4, e: 5 }; i = i + 1; };
    s
};
def make() -> Pal { { a: 1, b: 2, c: 3, d: 4, e: 5 } };
def take(p: Pal) -> long { p.a };
def f3(n: long) -> long {            // a literal RETURNED by a def
    let i = 0; let s = 0;
    while (i < n) { s = s + make().a; i = i + 1; };
    s
};
def f4(n: long) -> long {            // a literal PASSED as an argument
    let i = 0; let s = 0;
    while (i < n) { s = s + take({ a: 1, b: 2, c: 3, d: 4, e: 5 }); i = i + 1; };
    s
};
def f5(n: long) -> long {            // an ARRAY literal
    let i = 0; let s = 0;
    while (i < n) { let d: [long; 12] = [48; 12]; s = s + d[0]; i = i + 1; };
    s
};
def f6(n: long) -> long {            // the control: re-bind a module-level value
    let i = 0; let s = 0;
    while (i < n) { let p = P; let d = D; s = s + p.a + d[0]; i = i + 1; };
    s
};

let n = 1000; let sink = 0; let form = tolong(argv()[1]);
let h0 = heap_used();
if (form == 1) { sink = f1(n); };
if (form == 2) { sink = f2(n); };
if (form == 3) { sink = f3(n); };
if (form == 4) { sink = f4(n); };
if (form == 5) { sink = f5(n); };
if (form == 6) { sink = f6(n); };
let h1 = heap_used();
print("delta "); print(h1 - h0); print(" for "); print(n);
print(" calls\n");
```

```
$ refs/ycc.ref alloc2.y -o alloc2
14:21: warning: unused variable 'p'
$ ./alloc2 1
delta 
64000
 for 
1000
 calls
```

(`print` puts a newline after every value, which is why the numbers are on
their own lines. Form 6, the control, prints the same shape with `0`.)

### Verified matrix

| form | bytes per call |
|---|---|
| 1 · local record literal, read, does not escape | **64** |
| 2 · local record literal, never read | **64** |
| 3 · record literal returned from a `def` | **64** |
| 4 · record literal passed as an argument | **64** |
| 5 · local `[long; 12]` literal (both literals in scope) | **136** |
| 6 · re-bind a module-level record and array | **0** |

Deterministic: `heap_used()` before and after is identical over five runs. So a
record literal is 64 bytes and an array literal 72, every time, regardless of
use — and **re-binding an existing record or array is free**, which is the whole
of the current workaround and the whole of the ergonomics complaint.

### Environment

`refs/ycc.ref` sha256 `63a4c3d0691dea43542341c56bc65779f6323646cfcb4d9c65c5ed0503b318bc`
· found while writing `examples/donut` (Wave 1), which needed three of these
removed from its frame loop before `heap_used()` reported a delta of 0 across
300 frames.

**Costs** Option 1 is escape analysis over a local's uses in `native.y`, plus the
interaction with captures (a captured local must outlive the frame, so it stays
on the heap) — medium, and it needs care around closures. Option 2 is a new
binding form in `parser.y`, a new storage class in `types.y`, and a lifetime
rule in `rename.y` — also medium, and it puts a footgun in the language. Option 3
is one pattern in `lint.y` plus its twin in `src/c/lint.c` — nearly free, and it
is what would have saved the three places in `donut.y` that had to be written
around.

### One instance of this the workaround cannot reach: `fs.cwd()` costs 4 248 bytes a call

Added 2026-10-05, measured in `examples/bignum`. The std pack has the same
defect, and the "hoist every literal by hand" workaround **does not apply to
it**, because the literal is in `src/y/std/fs.y`, not in the caller's code:

```y
def cwd() -> str {                          // src/y/std/fs.y
    let buf: [byte; 4096] = [0; 4096];      // ← a 4 KiB literal, in the body
    let n = syscall(79, &buf[0], 4096);
    if (n <= 0) { "" } else { from_bytes(buf[0:n - 1]) }
};
```

Measured on the current pin, 200 calls, `heap_used()` either side of the loop:

| | bytes per call |
|---|---|
| `fs.cwd()`, cwd 21 chars | **4 248** (4 096 buffer + 40 of header and rounding, + 112 for the `str` it returns) |
| `fs.cwd()`, cwd 43 chars (`examples/bignum`) | **4 296** — only the returned string grew |
| `from_bytes` of 21 bytes, alone | 112 |
| a hand-copied `my_cwd()` with the same body | **4 248** — identical |

The fourth row is the point: it is not something about `fs` doing extra work, it
is **exactly this entry's mechanism**, 4 096 bytes of array literal per call, and
the second row shows the fixed part dominates.

**Why it is worth an entry rather than a note**, because it is the shape that
keeps recurring: *resolving your own executable path* is what every program that
forks or execs itself has to do, and `argv()[0]` is relative as often as not, so
`fs.cwd()` is called once per child. `examples/bignum`'s battery forks 31
children and pays **4 448 bytes each** — `fs.cwd()` at 4 296 in that folder plus
the 152-byte `cwd + "/" + argv[0]` concatenation — **137 888 bytes** in total,
2.7% of the whole run, for a path that never changes. That `self_path` shape is
written out twice in this corpus with the same comment about a relative
`argv[0]` — `examples/bignum/check.y` and `examples/toolkit-cli/selftest.y` —
and both pay it silently, which is the point: the caller sees no diagnostic and
no reason to suspect `fs`.

**What it buys**: fixing it in `fs.y` alone (a module-level scratch buffer,
written in `src/y/std/fs.y` and its C twin `src/c/std/fs.c`, re-created on
every `fs.cwd()` call in case a program `chdir`s) is contained and safe — but it
does **not** remove the underlying hazard, because the next std function with a
literal in its body has it again and no caller can hoist it. That is the
argument for Option 1 or Option 3 of this entry rather than a one-line patch:
#3's lint warning would fire *inside* the std pack too, which is exactly where a
program cannot fix itself.

**Environment** · `refs/ycc.ref` sha256
`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b`, all four rows
measured on it · found while fixing `examples/bignum`'s golden, where measuring
that example's *check* heap delta is what turned a hunch ("a delta is
automatically path-independent") into the opposite measured fact: `bignum check`'s
delta moves 137 888 bytes by invocation path, because the battery re-reads argv 31
times. So a delta is only path-independent when the measured region does not
touch argv — a caveat worth attaching to the delta idiom everywhere it is
recommended, which is #7 and entry #24 as well.

---

## 8. A runtime-sized array: let `[0; n]` take an expression, not only a literal

**Useful because** an array's length is the one thing a program almost always
knows only at run time, and `[v; n]` — the repeat form that produces a typed
array in one step — takes an **integer literal** only. So the natural
`make(n)` helper does not compile, and the array can only be built at its
maximum size with a logical length beside it.

Today — this is the whole idiom, and it is what a cellular automaton, a
raster, a histogram or any `size`-driven program ends up writing:

```y
def make(w: long, h: long) -> [long] { [0; w * h] };
```
```
1:44: error: expected an array size (an integer literal from 0 to 2147483647), got 'w'
```

A `const` does not help — the size is a literal, not a name:

```y
const N = 40;
def make() -> [long] { [0; N * 2] };
```
```
2:28: error: expected an array size (an integer literal from 0 to 2147483647), got 'N'
```

so the program allocates the **largest buffer it will ever need** and tracks
the real size itself. From `examples/life/sim.y`, which is a torus-wrapped grid
whose width and height come from `--size`:

```y
const MAXCELLS = 262144;
type Sim = {
    w: long, h: long,
    cur: [long; 262144],   // the literal again, spelled out four times
    nxt: [long; 262144],
    ...
};
```

Two costs follow, and they are the reason this is worth filing. The 8 MiB is
allocated whether the grid is 2 × 2 or the maximum, so `life --size 2x2` costs
the same memory as `--size 512x512`. And every grid shape has to be checked by
hand — `--size 999x999` cannot be a diagnostic, because the store is already
fixed; the program has to invent the limit, and the limit is a property of the
program rather than of the request. The constant and the type position also
disagree by construction: the comment in `sim.y` has to say "the array types
below have to spell it as the literal 262144", because nothing keeps the two
in step.

Wanted — the size as an expression, checked against the same range the literal
has today:

```y
def make(w: long, h: long) -> [long] { [0; w * h] };        // exactly this long
let rows: [long] = [0; cols];                                // 80 rows, not 80 rows worth
```

**Costs** Small. The parser already parses an expression there and throws it
away (`parser.y`, `parse_array`: `let cnt = parse_expr(…)` and then
`expect_err(…)`), so the shape of the change is to keep that node and let the
checker emit a repeat of a run-time count instead of a constant one. The
questions worth deciding are the ones C answers: a negative count, a count that
overflows the size type, and whether `[0; n]` with a non-constant `n` should
still produce a *fixed* `[T; n]` (impossible — the type would depend on the
value) or a growable `[T]`. Making it a growable array whose length is set at
the point of creation would also give `examples/life` and `examples/donut` back
the "allocate once, exactly the size asked for" line they have to work around.

### A second workaround, and what it costs — `examples/aoc/day04`

From the Advent of Code day-4 example (`examples/aoc/day04`), which needs three
arrays of `w * h` cells where `w` and `h` come out of the input file (a 135 × 135
diagram = 18 225 cells), and which cannot afford the "allocate the largest buffer
this input could ever need" advice above.

**Workaround used** — append zeros and let capacity doubling do the work, which
sizes the array to the actual input rather than to a guessed maximum:

```y
let deg: [long] = [];
let i = 0;
while (i < w * h) { deg += 0; i = i + 1 };
```

**Measured cost**, from that example's `--heap` mode (`heap_used()` sampled
around each phase), under `refs/ycc.ref` sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631` and
re-measured, unchanged, under `6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`:

| cells | `[0; n]` would cost | append-zeros costs | ratio |
|---|---|---|---|
| 100 (a 10 × 10 diagram) | 800 B | 2 128 B | 2.7× |
| 18 225 (a 135 × 135 diagram) | 145 800 B | **524 224 B** | 3.6× |

The factor is the sum of the doubling ladder, not one allocation: growing from 0
to 18 225 elements allocates 8 + 16 + … + 32 768 = 65 528 longs, i.e. 3.6× the
final size, and the arena never reclaims any of it. So the append form is
better than a guessed maximum for a *small* input and worse than an exact
allocation for a large one — which is the trade the entry above describes from
the other side. Three such arrays in one run cost 1 574 224 B for the two
part-2 peels plus 524 224 B for the parse, on a run whose whole working set
otherwise stays under 7 MB.

What would remove the whole cost is the one line already asked for:
`let deg: [long] = [0; w * h];`.

### Environment
`d459af4f…` in `ORCHESTRATOR.md` §3/§8 and the `6f873c27…` in §4 above are
older — the reference has been reblessed since.)

*Update, appended rather than edited: the reference has been reblessed again
since this entry was filed, and is now
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`. The two
errors above reproduce identically against it — `examples/life` compiles with
zero warnings and produces byte-identical output under both pins.*
---

### Status (round 63, 2026-10-06) — STILL OPEN, re-confirmed in one line

`let n = 3; let a: [long] = [0; n];` is still
`error: expected an array size (an integer literal from 0 to 2147483647), got 'n'`.
A fixed-size array whose length is a literal works (`[0; 3]`); a runtime length
does not, so this entry is exactly as open as it was written.

## 9. No way to write one scalar into a `[byte]` at an offset — `struct` has readers that cost nothing and writers that cost 48 bytes a call

**Useful because** every binary format in Y is read with `struct`'s getters —
which are perfect — and none of them can be *written* in place. A program that
builds a header (a fixture, a test vector, an asset generator, a protocol
frame) has to slice and concatenate, or index four bytes by hand, and every
one of those routes allocates. Since the heap is an arena and nothing is ever
freed, a builder that runs per record leaks by the record.

Today — this is what `examples/bmpview/selftest.y` has to write to build one
malformed fixture: take the writer's four bytes and copy them in, because
`struct.u32le(v)` answers a **new** array.

```y
import struct;
def set32(b: [byte], off: long, v: long) {
    let w = struct.u32le(v);
    let i = 0;
    while (i < 4) { b[off + i] = w[i]; i = i + 1; };
};
```

The numbers are the argument. The getter side of the format story is already
right — `struct.get_u32le(g, off)` inside a loop costs **zero** bytes, which is
why `bmp.y`'s decoder can read a header field by field in a hot path without
thinking about it. The setter side has no equivalent, so the two halves of the
same module do not compose, and the cheapest available spellings are a
four-iteration copy loop or a slice:

```
1000 struct.get_u32le calls:      0 bytes    # the readers are free
1000 struct.u32le calls:      48000 bytes    # 48 a call, for four bytes of payload
1000 array slices b[8:24]:   56000 bytes    # 56 a slice, for sixteen bytes of payload
```

And the slice is a *copy*, not a view: `let s = b[0:n]` detaches, so writing
through `s` does not write `b`. (Verified: `BUF[8] = 99` after
`let s = BUF[8:24]` leaves `s[0]` at its old value.) So a fixture builder has
three choices and all three allocate.

Wanted — writers that take the destination and an offset, matching the getters
exactly:

```y
import struct;
struct.put_u32le(b, 18, 63);        // biWidth, in place, no allocation
struct.put_u32le(b, 22, 0 - 47);    // a negative height: top-down rows
struct.put_u16le(b, 28, 24);        // biBitCount
let hdr = struct.new_zeros(54);     // optional: a zeroed buffer to write into
```

and, if a real view is out of scope, at least a spelling of the slice that says
out loud that it copies — `b.view(lo, hi)` for something explicitly
copy-on-write, so the next reader does not have to rediscover it.

**Costs** `put_*` is small: fourteen functions of four byte stores each, in
`src/y/std/struct.y`, using the offsets the getters already use, plus a
`new_zeros(n)` that is `[0; n]` behind the same range check. The zero-copy view
is not small — it is a `(ptr, len)` pair that must not escape into places
expecting a real array, or a borrow checker, and Y has no story for either. That
is why this entry asks for the writers first: they remove the allocation from
the common case (a handful of fields per record) without promising the type
system anything.


### Narrowed by `examples/hexview`: the gap is only for scalars WIDER than a byte

The three "choices" above are all true for a `u16`/`u32`/`u64` and **none of
them is needed for a `byte`**, because a single-byte store into a `[byte]` is
already an element assignment:

```y
let BUF: [byte] = [0; 16];
BUF[3] = 0x41;              // zero bytes: no writer, no slice, no copy loop
```

Measured on `refs/ycc.ref` sha256
`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`: 20 000 such
stores in a loop cost **0 B**, against the 48 000 B for 1 000 `struct.u32le`
calls this entry already quotes. `examples/hexview` edits every byte of a file
with `DATA[off] = v` (`hx.set`), and its round-trip property check measures that
edit landing on disk, with no `put_*` anywhere in the program.

So the entry's real scope is **"no in-place setter for a scalar wider than a
byte"** -- 48 bytes a call for four bytes of payload, and 56 a slice -- and the
title overstates it. Nothing here changes what `put_*` is worth: a header is 14
field writes, not one, and a u32 field cannot be an element assignment. It only
means the one-byte case should not be cited as motivation, and that a hex editor
is not evidence for this entry.
---

## 10. `lock m { e }` allocates a closure, so a lock is not free on a frame path

**Useful because** a mutex is the obvious tool for the job Y cannot otherwise
do — handing a value from one thread to another with an ordering guarantee —
and then it costs 16 bytes every time, forever. A render loop that locks twice
a frame leaks 32 bytes a frame: 1.9 MB an hour, 1.9 GB a thousand hours, and
`heap_used()` moves so slowly that nobody notices until it is a problem. The
heap is an arena (ORCHESTRATOR.md 2.7), so the cost is the whole story.

Today:

```y
// a worker's hand-off: 16 bytes, every time
lock guard {
    rows_done = rows_done + 1;
    if (rows_done >= rows) { post done; }     // post itself is FREE
};
// 1 frame, 8 workers, 2 locks a piece: 256 bytes a frame
```

Wanted:

```y
// no closure: the lock block is compiled away when it captures nothing that
// outlives it, or `lock` gains a statement form
lock guard { rows_done = rows_done + 1; if (rows_done >= rows) { post done; } }
```

or, if the block has to stay a closure, a way to say so once:

```y
let g = mutex_guard(m);      // a record with `unlock()`, no closure per use
g.lock { ... };
g.unlock();
```

**Measured**, ten thousand of each on `refs/ycc.ref`, nothing else running:

| form | heap |
|---|---|
| `post s;` | **0** |
| `post s; wait s;` | **0** |
| `wait s;` via a `[sem]` array | **0** |
| `lock m { }` | **160000** (16 each) |
| `lock m { x = x + 1; }` | **160000** |
| `lock(m, def () -> long { 1 })` | **160000** |
| `try_lock m { }` | **160000** |
| a plain function call | **0** |

`post`/`wait` being free is the useful half of this: a semaphore handshake is
already the right way to hand a thread off in Y, and it costs nothing. The
mutex is only needed for the *ordering*, and there is a way to get ordering
without a per-use closure — see below.

**Costs** Small in `native.y` if the closure is only needed when it captures
something: the parser turns `lock m { e }` into `lock(m, def () { e })`, so
the emitter can recognise a closure whose capture list is empty and pass a
null code pointer with the lock and unlock emitted inline around `e`. That is a
peephole on one syntactic form, not a language change, and it covers the case
that actually matters — a lock around a counter or a flag, which is what a
hand-off is. The general case (a block that captures, or `lock(m, f)` called
directly) has to keep allocating, because the closure has to outlive the
statement.

### Workaround used by `examples/mandelbrot`

Not a workaround so much as a design consequence, and the numbers are in that
folder's README. The renderer's work queue locks once per row *claim*, and the
main thread's per-frame path locks **zero** times: the frame is reset with
plain stores, completion is a **blocking** `wait` on a semaphore rather than a
spin on a counter, and the totals are read back plainly. That works because
`post` and `wait` are free and are locked read-modify-writes, hence full
barriers. The result is `heap_used()` unchanged across a thousand frames and a
process whose address space does not grow over four thousand. The price is
stated honestly in the README: the *worker* side still takes one lock per claim
and pays 16 bytes for it on the worker's own heap, which `heap_used()` cannot
see.

---

## 12. A `[byte; N]` does not unify with `[byte]`, and a `*byte` cannot be walked — so a buffer helper has to be written once per buffer size

**Useful because** every binary protocol in Y — a pipe, a socket, a file, an
ELF section — is read and written through a byte buffer, and the natural helper
(`read_exact(fd, buf, len)`) cannot be written once. Two independent gaps close
the same door:

```y
def rd_all(fd: long, buf: [byte], off: long, n: long) -> long { ... };

let buf: [byte; 1024] = [0; 1024];
rd_all(fd, buf, 0, 64);
// 4:34: error: 'rd_all' arg 1: expected [byte], got [byte; 16]
```

```y
def rd_all(fd: long, p: *byte, n: long) -> long {
    let got = syscall(0, fd, p + n - got, ...);
};
// 4:34: error: '+' left operand: expected long, got *byte
```

So the helper has to take the fixed array **by name** — `buf: [byte; 1024]` —
and address bytes as `&buf[i]` with an index it owns. That works, and it is
what `examples/crypto-chat/wire.y` does, but it has three costs that are all
paid at once by every program with a framed protocol:

- **One copy of the helper per buffer size.** `rd_all`/`wr_all` can only ever
  mention one `N`, so a protocol with a 64-byte header buffer *and* a 1024-byte
  payload buffer needs two copies of each, and `&buf[i]` only reaches a buffer
  that is already in scope, so the helper cannot be reused across call sites
  with differently-sized buffers.
- **Every caller commits 1 KiB of stack-ish allocation whether it needs 64
  bytes.** The signature says `[byte; 1024]`, so a 40-byte handshake frame is
  handed a 1024-byte cell.
- **The size is invisible to the type checker.** A helper that says `[byte; 1024]`
  cannot be handed a `[byte; 64]`, so a size mismatch is a *compile* error rather
  than a checked argument — which is the one thing a fixed-size type is usually
  wanted for. `wire.FRAME` in that example is a single module-level constant
  precisely so nothing has to disagree about it.

Wanted — either of these, and the first is far the smaller:

```y
// a slice type parameter, or a [byte; N] that widens to [byte] at the call:
def rd_all(fd: long, buf: [byte], off: long, n: long) -> long { ... };
rd_all(fd, buf16, 0, 16);      // a [byte; 16] widens, as a str->*T does today
```

or, keeping the current shapes, pointer arithmetic so the `*byte` form becomes
usable and the fixed-array form is no longer the only door:

```y
def rd_all(fd: long, p: *byte, n: long) -> long {
    let got = 0;
    while (got < n) { let k = syscall(0, fd, p + got, n - got); ... };
    got
};
rd_all(fd, &buf[0], 16);        // one helper, any buffer
```

`&buf[i]` already yields `*byte`, and `syscall` already accepts a `*byte`, so
only `p + got` is missing — one `add` on a pointer in `native.y` and its twin.

**Costs.** Widening `[byte; N]` to `[byte]` is a conversion rule in `types.y`
plus the C twin, and it interacts with the fixed-array-is-a-value story (a
`[byte; N]` is currently stack-allocated, so widening it to a heap `ref` is a
representation decision, not only a checker one) — medium, and it wants the
same care TODO.md §1 lists for type identity. Pointer arithmetic is much
smaller: `+` and `-` on `*T` with an integer, a scale by the pointee size, and
the bounds story stays with the caller's index. Neither is a prerequisite for
anything else on this list, and neither is on it.

### What it cost `examples/crypto-chat`

Two compile errors before the shape was found, then a design constraint that
stayed for the rest of the example: `wire.FRAME` is one constant that every
frame buffer in the program obeys, `wire.TXBUF`/`RXBUF` are module-level
`[byte; 1024]` cells rather than locals, and `wire.get_bytes` takes a
`[byte; 1024]` for the same reason. `bench.y` inherits it: its three measured
loops all address `BBUF` as `[byte; 1024]`. Filed because the gap has a
one-line shape on the pointer side and a design consequence on the other.

### Environment

`refs/ycc.ref` sha256 `c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`
· both errors above are the compiler's own output on the pinned binary,
reproduced from `examples/crypto-chat`'s first draft.

### The same gap generalised past `byte`, with the costs measured

The byte-specific case above is one instance of a wider one, and the wider
form is what a caller actually hits: **a fixed `[T; N]` is not usable where
`[T]` is expected, for any `T`.**

```y
def last_of(xs: [long]) -> long {
    let i = 0;
    while (i < len(xs)) { i = i + 1 };
    xs[i - 1]
}
```

cannot be called with `HENT`, which is `let HENT: [long; 4096] = [0; 4096]`:

```
error: 'last_of' arg 0: expected [long], got [long; 4096]
```

**This is not a rare shape.** `examples/wavefunction` keeps seven
4096-element fixed arrays (`MASK`, `CNT`, `WSUM`, `HENT`, `UL_I`, `UL_M`,
`DL`) and `check.y` three more, and every cross-module helper that wanted to
range over one of them had to be written per-array or pay a copy.

Three workarounds, and what each costs:

1. **Write the helper against `[T; N]` and repeat it per length** — the same
   body four times, which is what `wavefunction` does.
2. **Pass the length separately** — `def last_of(xs: [long], n: long)` —
   which loses `len()` and pushes the bound onto the caller.
3. **Copy** — `let g: [long] = [0; 4096];` — 32 KiB of heap for a
   4096-long buffer, in a program whose whole claim is that it allocates
   nothing (`wavefunction --soak 200` measures a heap delta of **0**).

**Wanted.** A fixed `[T; N]` accepted where `[T]` is expected, at least for
reading: `len()`, indexing, iteration and `foreach` already behave
identically, so this is a widening in the checker's array arms (one `T` case
in `of_array`) rather than a new representation. If that is too loose as
stated, the narrow version is syntactic — let a parameter be declared
`xs: [long]` and bind a fixed array to it, erroring only on `+=`/`*=` through
the parameter, since those are the operations a fixed array cannot support
(ORCHESTRATOR.md §2.10).

**Costs.** Small for the widening: `types.y`'s array type test plus the
`src/c` twin, and one fixture in each direction. Medium for the narrow form —
the checker must know what it will allow through the binding, so it needs
either a separate "view of a fixed array" type or an extra flag on the
binding: a real (if small) design decision, and about half a day more.

Verified on `refs/ycc.ref` sha256
`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`
while writing `examples/wavefunction`.

---

## 13. `chacha_seal` and `chacha_open` cost 4.6 KB of arena each, so one AEAD message costs 5.3 KB for ever

**Useful because** a chat program, a TLS record layer or a file encryptor seals
messages in a loop, and the heap is an arena where nothing is ever freed
(ORCHESTRATOR.md §2.7), so every sealed message is 5.3 KB of address space that
never comes back. Three hundred thousand messages exhausts the campaign's
3.5 GiB cap — with no diagnostic, and at a rate slow enough that nobody
attributes it. The arithmetic is genuinely allocation-free; only the
scaffolding around it is not.

**Measured**, `refs/ycc.ref`, `heap_used()` either side of the loop, 2000
iterations, 57-byte plaintexts:

| loop | delta | per message |
|---|---|---|
| full: build aad, build nonce, `chacha_seal`, frame, slice, `chacha_open` | 10 616 008 | **5 308** |
| `chacha_seal` + `chacha_open` only | 9 280 000 | **4 640** |
| frame layout + payload slice only | 240 000 | **120** |

and the growth is a fixed stride, not compounding: the same loop at 4000
iterations costs exactly 2.00× the 2000-iteration figure. So the 120 B in the
last row is the caller, and the **4 640 B in the middle row is
`src/y/std/crypto.y`**.

The two loops that have to exist — `chacha20_block(key, 0, nonce)[0:32]` for
the Poly1305 one-time key, and `aead_mac_data(aad, ct)` for padding and the two
64-bit lengths — are called *twice per open*, once per seal, and each builds its
own arrays. `chacha20()` also builds a keystream array per 64-byte block. None
of that can be hoisted by the caller: the signatures are `(key, nonce, aad,
plain) -> [byte]` with no place to put scratch.

Today — there is no way to ask for a reusable context, so a caller that wants
the allocation-free path writes the AEAD itself (Poly1305 over 26-bit limbs and
ChaCha20 over four words are each a page of arithmetic) or pays:

```y
let sealed = crypto.chacha_seal(k, n, aad, plain);   // ~2.3 KB, never freed
let opened = crypto.chacha_open(k, n, aad, sealed); // ~2.3 KB, never freed
```

Wanted — a caller-supplied context, with the existing two functions kept as the
allocating convenience over it:

```y
import crypto;

let ctx = crypto.seal_ctx(k, n);          // reusable: keystream block, OTK,
//                                         // the MAC's padded input buffers
let sealed = crypto.seal_into(ctx, aad, plain);   // same bytes, no allocation
let opened = crypto.open_into(ctx, aad, sealed);  // [byte]? as today
```

The invariant worth keeping is that `seal(k, n, aad, plain)` must stay
byte-identical to `seal_into(ctx, aad, plain)` for the same inputs — an AEAD
whose two entry points can disagree is worse than a slow one.

**Costs** Contained entirely inside `src/y/std/crypto.y`: one record holding the
scratch (the 16 ChaCha state words, the Poly1305 accumulator and its partial
block, the two padded MAC buffers), plus `*_into` variants that read and write
it. No compiler work, no `src/c` twin (std modules stay Y). The design question
is only whether the context is per-key-and-nonce or per-key — per-key with the
counter and nonce threaded through is the useful one, since a caller seals a
whole conversation under one key.

### Workaround used by `examples/crypto-chat`

None that reduces it: the example sends ten messages, so it pays about 53 KB of
arena for the whole conversation and the transcript reports `heap_used()` at the
end. What it does instead is **measure and decompose** — `bench.y --bench N`
runs three loops and names the 120 B that is the example's own, so the 4 640 B
is attributed rather than guessed. Filed because the number is the difference
between a chat that runs for ever and one that quietly dies, and it is entirely
inside the standard library.

---

## 15. A function's return value is not the exit status, and nothing says so — so `main() -> long` returning 1 exits 0

**Useful because** every example with an error path needs one, and the
natural shape — a `main` that answers a status — silently answers 0. A Y
program's exit status comes from `exit(n)` and from nothing else: `main` is
not a concept the compiler has (there is no `"main"` anywhere in `src/y/`), so
`main();` at the end of a file is an ordinary call whose value is discarded.

Today, the working shape is the value handed to `exit` explicitly:

```y
def main() -> long {
    if (bad_flag) { eputs("prog: …\n"); return 2 };
    if (load() < 0) { return 1 };
    0
};
let code: long = main();
exit(code);
```

and the trap is that removing the last two lines compiles, runs, prints its
error and **exits 0**. Measured in `examples/perft` while writing it: a
malformed FEN printed nothing at all and exited 0 through two intermediate
versions that returned 1 from every error path — because the value went
nowhere. The same run also had `move_list` returning the move count and the
program exiting 5, because a *data* value had reached `exit` through a helper
that should have returned a status.

What it costs today, in an example with three or four modes: every helper on
the path to `exit()` must be written to return a status rather than its own
answer, and every caller needs `code(r)` to fold `-1` into `1` (`exit(-1)` is
255). That is four extra lines and a convention nobody would guess.

Wanted — the smallest thing that would do:

```y
// one of:
// (a) NATIVE.md: "the exit status comes from exit(n) only; a function's
//     return value is discarded" — a documentation fix, and the cheapest
// (b) a top-level `exit <expr>;` statement, or a `main` whose value the
//     runtime passes to exit_group, so the call at the bottom of the file
//     can be the program's status
```

Either removes a silent failure mode from every future example. Honest cost
estimate: (a) is a paragraph. (b) is a codegen change in the top-level emitter
— the value is already computed — plus a decision about what a `void` main
means, so it is a small afternoon, not a redesign.

Not one of the nine in the root `TODO.md`. Reproduced on
`refs/ycc.ref` sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`.

## 17. There is no `sort`, and no way to pass a comparison, so sorting twice costs sixty lines — and the pair sort cannot be expressed at all

**Useful because** ordering is the first thing almost every algorithm wants,
and Y has no way to ask for it. `examples/aoc/day05` needs two different
sorts — one over plain integers, one over `(lo, hi)` pairs — so this is not
hypothetical.

What you write today instead, and what it costs. Over plain values, a
bottom-up merge sort is the shortest thing that does not allocate per
comparison (`[0; n]` takes only a literal size, so the scratch buffer has to
be filled by a loop):

```y
def merge_step(a: [long], tmp: [long], lo: long, mid: long, e2: long) -> long {
    let i = lo; let j = mid; let k = lo;
    while (k < e2) {
        if (i < mid && (j >= e2 || a[i] <= a[j])) { tmp[k] = a[i]; i = i + 1 }
        else { tmp[k] = a[j]; j = j + 1 };
        k = k + 1;
    };
    e2 - lo
}
def msort(a: [long], tmp: [long], m: long) -> long {
    let w = 1;                              // NOT 2: a merge step may only
    while (w < m) {                         // join two runs that are each
        ...                                 // already sorted
    };
    m
}
```

Over **pairs**, there is no encoding that works: each end of a real ingredient
ID range is about 2^49, and two of them do not fit in one `long`, so the
comparison has to see both halves and that means a second hand-written merge
(`merge_pairs`) plus its own driver (`sort_pairs`). Packing the two ends into
one sortable `long` is not an option at this magnitude, and the obvious
workaround — interleave them into one `[long]` and sort the values — compiles,
produces an ascending array, gets every total right, and is **wrong**:
sorting values pulls the two smallest into a "pair". `examples/aoc/day05`
shipped that bug for one build (`144` merged segments instead of `78`, and a
part-2 answer of `256288138474184` instead of `344486348901788`); it was
caught by the permutation oracle, not by anything else, which is the whole
argument for `check_pair_permutations` living next to `sort_pairs`.

`min`/`max` are absent too, so the merge also carries a hand-written `imin`
on every iteration — the same shape as suggestion 16, one more site where a
plausible expression is silently wrong.

Wanted — `sort` on an array in place, plus a comparison form for the case
that cannot be an encoding:

```y
let a: [long] = [5, 1, 4, 1, 3, 9];
sort(a);                                    // ascending, in place
print(a);                                  // 1 1 3 4 5 9

// pairs, or anything else whose order is not a function of one value
let lo: [long] = [10, 3, 7];  let hi: [long] = [12, 9, 7];
sort_pairs(lo, hi);                         // by (lo, hi): 3-9 7-7 10-12
```

and, if a general comparator is wanted rather than a second builtin, a
function value — which the type system already has, since a `def` is a
first-class `(parameter type) -> return type`:

```y
sort_by(lo, hi, [(long, long) -> bool], by_lo_then_hi);
```

**Costs** Small for `sort`, small for `min`/`max`, moderate for a general
comparator. `sort` in place is a checker entry (one array parameter, mutating)
plus a native helper over the existing array header — no new syntax, no new
runtime representation, nothing for `src/c` beyond the matching twin the port
gate needs. `sort_pairs` is two more. A `sort_by` taking a closure is larger
only because it needs a runtime calling convention for the comparator, which
the closure layout (`[code, caps...]`) already provides; call it a day rather
than an hour, and budget a second for documenting that it allocates a
closure capture per call. `min`/`max` are one `native.y` case each and
already suggested by the shape of suggestion 16. Do **not** bundle `sort` with
suggestion 16's floored `mod`: different files, different review, and a
reader who wants one should not have to take the other.

Not one of the nine in the root `TODO.md`. Observed while writing
`examples/aoc/day05`. Verified on `refs/ycc.ref` sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`.

## 19. A fixed `[T; N]` is not usable where `[T]` is expected, so a helper cannot take a buffer

> **Duplicate of an earlier entry, kept for the record; the material has been
> folded into it.** The defect is *"A `[byte; N]` does not unify with
> `[byte]`"* (entry 12 above), which is the same rule stated for one element
> type. This entry is that rule generalised to any `T`, and everything
> unique here — the generalisation, the three workarounds with their costs,
> the `wavefunction` census of ten fixed arrays, the wanted syntax and its
> cost estimate, and the `9ce37629` verification — **now lives in entry 12
> under "The same gap generalised past `byte`, with the costs measured"**.
> Read that one; do not file this again.
>
> It was written by a different agent from the entry it restates, which is
> the second time in this campaign that two agents each grepped the ledgers
> and each missed the other's entry (the first was the `'+=' string` / byte
> pair in `BUGS.md`). The grep-before-append rule is right; it is just not
> automatic.

**What it buys.** One function can take a buffer of any fixed length. Today the
two array types are unrelated in the checker, so a helper written as

```y
def last_of(xs: [long]) -> long {
    let i = 0;
    while (i < len(xs)) { i = i + 1 };
    xs[i - 1]
}
```

cannot be called with `HENT`, which is `let HENT: [long; 4096] = [0; 4096]`:

```
error: 'last_of' arg 0: expected [long], got [long; 4096]
```

and the workaround — copying the fixed array into a growable one first — costs a
heap allocation of the whole buffer, which is exactly what the fixed arrays in
this campaign exist to avoid. This is not a rare shape: `wfc.y` keeps seven
4096-element fixed arrays (`MASK`, `CNT`, `WSUM`, `HENT`, `UL_I`, `UL_M`, `DL`)
and `check.y` keeps three more, and every cross-module helper that wanted to
range over one of them had to be written per-array or pay a copy.

**What you write today instead, and what it costs.** Either write the helper
against `[T; N]` and repeat it for every length (the same body, four times, in
`examples/wavefunction`), or take the buffer by name and pass the length
separately (`def last_of(xs: [long], n: long)` — which loses `len()` and pushes
the bound on the caller), or copy (`let g: [long] = [0; 4096]; ...` — 32 KiB on
the heap for a 4096-long buffer, in a program whose whole claim is that it
allocates nothing: `wavefunction --soak 200` measures a heap delta of **0**).

**Wanted.** A fixed `[T; N]` accepted where `[T]` is expected, at least for
reading: `len()`, indexing, iteration and `foreach` already work identically, so
this is a widening in the checker's array arms (one `T of_array` case in
`types.y`) rather than a new representation. If that is too loose as stated, the
narrow version is a syntactic one — let a parameter be declared `xs: [long]` and
bind a fixed array to it, erroring only on `+=`/`*=` through the parameter, since
those are the operations a fixed array cannot support (see
ORCHESTRATOR.md 2.10, "a fixed `[T; N]` cannot grow").

**Costs.** Small for the widening: `types.y`'s array type test plus the `src/c`
twin, one `test_port.sh` fixture in each direction. Medium for the narrow form —
the checker has to distinguish what it is going to let you do with the binding, so
it needs a separate "view of a fixed array" type or an extra flag on the binding,
which is a real (if small) design decision and half a day more.

Not one of the nine in the root `TODO.md`. Observed while writing
`examples/wavefunction`. Verified on `refs/ycc.ref` sha256
`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`.

---

## 20. A `str` built by `+` from constants inside a loop body allocates every iteration — the string arm of #7

**What it buys.** One pass in the constant folder, and every program that
assembles a line of text in a loop stops leaking. #7 measures an **array**
literal and a **record** literal in a loop body at 64 and 40 bytes an
iteration; the string case is the same shape and its table has no row for it.

**Independently measured**, `heap_used()` either side of a 20 000-iteration
loop, one binding per row, on `refs/ycc.ref` sha256
`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`:

| loop body | heap delta | per iteration |
|---|---|---|
| `let s = "abcdefghij" + "klmnopqrst";` | **960 000 B** | **48 B** |
| `let s = A + B;` (`const A`, `const B`, `+` still in the loop) | **960 000 B** | **48 B** |
| `let s = FOLDED;` (`const FOLDED = "abcdefghij" + "klmnopqrst"`) | **0 B** | **0 B** |
| `let s = "abcdefghij";` (one literal, no `+`) | **0 B** | **0 B** |

The result is twenty bytes and the cost is 48, so this is a header plus a copy,
not a per-byte charge. The third row is the whole diagnosis: **the constant
folder already folds `const FOLDED = "a" + "b"` — the machinery exists and is
not reached** when the same `+` sits in a loop body. The second row says the
literals are not the problem; the runtime `+` is. The fourth row says a bare
literal is already interned.

**What you write today instead, and what it costs.** Hoist the concatenation to
module scope — `const FOLDED = "a" + "b";` and then read `FOLDED`, measured at
**0 B an iteration**, which is what #7 recommends for arrays and records. The
cost is that the text can no longer be assembled from pieces that are only known
at run time; for that case the honest spelling is to append into a fixed byte
buffer (`sb`, `+=` on a `[byte; N]`), which is also 0 B.

**What actually bit.** `examples/hexview`'s interactive status line, which is
built on every frame:

```y
sbs("arrows/hjkl move  tab pane  0-9a-f type  m mark  [ ] marks  "
    + "/ find  n N next  o open  w write  g G ends  q quit");
```

One call, a `+` between two literals. `sbs` takes a `str`, so the concatenation
has to exist before the call, and the compiler built a fresh one every frame:
**136 bytes a frame**, 16 KB a minute, invisible in `EXPECTED` because the bytes
were identical every time. Split into two `sbs` calls the delta went to **0**.
It is the string form of the rule in `ORCHESTRATOR.md` §2.7 — "hoist every literal out of
every loop" — and it is here to say that the rule has to be widened to
*expressions that build a string from constants*, not just to literal
expressions.

**Wanted.** Nothing syntactic. The compiler's constant folder already handles the
`const` form, so this is extending it to fold `str + str` where both sides fold
to constants, in the same place literals are interned — plus the C twin.

**Costs.** Small: one extra case in the folder `native.y` already runs for
`const` initialisers and its twin, and a guard so the fold only fires when both
operands are already folded literals (so a run-time `+` keeps its current
semantics, including its length). Well under an hour, and it needs its own
matrix in `types.y` if the folder is shared with the checker's literal handling.

**Reproduction** — the whole of it, on the pinned binary:

```y
const A = "abcdefghij";
const B = "klmnopqrst";
const FOLDED = "abcdefghij" + "klmnopqrst";
def main() -> long {
    let n = 20000;
    let h0 = heap_used();
    let i = 0;
    while (i < n) { let s = A + B; i = i + 1; };
    let h1 = heap_used();
    let j = 0;
    while (j < n) { let s = FOLDED; j = j + 1; };
    print(h1 - h0, " ", h1 - h1, "\n");      // 960000 0
    0
};
exit(main())
```

(`let s` is unused, so the compiler warns; the allocation happens before the
warning would matter, and the numbers are unchanged with `s` printed.)

### Environment

`refs/ycc.ref` sha256 `9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`
· both numbers above are the compiler's own `heap_used()` on that binary, and the
per-frame figure (136 B) is `--frames N --time` from `examples/hexview`, before
and after the two-call rewrite.

## 23. `--help` should be reserved the way `y_` is, so a declared `help` cannot silently disable usage

`y_` is a reserved prefix: a `def y_thing` is emitted under its bare name
because generated code calls it by a fixed label, and the cost of a collision
is a link error with a clear name. `--help` has exactly the same shape of
problem and none of the protection.

### What it does now, silently

If a flag spec declares a long option named `help`, then `--help` is **that
option**, not a request for usage. `parse()` returns `OK` having printed no
usage, and `has("help")` is true. There is no warning at the declaration and
none at parse time, so a program that declares `help` and then calls
`parse_or_exit()` loses its usage text with no diagnostic anywhere. The
symptom is a program that appears to have no `--help` at all.

### What it buys

Every command-line program in this campaign gets its flag table from one
vendored `args.y`, so this is a decision made once per program and it is
invisible when it goes wrong. Reserving `--help` — or at minimum warning when
a spec declares it — removes a whole class of "why is there no help" report,
and it costs a program nothing: `--help` means what the user expects it to
mean, which is usage.

### What you write today, and what that costs

Declare `help` and handle it yourself, which is four lines:

```y
{ long: "help", short: "h", kind: args.BOOL, help: "show usage" }
args.init("prog", "what it does", OPTS, "");
args.parse_or_exit(argv());
if (args.has("help")) { print(args.usage()); return 0 };
```

The cost is small and it is *only* small because `has("help")` happens to be
false for a real HELP request and true for a declared one — a distinction
nothing documents. The trap is that the correct code and the code that
silently drops `--help` look identical, and both exit 0.

This cost the campaign a deferral. `test/std/args.y` is the file a
toolkit author opens first, and the behaviour was written down only in
`args_test.y` checks 6e–6h, where it is testable but where nobody reads. It
is now documented in `args.y`'s own header as well, and `args.y` was
re-vendored to all 23 folders that copy it (`c81a1460` → `cdac36da`) rather
than left as a known gap.

### Wanted

Either is enough:

```y
// A: reserved outright, like y_
const OPTS: [args.Opt] = [{ long: "help", ... }];
// error: 'help' is reserved for --help; use args.want_help() instead

// B: a warning at the declaration, which is the smaller change
// warning: args.y:12: a declared `help` makes --help an ordinary flag;
//          --help will not print usage
```

**Costs** Very small. A is a few lines in the checker's name check plus an
escape hatch, because a program that genuinely wants its own `--help` should
be able to have it — `args.want_help()` returning a bool is enough. B is a
`lint.y` warning keyed on the option's `long` field, which is a smaller diff
than A and gets 90% of the value, since the failure is always accidental.
The one real design question is which: silently changing what an existing
spec means (A) is a compatibility break, while a warning (B) is not. My
recommendation is **B first**, then A once the escape hatch exists.

### Workarounds

`test/std/args.y` documents it in the header, and `args_test.y`
checks 6e–6h pin all four statements in both directions, so a change to the
behaviour fails the suite rather than passing unnoticed.

---

## No pointer-to-integer conversion, so a syscall that takes a struct containing a user pointer cannot be issued

**Useful because** a syscall whose argument is a *struct the kernel reads* that
contains a pointer to the caller's own memory is the normal shape for every
device API that is not a file: `SND_PCM_IOCTL_WRITEI_FRAMES` takes a
`struct snd_xferi { unsigned long result; void *buf; }`, `mmap`-backed ring
buffers, `sendmsg`/`recvmsg` with `SCM_RIGHTS`, `epoll_event.data`, `struct
msghdr.msg_name`. Today `let n: long = p` where `p` is a `*byte` is a compile
error, so the pointer cannot be *stored* anywhere the kernel will read it back.

Today:

```y
// examples/audio/pcm.y -- the real thing, from ALSA's own PCM API.
// It compiles, runs, and answers -EFAULT on every device.
type Xferi = { result: long, buf: *byte };
let xfer: Xferi = { result: 0, buf: &hwbuf[0] };
xfer.result = want;
xfer.buf = &pcm_bytes[cursor];
let rc = syscall(16, dev, REQ_WRITEI, &xfer);   // rc == -14, EFAULT
```

Three things have to be true at once and none of them can be:

- the pointer must become an integer, to be written into the struct — **`*T` → `long`
  does not exist**;
- the struct's own address must be reachable as a `*byte` to hand to
  `syscall` — and `&xfer` is a `*{...}`, and `&a_record` is a pointer to the
  record's **type descriptor**, not to its fields, so a record cannot stand in
  for the struct either (measured: 40 bytes written through `&xfer` are the
  descriptor followed by zeros);
- the struct's layout must be exactly the kernel's — which it can be, with
  offset-taking accessors over a fixed `[byte; N]`, and is.

The first gap is one conversion rule. The second is the same missing piece: with
a numeric pointer, `hw32(off, value)` writes the address into a byte buffer and
the record is not needed at all.

Wanted — either of these, and the first is a few lines:

```y
let n: long = p;              // p : *byte  -- the address, as an integer
let q: *byte = 140737488355328;   // and back
```

or, if a pointer-to-integer cast is not wanted on its own, a narrow and honest
one for exactly this shape:

```y
// address of a byte, as an integer, for storing in a struct the kernel reads
def addr_of(p: *byte) -> long;
```

`str -> *T` already exists, so the *caller* side of this is not unknown
territory; what is missing is the value.

**Costs.** Small in `types.y` and its C twin: `*T` and `long` are both 64-bit
cells, so it is a reinterpretation, and the honest version needs a guard — a
`*T` is only meaningful while its referent is alive, and the value it produces
is meaningless to Y's GC and to the reader. That is the whole design question,
and it is why this is a suggestion rather than a two-line patch. It also
collides with nothing on this list: **#12** asks for `p + n` so a `*byte` can be
*walked*, which is the opposite direction (a pointer from an integer is already
reachable through `str -> *T`, and `&buf[i]` already yields `*byte`), and the two
compose rather than overlap.

### What it cost `examples/audio`

One syscalls' worth of engineering, and it is the transfer. `examples/audio`
opens a real ALSA PCM device, negotiates `hw_params` with a hand-built 608-byte
`struct snd_pcm_hw_params`, issues `SW_PARAMS`, `PREPARE` and `DRAIN` — all of
which are plain byte buffers the program fills in, and all of which work — and
then cannot push a single sample through `snd_pcm_writei`. The example ships a
`write(2)` transfer instead, which is measured to be the same ring
(`appl_ptr` advances by exactly the frames written, `hw_ptr` consumes it, and
`DRAIN` returns 0), and keeps `--transfer writei` selectable so the `-EFAULT` can
be reproduced on demand rather than believed. Nothing else in the example was
blocked: the kernel also implements `read`/`write` on `/dev/snd/pcmCxxDxx`, and
that is the route the shipped player takes.

### Environment

`refs/ycc.ref` sha256 `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3`
· `examples/audio/pcm.y`, compiles with zero warnings and the same program with
the ioctl issued from C writes normally (4 frames for 480 requested), so the
ioctl and the struct are right and only the address cannot be expressed.

---

## Revision — the same six proposals, combined into four modules, with the API as function headers only

**IMPLEMENTED.** `std/tui` (the terminal and surface halves), `std/args`,
`std/test` and `std/json` are in `src/y/std/`, with self-test suites under
`test/std/` and fixtures under `test/y/native/`; the numbered items that asked
for them (1, 3, 25, 26, 27, 28, 29, 30) have been removed from this ledger.
What follows is the API the campaign agreed, which is what shipped.

The six entries above are right about the evidence and wrong about the module
boundaries. Three corrections, all of them from measuring rather than taste.

### Correction 1: `time.y` is two thirds duplication, and the missing third is one function

`rt.y` **already has the clock**:

```
def y_clock_us() -> long
def y_time_us() -> long
def y_sleep(ms: long) -> long
```

So `time.y`'s `now_us` and `now_ms` re-implement what the runtime unit
already provides, in 19–20 folders. What `rt` does **not** have is
sub-millisecond sleep: `y_sleep` takes whole **milliseconds** and splits them
into `ts[0] = m / 1000; ts[1] = (m % 1000) * 1000000`. A microsecond-precision
nap cannot be expressed, and `ORCHESTRATOR.md` §0d asks for "sub-millisecond
pacing" by name. `badapple` re-implemented `nap_us` three separate times, once
per pipeline, rather than share it.

So: **one function is the whole gap.**

```
def y_nap_us(us: long) -> long
```

### Correction 2: `term`, `fb` and the pacer are one module, not three

`term.y` sets the terminal up, `fb.y` draws the cell grid into it, and the
`Pacer`/`Fps` types exist only to pace the frame loop that connects them. Folding
them together gives **one module of 128 functions** and removes the question of
which of the three a program needs. It is one module because the dependency is
not optional: `fb.flush_diff` is the per-row diff, `term` is the tty it diffs
into, and a frame loop needs the pacer to call them at a rate.

**The measurement that justifies merging the other two:** exactly **one** folder
(`perft`, a threaded chess move generator) uses the clock without a terminal.
Everything else that vendors `time.y` also vendors `term.y` or `fb.y`. That
one user is served by `rt`'s existing `y_clock_us` and `y_sleep`.

### Correction 3: `args` and `test` stay separate, and here is the proof for `test`

`args` has **six users with no `term.y` at all** (`audio`, `crypto-chat`,
`perft`, `rest-client`, `toolkit-cli`, `weather`), so it shares nothing with a UI
module.

`test` earns its own module on stronger grounds than duplication. Across the
corpus **`ck` has four mutually incompatible signatures**:

```
def ck(cond: bool, what: str) -> bool                 sandfall
def ck(got: long, want: long, what: str) -> bool      hexview
def ck(name: str, ok: bool, detail: str)              audio, x11
def ck(name: str, ok: bool, detail: str) -> void      wavefunction
```

The third argument is a `bool` in one, a `str` in the next two, and a `long`
in `hexview`'s — where `ck` is not a boolean assertion at all but an equality
one, so `ck(a, b, "name")` reads as *pass* in `hexview` and as *assert a is
truthy* anywhere else, with no type error to stop it. `ck_eq` has the same
split, differing only in whether it returns `long` or `void`. A shared module
has to pick one and reject the rest at compile time, which is the entire point.

### The combined set

| module | absorbs | folders it deletes from |
|---|---|---|
| **`std/tui`** | `term` + `fb` + `Pacer`/`Fps` + `sink`/`textout` | 18–20 |
| **`rt` += `y_nap_us`** | the non-duplicated third of `time.y` | — (one function) |
| **`std/args`** | `args` | 25 |
| **`std/test`** | `ck`/`ck_eq`/`ck_near` + the report line | 8 |
| **`std/json`** | 8 additions to the unit that exists | 4 hand-rolled parsers |
| **`std/random`** | the delta to `TODO.md` #4 | 3 |

Six proposals become four modules plus one function and two extensions.

---

# The proposed API, as function headers only

Internal helpers are dropped. Names that exist only to let the module call its
own internals (`ar_*`, `rd32`/`wr32`, `buf_*`, `emit_*`, `esc_*`, `sgr_*`) are
not part of a std unit's surface.

## `std/tui` — terminal, surface, frames, pacing, capture

```
def is_tty(fd: long) -> bool
def raw_mode() -> bool
def cooked_mode()
def active() -> bool
def restore()
def restore_exit(code: long)
def arm_watchdog() -> bool
def size() -> Size
def set_size(rows: long, cols: long) -> bool

def read_key() -> long
def read_key_timeout(ms: long) -> long
def push_key(k: long)
def pop_key() -> long
def key_pending() -> long

def enter_screen()
def leave_screen()
def enter_alt_screen()
def leave_alt_screen()
def hide_cursor()
def show_cursor()
def clear_screen()
def home()
def cursor_to(row: long, col: long)

def rgb(r: long, g: long, b: long) -> long
def r_of(c: long) -> long
def g_of(c: long) -> long
def b_of(c: long) -> long
def grey(v: long) -> long
def lerp_rgb(a: long, b: long, t: long) -> long

def new(rows: long, cols: long) -> Surface
def resize(s: Surface, rows: long, cols: long) -> Surface
def rows(s: Surface) -> long
def cols(s: Surface) -> long
def clear(s: Surface, bg: long) -> long
def fill(s: Surface, cp: long, fg: long, bg: long) -> long
def put(s: Surface, row: long, col: long, cp: long, fg: long, bg: long) -> long
def put_skip(s: Surface, row: long, col: long, cp: long, fg: long, bg: long) -> long
def get(s: Surface, row: long, col: long) -> long
def key_at(s: Surface, row: long, col: long) -> long
def text(s: Surface, row: long, col: long, t: str, fg: long, bg: long) -> long
def hline(s: Surface, row: long, col: long, n: long, cp: long, fg: long, bg: long) -> long
def vline(s: Surface, row: long, col: long, n: long, cp: long, fg: long, bg: long) -> long
def rect(s: Surface, row: long, col: long, h: long, w: long, cp: long, fg: long, bg: long) -> long
def fill_rect(s: Surface, row: long, col: long, h: long, w: long, cp: long, fg: long, bg: long) -> long
def blit(dst: Surface, src: Surface, srow: long, scol: long, drow: long, dcol: long, h: long, w: long) -> long

def utf8_len(cp: long) -> long
def utf8_byte(cp: long, i: long) -> long
def width_of(cp: long) -> long

def ramp_index(v: long, n: long, levels: long) -> long
def shade(v: long, n: long) -> long
def shade_ascii(v: long, n: long) -> long
def shade_blocks(v: long, n: long) -> long
def shade_half(v: long, n: long) -> long
def shade_braille(v: long, n: long) -> long
def shade_len(mode: long) -> long
def braille(vs: [long], thresh: long) -> long
def braille_cp(mask: long) -> long
def braille_put(s: Surface, row: long, col: long, vs: [long], thresh: long, fg: long, bg: long) -> long

def begin_frame()
def cell_same(s: Surface, i: long) -> bool
def cell_commit(s: Surface, i: long)
def flush(s: Surface) -> long
def flush_diff(s: Surface) -> long
def end_frame(s: Surface) -> long

def capture_on()
def capture_off()
def capture_reset()
def capture_len() -> long
def capture_byte(i: long) -> long
def capture_str(from: long, to: long) -> str
def capture_checksum() -> long
def grid_digest(s: Surface) -> long
def grid_text(s: Surface) -> str

def pacer_new(fps: long) -> Pacer
def pacer_start(p: Pacer)
def pacer_next(p: Pacer) -> long
def pacer_period_us(p: Pacer) -> long
def pacer_frames(p: Pacer) -> long
def pacer_dropped(p: Pacer) -> long
def pacer_lag_us(p: Pacer) -> long
def fps_new(win_us: long = 500000) -> Fps
def fps_tick(f: Fps)
def fps_x100(f: Fps) -> long
def fps_frames(f: Fps) -> long
def fps_avg_x100(f: Fps) -> long
def fps_line(f: Fps) -> str

type Size = { rows: long, cols: long };
type Surface = { rows: long, cols: long, cp: [long], fg: [byte], bg: [byte], key: [long] };
type Pacer = { period_us: long, sched: long, frames: long, dropped: long, last: long };
type Fps = { win_us: long, t_beg: long, t0: long, f0: long, n: long, x100: long };
```

`grid_text` **returns a `str`** where `sink.y` wrote into the capture buffer and
returned nothing; nine folders wanted the same function and each wrote it
differently. One signature, one behaviour.

## `rt` — the one addition

```
def y_nap_us(us: long) -> long
```

`y_clock_us`, `y_time_us` and `y_sleep` already exist and are unchanged. This is
the whole proposal: `y_sleep` takes whole milliseconds.

## `std/args`

```
type Opt = { long: str, short: str, kind: long, help: str };

def init(prog: str, desc: str, spec: [Opt], tail: str = "")
def parse(toks: [str]) -> long
def parse_or_exit(toks: [str])
def has(name: str) -> bool
def get_str(name: str, dflt: str) -> str
def get_long(name: str, dflt: long) -> long
def positional() -> [str]
def nopts() -> long
def usage() -> str
def print_usage()
def errmsg() -> str
```

`kind: 0` is a flag with no value, `1` takes one.

## `std/test`

```
def ck(name: str, ok: bool, detail: str) -> bool
def ck_eq(name: str, got: long, want: long) -> bool
def ck_near(name: str, got: long, want: long, tol: long) -> bool
def ck_str(name: str, got: str, want: str) -> bool
def ck_bytes(name: str, got: [byte], want: [byte]) -> bool
def group(name: str)
def checks() -> long
def failures() -> long
def report() -> long
```

**One `ck`, and it returns `bool`.** The corpus has four incompatible forms —
`sandfall`, `hexview`, `audio` and `x11` with `wavefunction` respectively — and
the second of these is not an assertion at all but an equality check wearing
the name, so `ck(a, b, "name")` is equality there and truthiness everywhere
else:

```
def ck(cond: bool, what: str) -> bool
def ck(got: long, want: long, what: str) -> bool
def ck(name: str, ok: bool, detail: str)
def ck(name: str, ok: bool, detail: str) -> void
```

`ck_str` and `ck_bytes` exist because there are no generics, so a `ck_eq` over
`str` cannot be the same function.

## `std/json` — the eight additions

The unit already has 24 functions; these are what it is missing, and every one
is already written and working in the folder that needs it.

```
def parse_bytes(b: [byte; N], len: long) -> Val?
def get_long(o: Val, key: str, dflt: long) -> long
def get_str(o: Val, key: str, dflt: str) -> str
def get_arr(o: Val, key: str) -> [Val]?
def pretty(v: Val, indent: long, sorted: bool) -> str
def same(a: Val, b: Val) -> bool
def node_count(v: Val) -> long
def max_depth(v: Val) -> long
```

## `std/random` — the delta to `TODO.md` #4

```
def seed(v: long)
def next() -> long
def below(n: long) -> long
def range(lo: long, hi: long) -> long
def chance(pct: long) -> bool
def state() -> long
def set_state(v: long)
```

splitmix64. `below` rejects rather than using `%`, because `x % n` is biased for
every `n` that is not a power of two. `state`/`set_state` are what `TODO.md` #4's
sketch lacks: it says a failing case is worthless if it cannot be replayed, but
can only seed from the start — `mud/rnd.y` has them because a MUD bug reproduces
only from the divergence point, not from tick 0.
