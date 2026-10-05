# List of all bugs of YCC
Only include bugs of the compiler, make sure to include minimal reproduction.

This ledger is for the **examples** campaign: findings made while
writing programs under `examples/`. It is separate from the
compiler's own ledger at the repo root. The protocol — when a
finding is a bug versus a suggestion, the entry template, the
dedup rule — is in `examples/ORCHESTRATOR.md` §8.

A bug is something Y gets **wrong**. A missing feature is not a
bug; it goes in `SUGGESTIONS.md`. The absence of `sqrt` or of a
termios helper is a suggestion, never a bug. When you are unsure,
it is a suggestion.

Before appending: grep this file for the diagnostic text, re-read
any matching entry in case it is already fixed, and never renumber
what is here.

***INSTRUCTIONS WHEN FINISH*** remove the BUG item from this file when it has been completed

---

## A second `Response.text()` is silently empty, and `fs.write_file` then writes a 0-byte file and returns true

`http.Response`'s `text()` and `read(n)` are **read-once**: the body
is drained from the socket, so every call after the first returns an
empty value. Nothing says so at the point of use — the module's own
doc comment describes them as "two functions that read the body",
and the presence of a `size` field invites the reading that the body
can be inspected more than once.

The failure is silent and it composes into data loss: passing the
second, empty result to `fs.write_file` **creates an empty file and
returns `true`**, so the program reports success while having written
nothing. A program that parses a response and then also saves or
re-checks it loses the data with no diagnostic anywhere.

Found while setting up the campaign's web/API examples, where the
natural shape is to read a body once to parse it and once to show it.

### Minimal reproduction

Hermetic — the program starts and stops its own server, so this needs
no network and no third-party site:

```y
import net;
import http;
import fs;

def handler(req: str) -> str { net.http_response(200, "hello body\n") };

let pid = fork { net.listen_http(18197, handler); 0 };
sleep(400);

let r = http.get("http://127.0.0.1:18197/", { timeout: 5 });
print("first  text() = ", r.text().trim());
print("second text() = [", r.text().trim(), "]");
print("write_file returned ", fs.write_file("/tmp/opencode/body.txt", r.text()));
syscall(62, pid, 15);
wait_pid(pid);
```

```
first  text() = hello body
second text() = []
write_file returned true
```

```
$ ls -la /tmp/opencode/body.txt
-rw-r--r-- 1 yun yun 0 body.txt
```

An 11-byte body became a 0-byte file, and `write_file` said `true`.

### Verified matrix

**Fails** — a second read of the same response is empty:

```y
let r = http.get("http://127.0.0.1:18197/", { timeout: 5 });
let a = r.text();
let b = r.text();
print(len(a), " ", len(b));     // 11  0 — b should be 11
```

**Fails** — mixing the two readers, in either order. `read(0)` means
"all the rest", so whichever call goes second gets only a remainder:

```y
let r = http.get(url, { timeout: 5 });
let chunk = r.read(100);
let rest  = r.text();
print(len(chunk), " ", len(rest));   // 11  0
```

```y
let r = http.get(url, { timeout: 5 });
let all = r.text();
let more = r.read(100);
print(len(all), " ", len(more));    // 11  0
```

**Fails** — a second `read(n)` returns only what is *left*, not
nothing, so the caller silently gets a truncated body:

```y
let r = http.get(url, { timeout: 5 });
print(len(r.read(6)), " ", len(r.read(6)));   // 6  5  — an 11-byte body
```

This is the more insidious form: nothing is empty, so nothing looks
wrong, but the second read is a fragment. A third call returns 0.
It is `text()` (which is `read(0)`, "all the rest") that reliably
goes empty on the second call.

**Passes** — the ordinary single-read path is fine:

```y
let r = http.get(url, { timeout: 5 });
let all = r.text();
print(len(all) > 0);              // true
print(len(r.read(0)));            // 0 — the documented "at its end"
```

In these snippets `url` stands for the same loopback
`"http://127.0.0.1:18197/"` with the handler above; the byte counts
are the 11-byte `"hello body\n"`. Against a real page the first read
is its length — 8193 bytes for `adventofcode.com/2025/day/1` — and
the second is still 0.

**Note on `size`** — *not* part of this bug, and it needs no filing:
`size` is documented as "Content-Length, or -1"
(`src/y/std/http.y:23`), so a chunked response legitimately reports
`-1`. It is easy to misread as a bug while chasing this one.

### Practical guard until this is fixed

Check `r.err` and `r.status` **before** trusting the body, and read
the body **exactly once** into a variable:

```
let r = http.get(url, { timeout: 10 });
if (r.err != "" || r.status != 200) { /* report and stop */ };
let body = r.text();          // once, into a variable
```

This matters more than it looks: a failed connection also yields an
*empty* body rather than an error at the point of use. Observed while
testing this repro — when the port was still held by a previous run,
the child could not bind, and the parent got `first text() = ` with
no complaint. (`net.listen_http` reports the bind failure and exits
the child, per `src/y/std/net.y:67-76`, but the parent's `text()` is
still empty.)

### Cause

`src/y/std/http.y:415-424` — `text` is defined as
`from_bytes(read(0))`, and `read` consumes the `Body` on the link,
advancing `b.left` and setting `b.done`. There is no buffering of the
consumed body and no "already drained" signal, so a repeat call reads
a link that has nothing left and yields `[]`.

### Environment

`refs/ycc.ref` sha256 d459af4f08cfffc7fd89a60c6b27fa67e2f3a02fa773fc4d3130120667203cc3
· deterministic across 5 runs · reproduced identically against a
loopback server and against `https://adventofcode.com/2025/day/1`
(8193 bytes, then 0)

### Suggested shape of a fix (for whoever takes it)

Any one of these removes the hazard; the first is the smallest:

- **Cache the drained body in the `Response`** and have `read`/`text`
  serve from it once the link is exhausted, making both idempotent.
- **Or make it explicit**: return a distinguishable "already
  consumed" signal instead of an empty value, so a second `text()` is
  a visible mistake rather than a silent one.
- **At minimum, document it**, in the `Response` doc comment and at
  `text`, that the body is read-once and a second call returns empty.
  That alone would have prevented the bug this was found through.

---

## `'a'` is not a character literal — `c'a'` is — and the second bare apostrophe in a file replaces a positional error with a position-less `error: unterminated string literal`

Y spells a character literal **`c'a'`** (and a byte-string `b'a'`, an
f-string `f"..."`). A **bare** `'a'` is not the same thing and not valid
syntax. The diagnostics for it are the problem:

* **one** bare apostrophe pair gets a positional error at the quote —
  `1:15: error: expected an expression, got '''` — which is fair;
* **two** of them anywhere in the file get **`error: unterminated string
  literal` with no line, no column and no source position at all**, and
  that message names a fault the source does not have (all three
  apostrophes are balanced, and `b'c'` in the source — the `b` immediately
  followed by the second `'` — is what the lexer latches onto).

Neither message says that the feature exists under a different spelling,
so the natural first guess ("this is a quoting problem, add a closing
quote" / "my quotes are unbalanced") is wrong in both cases, and the
second form gives the reader nothing to search for.

This is not an exotic corner. `'x'` is how a character literal is spelled
in C, Python, Rust and Go, so it is the mistake a reader of this tree
makes first — including an agent writing an interactive program that
compares keypresses against `k == 'q'`.

### Minimal reproduction

```y
let x = 'a' + 'b';
```

```
$ refs/ycc.ref min.y -o min
error: unterminated string literal
$ echo $?
1
```

Three balanced apostrophes, and no position. Swap in the correct spelling
and it is a two-line program that runs:

```y
let x = c'a' + c'b';
print(x);              // ab
```

### Verified matrix

**Fails** — a bare apostrophe pair, whenever a later `b` or `c` word is
followed by another apostrophe (that is what the lexer commits to, and
then scans for a closing quote that is not there):

```y
let x = 'a' + 'b';              // error: unterminated string literal   (no position)
let y: long = 'b';              // error: unterminated string literal   (no position)
let xs: [str] = ['a', 'b'];     // error: unterminated string literal   (no position)
puts('a'); puts('b');           // error: unterminated string literal   (no position)
'a' 'b'                         // error: unterminated string literal   (no position)
let cc = c'a'; let y: long = 'b';   // error: unterminated string literal (no position)
```

**Degrades** — a single bare apostrophe pair does get a position, but a
message about the quote rather than about the missing `c`:

```y
let x: long = 'a';
// 1:15: error: expected an expression, got '''
// 1:16: error: expected ';', got 'a'

let xs: [str] = ['a'];
// 1:18: error: expected an expression, got '''
// 1:19: error: unexpected 'a' (expected ',' or ']')

if (113 == 'q') { print("x"); }
// 1:13: error: expected ')', got 'q'      <-- a token the source does not contain
```

**Passes** — the correct spelling, at every type the language offers. A
character literal is a `byte`, so it needs an annotation to become a
`long` (`byte` -> `long` is a legal conversion), and it compares against
a `long` directly:

```y
let q: long = c'q';            // 113
if (k == c'q') { ... };        // compares against a long: fine
let nl = c'\n';                // 10
let bs = c'\\';                // 92
let s = "q";                   // a str, not a byte
let xs: [str] = [c'a'];        // FAIL: [byte] does not unify with [str]
```

**Passes** — an apostrophe in a comment or inside a double-quoted string,
which is where the examples' prose is full of them:

```y
// the caller's palette, and Y's heap is an arena
let s = "it's fine";
```

### Cause

`src/y/lexer.y:646-653` — the character-literal arm is keyed on the
*previous word*, not on the character at hand:

```
} else if (word == "c" && src[i:i + 1] == "'") {
```

and `src/y/lexer.y:637-642` does the same for `b'...'`. In
`let y: long = 'b';` the lexer reaches the apostrophe, finds the previous
word was `long`, and falls through to the "character no token starts
with" arm at `src/y/lexer.y:750-757`, which emits an `op` token holding
`'`. The *next* iteration reads `b` as a word, sees that the character
after it is `'`, and takes the byte-string arm — `lex_quoted` from
`src/y/lexer.y:80`, which scans to end of file and calls
`puts("error: unterminated string literal"); exit(1)` at
`src/y/lexer.y:104`, which is why the message carries no position: that
`puts` is on the lexer's own top-level path.

So one stray apostrophe produces a parser error that points at itself and
two produce a fatal lexer error that points nowhere. A guard in the
byte-string/char-literal arms — the same shape the `0x` arm uses at
`src/y/lexer.y:531-538` for a prefix with no digits, where it reports
once, where the literal starts — would keep the positional message, and
naming the `c`/`b` prefix in it would turn the mistake into a one-line
fix.

### Environment

`refs/ycc.ref` sha256 `63a4c3d0691dea43542341c56bc65779f6323646cfcb4d9c65c5ed0503b318bc`
· deterministic across 5 runs

**Note for the ledger keeper**: `refs/ycc.ref` has been reblessed since
the first entry above was filed (that one records
`d459af4f08cfffc7…`, the second `fcdae3ccbd5877…`), so a repro that
stopped working against an older hash is worth re-checking against the
current one before it is called fixed.

### Impact on the examples campaign, and the workaround

`cube` compares three keypresses against character literals, so it hit
this on the first attempt. It routes around it by spelling them the way
Y does — `const K_Q: long = c'q';` — with the explicit `long`
annotation, which is the only bridge from a `byte` to a whole number.
The example then compiles clean and the interaction works.

---

## A `str +=` in a value-used position makes its whole loop O(n²) in heap — one missing semicolon turns 1.2 MB of output into 1.2 GB of allocation

`NATIVE.md` ("Owned strings") documents that an append statement
`gen_sappend` is emitted **only in discarded positions** — `gen_stmt`,
`gen_discard` — and that "a value-used `{ s += t }` keeps the plain
`s = s + t`". That desugaring is fine on its own, but **inside a loop it
silently destroys the amortised growth of every other append in the same
loop**: the value-used site allocates a fresh exactly-sized buffer each
iteration, and the in-place appends around it then have to grow from an
exactly-sized buffer every time. The documented cost — "10 000 one-byte
appends: 50 MB of heap … → 23 KB" — becomes **1.2 GB for 10 000
iterations producing 120 000 bytes**, and the process dies on the
campaign's 3.5 GiB cap.

The output is byte-identical. Only the memory is wrong, which is what
makes it worth filing: nothing crashes, nothing is miscompiled, and a
golden-file gate passes for ever.

Adding the missing `;` — which moves the append from a value-used
position to a discarded one — turns **1 200 519 984 bytes into 262 216**
for the same output, a factor of **4 580**. There is a one-character fix
and it is not discoverable from the diagnostic, because there is no
diagnostic.

### Minimal reproduction

```y
// repro.y -- no imports, no toolkit, no std module.
def n1(n: long) -> str {
    let s = "";
    let i = 0;
    while (i < n) {
        s += "abcdefgh";
        if (i % 2 == 0) { s += "ijklmnop" }     // <-- no ';' : VALUE-USED
        i = i + 1
    };
    s
};

def sum8(s: str) -> long {
    let i = 0; let t = 0;
    while (i < len(s)) { t = t + byte_at(s, i); i = i + 1 };
    t
};

def main() {
    let a = argv();
    let n = 10000;
    if (len(a) > 1) { n = tonum(a[1]); };
    let h = heap_used();
    let out = n1(n);
    print("heap=" + tostring(heap_used() - h) + " out=" + tostring(len(out)) +
          " sum=" + tostring(sum8(out)));
};

main();
```

Builds with **zero warnings** on the pinned compiler. Run:

```
$ (ulimit -S -v 3670016; refs/ycc.ref repro.y -o repro) </dev/null
$ (ulimit -S -v 3670016; ./repro) </dev/null
heap=1200519984 out=120000 sum=12380000
```

**120 KB of output costs 1.2 GB of heap**, and one more doubling kills it:

```
$ (ulimit -S -v 3670016; ./repro 20000) </dev/null
runtime error: out of memory
exit 1
$ (ulimit -S -v 3670016; ./repro 40000) </dev/null
runtime error: out of memory
exit 1
```

and the one-character fix, `;` added, same output byte for byte:

```
$ (ulimit -S -v 3670016; ./repro_fixed) </dev/null
heap=262216 out=120000 sum=12380000
```

**4 580× less heap for the same bytes.**

### Verified matrix

Four loops, same output, same machine, `heap_used()` deltas. **Case 2 is
the only difference that matters: a `;`.**

| n | output | **case 1** value-used, `while` | **case 2** same + `;` | **case 3** value-used is the only append | **case 4** value-used, `for` loop |
|---|---|---|---|---|---|
| 1 250 |  15 000 B |    18 815 208 |        **33 040** |     6 285 224 |    18 815 208 |
| 2 500 |  30 000 B |    75 130 208 |        **65 816** |    25 070 224 |    75 130 208 |
| 5 000 |  60 000 B |   300 260 208 |       **131 360** |   100 140 224 |   300 260 208 |
| 10 000 | 120 000 B | 1 200 520 208 |       **262 440** |   400 280 224 | 1 200 520 208 |
| 20 000 | 240 000 B | out of memory |       **524 592** | 1 600 560 224 | out of memory |
| 40 000 | 480 000 B | out of memory |     **1 048 888** | out of memory | out of memory |
| 80 000 | 960 000 B | out of memory |     **2 097 472** | — | — |
| 160 000 | 1 920 000 B | — |         **4 194 408** | — | — |

(`repro` reports 1 200 519 984 for n = 10 000 and the four-loop harness above
reports 1 200 520 208: a 224-byte difference from one extra call frame in
the harness. Both are the same quadratic; the harness numbers are the
ones in the table because all four columns come from one run.)

Every failing column is **exactly 4× per doubling** — quadratic. The one
passing column is exactly 2× — amortised, as documented. The byte sum of
the output is identical in all of them (12 380 000 at n = 10 000), so the
output is not the thing that is wrong.

**What passes, and why it matters for the fix:**

| form | result |
|---|---|
| `s += t;` (discarded position, trailing `;`) | amortised, as documented |
| `s += t` as a **statement** in a loop body | amortised |
| `let _ = s + t` (never written) | fine — the buffer is never replaced |
| accumulating into a **`[byte]`** array with `+=` | amortised; array growth is capacity doubling, with no ownership cell involved |
| the value-used append with **no other append in the loop** (case 3) | still quadratic — one such site is enough |

**Where the two code paths diverge**, from `refs/ycc.ref -S repro.y`:
the discarded-position append pins the ownership cell and calls
`y_str_app`:

```
        mov %rax, -8(%rbp)                  ; seeded = true
        mov yg_0_s$5(%rip), %rax            ; s        <- gen_id: this read clears c
        push %rax
        mov ygo_0_s$5(%rip), %rdx           ; c
        cmp %rdx, %rax
        sete %al
        movzbq %al, %rax
        mov %rax, ygo_0_s$5(%rip)           ; c := (c == s)
        lea ystr_9(%rip), %rax              ; t
        push %rax
        mov ygo_0_s$5(%rip), %rax
        push %rax
        call y_str_app                      ; in place when c is 1
        mov %rax, yg_0_s$5(%rip)            ; s = result
        mov %rax, ygo_0_s$5(%rip)           ; c = result
```

while the value-used one clears the cell and never sets it again:

```
        xor %eax, %eax
        xor %eax, %eax
        mov %rax, ygo_0_s$5(%rip)           ; c = 0   <- ownership dropped here
        mov yg_0_s$5(%rip), %rax
        push %rax
        call yfn_2_f$3                      ; t
        push %rax
        call y_str_cat                      ; s = s + t, an EXACT copy
        ...
        mov %rax, -72(%rbp)
        mov -72(%rbp), %rax
        mov %rax, ygo_0_s$5(%rip)           ; c = the new (exactly sized) buffer
        mov -72(%rbp), %rax
        mov %rax, yg_0_s$5(%rip)            ; s = the new buffer
```

The last two instructions do re-establish `c`, so the loop's *next*
iteration starts owned — but the buffer it now owns has **zero spare
capacity**, because `y_str_cat` allocates exactly `len(s) + len(t)`. The
in-place append at the top of the body therefore has to reallocate on the
very next iteration, from an exactly-sized base, every time. That is the
whole of it: nothing is corrupted, and the capacity policy that is
supposed to make this amortised never gets to double.

A fix belongs in `gen_sappend`'s value-used case — growing the buffer
with the same doubling policy `y_str_app` uses, instead of `y_str_cat` —
or in a lint warning, since a semicolon is all it takes at the source
level and there is currently nothing to tell a reader that.

### How this was found, and what it cost

It was found by the acceptance gate, not by a test: a JSON pretty-printer
in `examples/toolkit-cli` reformatting a **130 KB** document consumed
2.7 GB and died on the cap. Its emitter recursed; making the recursion
iterative did not help, because the value-used append was still there.
The emitter now accumulates into a `[byte]` (see the WORKAROUND note in
`examples/toolkit-cli/jsonval.y`, above `render()`), which sidesteps the
ownership cell entirely and is linear: the same 7.5 MB document now emits
in 201 ms with a peak heap of 624 840 312 bytes, against a parse that
alone costs 156 797 864.

### Environment

`refs/ycc.ref` sha256
c53cc41524a7baa2de88faf5e2c9d006845ab5fa7a1b70edc53f9df6631
· deterministic across runs (every number above reproduced on three
consecutive runs; `heap_used()` is a byte count off the bump allocator,
so it is exact, not a sample)

---

## An apostrophe inside an f-string is charged to the enclosing call: `puts takes exactly 1 argument`

A `str` literal written with single quotes inside an `f"..."` field ends
the f-string at the apostrophe, and the parser then reports what is left
over **against the call that contains it**. The first message names the
call's arity, and the call's arity is not wrong:

```y
puts(f"[{'a'}]");        // one argument, passed.  The error says otherwise.
```
```
1:5: error: puts takes exactly 1 argument
1:11: error: expected ';', got 'a'
```

The reader's first move is to look at `puts` — which takes one argument,
receives one argument, and is not the problem. The problem is one
character three columns away. This is the same apostrophe mistake as the
entry above ("`'a'` is not a character literal"), but the diagnostic is
worse there: outside an f-string the quote at least gets its own message
at its own position, and inside one it borrows a message that points
somewhere else entirely.

It is not an exotic corner either. `f"{name:<20}"` is the obvious way to
write a padded column, and the obvious way to fill it in is a literal --
`f"{'route':<20}"` is what a reader coming from C, Python or Rust writes.

### Minimal reproduction

```y
puts(f"[{'a'}]");
```
```
$ refs/ycc.ref repro.y -o repro
1:5: error: puts takes exactly 1 argument
1:11: error: expected ';', got 'a'
$ echo $?
1
```

Both lines go to **stdout**, not stderr, and are byte-identical over
three consecutive runs.

### Verified matrix

**Fails** — one argument, wrongly accused of arity. Both messages are
about the call, neither about the quote:

```y
puts(f"[{'a'}]");
// 1:5:  error: puts takes exactly 1 argument
// 1:11: error: expected ';', got 'a'

def tag(t: str) -> str { "[" + t + "]" };
let s = tag(f"[{'a'}]");
// 2:12: error: 'tag' takes 1 args, got 2
// 2:18: error: expected ';', got 'a'
```

**Fails** — the same mistake without a call: still wrong, at least the
position is inside the f-string, and the token named (`a`) is text the
reader can see:

```y
print(f"[{'a'}]");
// 1:12: error: expected ')', got 'a'

let s: str = f"[{'a'}]";
// 1:19: error: expected ')', got 'a'

let n = 42;
let s = f"n={n} name={'bob'} end";
// 2:24: error: expected ')', got 'bob'
```

**Passes** — double quotes inside the field. The feature works; only the
C/Rust spelling of the literal is rejected:

```y
puts(f"[{"a"}]");         // [a]
```

**Passes** — the real character literal, and a variable:

```y
puts(f"[{c'a'}]");        // [97]   (a byte, so it prints as a number)
let t = "a";
puts(f"[{t}]");           // [a]
```

**Passes** — an apostrophe in a comment or in a double-quoted string
(as the entry above records):

```y
// the caller's palette, and Y's heap is an arena
let s = "it's fine";
```

### Workaround

Use double quotes for a literal inside an f-string (`f"[{"a"}]"`, or
`f"{"route":<20}"`), or hoist the string into a `let` and interpolate
the variable. `examples/httpsrv` writes its own `padl`/`padr` helpers for
table headers rather than `f"{'route':<20}"`, which is the shape this
diagnostic pushes you into; see the header comment of
`examples/httpsrv/httpsrv.y`.

### Environment

`refs/ycc.ref` sha256
c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
· deterministic across 3 runs (exit 1 every time)

---

## A bare `return;` is rejected with a message naming a type the source does not contain, and never says what to write instead

A `def` with no written return type takes its return type from the **end of its
body**.  So a `return;` — which is a *void* expression — is accepted or rejected
depending on whether the last statement happens to produce a value, and when it
is rejected the message quotes the type of that last statement.  The type is
named as though the programmer had written it, the source contains no such
annotation, and nothing in the message says that the fix is to write `-> void` —
which is one word, and which the checker already knows how to suggest
elsewhere ("`'f' is used before its return type is known (annotate it)`").

This is a diagnostic that misdescribes the source, which is why it is filed here
rather than as a suggestion: the rule underneath is defensible (a body that ends
in a value has a return type, and a void `return` disagrees with it), but the
message sends the reader looking for a `long` that is not there.

### Minimal reproduction

One line, no variables, no calls:

```y
def f() { return; 0 };
print(f());
```

```
$ refs/ycc.ref m1.y -o m1
1:11: error: 'return': expected long, got void (the return type is inferred from the end of the body)
$ echo $?
1
```

The `long` comes from the literal `0`.  There is no `long` anywhere in the
program.

### Verified matrix

**Rejected** — whenever the body's tail produces a value, and the message quotes
*that* value's type:

```y
def f() { return; 0 };              // expected long,  got void
def f() { return; "" };             // expected str,   got void
def f() { return; 0.5 };            // expected float, got void
def f() { if (true) { return; }; 0 };   // expected long, got void
```

**Accepted** — the identical `return;`, once the tail is void:

```y
def f() { return; };                // no tail at all
def f() { print(0) };               // a void tail: print(x) is a statement
def f() { if (true) { return; }; print(0) };
def f() -> void { return; };        // the fix, written out
def f() -> void { if (true) { return; }; print(0) };
```

**Accepted** — a `return` that carries a value, next to a tail of the same type,
with the type written or inferred:

```y
def f() { if (true) { return 1; }; 0 };      // inferred long
def f() -> long { if (true) { return 1; }; 0 };
def f() -> bool { if (true) { return true; }; false };
```

So `return;` is not the problem — a `return;` that does not agree with an
inferred non-void tail is, and the diagnostic says nothing about the spelling
that resolves it.

### Cause

`types.y`'s checker types a `def` body from its final expression, and the
`return` check compares each `return`'s type against that.  The comparison is
right; the message template is what is wrong: it substitutes the *inferred* type
into the standard "expected X, got Y" shape, so the reader sees a type they never
wrote. The same checker's forward-call diagnostic already has the phrasing that
would fix it ("annotate it"), and the annotated-void form is the answer, so
either naming it or accepting `return;` as "return the inferred type's zero
value" would remove the whole class of confusion.

### Environment

`refs/ycc.ref` sha256 c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631
· deterministic across 5 runs (exit 1 every time)

### Workaround, and where it bites

Write the return type. `-> void` on a `def` that uses a bare `return;` is the
whole of it, and `examples/editor/buf.y` does it on every one of its ~30 void
helpers (`def msg(s: str) -> void {`, `def scroll_fix() -> void {`, …) for exactly
this reason. The ergonomic cost is that a *useful* annotation is needed only to
make the compiler happy, and a reader of the source cannot tell that from an
annotation the program needs. `examples/editor/modes.y` carries a comment on each
one.

The part that cannot be worked around by reading the source: a tail that is a
**call statement** is inferred `void`, while a tail that is a **literal** is
inferred `long`.  So these two differ by one token, and neither looks like it
should:

```y
def f() { if (true) { return; }; print(0) };   // compiles
def f() { if (true) { return; }; 0 };          // error: expected long, got void
```

