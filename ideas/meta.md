# Compile-time code generation — `#{ … }#`

Meta code that runs while the compiler runs, and whose output becomes the source
that gets compiled. **v1 is two constructs**: a block `#{ … }#` that produces text, and
plain `import` inside a block. Nothing else. A block nested inside another block is
**not** a third construct — it is the same one, splicing, at every level
([why](#nesting-is-splicing-at-every-level)). `#if` and `#meta` are cut and parked in
[Deferred](#deferred-if-and-meta) — with the findings that killed them, so the reasoning
is not lost.

This is **not** a prerequisite for [`WINDOWS.md`](WINDOWS.md). It was thought to be,
because W4 wanted `#if` for one diagnostic and W5 wanted it for std sources; both turn
out to be reachable without meta at all (see that doc's landing order). It is worth
having on its own: it is the "can we do computation during compilation" question that
[`OPTIMIZE.md`](OPTIMIZE.md) Part 3 only gestures at, taken all the way.

Everything below was read off this tree and audited against it three times; corrections
from those audits are folded in. Two of them were fatal and are recorded under
[Corrections](#corrections).

**On citations.** `src/y/native.y` is in flux (there is an uncommitted refactor in the
tree), and its line numbers have drifted from this document even against `HEAD`. So
references into it are by **function name** (`native_resolve_seen`, `gen_push_args`,
`compile_unit`, `std_compile`, …) rather than by line. References into `src/y/arch/*.s`,
`asm.y`, `enc64.y`, `tags.y`, `lexer.y`, `ycc.y`, `pkg.y`, `test/sh/*.sh` and
`refs/ycc.ref` do carry line numbers, and those files are stable.

---

## Requirements and constraints

| # | Requirement | Enforced by |
|---|---|---|
| R1 | **The C twin is 1:1.** Every line of new compiler code lands **twice**. | `PORTING.md`, `make ycc` |
| R4 | **No warnings** from `src/y` and `src/y/std`. A meta block in compiler source would put a synthesized statement in a top level that has none, so `src/y` uses no blocks. | `src/tools/ytest/su_fixpoint.y`, `lint.y` |
| R5 | **Deterministic output** — no hash-map iteration order. | `src/tools/ytest/su_port.y` |
| R8 | **Every process under `ulimit -v 3670016`.** | `test/sh/capped.sh` |
| R11 | **Every diagnostic has a test**, every manual section a `COVERAGE.md` row. **`src/tools/ytest/su_coverage.y` hard-codes the scanned file list**, so a new `src/y/meta.y` must be added there or it is invisible. | `src/tools/ytest/su_coverage.y` |
| R12 | **No new closures in `src/y`** — the C twin's value model has no function value to store one in. | `yv.h` |
| R13 | **Line numbers stay honest.** Not "preserved" — a block may emit any number of lines, so the rule is *mapped*, not *equal*. See [Line mapping](#line-mapping). | the pass's line map |

Full table in `WINDOWS.md`. Tooling that already exists is listed in both.

---

## What I read from the repo

**1. There is no `#` in code position anywhere in the corpus.** Measured: **402**
occurrences of `#` across every `.y` in `src` (56), `test` (160), `bench` (0),
`examples` (186). Every existing `#` is inside a string, an f-string or a comment, so
the pass can take over code-position `#` with zero migration cost.

One correction to the obvious assumption: a stray `#` **already** gets a positioned
error today (`2:1: error: expected an expression, got '#'`). So the only behaviour
change is the message.

`test/fuzz/mutate.y:18` already has `"#"` in its `TOKENS`, so the existing fuzzer
exercises the new path. It must still produce an error at the offending line, never a
crash.

**2. `import` never reaches the lexer or parser.** Verified: there is no `import`
token in either; `def f() -> long { import foo; 0 }` gives `undefined variable
'import'`. The splicer consumes whole lines at file scope and splices the module's text
in place. This is why an `import` written *inside* a block is new work, and why it is
cheap: it is one more thing the pass hoists into text the splicer already understands.

**3. A block's value is its last statement without a trailing `;`** — tested:
`let f = { 1 + 1 };` is `2`; `let f = { 1 + 1; };` is *"cannot bind a void value"*.
And **void does not coerce**: a void block where `str` is expected gives *"cannot pass
a void value"* — an existing message, so the enforcement below costs no new diagnostic.

**4. `if` and block expressions work in expression position** — tested, and both are
load-bearing: `let a = if 1 + 1 == 2 { "2" } else { "true" };` binds `"2"`, and
`emit({ 1 + 1 })` reaches the checker (fails only on the type, not the position).
`tostring` also handles a union value directly (tested on `A | B`), so no `match`
is needed.

**5. The std pack holds compiled units.** `std_pack` (`std_pack`) serializes a `Unit`,
so blocks in std are already expanded when the pack is built. See
[Edge cases](#std-sources-are-outside-all-of-this) — this is more constrained than it
first looks.

**6. `let` and `const` do not hoist; `def` does.** Measured, and it is the single most
load-bearing fact in this document:

| program | result |
|---|---|
| `let x = 1;` then `print(x)` | `1` |
| `const P: long = 7;` then `print(P)` | `7` |
| `print(P);` then `const P: long = 7` | **`1:7: error: undefined variable 'P'`** |
| `print(f());` then `def f() -> long { 1 }` | `1` |

Every scoping decision below follows from the third row.

---

## Pipeline position, and why it is text-level

| level | generator sees | cost |
|---|---|---|
| **text, before parse** | source text | cheap; re-parsed and checked normally |
| AST, after parse | unresolved names, no types | a partial program, and re-entering rename |
| after typecheck | resolved names, full types | breaks "checked in order, errors fatal"; a second checker |

Only the first is affordable in a compiler whose discipline is *one* checker, run
once, in order. And the limitation is smaller than it looks: a generator that wants
semantics re-parses the text itself with the compiler's own `lexer`/`parser`/`types` —
which it can, because they are Y. **That is what "the engine is ycc itself" means
here**: no new reflection API, no interpreter, just meta code run by the same
compiler whose output is text.

Rejected: an in-process tree-walking interpreter (a second implementation of the
language's semantics, written twice under R1, and it must match exactly).
Rejected: compiling meta code to a binary and `exec`ing it — pays a process spawn and
a temp-file round trip per block. [M1](#m1--run-an-image-in-a-child) does better.

---

## Syntax — the entire surface

```
#{ T }#                     expression position: the text goes where the block was
#{ T }#                     statement position (alone on a line): same, as a statement
import name;                inside a block: hoisted to the top of the meta program
import name from "path.y";  likewise
```

No `#import`, no `#define`, no new escape character, no directives at all in v1.

### Per context

| context | `#{` | literal `#{` |
|---|---|---|
| code | a meta block | none needed — a bare `#` here is an error either way |
| `"…"`, `f"…"`, `b"…"`, `'` | **inert** — plain text, so no escape is needed anywhere | nothing |
| `//` comment | **inert** | nothing |
| `/* … */` comment | **inert** | nothing — but the pass needs a block-comment state (see Edge cases) |

So: **no new escape character at all**, and in code position none is needed, because
there is no valid Y text containing `#` there. An earlier draft had `##` as a literal
escape; it was dropped because it only existed to survive a re-scan, and there is no
re-scan.

**Only code position is scanned**, so a `#{` inside any literal or comment is plain
text — and a generator may emit string literals containing `#{` freely.

---

## Semantics

### One layer

There is exactly one generator program. Call the program's own text **T**; call the
generator **G**.

```
G = T with every block replaced by a call
P = T with every block replaced by that call's text
```

`G` is compiled for the host and run; its output is the piece table; the pass splices
the pieces into `P`; `P` is handed to the existing lexer, unchanged, **with the pass
off**. A program with no blocks skips all of it — one scan finding nothing.

`G` is the program's own text, not a stripped-down version. That is deliberate: `G` goes
through the same parse, rename and typecheck as the program, so a block sees the file's
top level *exactly* as the program does — same `def`s, same `let`s, same `const`s — with
no scope reconstruction and no second opinion about what a name means.

### A block sees the whole top level, and only the top level

**A block must not be lexically inside a `def` or `type` body.** Anywhere else counts:
expression position, statement position, mid-expression, inside another block.

A block at the **top level** puts its call **where the block was**. Both halves matter,
and the audit forced each one.

*Not hoisted* — an earlier draft hoisted every call to the top of the generator, which is
outside any enclosing `def`, so a block saw no locals at all:

```
3:10: error: undefined variable 'x'
```

*Not inside a `def` body* — in-place emission makes a block inside a function **look**
like it captures that function's scope, and it does: the generator really does run
`top(0, { x + size })` with `size` bound. But it only runs if something calls that
function during generation, and the only caller could be another block. And the value
it produced would then be **spliced into the source at one place**, so every runtime
caller of that function gets the same compile-time text:

```
def banner(label: str) -> str { return "<" + #{ decorate(label) }# + ">" }
// banner("hi") and banner("bye") would both return "<hi!>"
```

That is a macro parameterised by a value chosen at generation time — technically
coherent, practically a trap, and it adds a silent failure mode (a block in a `def`
nobody calls during generation never runs, so its slot is never filled). So it is a
**diagnostic**: *a block cannot be inside a function body; only the top level and other
blocks*. The pass already tracks brace depth and literal state for its own scanning, so
it knows whether it is inside a `def` header's braces.

What a block *can* see is then everything a top-level statement can see: the file's own
top-level `def`s, `let`s and `const`s, its hoisted imports, and the injected helpers. So
**a generator takes parameters** — ordinary Y parameters, called normally:

```
def emit_table(names: [str], scale: long) -> str { … }   // a top-level def
#{ emit_table(["a", "b"], 10) }#                          // called with values
```

with the data itself a top-level `let`, which the generator's run initialises like any
other. That is the whole parameter story, and unlike the function-body version it has no
surprise in it.

### The cost: the top level runs once per round

`G` is `T`, so **the program's top-level statements execute in the generator as well as
in the program.** With in-place emission this is unavoidable, and it is the one real
hazard in the design. With nesting there is more than one round, so the count is
*once per round*: twice for a file whose blocks contain no block, and `d+1` times for a
nest of depth `d` ([Nesting is splicing](#nesting-is-splicing-at-every-level)).

With blocks restricted to the top level, what is left is small and is bounded by making
it explicit rather than clever:

> **With blocks present, a top-level statement may be a `def`, `type`, `const`, `let`,
> `import`, or a block. Anything else is a warning** naming the line: *a top-level
> statement runs once in the generator and once in the program, so it must be a
> declaration*.

Checkable from the AST, not textually — the top level of a `Block` *is* the list of
top-level statements, so this is an emitter/lint check, not a pass-level guess.

With nesting, the same statement runs in every round. That is the reduction's job where
it can be: a round that cannot yet produce a block's text leaves out the statements that
are neither declarations nor block-bearing, so they cannot double-run there
([the reduction](#the-reduction-and-the-one-shape-it-costs)). The
alternative designs were both rejected:

| design | why not |
|---|---|
| `G` = blocks only, enclosing `def`s stripped | orphans the in-place calls, so capture dies |
| `G` = `T` with non-declaration top-level statements dropped textually | needs brace **and** paren tracking plus a `def`-header state to avoid cutting a multi-line parameter list in half — ~60 lines of fragile scanner, to save a warning |

The residual after both rules: a top-level `let` initializer runs in both. If it is
impure *and* a block reads it, the block sees the generator's value. Say so in the
warning text and the manual: **keep top-level `let` initializers pure.**

Every block runs in **every** round it is live in, because a live block's call is in `G`
and the top level runs. There is no "slot never filled" case to detect: a round either
produces a block's text or leaves the stand-in that keeps its call compiling
([the reduction](#the-reduction-and-the-one-shape-it-costs)).

### Nesting is splicing, at every level

A block nested inside a block contributes **text to the enclosing block's source**, and
that is the whole of it — there is no second dialect and no case where nesting means
something else. Resolve innermost first, run it, splice what it emitted into the source
of the block around it, compile *that*, and run it. Repeat to a fixed point.

```
#{ let a = #{ "1+1" }#; a }#
```

| step | what runs | what the enclosing source becomes |
|---|---|---|
| 1 | `#{ "1+1" }#`, whose value is the three characters `1+1` | `let a = 1+1; a` |
| 2 | that: `a` binds 2, and the block's text is the rendering of `a` | — |

so the block resolves to `2`. Measured: `./ynew -E` on that file prints `2`.

This section used to argue the opposite — that splicing was *impossible*, because `G` is
compiled before it runs, and that the cost would be a second compile per level, which it
called a layering model and cut to [Deferred](#deferred-if-and-meta). The
argument about `G` was right and the conclusion was wrong: the inner text does have to be
in `G` before `G` is compiled, so the pass **runs `G` again**, once per level, and the
second compile per level is simply the price. The layering model is what got built.

#### What a block's text *is*

The rendering of the block's **own value**, and that is the rule the acceptance case
forces: the enclosing block above ends by *naming* `a`, and the answer is `2`, not
`let a = 1+1; a`. So the pass writes every block's value through `tostring(...)` when it
builds the call (`mg_helpers`), and a block whose value is a `long` is the ordinary case
for a nested one — which is also why the helpers' parameter can stay `str`. A `str` value
is its own rendering, so `tostring` changes nothing for it and `lit`-style quoting is
still what a string needs before it lands as source.

The consequence worth stating, because it is the one place the request and the semantics
pull apart: a block emits its **value**, not its **source**. So

```
#{ let var1=1; let var2=2; var#{ 1+1}# }#      // splices to var2; emits "2"
print(var2);
```

The same block as the initializer of a top-level `let` is exactly the case, and it
works — MEASURED, `ynew` and `ycc`, byte-identical binaries:

```
let x = #{ let var1=1; let var2=2; var#{ 1+1}# }#;
print(x);                                       // prints 2
```

In **statement** position, though, it does not compile — this document used to claim it
"compiles and prints nothing", and that is wrong. The mid-token block's call is hoisted to
the statement that contains it (`sg_mids_move`), which for a bare top-level block is the
block's own, so the call lands after `var2`; the block's value is then the hoisted
`ycc_meta_stmt`, which returns void, and the enclosing `tostring(...)` is refused:

```
acc2.y.meta:2:26: error: tostring supports long/bool/float/str/array/record/map/option, got void
error: the meta generator did not compile
```

It is the *last* statement that decides, which is the ordinary rule and nothing new: put
anything after the mid-token block and the same statement-position block compiles (MEASURED,
`#{ let var1=1; let var2=2; var#{ 1+1}#; 99 }#` compiles; as a `let` initializer it yields
`99`, and `#{ …; 99; var#{ 1+1}# }#` yields `2`). Unchanged by the merge of master
`d35af36`: the pre-merge build at `72f5ede` fails with the same message at the same position.

The nearest working form for the statement-position case is for the enclosing block to
return the text the program should get, with the generated name in it —
`t202_meta_nest_mid_token.y`:

```
#{ let var1 = 1; let var2 = 2;
   "let var1 = 1;\nlet var2 = 2;\nprint(var" + tostring(var#{ 1+1}#) + ");\n" }#
```

which emits exactly the three statements and whose program prints `2`.

#### The rounds, and what they cost

A nested block's text is spliced into a source that has to be compiled before it can run,
so the enclosing block cannot produce its text until the nested one has produced its. The
pass therefore runs `G` **once per level** (`mg_pending`, driven by `meta_resolve` in
`native.y`), and a chain of depth `d` costs `d+1` generator compiles and runs.

A block with **no nested block pays nothing**: the loop is only entered when the
collecting scan found nesting (`mg_nest`), a block with nothing inside it is never even
*held* (its text is written straight into `G`, `sg_hold` is for a block that may have to
give its text up), and its `G` is byte for byte the one the pass has always built —
`ytest meta-identity` checks the weaker, sharper claim that the pass is the identity
on a file with no blocks at all (393/393 after the merge of master `d35af36`, which grew
the corpus from 381), and `make test` checks the rest.

MEASURED, `ynew` on a generated program of 400 declarations (24 KB) with a nest of depth
`d` appended, 8 runs each:

| depth | blocks | generator rounds | ms/run | peak RSS |
|---|---|---|---|---|
| 0 | 1 | 1 | 25.5 | 61 MB |
| 1 | 2 | 2 | 40.2 | 95 MB |
| 3 | 4 | 4 | 68.7 | 161 MB |
| 5 | 6 | 6 | 95.8 | 227 MB |
| 7 | 8 | 8 | 122.3 | 293 MB |

so **a level costs one compile and one run of the program-as-generator: 13.8 ms and 34 MB
there**, and both scale with the program: the same measurement on 1600 declarations
(122 KB, the compiler's own size class) is **43 ms and 103 MB per level** (0.09 s / 202 MB
at depth 0, 0.39 s / 924 MB at depth 7). The same program with no block at all compiles
in 11.0 ms — the block itself, not the nesting, is what costs the 14 ms baseline.

#### Why the cap is 8

**Nesting depth** is bounded by cost, not by the parser. The parser's own limit is
`MAX_NEST = 1000` (`tags.y:79`, message from `too_deep` at `tags.y:97-102`), counted in
five walks — three in `parser.y`, one in `rename.y`, one in `types.y` — so it is ~333
effective (measured: 332 nested `ycc_meta_expr({ … })` compile, 333 fails). A round is a
whole extra compile **inside** the compiler's own process, and ycc never frees, so the
memory is the binding constraint: at 103 MB a level, 8 levels of a compiler-sized program
is 824 MB and 16 would be 1.6 GB, which a program twice that size could not afford at
all. `MG_NEST = 8` keeps a compiler-sized program with the deepest legal nest under 1 GB
of the 3.5 GB budget (`e188_meta_nest_too_deep.y` is one over), and the diagnostic says
what the limit costs rather than leaving `too_deep` to fire inside a file that does not
exist.

#### The reduction, and the one shape it costs

A round in which a block cannot produce its text leaves a **stand-in** where its call
goes (`mg_stub`: the real call's helper, position and `;`, with the body `0`), because
its own source wants text that does not exist yet. A stand-in declares nothing, so a
top-level statement naming something that block was going to define would not compile —
`#{ let v = #{ "1+1" }#; let x = v; }#` followed by `print(x);`. So in a round with
nesting, the reduction leaves out of `G` every top-level statement that is **neither a
declaration nor carries a block** (`sg_region_*`). The extent is exact and needs no
parser: a top-level statement in Y ends at a `;` or at the `}` that closes it (measured:
`print(1)` with no `;` is *expected ';'*), so the regions are exactly the statements.

That costs the generator no **name** — the only statements dropped begin with `print(`,
`f(`, an operator, and none of them declares anything, so every binding `G` needs is
still there. It costs a block the **side effect** of such a statement, which is what the
pass's own warning about top-level statements already says to avoid, and it has one sharp
edge: a top-level `let` is a declaration and so is **kept**, so a `let` whose initializer
reads a name a block generates still fails in a stand-in round
(`e189_meta_toplevel_let_reads_block.y`). The rule is the "keep top-level let
initializers pure" rule one step sharper: pure is not enough, the initializer must not
depend on what a block generates.

The reduction is off for a program with no nesting, which is what keeps every other
program's `G` — and its emitted binary — exactly as it was.

### Mid-token blocks: two cases, and the call does not have to be in place

`def helper#{x++}#()` — a block between two tokens of an expression — generates a **name**,
and that is intended code. It works, and the reason it works is the thing the earlier
draft of this document got wrong:

> **The call does not have to be at the block's own byte offset.** A block's text lands
> at its recorded byte range in `P` regardless of where its call sits in `G`; the call
> only has to *run* before `G` finishes.

So the rule is two cases, decided by the byte before the `#{`:

1. **An operand position.** The preceding non-space, non-comment byte is one of
   `(` `,` `=` `[` `{` `;` `:` `?`, or a binary or unary operator, or the block is at the
   start of a line, or after a keyword such as `return`. The call stays **in place** as
   `ycc_meta_expr(SLOT, tostring({ T }))`. This is `let count = #{ … }#`, `f(#{ … }#, 2)`,
   `#{ T }#` alone on a line, and anything else already sitting where an operand goes.
2. **Mid-token.** The preceding byte is an identifier character, `)`, `]`, or a literal,
   so there is no operand position and a call cannot go there. The block's **bytes are
   dropped from `G` entirely** and `ycc_meta_stmt(SLOT, tostring({ T }));` is emitted as a
   statement **immediately before the top-level statement that contains the block**.

Case 2 is safe precisely because it is mid-token: the block is an adjunct between two
adjacent tokens, and dropping it leaves them adjacent.

**Case 2 survives the splicing, and it has to.** Splicing subsumes the *nested*
mid-token case's bookkeeping -- once the table has the nested block's text it is
spliced and no call is emitted at all -- but it does not subsume the rule, for two
reasons that are each necessary on their own:

- **A mid-token block at the top level has no enclosing source to splice into.**
  `def as#{nm}#() -> long { 7 }` is a top-level block: its text goes into `P`, and to
  *run* it its bytes must come out of `G` and its call must go somewhere a call can go.
  That is case 2, and nothing about splicing changes it.
- **A nested mid-token block's text is unknown in the round that needs it.** The rounds
  run innermost-first, so the round that compiles the enclosing block's source is the
  round in which the nested block has *just* produced its text -- and in the round
  before it the nested block has none, so its call must be hoisted exactly as case 2
  says. Splice and hoist are not alternatives: a nested mid-token block hoists in the
  rounds and splices in the last one, and each of those is one of the two rules above.

So the two cases are how nesting is dispatched too, not a third rule: **a mid-token
block and a nested block share case 2 verbatim** (`sg_open`:
`else if (mid || nested)`), and a nested block in an operand position is the only case
whose *meaning* changed -- it used to put an in-place call inside the enclosing block's
source and it now splices.

| | `G` becomes | `P` becomes |
|---|---|---|
| `def helper#{nm}#() -> long { 7 }` | `ycc_meta_stmt(0, tostring({ nm }));`<br>`def helper() -> long { 7 }` | `def helpergen() -> long { 7 }` |
| `obj#{i}#.field` | `ycc_meta_stmt(1, tostring({ i }));`<br>`obj.field` | `obj.field` |
| `tag#{i}#` (whole tail) | `ycc_meta_stmt(1, tostring({ i }));`<br>`tag` | `tag` |
| `f(#{x}#, 2)` (case 1) | `f(ycc_meta_expr(2, tostring({ x })), 2)` | `f(<the piece>, 2)` |
| `let a = #{ "1+1" }#; a`, round 1 (nothing known) | the inner block's call hoisted, the outer one a stand-in:<br>`ycc_meta_stmt(0, tostring({ 0 }));` | nothing usable yet |
| the same, round 2 | the inner text is spliced into the enclosing source and the enclosing block's own call runs on it:<br>`ycc_meta_stmt(0, tostring({ let a = 1+1; a }));` | `2` |

(The `tostring` wrapper is in every call because a block's text is the rendering of its
value -- see [What a block's text *is*](#what-a-blocks-text-is).)

**The statement start is a byproduct of the state machine**: the position of the first
byte that is neither a blank nor a comment since the last depth-0 `;`, `{` or `}`. That
is exact, not an approximation — a top-level statement *can* begin mid-line (`let a =
f(); def helper#{x}#() …`), and the anchor follows the `;`, so the hoisted call still
comes after everything the statement before it initialised.

**Ordering** is the load-bearing part, and it falls out of where the calls are recorded:
a hoisted call is appended when its block **closes**, which is innermost-first and then
siblings in source order — the order they have to run in. Within one statement they are
therefore inserted back to front, each landing before the one already there; statements
are done from the last to the first so an insertion never moves a position a later pass
still has to read.

Three limits, all measured, none of them silent:

- **The fragment needs a character of the name on one side.** `def #{nm}#() -> long { … }`
  is not mid-token (nothing ends a token there) and its call cannot go in place either
  (a def header is not an operand position), and dropping its bytes would leave
  `def () -> long`. It is refused. `def as#{nm}#()` works.
- **`G` holds the def under the SHORT name.** So nothing in the *source* may call the
  generated name — the generator's copy of a call to `assembled()` would not resolve.
  The name and its call sites have to be generated together; that is the shape, and it
  is what makes this usable.
- **A block cannot be adjacent to another block.** `}##{` is two blocks but `}#{` is one
  block followed by a brace: the closing `#` is consumed by the first. Write
  `def a#{x}#b#{y}#()` — with literal text between the fragments — not `def a#{x}##{y}#()`.

**One new diagnostic**, and it is the one shape where removal provably cannot work: a
block in a `def` or `type` header that is not part of a name.

> `a meta block in a def or type header must be part of a name, with a character of the
> name beside it: a call cannot go in a header, and dropping the block's bytes would
> leave nothing behind`

(`e187_meta_header_whole_name.y`). It is worth its own message rather than the existing
"inside a def or type body" one, because the block is **not** inside the body — the old
message would have pointed at the wrong place. Everything else removal cannot fix is
still caught by `G`'s own compile: the error is `the meta generator did not compile`
naming the block's line, which is where a bad `import` or an undefined name in a block is
reported too.

### Sharing: one block, or a module

v1 has no declaration region, so **two blocks cannot share a `let`.** Three answers, in
order of preference:

| | route | when |
|---|---|---|
| 1 | **one block that emits everything** | almost always. If two blocks want the same data, one block can produce both pieces — it has two `ycc_meta_expr` calls. |
| 2 | **a nested `def` inside the block** | the generator needs structure, not sharing |
| 3 | **a module** (`import gen;`) | across files, or shared by several programs |

```
#{ import gen; gen.emit_all() }#      // one block, two pieces, one module
```

**Blocks are lexically isolated.** A `def` inside a block is a *nested* def, local to
that block — tested: `{ def helper() -> long { 7 }; print(helper()) }; { print(helper()) }`
prints `7` then `42`. The pass does **not** lift block-local `def`s out, because that
would regress a case that works today (`{ let base = 10; def scaled() -> long { base * 2 }; scaled() }`
is a closure over `base`, and lifting it would break the reference), and a text-level
"does this def mention a block local" check would be a second, wrong parser. Two hard
limits follow, both from the language rather than from this design:

- **A closure cannot be stored.** `yv.h`'s value model is
  `none|bool|long|float|str|array|record` — there is no function value to put in a map
  or an array (R12). Behaviour can only be shared by name.
- **A module imported into the generator is plain Y** — declarations and imports, no
  `#{ }#`. If it contained one it would land as raw text in `G`, whose compile has the
  pass off. One clear diagnostic.

**Use the bare import form for modules.** `import gen;` keeps the module's namespace
(`gen.emit`), so two helper modules cannot collide on their exports.
`import gen from "gen.y"` is *flattened* into the generator's top level and can then
collide. Resolution is ordinary: next to the importing file, then `std/`, then the
self-dir fallbacks (`std_resolve`).

Hoisted imports become ordinary lines at the top of `G`, so **cycle detection is
free** — the existing splicer resolves them when `G` is compiled, with its dedup, its
namespacing, and its depth-32 *"native import depth exceeded (cycle?)"*. No pass-side
resolver, no new message, no new test surface.

Hoisted paths are normalized against the dir of the file the block came from, not
`G`'s `base_dir` — the pass tracks per-line origins, so it knows which file each block
belongs to.

### The lowering

| source | in `G` | in `P` |
|---|---|---|
| `#{ T }#` in **expression** position | `ycc_meta_expr(SLOT, tostring({ T }))` | the piece's text |
| `#{ T }#` in **statement** position | `ycc_meta_stmt(SLOT, tostring({ T }))` | the piece's text |
| `#{ T }#` **nested inside another block** | hoisted out to the level that can hold it, innermost first — the same hoisted-call path a mid-token block takes | the piece's text, inside the *enclosing* block's text |
| a **mid-token** block | the call is always `ycc_meta_stmt`, hoisted to a statement of its own | the piece's text, inline |
| a block that cannot produce its text **yet** (a stand-in round) | the same call with the body `tostring({ 0 })` (`mg_stub`) | unchanged that round |
| `import` inside a block | hoisted to the top of `G` | gone |
| a block inside a `def`/`type` body | — | **a diagnostic**; it is not in `G` at all |
| everything else | verbatim | verbatim, shifted by the line map |

**Three injected helpers, and the top-level split is forced.** `ycc_meta_expr` returns
`str` because expression position needs a value. `ycc_meta_stmt` is **void** because
statement position must not warn: a statement whose value nobody reads warns at `-W 1`
(*"the value of 'f()' is not used"*, measured). Both take the block's **value**, so a
non-`str` block is an existing type error, not a new diagnostic.

The third, `ycc_meta_emit(slot, body)`, is **void** and is what the other two call — it
is the one place a piece is written, so the two forms cannot drift apart in how a piece is
recorded. This doc said "two helpers" until the code was read: `ycc_meta_emit` was added
during M2 and is invisible from the call sites, which is exactly the kind of helper a
counting-the-call-sites approach misses. All three are in the reserved-name set, so a
program that defines one is a diagnostic rather than a silent shadow.

Nesting changed one thing here and left the rest alone. The **body argument stays a
`str`**, because the pass does not need a union: it wraps every block body in
`tostring(...)` when it writes the call (`sg_open`, `sg_m_open`, `mg_stub`), so the
rendering rule is in one place and a `long`-valued block — the ordinary case once a block
can be nested — arrives as text without a `match`. What the change did *not* do is invent
a fourth helper for the outer rounds: the enclosing block is spliced into its own source
and re-run by exactly the same three, in a later round. The helper set is the v1 set.

**`SLOT` is load-bearing.** An append-only accumulator cannot insert text at a source
position, and generated text is unconstrained — it may be half a statement, a whole
declaration, or thirty lines. So the pass assigns a slot index to each block **in source
order**, records the byte range each occupies in `P`, and after the run splices piece
*i* into that range.

The slot is resolved by the **pass**, not by the guest: the guest writes pieces in
order, and the pass knows the offsets. So there is no `.bss` array to read back — see
[M1](#m1--run-an-image-in-a-child).

---

## Line mapping

R13 cannot be "line numbers are preserved": a block may emit any number of lines.
`ideas/meta.y`'s one block emits **eight**. So:

> Every line of `G` and of `P` carries the **source line it came from**. Lines the pass
> generated carry the line of the `#{`. Lines after a block shift by that block's
> emitted-minus-consumed delta.

The pass builds both texts as `(text, origin_line)` pairs rather than strings, so the
map is a byproduct of construction, not a repair pass. "Rebuild origins" means all
five `Origin` fields (`files`, `nuser`, `file`, `line`, `mods`) and all three consumers:
the `.file` table (`file_dirs`), `dbg_file`/`dbg_line`, and `rename_program_x`
(`rename.y:1376`, called in `compile_unit`, which uses `mods` to namespace).

Consequences, stated rather than hidden:

- A diagnostic **inside** generated code points at the block's `#{` line. That is the
  honest answer — there is no better one.
- `-g` line info for generated code points at the block. `perf annotate` will show one
  line standing for a generated region. Acceptable, and documented.
- A column in generated text is meaningless; the checker reports it, and it is ignored.

---

## The pass, and where it runs

**One scan per file, at the top of `native_resolve_seen`, before its line loop.** It
sees one kind of thing — a block — and this is the only position that satisfies
everything:

- `embed` is expanded *inside* that line loop, so scanning before it leaves embedded
  bytes inert — an embedded file containing `#{` stays text.
- Each file's own `base_dir` is in scope, so hoisted-path normalization is free.
- The scan runs before `words_seen`, so std-unit selection sees the *generated* text —
  required, and it works.

**The pass lives in a new `src/y/meta.y`.** Not inside `native_resolve_seen`, for two
reasons: `src/tools/ytest/su_coverage.y` hard-codes the scanned file list, so a new
file is invisible unless the list is edited (cheap, but it must be *remembered*); and
`src/tools/lsp/check.y` is a **second checker** that runs the lexer and types itself,
so it will report `expected an expression, got '#'` for every meta file unless it can
reach the same pass. One module, two callers, one implementation.

**Both halves of that are now done rather than intended.** `meta.y` is in the scanned
list, and `src/tools/ytest/su_coverage.y` passes with **all 488 diagnostic sites tested or excused**,
175 builtins called, 15 keywords used, 85 manual sections with rows and 502 test
references resolving — so the R11 chain (code → fixture → `COVERAGE.md` row) holds for
all 23 meta fixtures. (Those counts moved when master merged: it brought diagnostics,
std modules and a language server of its own. At this branch's own tip, before the
merge, they were 409 / 113 / 12 / 84 / 454, and the nesting work moved the last one to
502 with three more rows.)

The gap this paragraph used to call pre-existing is **closed**.
`src/tools/ytest/su_coverage.y` scans `ir.y`, `asm.y`, `enc64.y`, `elf.y` and `dwarf.y`
alongside everything else. Adding a file to that list was **not sufficient on its
own**: `coverage_diag.awk` matches **per file**, so `asm.y` (`asm_state_err`) and
`enc64.y` (`enc_err`) each needed a rule of their own before those files contributed
anything at all. `elf.y` and `dwarf.y` print no diagnostics of their own, and `ir.y`'s
are the trap strings the `anywhere` rule already covered.

The LSP half is **not** done. This paragraph used to place the server at `tools/lsp/`,
which is where it was at the branch's base; master has since moved it, and the path
above (`src/tools/lsp/check.y`) is now the correct one. Nothing there has been taught
about blocks, and **no fixture under `src/tools/lsp/test/` contains a meta block**, so
the server's behaviour on one is untested rather than known-good. The mechanism is
visible in `diag.y:135-142`: the tolerant scanner reports `unterminated <kind>` in place
of the `exit(1)` that `lexer.tokenize` would take, and on `#{` the `{` is exactly such an
unterminated something. Teaching the server the pass is a feature, not a merge — it is
the one part of this section that remains open.

Pieces accumulate across files; `G` is built after the last resolve. `ycc build` keeps
its shape — all units are resolved (`ycc.y:456-469`) before any is compiled — but a
generator is per resolve, i.e. **per package**: a block in package A cannot see a
declaration in package B.

---

## The invariants

1. **The lexer and parser never learn any of this.** The pass runs to exhaustion, so
   the text handed to `lexer.tokenize` contains no `#{`. Every leak path is a
   **pass-level diagnostic carrying the offending line**, never a hand-off to the lexer.
   Checkable statically: `rg '#\{' src/y/lexer.y src/y/parser.y` stays empty, **and**
   the callers of `lexer.tokenize` stay enumerable (`rg -n 'lexer.tokenize' src/y`).
2. **One compile and one run per level of nesting**, for programs with blocks: a chain of
   depth `d` costs `d+1` generator compiles and runs. A program whose blocks contain no
   block pays exactly one, and a program with none skips every round — its `G` and its
   binary are byte for byte what they were before the pass existed.
3. **No blocks means no generator** — one scan finding nothing, and the common case
   costs one `index_of(line, "#")` per line (`index_of` is a builtin; there is no
   `memchr` in the runtime).
4. **`G` is compiled with the pass off**, so nothing is re-scanned and emitted text can
   never gain a new block.
5. **The generator runs in a forked child, never in the compiler's own address space.**
   See [M1](#m1--run-an-image-in-a-child) — this is what makes traps, `exit`, `exec` and
   `%fs` non-issues rather than caveats.
6. **The generator compiles for the host**, never the target — so a Windows-targeted
   compile from Linux never tries to execute a PE.
7. **Line numbers are mapped, not preserved** (R13) — see [Line mapping](#line-mapping).
8. **Meta code may read files, call `exec`, and use `clock_us`.** Nondeterminism is the
   author's choice and surfaces as a `make check` compare failure. **But it may not
   `spawn`, `join`, take a `mutex`/`sem`, or `fork { }`** — see
   [Edge cases](#guest-threads-and-why-they-are-refused). A restriction, not a preference.
9. **`G`'s own diagnostics are attributed to `<file>.meta`**, so a warning or error from
   a synthesized program is visibly not the user's file — and it still has a line, via
   the line map.
10. **The generator is cached by the hash of its *resolved* text** plus pack version,
    host target and flags — not the raw source. That is what makes editing an imported
    helper module invalidate it; keying on the source would not.

---

## Edge cases, complete

### Guest threads, and why they are refused

The compiler's own assembly lives in `src/y/arch/*.s`. `%fs:24` is read in exactly four
places: `src/y/arch/prelude.s:345` (`y_alloc_slow`) and `:403` (`y_heap_used`), and
`src/y/arch/threads.s:51` (`y_spawn`) and `:179` (`y_join`).

Both **prelude** sites sit behind the guard `y_heap[3] != 0` ("a thread was ever
spawned", `src/y/arch_x64.y:97-113`), which only `y_threads_on` sets
(`threads.s:9-28`), called only from `y_spawn` (`threads.s:45`). Nothing in `src/y`
spawns, so **a guest that merely allocates is harmless** — it takes `y_alloc_more`
(`prelude.s:347-372`) and `mmap`s chunks inside its own image, with its own `y_heap`.

The hazard is a guest **`spawn`**: its `y_threads_on` runs `arch_prctl(ARCH_SET_FS)`
(`threads.s:26-27`), which would point the thread block at the guest image. Under the
fork design that damage lands in the child and dies with it — so the refusal is
belt-and-braces, kept because it is one line and names the mistake. Refused:
`spawn`/`join`/`mutex`/`lock`/`try_lock`/`sem`/`post`/`wait`/`fork { }`. It also rules
out running the guest on a `spawn`ed thread.

### The pass needs its own lexical state, and there are already three copies

`lit_end` (`lexer.y:172-185`) is the reusable one, but:

- it is **not exported** (`lexer.y:764`: `export { tokenize, fstr_walk };`) and is
  `static` in the C twin, so it has to be exported in both;
- it **cannot report "unterminated"** — `end` is initialised to `n` and set to `i + 1`
  at the closing quote, so "closing quote is the last byte" and "never closed" both
  return `n`. The pass needs that distinction, so `lit_end` gains a second out-param —
  a behavioural change for its other two callers;
- and the tree already has **three** copies: `lit_end`, `lex_quoted`, and an inline copy
  inside `words_scan`.

So the work is: export `lit_end`, add the out-param, collapse the copies onto it —
3 edits × 2 trees under R1. Not "reuse it, do not copy it".

**As built, the collapse is two of the three.** `lit_end` is exported with the out-param
and `words_scan` calls it, so what the pass needs — a literal scan that says whether the
literal closed — is one function. `lex_quoted` still carries its own loop, and it must:
master's `0b48dad` gave it a `what` parameter and an `err` return, so an unterminated
literal is a *token* the parser reports in place (`9:7: error: unterminated byte string`)
instead of the bare `puts` + `exit(1)` this branch's version had. It counts line and
column as it scans, which `lit_end` does not do. Merging master `d35af36` therefore took
master's `lex_quoted` verbatim (its call sites pass five arguments) and left the out-param
on `lit_end` for the pass and `words_scan`, which is where it is load-bearing.

### Delimiter safety

The only place the pass can be *tricked*, because it never parses and only splices at
byte offsets:

| case | handling |
|---|---|
| `}#` inside a string in a block | string state; does not terminate (legal, and the output keeps the text — so **not** a fixture) |
| `}#` inside a `//` or `/* */` comment in a block | comment state; does not terminate — so the pass needs a **block-comment** state, which none of the three existing scanners factors out |
| `#{` inside a comment or an `f"…"` | inert |
| `#{` in code position inside a block | **the normal nested case**, not an error: the scanner counts it, the call is hoisted, and the piece is spliced into the enclosing block's text |
| a string spanning newlines | scanner state crosses lines — legal, and strings are **not** newline-terminated (`lexer.y:89-100`) |
| `'` char literals | same state machine as `"` |
| `}#` in code position with no open block | **an error** — the one stray-delimiter diagnostic |
| `#` at EOF, or `#x` in code position | **an error** |
| a block **inside** a block, mid-token | works: hoisted like any other mid-token block, in close order, so it runs before its parent (see [Mid-token](#mid-token-blocks-two-cases-and-the-call-does-not-have-to-be-in-place)) |
| a mid-token block at the **start** of a `def` name | **an error** — nothing ends a token there, and dropping the bytes would leave `def () -> long` |

**Generated text is unconstrained, by design.** A block that emits half a statement
works, because the pass only needs to find its own delimiters and has no idea what
syntax surrounds them. Unbalanced brackets from generated text are the parser's
problem, and the line map points the error at the block.

### std sources are outside all of this

`std_compile` calls `lexer.tokenize(std_unit_src(name))` **directly** — no splicer at
all — and builds an `Origin` with empty `file`/`line`, so a block in a std source has
no origin to point at. `std_units` is called at `ycc.y:651`, which is **after**
`tokenize` (`:638`) and `parse` (`:641`), so a std block would arrive after the
program's pass has run. And `src/tools/ytest/su_fixpoint.y` compiles each `src/y/std/*.y` as its
own standalone program.

So **a `#{` in a std source is a diagnostic** in v1. Revisiting it means moving
`std_units` earlier and giving `std_compile` a real origin.

### `import` placement

The pass runs *before* the splicer's line loop, so whatever it leaves is spliced
normally afterwards:

| an `import` written… | goes to |
|---|---|
| the program's own top level | the program (unchanged behaviour) |
| inside a block | hoisted to the top of `G` |
| *emitted by* a block | the program if it lands as a whole line, **nothing** if it lands mid-line (`let x = <import>;`) |

### Debuggability

A feature that rewrites its own source is unusable without a way to see the result:
**`ycc -E FILE`** dumps the post-pass source with origin markers (comments, which the
pass ignores — the synergy is free). Familiar from `cc -E`. Neither `-E` nor `run`
exists today (`parse_cli_args`, `ycc.y:28-121`).

With one layer there is no earlier layer to inspect, so `-E` needs no level selector.

---

## Diagnostics required (R11)

`e*.y` fixtures for: unterminated `#{` at EOF; stray `}#`; `#` at EOF; unknown `#x` in
code position; unterminated string literal (the pass should report it rather than scan
garbage with the state machine stuck); a mid-token block at the start of a `def` name;
nesting past the pass's
own cap; a block whose output contains a NUL byte (a Y `str` can hold one —
`fs.write_bytes` documents NULs passing through — so it would land in the program's
source; reject it and name the block's line); emitted text past the size cap; a block
**emitting a `#{`** — which no source-level mutation can reach; a reserved-name
collision on `ycc_meta_expr`/`ycc_meta_stmt`; a non-top-level `import` inside a block;
`spawn`/`join`/`mutex`/`lock`/`try_lock`/`sem`/`post`/`wait`/`fork` in a block;
a block inside a `def` or `type` body; a non-declaration top-level statement in a file
with blocks (**a warning**, so a `t*.y` with `// expect-warning:`); a block in
`src/y/std/*.y`; a block in a module imported into the generator; and a generator that
**dies** — trapping, or exiting non-zero, or writing past the size cap — reported as an
error naming the block.

Not a fixture, though it is a case: **`}#` inside a string is legal** and the text
survives.

Two of these are only checkable for text the pass *sees*: a generator that emits
`def ycc_meta_expr` collides silently, like any other duplicate top-level name, and no
amount of checking in the pass can diagnose it. The manual has to say so.

`ytest fuzz` mutations: splice a bare `#`, splice a `#{`, splice an
unterminated `#{`, and `/* }# */`.

---

## Phases and gates

### M1 — run an image in a child

The image already exists as a byte array (`elf_build`; the driver just writes it out).
The question is only **where it runs**, and the answer is *not* in this process:

> Run the compiled image in a **forked child**, mapped into memory and called directly,
> with the pieces written back over a pipe.

An earlier draft called it in-process. That is wrong, and three independent things break
it:

- **The five trap stubs reach the host.** `src/y/arch/prelude.s` has five
  `exit_group` sites — the divide-by-zero, shift-count and cast traps. A generator that
  divides by zero writes its message to *ycc's* stdout and exits **1**, taking the
  compiler's exit status with it.
- **`exit(0)` makes `ycc` exit 0 having emitted nothing** — a silent success.
- **`%fs:24` is shared.** A guest `spawn` repoints the compiler's own thread block.

Forking dissolves all three at once. The child gets a copy-on-write `%fs`, so
`arch_prctl` there cannot reach the parent; a trap kills the child, not the compiler; and
`waitpid` turns the child's death into a diagnostic naming the block. It also makes the
guest's stdout and `exec` harmless. **This is the single biggest design change the
audit produced.**

So:

1. **Get the segments, not the file.** `ycc_assemble` returns
   `{ok, bytes, octal, error, times}` (`asm.y:1595`) — one flat array. M1 needs `code`,
   `rodata`, `bss_len` and `entry_off` separately, or it must parse the ELF it just
   built. Either way it is a signature change, ×2 copies. The `.bss` length in
   particular is needed and is not derivable from the flat bytes.
2. In the child: `mmap` a scratch region at an address that is **not** the image's own
   `0x400000` (`./ycc` is an `ET_EXEC` based there, `readelf -h ./ycc`, and even in a
   child a `MAP_FIXED` there would be a lie waiting to happen), copy the image in,
   `mprotect` `PROT_READ|PROT_EXEC`.
3. Fabricate `[argc][argv…][NULL]` at the top of an `mmap`ed stack. `_start` reads
   exactly that (`emit_one_fn`'s `_start` argv prologue) and nothing else — no crt, no
   auxv, no `__libc_start_main`.
4. **Call the entry point.** One emitter change: in run mode `_start` emits its
   ordinary epilogue (`mov %rbp,%rsp; pop %rbp; ret`) instead of `exit_group(0)`.
5. **The child writes the pieces back over a pipe** and exits. One convention for both
   uses: the generator appends to a `str`, and run mode's epilogue is
   `write(3, ptr, len); exit_group(0)`. So there is **no `.bss` accumulator to read back
   and no slot array in the image** — the pass holds the offsets, and the child's exit
   status plus byte count are the whole protocol.
6. The parent reads to EOF, then `waitpid`. Non-zero exit, or death by signal, is
   `error: the block at FILE:LINE trapped` or `exited N`, with the child's own stderr
   passed through so the guest can explain itself.

Two facts worth keeping straight:

- **The image can move** because `label_addr` returns **segment offsets**
  (`asm.y:554-563`) and every fixup is a *difference* of offsets
  (`asm.y:1345-1380`), so the code contains no absolute address to relocate. That is
  the real invariant, and it is the one that would catch an absolute-address bug —
  which `enc64.y` would **silently truncate**, since it has no `movabs`.
- **There is no `y_heap` to save.** The guest has its own four `.bss` words in its own
  image (`src/y/arch_x64.y:97-113`), and it is a different process.

Then `ycc run FILE` on top of it: same fork, propagate the child's exit status. Useful
alone, and it is how M1 gets tested without going through a block.

Rejected: running on a `spawn`ed thread — reuses the thread prelude for the stack, TCB
and `%fs:24`, and recycles the heap block, but pulls ~370 lines of thread prelude into
every binary that has a meta block and runs into the same `%fs:24` sharing.
Rejected: `execveat` on an `O_TMPFILE` fd — still a kernel exec, so the temp-file round
trip M1 exists to avoid.

*Gate:* `ycc run` over the fixture corpus produces identical stdout/exit to the
compiled-then-executed path; a fixture program that traps, and one that calls `exit(7)`,
each produce the right status and no compiler crash; R8 still holds (the fork doubles
peak, so measure); `make check` green. **Test this phase directly, not through blocks** —
it is load-bearing for all of M2.

### M2 — the pass

`src/y/meta.y`, exporting `lit_end` with the unterminated out-param first and collapsing
the `words_scan` copy onto it (the `lex_quoted` copy stayed, for the reason given above).
Then the per-file scan at the top of `native_resolve_seen`,
pieces accumulating across files, the three injected helpers, slot indices in source order,
the line map. Then: build `G`, compile it for the host with the pass off, run it in a
forked child via M1, splice the pieces into `P`, rebuild origins, hand `P` to the
existing lexer — unchanged.

*Gate:* every diagnostic above has a fixture; the fuzz cases pass; `src/tools/ytest/su_coverage.y`'s
file list updated with `meta.y`; `test/COVERAGE.md` rows; a manual section (short — one
construct); byte-identity from both compilers and across two consecutive runs; the LSP
reports no error on a meta file; and `ycc -E` dumps a program containing a literal `#{`
inside a string, and re-compiling that dump gives the same bytes.

---

## Risks

| risk | mitigation |
|---|---|
| **The program's top level runs once per round** — the price of emitting the call in place. With no nesting that is twice; with nesting, once per level. | A warning naming any non-declaration top-level statement in a file with blocks, plus the manual's "keep top-level `let` initializers pure" — and, where a round cannot yet produce a block's text, a stand-in round in which non-declaration statements are left out of `G` entirely (see [the reduction](#the-reduction-and-the-one-shape-it-costs)). AST-checked, not guessed. |
| **A block inside a function body** would have compile-time-fixed values and could silently never run. | A diagnostic. Blocks are the top level and other blocks, so every live block's call is in a `G` that runs. |
| **The `#{`/`}#` scanner is the fuzzer's main target** — `#{ "a}#b" }#`, `#{` at EOF, `/* }# */`, a string spanning lines. | One shared literal scanner, four states plus block comments, an own depth cap, a dedicated fuzz mutation set. |
| **A generator that traps or exits** used to kill the compiler. | Fixed by the fork: the child's death is a diagnostic naming the block. M1 is gated on exactly this. |
| **A block that grows without bound** (a generator in a loop) can exhaust the cap. | A size cap on emitted text with the block's line in the diagnostic. R8 is not negotiable. |
| **Headroom is ~4×, not 10×.** Re-measured: one compiler-scale compile is `TOTAL 382.487 ms 840407 KB`, max RSS 841896 kB, and 4 MiB `y_alloc_more` chunks (`prelude.s:347-372`) are never reclaimed. | The size cap covers emitted text; the child's peak allocation is separately bounded by the same cap. |
| **Two blocks cannot share a `let` in v1.** | One block emits both pieces; or a module. Documented with a table, and the reason it is a v1 limit rather than a design choice. |
| **Diagnostics inside generated code point at the block.** | Unavoidable and honest; the line map is exact for everything that is *not* generated, which is the case that matters. |
| **std sources are outside the splicer and after the parse.** | v1 makes a `#{` in `src/y/std/*.y` a diagnostic. Revisit only with `std_units` moved and a real origin for `std_compile`. |
| **A silently duplicated top-level name** (measured: no error, no warning at `-W 1`). Reachable by a generator emitting `def helper()`, or two flattened modules. | The bare import form namespaces modules, which prevents the second. A reserved-name diagnostic covers the injected helpers. |
| **`src/c` doubles every line** (R1). | Inherent. Most of it is the injected helpers and the scanner, both mechanical. |
| **A nondeterministic generator** silently breaks byte-identity far away. | Accepted policy (invariant 8): `make check`'s compare step names the program. |
| **A future Y `#` syntax** would collide with the pass owning `#` in code position. | Found immediately: the corpus-wide `rg` shows zero occurrences. |

## Answered questions (measured, keep out of the open list)

- **`let`/`const` do not hoist; `def` does.** The fact the whole scoping story rests on.
- **`tostring` handles a union value directly** (tested on `A | B`), so the block value
  can be enforced by one parameter type with no `match`.
- **Void does not coerce** (tested), so a void block is an existing type error.
- **`if` and block expressions are usable as values** (tested), which is what makes the
  nesting story work at all.
- **Cross-block `def` sharing does not exist** (tested) — hence "one block or a module",
  by decision rather than by omission.
- **Blocks are emitted in place at the top level, never hoisted** — hoisting puts a
  call outside every enclosing scope, so a block sees nothing. Measured both ways.
- **A block inside a function body is refused.** In-place emission makes it look like
  capture, but the value is compile-time-fixed and shared by every runtime caller, and
  the block silently never runs if nothing calls the function during generation.
- **Only code position is scanned**, so a `#{` inside any literal or comment is plain
  text and a generator may emit string literals containing `#{` freely.
- **The read-back channel is a pipe, not a `.bss` array.** Forking makes the child's
  memory unreachable, so an array would have to be copied out anyway; a pipe is simpler
  and gives the exit status for free.
- **The effective nesting cap is ~333**, not 1000 (measured) — that is the *parser's*,
  counted across five walks. The **pass's own** cap is **8**, and it is a cost limit, not
  a syntax one: see [Why the cap is 8](#why-the-cap-is-8).
- **Nesting is splicing, at every level, with no second dialect.** A nested block
  contributes text to the enclosing block's source, the enclosing source is recompiled,
  and the pass repeats to a fixed point — which is what [Deferred](#deferred-if-and-meta)
  called a layering model and cut. The round count is the nesting depth, and the pieces
  are spliced all at once, at the end, from the slot table.
- **The emitted-text size cap is an error**, not a warning — a resource limit the author
  cannot fix in place, and R8 makes exceeding it fatal.
- **The pass lives in `src/y/meta.y`.** Forced by the LSP being a second checker.

## Open questions

1. ~~What the pass's own nesting cap should be.~~ **Answered: 8** (`MG_NEST`), on measured
   cost, with a diagnostic that names the cost rather than leaving `too_deep` to fire
   inside a file that does not exist — [Why the cap is 8](#why-the-cap-is-8), and
   `e188_meta_nest_too_deep.y`. The open part is not the number but whether it should be
   a flag, and whether a deeper program should be allowed to spend more compile time
   deliberately; both are for the manual, not the pass.
2. Whether the top-level-statement warning should be an error when the statement is
   obviously impure (a call at top level) rather than a warning in every case.
3. Whether `-E` should also dump `G`, which is the text whose *diagnostics* are the ones
   a generator author actually hits.

---

## Corrections

This document was wrong twice while being written, and nine more times while being
built. All eleven are recorded, because a design that hides its corrections is a design you
cannot check. The first two are [found by designing it](#found-by-designing-it-two-that-changed-the-design);
the other nine are [found by building it](#found-by-building-it-nine-measured).

### Found by designing it: two that changed the design

**1. The generator program's layer order was self-contradictory.** An earlier draft said
both "`G` = the text at depths *d* and *d+1*" (shallower first) and, in its own trace
table, "depth-2 text + depth-1 text" (deeper first). With `let`/`const` not hoisting,
the order decides whether a `let x = 1;` at depth 2 is visible to the depth-1 blocks
that use it — and every `#meta` example in the document, `ideas/meta.y` included,
depended on the answer. Moot in v1, which has one layer; recorded because it is the
trap the layering model walks into, and because the fix for it — "put the deeper text
first" — is only half the answer: it makes `let` and `const` visible and leaves `def`
ordering as a second, separate question.

**2. Blocks were hoisted to the top of the generator program.** That put every call
outside any enclosing `def`, so a block saw no locals at all and **a generator took no
parameter** — the feature's usefulness capped at zero-argument functions. Fixed by
emitting the call in place.

That fix then produced a third problem, which is why the final answer is *in place, at
the top level only*. In-place emission makes a block inside a `def` capture that
function's scope, but only if something calls the function during generation, and the
value produced is spliced at one place so every runtime caller shares it — a trap, plus
a silent "never ran" mode. Restricting blocks to the top level keeps the capture that
matters (the file's own `def`s and `let`s) and drops both problems.

The price of in-place emission is that the program's top level runs twice, which is now
a warned-about rule instead of an unstated hazard.

---

## Deferred: `#if` and `#meta`

**Layering is no longer here — it is in v1.** This section used to be the home of the
"second compile per level" model, cut on the grounds that nesting had one artefact, a
demo, and that the price was a layering model. The price turned out to be exactly one
extra compile **and run per level, inside the compiler's own process**, which is
affordable: 13.8 ms and 34 MB per level on a 24 KB program, 43 ms and 103 MB per level at
the compiler's own size class ([Why the cap is 8](#why-the-cap-is-8)). So
[Nesting is splicing](#nesting-is-splicing-at-every-level) got built, and what is left
deferred is the *region* form — `#meta` — and `#if`.

What is still true of the cut: the honest baseline for "generate a file, then compile it"
is `ycc build` plus a code-generation package in `y.toml`, which has a dependency graph
and an object cache. The delta over that is *"don't write a temp file"* — **which is M1,
and is in v1.**

### What the layering model was, and what it turned into

`P₀` = the program's source. `P_d` = the text at depth *d*, with that depth's block
outputs substituted. A block at depth *d* is a **statement of `P_{d+1}`**, and its
output is spliced into the text at depth *d*:

```
P_{d+1} = the text at depths d+1 and d, as code, with the depth-d blocks as calls
```

Execution is **inside-out**: `P_{d+1}` runs to produce `P_d`'s source, down to `P₁`
producing `P₀`'s, then the program is compiled. One compile + one run per `#meta` depth.

**That is what shipped, minus the per-depth texts.** The prediction that forced the cut
was structural: each depth wanted its own `lines` list with its own `ofile`/`oline`,
threaded `native_resolve_seen` → `resolve_unit` → `compile_unit` → `emit_program`, which
are typed on one list each. The built version needs none of it, because a round is *one*
text: the pass rebuilds `G` from the post-run source of the previous round and re-compiles
it, so the only thing a depth adds is another trip round `meta_resolve`. `compile_unit`
and `emit_program` still take one `lines` list, because there is still exactly one final
program. The regions do exist internally — `sg_region_*` is where the reduction finds the
statements it leaves out of a stand-in round — but they are a pass-local detail, not a
parameter threaded through the pipeline.

### What is still cut: the `#meta` region

| | why it is still cut |
|---|---|
| **A block sees declarations at depth *d* and *d+1*** — so a generator can be written inline at file top level (`#meta`), with no extra file, instead of as a module. | A nested block already gets a version of this: `#{ … #{ … }# … }#` runs inside the enclosing text, so it sees the enclosing block's declarations. What `#meta` adds is seeing the **program's** top-level declarations, and that is what a generator *module* (`import gen;`) is for — already implemented, already tested. |
| **A `#meta` region's text is at file top level**, so a `def` in it is an ordinary top-level function — not a closure, with no capture question to get wrong, and no `{}` to scope it. That is the piece that lifting a block's `def`s out could not do safely. | A nested block still gets *its own* `def`s into the enclosing text, one level down per depth, which is enough for the composition case; a region would put them at depth 0, where a `let` from an enclosing block is out of scope. Cheap to add on top of a pass that already has regions and rounds, and it is not needed by anything measured. |
| It is the only route to **a generator that generates a generator**. | No longer true — nesting *is* that route, and it is what `t201_meta_nest_expr.y` tests. |
| Each depth's top-level statements **execute once per round** — a file append, a counter, an `exec` or a progress print repeats with no diagnostic. | Real, and already paid: the [reduction](#the-reduction-and-the-one-shape-it-costs) drops the statements that cannot compile in a stand-in round, and the warned-about rule covers the rest. A region would need its own accounting on top. |
| A `#if` condition needs a name for `os`/`target`, and `lint.y` needs the top-level-execution rule for regions. | Small, but both only make sense with the region. |

### The `#if` that was cut is not needed by `WINDOWS.md`

`WINDOWS.md` W4 wanted `#if` for exactly **one diagnostic** (`fork is not available when
targeting windows`), and W5 wanted it for per-target std sources. Both are reachable
without meta: W4 gets `os`/`target` as builtin constants in the checker (next to
`is_intrinsic_name`), and W5 puts its conditionals in per-target std *modules*, which
its own decision to put the target switch in the import splicer already provides.

So `meta.md` is **not** a prerequisite for Windows. It was believed to be because
`#if` looked like the natural place for a target conditional; it is not, and the checker
is.

### Block-local scoping stays as it is

Blocks remain lexically isolated — a `def` in a block is a nested `def`, local to it
(tested: `{ def helper() -> long { 7 }; print(helper()) }; { print(helper()) }` prints
`7` then `42`). Lifting them out would regress a closure case that works today. So the
deferred region is the sharing route, not a rewrite of block scoping.

---

### Found by building it: nine, measured

Written after the fact, so the design above can be read against what the code
actually does. Each is a place this document was wrong, with the measurement.

**1. The clone syscall does not transfer control, and the entry address is not
in the stack.** [M1](#m1--run-an-image-in-a-child) says `sysretq` pops it. Under
gdb the child comes back from `syscall(56, SIGCHLD, stack_top, 0, 0, 0)` with
`%rax = 0`, `%rsp = stack_top`, RIP at the *next* instruction — still running
ycc. So the transfer is one `jmp *%rax` later, which is why `jmp_at` exists
(`ir.y` `F_JMP_IND`, `enc64.y`'s `enc_jmp` `K.ind`, `types.y`'s typeof arm): a
`call` would push a return address onto the fabricated stack, and a process
entry point reads its argv from there.

**2. `MAP_FIXED` is unusable on this kernel.** `mmap(MAP_FIXED)` at a fresh
address immediately above an existing mapping returns `EINVAL`. So the image is
one `memfd` sized to the whole span (the ELF's bytes, then the `.bss` at its own
offset, the gap page being part of the file's zeros), one `mmap` `PROT_RW`, then
`mprotect(img, memsz, PROT_RX)`. The `.bss` is unusable until `ftruncate`, or
`mmap` past the end of a file gives `SIGBUS` rather than zeros.

**3. `split` drops ONE trailing empty element.** `split("a\n", "\n")` is `["a"]`.
Two consequences this document did not see: `lit_end`'s `end = n` is ambiguous
between "closed at the last byte" and "ran off the end" (hence the out-param, and
the three copies collapsed onto the one in `lexer.y`); and anything that splits
generated text to find its lines loses a trailing newline — the last line of
every piece used to run into the next one.

**4. An f-string is not `lit_end`.** A field holds one expression, and that
expression may be a string literal, so `f"{d["k"]}"` has no `lit_end` answer:
its closing quote is not the next quote in the source. The scanner calls the
lexer's own `fstr_walk`, which already knows that (and falls back to `lit_end`
when the f-string is broken, which is what the lexer does too).

**5. "A keyword can only start after a newline, `;`, `{`, `}` or `#{`" is right
about CODE, but a *word* inside a block is a position too.** `let t = spawn { … }`
has `spawn` mid-expression, and refusing it is the whole value of the check. So
the scanner stops at a word start as well — inside a block only, which is why a
file with no blocks still costs one `index_of` per file.

**6. `import` must not be tokenized, and the direction of the import graph is
forced.** G's text is resolved before it is tokenized, so a hoisted import is
spliced by the ordinary splicer with its dedup, its namespacing and its depth-32
diagnostic. And `meta.y` must not import `native.y`: the splicer dedups only
*downward*, so a cycle splices the file on the way back up a second time and
every `def` collides. The compile and the run therefore live in `native.y` and
take what they need through `mg_*` accessors (with `mg_setup` passing values,
because `strip_ns` rewrites `K.dot` reads but not `K.dotassign`).

**7. "The pass runs before the splicer's line loop, so `embed` is already
expanded" is true but not for the reason given.** The reason it has to be before
*that* loop is `std-unit selection`: `resolve_unit` picks the std units from the
text after the loop, and a block's generated text must be able to mention
`readline`. An embedded file's bytes land inside a string literal, and the
scanner has already read that line, so nothing in them can be a block either way.

**8. A block's slot must be its index in the block table, not a counter that
keeps counting.** The two resolves of one unit (collecting, then splicing) rebuild
the table, so a monotonic counter hands the second pass slots 4,5,6 for blocks
that asked for 0,1,2 and the pieces are matched to nothing. The counter resets per
pass (`mg_pass`), which is the one piece of state the second resolve has to reset.

**9. "Nesting is data, not splicing" was the wrong answer to a right question.**
The document argued that a block nested in a block could not be spliced, because
`G` is compiled before it runs — a nested block's text has to be *in* `G`. Both
halves of that are right and together they imply the opposite conclusion: the pass
compiles and **runs `G` again**, once per nesting level, and splices the outer text
last. No per-depth `lines` list is needed, so the "one structural change" the
[Deferred](#deferred-if-and-meta) section costed never existed. What the argument
did get right is the acceptance case it was written for: it is not a block's
*source* that is spliced but the rendering of its **value**, and that is why the
helpers still take a `str` and the pass wraps each body in `tostring(...)`
([What a block's text *is*](#what-a-blocks-text-is)). The cost, measured twice at
two program sizes, is 13.8 ms / 34 MB per level and 43 ms / 103 MB per level
([What the measurements cost](#what-the-measurements-cost)) — affordable, and the
depth cap is set from it rather than from the parser's limit.

Corrected in `ideas/meta.y` itself, twice: the `let count` block wanted the number
65 and got 65 as the *length* of the text the block generates (so it now yields
the text), and a `str` value spliced as text needs `lit` — which escapes — not
`quoted`, or it lands as bare code and the program's own parser sees
`let count = let names = …`. The file says so.

### What the measurements cost

Base is the M1 commit's compiler, same machine, `bench/y/*` compiled with each:

| | base | with the pass |
|---|---|---|
| `src/y/ycc.y` (self-compile) | 0.46 s / 1142080 KB | 0.47 s / 1157564 KB |
| `bench/y/scan.y` | 0.00 s / ~17.2 MB | 0.00 s / ~19.4 MB |
| `bench/y/hello.y` | 0.00 s / 2.25 MB | 0.00 s / 2.70 MB |
| `resolve` phase of `src/y/ycc.y` | 19.5 ms | 24.6 ms |
| `asm_bytes` of `src/y/ycc.y` | 5225719 | 5225719 |

The `scan.y` row is an artefact, and worth naming rather than hiding: it is one
benchmark crossing the 4 MiB heap-chunk boundary (five chunks instead of four,
and RSS counts the half of the last one that was touched). The compiler's own
`heap_used` for that file is 16326 KB before and 16334 KB after. Every benchmark
takes the `index_of(src, "#") < 0` fast path — none of `bench/y/*.y` has a `#` in
it at all — so the scanner itself is not in that number; the extra is the
per-output-line `ogen` map and the resolve indirection, which is why the self-
compile's resolve phase is the honest one to quote: **+5.1 ms and +15 MB on a
1.3 MB self-compile**, and both are only paid by a program that *has* blocks.

**Nesting is the second-order number, and it is the one the depth cap is set from.**
Measured on a generated program of 400 declarations (24 KB) with a nest of depth `d`
appended, 8 runs each, so the differences are the per-level cost rather than the
one-block baseline:

| | depth 0 | depth 7 | per level |
|---|---|---|---|
| 400 decls, 24 KB | 25.5 ms / 61 MB | 122.3 ms / 293 MB | **13.8 ms / 34 MB** |
| 1600 decls, 122 KB (compiler size class) | 0.09 s / 202 MB | 0.39 s / 924 MB | **43 ms / 103 MB** |

The same 400-decl program with **no block at all** compiles in 11.0 ms, so the block
itself — not the nesting — is the 14 ms baseline, and both columns above are
linear in the depth with no cliff and no super-linear term at 7. Memory is the
binding constraint, which is why `MG_NEST` is 8 and not 16:
[Why the cap is 8](#why-the-cap-is-8).

---

## Landing order

```
M1   run an image in a child + ycc run     (no dependencies, useful alone)
M2   the meta pass                          (needs M1)
M3   the C twin, per PORTING.md             (needs M2; this is not optional)
M4   the manual section in docs/src         (R11; COVERAGE.md already points at it)
```

**M3 is not optional and is not a follow-on.** R1 makes the C twin 1:1, so a `src/y`
change without its `src/c` mirror is an unbuildable compiler — `make cycc` would compile
against a `native.c` that no longer matches the emitter's shapes. The gate is
`make port-check`, which aims the port suite at `./ynew`: the C copy and the Y build must
agree **byte for byte** on every `test/y/**.y` plus `src/y/ycc.y`, with identical
warnings, and a program both reject must get identical diagnostics. With N new
diagnostics that is N new two-compiler assertions, so every message is a byte-for-byte
contract rather than a wording preference.

**M4 exists because `test/COVERAGE.md` already carries rows pointing at `02-lexical` →
"Meta blocks"** and no such section exists. The coverage suite cross-checks the manual's
sections against `COVERAGE.md`, so the rows and the prose have to arrive together.

Windows does not wait on any of this — see [`WINDOWS.md`](WINDOWS.md).
