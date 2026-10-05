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

