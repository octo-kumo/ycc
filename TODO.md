# List of LANGUAGE features to add to YCC

Language features to be added, insert a reason why it is useful, a snippet of how it looks like

Each entry says what it buys and what it costs today.

***INSTRUCTIONS WHEN FINISH*** remove the TODO item from this file when it has been completed

## 1. A recursive `type` alias through an array, option or map member

**Useful because** recursion in an alias currently has to go through a record
field, which is the only indirection the renamer recognises. That forces a
one-field wrapper record around every nested list or dictionary — noise in every
recursive type in the language, and the reason `std/json.y` needs a `jobj()`
wrapper that exists only to satisfy the rule.

It is also arbitrary: an array, an option and a map are heap objects with
headers, structurally as sound a place to recurse through as a record.

Today — all three rejected:

```y
type Ids = [Ids];
type Tree = { str => Tree };
type Maybe = Maybe?;
```
```
1:1: error: type 'Ids' refers to itself outside any record field or function type
```

Wanted:

```y
type Ids = [Ids];
type Tree = { str => Tree };

type Json = Num | Str | Bool | Arr | JObj;
type Arr  = { v: [Json] };              // still a record field -- already legal
type JObj = { v: { str => Json } };
// and, once C3 lands, without the JObj wrapper at all:
type Tree2 = { str => Tree2 };           // the map itself, recursive
```

**Cost.** Small: in `rename.rn_reaches_go` (`rename.y:480`) make the array,
fixed-array, option and map arms (`rename.y:496-499`) respect `bare` the way
the record (`rename.y:507`) and function (`rename.y:517`) arms already do, plus
the 1:1 `src/c/rename.c`. It does need validating against everything that
consumes a recursive alias — `teq`'s 64-level unfold limit (`types.y:200`),
`tcanon`, `unfold`, and the emitter's record-type hashing (`native.y:5755`) —
and bench and fuzz numbers, because the emitter and the checker both recurse
over these types.

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

## 4. `std/random.py` — a `random` module

**Useful because** every std module so far is deterministic — `crypto` takes
its entropy from the kernel, `struct` and `str` are pure — so there is no way
to write a program that varies between runs: a fuzzer, a load generator, a
sampler, a test that wants a different seed each time. `random.seed(n)` matters
as much as the generator, because a failing case is worthless if it cannot be
replayed.

```y
// wanted
import random;

random.seed(1234);            // optional; omit for a kernel-seeded stream

let d = 0;
while (random.randint(0, d + 10) < 100) {
    print(d);
}
```

Today:

```y
import random;
```
```
error: cannot find module 'random' (import name; looks next to the importer and in std/)
```

**Cost.** Small, and it is a module rather than a language change: a file in
`src/y/std/` with an `export` clause, no `src/c` twin (std modules stay Y), and
the usual obligations — a manual section in `docs/src/09-builtins.tex`, a
`test/COVERAGE.md` row, and checked `t*.y` fixtures. The one real design
question is the entropy source: `std/crypto.y:87` already reaches `getrandom(2)`
(`syscall(318, …)`) and it is the only std module that does, so seeding should
come from there rather than inventing a second source.

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

## 7. Byte literals — the `b` suffix

**Useful because** the `byte` type and `[byte]` arrays exist and `bytes("hi")`
converts, but there is no way to *write* a byte value in source. Byte data
turns up constantly in this codebase's own domain — `struct.y`, `crypto.y`,
`x509.y` and the ELF writer are all byte manipulation — and every such literal
today has to be spelled as a decimal `long` and converted, or assembled into a
`[byte]` array element by element.

```y
// wanted
let a = 129b;              // decimal byte
let b = 0b10001b;          // binary byte
let c = 0bx1b;             // hex byte, forced, so 0x1b is never confused with 0x1b
let d = 255b;              // the maximum
// and the errors, per RFC-style literal rules:
//   256b    -- does not fit in a byte
//   0 - 1b  -- byte literals are unsigned, so negative is an error
//   3.14b   -- a byte is not a floating point value
```

Today:

```y
let a = 129b;
```
```
1:12: error: expected ';', got 'b'
```

and the forced-hex form fails differently, because the lexer takes `0b` as a
binary prefix and then finds no digits:

```y
let c = 0bx1b;
```
```
1:9: error: binary literal '0bx1b' has no digits
```

**Cost.** Small to medium, and it is a lexer change with real care in the
grammar. The lexer has no `b`-suffix handling at all today. The awkward part is
`0bx1b` versus `0b1010b`: `0b` is already a binary prefix, so a suffix cannot
simply follow the digits — the scan has to decide `0b1010b` is a suffixed binary
literal while `0b1010` is a plain one, and `0b` alone stays the existing
"no digits" error (`docs/src/02-lexical.tex:58`). Digit grouping with `_` and
the range/negative/float checks all have to compose with it. `byte` is a
distinct type from `long`, so a suffixed literal also needs to infer as `byte`
and reject an out-of-range value rather than silently wrap.

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
