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

