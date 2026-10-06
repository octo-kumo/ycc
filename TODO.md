# List of LANGUAGE features to add to YCC

Language features to be added, insert a reason why it is useful, a snippet of how it looks like

Each entry says what it buys and what it costs today.

***INSTRUCTIONS WHEN FINISH*** remove the TODO item from this file when it has been completed

## 2. A primitive as a union member

**Useful because** it would let a union model "a value of one of several
kinds" without inventing a wrapper record per kind — the shape almost every
serialisation format wants.

Today — rejected:

```y
type V = long | str;
def f(v: V) -> long { 1 }
```
```
2:1: error: parameter 'v' has unpassable type long | str (a void value has no representation, and a type pattern cannot be passed by value)
```

Wanted:

```y
type Json = long | str | bool | [Json] | { str => Json };
type V = long | str;
def f(v: V) -> long { if let long x = v { x } else { 0 } }
```

**Cost.** Language-scale, and not a rename-layer fix like item 1. A union is
passed as one of its record members, so a `long` arm has no representation
beside the value itself and the void arm has none at all. This needs unions to
become a tagged, heap-boxed runtime value: the emitter, `src/c/yv.h`'s value
model, the 1:1 twin, `make bench`, and the fuzzer. Worth arguing for on its own
merits rather than as support for a particular module.

## 3. JSON literal syntax

**Useful because** reading and writing JSON without a module per task is the
common case for a language with `net`, `http` and `tls` in std, and a module
cannot fix it: with no literal syntax, every value is a constructor call.

Wanted:

```y
import json;

let req = json{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "textDocument/hover",
    "params": { "textDocument": { "uri": "file:///a.y" }, "position": { "line": 3, "character": 9 } }
};

let text = json.stringify(req);
// {"jsonrpc":"2.0","id":1,"method":"textDocument/hover","params":{...}}

Today — `json{` is not a token at all. It lexes as the identifier `json`
followed by `{`, so the line dies at the brace:

```y
let o = json{ "a": 1 };
print(o);
```
```
1:9: error: undefined variable 'json'
1:13: error: expected ';', got '{'
```

Two errors, and between them they are the whole argument: the checker sees a
plain identifier `json` that nothing defines, and the parser then finds a `{`
where it expected a statement end.

A **sigil** rather than a type-directed feature, which is what keeps it
unambiguous: `json{ … }` is a JSON object, `{ … }` stays a record literal, and
no type inference is involved. Inside a `json` literal a nested `{ … }` is an
object, `[ … ]` is an array, and a bare literal is wrapped, so the nesting
needs no repeated sigil.

The parser desugars it the way `x!` → `unwrap(x)` and `?:` → an if-chain over
synthetic temps already do, so the checker, renamer and emitter see ordinary Y
with no new cases, and `json.obj`/`json.num`/`json.jstr`/`json.jobj` stay in
`std/json.y` as the runtime the desugaring targets — they just stop being
something a person writes.

**Cost.** Medium, and more process than semantics. New syntax touches the
lexer, the parser, `tags.y` and its C twin, `docs/src/02-lexical.tex` and
`03-grammar.tex`, the `test_coverage.sh` gates, and `make check` / `bench` /
`bench-ir` / `rebless`, and it gives the fuzzer a new family to mutate.
`make corpus-diff` is the gate that no existing program changed meaning.

Independent of item 1 and item 2 — the desugaring targets the representation
that already works, so this can land first and `std/json.y` then gets smaller.
---

The rest of this file is items 4–8, checked against `refs/ycc.ref` and moved
over from `TODO.y` (2026-10-04). Four of the eight features `TODO.y` lists are
already implemented and were **not** moved: `while` and `if` without brackets,
and the `0b1010` binary literal.

## 5. `break` to a label (multi-level exit)

`break` and `continue` are implemented (they landed with the 2025 loop work;
`native/t198_break_continue.y` and `native/e168`/`e169` are the tests). What
is still missing is breaking out of more than one loop at once.

**Useful because** a nested loop with an early exit needs a flag today, and
the flag has to be declared before the *outer* loop and tested there, so the
inner loop's exit and the outer loop's are coupled through a name neither of
them owns:

```y
// wanted
for x in 0..n {
    for y in 0..m {
        if grid[x][y] == 0 { break outer; }
    }
}
```

Today — one flag per level, and every level between tests it:

```y
let done = false;
for x in 0..n {
    if (done) { break; }
    for y in 0..m {
        if grid[x][y] == 0 { done = true; break; }
    }
}
```

**Cost.** Medium. A plain `break` is one `jmp` to a label the loop already
published, so a labelled one is a jump to any *enclosing* loop's label — which
means the name has to be resolved to the right loop, so it cannot be checked by
the checker as a bare statement (it has to know which loops enclose it, and
`types.y` already threads that: `TcSt.loops`/`loop_fd` grew for `break`, and a
label makes them a list of (name, label) pairs rather than a count). Labelled
`continue` is a second keyword shape (`continue outer;`) or an optional label
on `continue`. Both copies, plus the emitter's save/restore, which currently
keeps one target per loop and would need a stack of them.

## 6. Tuples, with type inference

**Useful because** a function that must return two or three related values
currently has to invent a record type for the occasion, and the record is exact
(`AGENTS.md`), so it cannot be passed where a caller's own two-field record is
expected. Tuples are the shape for "these values travel together and nobody
cares what they are called".

```y
// wanted
let tup: (long, str, float) = (1, "hello", 3.14);
let inferred = (2, "world", 2.71);          // inferred, statically typed
print(tup.0);                              // element access by index
print(inferred.2);

def divmod(a: long, b: long) -> (long, long) {
    (a / b, a % b)
}
let q = divmod(17, 5);                     // q.0 == 3, q.1 == 2
```

Today:

```y
let tup: (long, str, float) = (1, "hello", 3.14);
```
```
1:33: error: expected ')', got ','
```

Note `TODO.y` wrote the type as `(int, str, float)`; there is no `int` in Y,
the integer type is `long`.

**Cost.** Large — this is the most invasive item on this list. A tuple is a
*type* that is also a runtime value: a fixed-length heterogeneous record behind
one uniform 8-byte representation, or boxed. That means a new type kind in the
parser and `tags.y`, layout and code generation in `native.y`, `tdisp` and
`teq` in `types.y`, the C twin, and the value model in `src/c/yv.h` — because a
tuple holding a `str` and a `long` has no representation today. `.0` is also
not a `Dot`: `Dot.key` is a `str` (`parser.y`), so index access is either a
parser change or sugar that lowers to an `Index`.

## 8. Parameter types inferred from context

**Useful because** it is the one item here that would shorten every signature in
the language, and `TODO.y` asks for it explicitly.

```y
// wanted
def randomThing(i) {          // i is a long, from random.randint's second argument
    random.randint(0, i + 10)
}
```

Today:

```y
def f(i) { i }
```
```
1:1: error: parameter 'i' has no type (annotate it)
```

**Cost, and a caveat.** This is currently a **deliberate rule**, not a gap:
`AGENTS.md` states *"No unknown types: every parameter is annotated (or has a
literal default)"*, and the checker enforces it. The rule exists because
inference would have to run over the whole program to know `i`'s type before the
body can be checked, which is a different checking order from the current
one-pass model — and the void-poison trick (`types.y:51`), which is what keeps
error reporting to one message per root cause, depends on knowing a type up
front.

So this is not a cheap addition; it is a revisit of a core design decision, and
it belongs in `TODO.md` only with that stated. A narrower version would be worth
considering first: infer a parameter type from **its default value's literal**
(which the language already accepts, `def f(x: long = 0)`), extended to infer
from a literal passed at a call site for single-candidate functions.

## Not moved: already implemented

Checked and working, so these stay only in `TODO.y` as history:

| `TODO.y` item | Status |
|---|---|
| `while cond { }` without brackets | implemented |
| `if cond { }` without brackets | implemented |
| `0b10001` binary literal | implemented (`0x1F` and `_` grouping too) |
| `0o755` octal literal | implemented (`0O17`, `_` grouping, and the one `radix_of` prefix test the other radixes now share) |

# DONE: the tree shake drops functions, not data (was item 9)

Done in round 28. The emitter brackets every top-level global's initializer
with two labels named for the cell (`ygiS_<cell>` / `ygiE_<cell>`), and the
link step deletes that range when nothing reads the cell -- and refuses to
unless the range is pure: no call except `y_alloc`, no store to another cell,
no raw text. The shake that follows drops whatever only that range called.
Both copies carry it, byte-identical.

Measured:

| program | before | after |
| --- | --- | --- |
| `import math; print(7);` | 7678 | **973** |
| `import regex;` / `import crypto;` / `import fs;` unused | 1155 / 1393 / 1045 | 973 |
| 400 unused `[long; 8]` tables | 78173 | **973** |
| three dead tables beside one live one | 1491 | 1491 (they cost nothing) |
| `print(math.sqrt(9.0))` (math used) | 17132 | 10427 |

`test/treeshake/costs.txt`: math 6705 -> 0, regex 182 -> 0, crypto 420 -> 0,
fs 72 -> 0. What is left is the rule doing its job, not a gap: x509 and tls 94,
json 25 -- top-level statements with an effect, which must run whether or not
anything reads their value.

Two lessons worth keeping, both learned the hard way across six rounds:

  * **`ys_slice`, not `ya_slice`.** A `str` in the C copy is not an array, and
    `ya_slice` on one answers EMPTY. `mark_cell` used it, so every mark looked
    like a non-mark, nothing was deleted, and the pass was silently a no-op in
    the C copy -- with the Y copy working perfectly, which is why the port gate
    is not optional. PORTING.md's ys_/ya_ rule applies to every string
    operation, not just the obvious ones.
  * **An unread cell's initializer is not dead.** The first version asked only
    "is the cell read", deleted `let result = main(...)` -- the call to `main`
    -- and produced a compiler that exited 0 and did nothing.
    `test/y/native/t348_unread_init_side_effect.y` is that regression, and
    `range_is_pure` is why it cannot come back.

Also: probes that "proved" the marks were missing were themselves wrong (a
buggy guard in the probe), so the three rounds spent chasing "the marks are
not in the items" were chasing nothing. Dump the first few items and read
them; do not trust a counter you have not validated.
