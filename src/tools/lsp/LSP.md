# LSP.md — a language server for Y, and the VS Code extension

**Status: built and running; §11's milestone table is the authority.** `yserve`
exists, is driven by a VS Code extension in `vscode-y-lang/`, and is tested as a
real process. M1 (R1, errors and warnings), M2 (R2, semantic tokens) and M3 (R3,
formatting) are done; **M4's Stage A is done** (R4, R5, R6 — hover, go-to-
definition, completion, from the open buffer's own declarations), measured at §11.3
and costed at §9.2.

This line used to read "proposed, not implemented … nothing here has been built
yet", which was wrong from the moment M1 shipped and stayed wrong through four
milestones. A design document that understates its own state is worse than one
that has none: a reader checks whether it is real before reading it.

What is **not** built, precisely — and this list was three entries long while three
of them were wrong, which is the failure mode this document's own next paragraph
warns about, so each was checked by running the thing rather than by reading the
claim:

- **M-sugar (§16)** — C3's recursive aliases through `[T]`/`T?`/`{K=>T}` and then
  C5's `json{ }` / `json[ ]` literal syntax. The only milestone open. It is a
  **compiler** feature rather than LSP work, nothing here is blocked on it, and no
  requirement above needs it. §16.5 has the cost and §16.6 says why C3 is the
  separable one.
- **A marketplace entry.** `make lsp-vsix` produces
  `y-lang-0.2.0.vsix` through `@vscode/vsce` and it is on disk, so the packaging
  this list used to deny exists; what does not exist is a *published* listing.
  `package.json` carries a `publisher` and no `repository`, which is what
  publishing needs and this document cannot honestly claim.
- **A user switch for the semantic layer** — and it is deliberately absent rather
  than missing. The grammar is unregistered (§10.3a), so semantic tokens are the
  only highlighter and a switch for them would reintroduce the exact
  "no syntax highlighting" report §10.3a records. R2.3 used to promise one; the
  promise was written before the grammar was unregistered and is withdrawn.

Everything else in the milestone table is delivered and marked as such: M-json,
M1, M2, M3, M4 and M5 done, M0 dropped. Each row names the checks that make its
claim checkable, and none of them is a number nothing compares.

The requirement text below is unchanged and still the target; where a
requirement is partly delivered the status note at its head says which part. The
one standing deviation is R2.3's `method` class: nothing in the language
distinguishes a method from a function called through a field, and §R2.3 says so
where it happens rather than shipping a class that guesses.

**On citations.** Compiler internals are named by **symbol** — `types.check_program`,
`native.origin_file`, `rename.rn_reaches_go` — and never by line number. `src/y`
moves: a single refactor shifts hundreds of lines, and during this document's
life `native.y` moved twice (the wide-environment index, then the extraction of
the prelude into `src/y/arch/*.s`) for a cumulative drift of over 600 lines on
some references. A line citation is stale the day it is written, and a stale one
is worse than none: it reads as authoritative and points at unrelated code.
Where a line number remains — a handful, mostly into the LaTeX manual, which
changes rarely — `check-refs.py` next to this file resolves every citation and
prints what it finds there:

```sh
python3 src/tools/lsp/check-refs.py -v
```

Run it after touching `src/y`. It used to say it was not wired into `make test`
because that is the compiler agent's file; it is wired now, into
`test/sh/test_lsp.sh` alongside `check-names.py`, so `make test` runs it.

It supersedes the sketch at the end of `future.y`:

```
// some kind of full featured LSP, which can be used by vs code etc
// will provide features like autocompletion, go-to-definition, and real-time error checking
// will also support formatting code
// a new entrypoint in src/y/lsp.y, which will make a seperate binary, but it can share code with ycc
```

The sketch's filename (`src/y/lsp.y`) is the one part we deliberately do not
follow — see §4.

---

## 1. What this is

A Language Server Protocol server, `yserve`, that makes the Y compiler's
existing knowledge available to an editor, plus a VS Code client that speaks to
it. It is not a separate analysis: every diagnostic, every type and every
definition it reports is produced by the same `src/y/` code that `ycc` itself
runs, so the editor and the command line can never disagree.

Six features, in the order they are built:

| | Feature | Milestone |
|---|---|---|
| 0 | `std/json.y`, a JSON module for Y programs | M-json |
| 0b | JSON **literal syntax** in the language, so the module needs no `json.num` / `json.obj()` | M-sugar |
| 1 | Errors and warnings | M1 |
| 2 | Highlighting (LSP semantic tokens) | M2 |
| 3 | Formatting | M3 |
| 4 | Type information (hover) | M4 |
| 5 | Go-to-definition | M4 |
| 6 | Auto-complete | M4 |

M-json lands first and blocks nothing else in the tree — it is an ordinary std
module — but M1 imports it, so it is built first. It is specified in full in
**§15**, including four language constraints that shape its API and that were
established by measurement, not assumption. The sugar that would remove the
explicit constructors is specified in **§16**.

M1–M3 need **no change to the compiler at all**. M4 needs one, described in §9.

## 2. Goals

- **One source of truth.** Diagnostics come from `types.check_program` and
  `lint.lint_unit`. Hover comes from the checker's own inferred types. Nothing
  is re-implemented, approximated, or pattern-matched.
- **No compiler fork.** `yserve` is a *program* that imports the compiler's
  modules the way `ycc.y` does. It never re-parses or re-checks anything
  `ycc` already knows.
- **Trust the checker.** Where the checker reports all its errors at once, the
  server publishes all of them. Where it stops at the first (the lexer), the
  server does too, and says so.
- **Safe on broken input.** An editor is fed half-typed programs constantly.
  No input may kill the server, hang it, or produce a wrong answer silently.

## 3. Non-goals

- Code actions, refactorings, rename-symbol, and folding. All are natural
  once §9.2 exists, and all are out of scope for v1.
- `ycc build` packages (`y.toml`, the object cache, git vendoring). A package
  graph has its own driver (`pkg.y`) and its own lifecycle; v1 treats a package
  as a whole-program import boundary.
- Multiple workspace folders, or any multi-root notion.
- Language Server Protocol 3.18 optional requests beyond the six above.

---

## 4. Architecture

```
┌───────────────────────────────────────────────────────────────────┐
│  VS Code                                                          │
│  src/tools/lsp/vscode-y-lang/   the EXISTING extension, extended   │
│    src/extension.ts             client: spawns ./yserve, speaks LSP│
└────────────────────────────┬──────────────────────────────────────┘
                             │  JSON-RPC 2.0 over stdio
                             │  Content-Length framed
┌────────────────────────────┴──────────────────────────────────────┐
│  yserve            parent process: framing, and the document       │
│                      store, and NOTHING else                      │
│                      read a frame → update the store → fork() →   │
│                      wait_pid()                                   │
│                           │                                        │
│                           └── child process, per message:         │
│                                 import tags, lexer, parser,       │
│                                 types, rename, lint, native       │
│                                 resolve → tokenize → parse →      │
│                                 strip_ns → rename → check → lint  │
│                                 → map positions → JSON            │
└───────────────────────────────────────────────────────────────────┘
```

### 4.1 Why fork per request

Three properties of the compiler make a long-lived in-process server
incorrect or unsafe. For each, forking is the whole fix.

1. **`exit(1)` in the lexer.** Two `exit(1)`s in `lexer.y` print
   to stdout and `exit(1)` on an unterminated string literal or block comment.
   `arch_x64.y`'s `exit` is `exit_group`, so this kills every thread and the
   whole server. In a child it kills one request. §5.1 adds a pre-flight pass
   so the case is *diagnosed* rather than merely survived.
   `native_resolve_x` has the same shape for an unresolvable `import`
   (five in `native_resolve_x`, for an `import` that cannot be resolved).

2. **Module-level state that is never reset between compiles.** The compiler
   is a one-shot batch tool; roughly twenty module globals accumulate across
   runs, and some are only reset on the paths `ycc` happens to take:

   | Module | Globals |
   |---|---|
   | `types.y` | `teq_unfolds` (`:368`), `tcanon_named` (`:447`), `inf_keys`/`inf_typs` (`:3996-3997`) |
   | `rename.y` | `rn_tref_ids`, `rn_tref_nodes`, `rn_reach_memo`, `rn_reach_n` (`:316-324`) |
   | `native.y` | `tcode_refs`, `tdec_encs`, `tdec_refs`, `tdec_n` (`:75-78`), `ty_sig_*` (`:91-93`), `ush_nodes`/`ush_vals` (`:95-96`) |

   Whether each is a harmless cache or a real cross-document leak is not
   established, and the emitter's record-hashing check (*two record types hash
   to*) suggests at
   least one is not harmless. A fresh process per request makes the question
   moot.

3. **Nothing is ever freed.** `src/c/yv.h` allocates every value once and
   keeps it for the process lifetime; `src/y` has the same model. A server
   that compiled documents in-process would grow without bound —
   `ycc.y` itself needs ~390 MB. The parent process here never runs the
   pipeline, so its heap stays small and `fork()` is cheap.

`fork {}` and `wait_pid(pid)` are builtins (documented in the manual under *Builtins*;
emitted by the `spawn`/`fork` arm in `native.y`). `pipe(2)` is syscall number 22; the raw
`syscall` builtin reaches it, as `std/fs.y` already does for every other fd
operation.

### 4.2 The parent owns the state; the child owns the work

This is the part that is easy to get wrong, and the first implementation got it
wrong. `fork {}` gives the child a **copy**: every write the child makes dies
with it. So a document store kept in the child is empty again for the next
message — and the symptom is quiet and convincing, because a formatting request
for an unknown document answers `{"edits": []}`, which is exactly what "already
formatted" also answers.

So the two halves of a message are handled by two processes:

| | runs in | what it does |
|---|---|---|
| `dispatch.apply_state` | **parent** | records which documents are open, their text and version; sets `initialized`, `shutting`, `exiting` |
| `yserve.handle_one` | **child** | everything else: the checker, the linter, the formatter, building the reply |

The parent calls `apply_state` **before** the fork, so the child inherits an
up-to-date view. The split is safe because the parent's half cannot exit:
`json.parse` is tolerant (it returns `none`, it does not raise) and the rest is
field reads and map assignments. That property is what makes fork-per-request
work at all — the parent has to be unkillable, because it is the only process
that survives.

`test-e2e.sh` pins this: it formats a document in one message, then formats it
again in the next, and requires both to answer identically. A child-local store
fails that.

### 4.3 The child may not write to stdout

The client reads fd 1 and *nothing else on fd 1 is a message* — that is the
protocol. But the compiler prints to stdout on its way to dying:

```
error: cannot open import './nope.y' (resolved to 'nope.y')
```

One line like that in the middle of the stream and the client reads a malformed
frame, loses its place, and drops the connection. So before forking, the parent
`dup`s stdout to fd 200 (`syscall` 32), and the child `dup2`s **stderr onto fd 1**
(`syscall` 33) before doing any work. Anything the compiler prints goes to the
client's log, where it belongs, and the reply goes to fd 200. 200 is high because
the runtime hands out low fds for files.

`test-e2e.sh` asserts that every frame the server emits parses as JSON, which is
what catches this class of bug: an unframed line fails immediately.

### 4.4 A missing import is diagnosed, not survived

`native_resolve_x` handles an unresolvable `import` by printing to stdout and
`exit(1)`. Forking contains that, but the user still gets nothing: no squiggle,
just a line in a log. So `diag.check` resolves the buffer's imports **itself**
first (`diag.missing_imports`, using `scan` spans — `import` is a *contextual*
word, not one of the twelve keywords, which is the kind of detail that makes this
silently return nothing) and reports a diagnostic on the line of the import.

It then returns those diagnostics *alone*. With a file missing there is no
program to check, so anything else would be a cascade off the same cause, and a
wall of red for one typo is how a user learns to ignore the panel. They come back
as soon as the import resolves, because the editor re-checks on every keystroke.

### 4.5 What the server does *not* do

It does not run the emitter, the assembler or the ELF writer. `yserve` never
imports `asm.y`, `elf.y`, `arch_x64.y`, `enc64.y` or `dwarf.y` — and it could not
pull in the prelude by accident either, since the compiler's own assembly now
lives in `src/y/arch/*.s` (`prelude.s`, `threads.s`) embedded by both copies
(`PORTING.md` rule 11), rather than being written inline in `arch_x64.y`.
Diagnostics stop at `lint_unit`, which is the last thing `compile_unit` does
before codegen (`compile_unit`'s error short-circuit). A smaller binary, and no way to
accidentally write a file.

---

## 5. Repository layout

```
src/tools/lsp/yserve.y        entry point, framing, fork, pack
src/tools/lsp/json.y          JSON value, parser, emitter       §7
src/tools/lsp/rpc.y           Content-Length framing, dispatch    §7
src/tools/lsp/pos.y           line tables, byte ↔ UTF-16, ranges  §8
src/tools/lsp/scan.y          tolerant span scanner              §5.1, R2, R3
src/tools/lsp/sem.y           semantic tokens (M2)                R2
src/tools/lsp/sym.y           documentSymbol / the outline        R2
src/tools/lsp/scope.y         declarations, visibility            R4, R5, R6
src/tools/lsp/nav.y           the word at the cursor, and its declaration  R4-R6
src/tools/lsp/strm.y          the string methods, from types.str_method    R6
src/tools/lsp/fmt.y           the formatter                       R3
src/tools/lsp/diag.y          diagnostics: errors and warnings    R1
src/tools/lsp/dispatch.y      the parent/child split              §4.2
src/tools/lsp/serve.y         the server: methods, pipeline       §7

# `scope.y` was `index.y` until M4. An `import` binds the module's BASENAME as
# a name in the shared namespace, and native.strip_ns rewrites every `name.field`
# in the WHOLE program as a qualified module reference -- so a module called
# `index` turned the compiler's own 42 `index.idx` / `index.arr` reads in
# src/y/types.y into module-qualified names that do not exist, and every one came
# back as "undefined variable" from inside types.y with nothing pointing at the
# server. `check-names.py` now tests each module's basename for this.

src/tools/lsp/vscode-y-lang/  the VS Code extension (existing)

src/y/std/json.y             the JSON module (M-json, §15)
```

`src/tools/` is where tools live — the dead `lsp` and `as` prototypes already
sit there, and this plan takes over `src/tools/lsp/` rather than adding a
parallel directory.

### 5.0 Why not `src/y/lsp.y`

`PORTING.md` requires `src/c/` to be a **1:1 copy** of `src/y/`, enforced by
`test_port.sh`, which compiles every `test/y/**.y` with both compilers and
requires byte-identical binaries. A module in `src/y/` therefore implies a
`src/c/` twin — and, per `AGENTS.md`, a twin written under the C value model
(`yv.h`: `none|bool|long|float|str|array|record`) which has **no function
value**, so every callback-shaped structure would have to be avoided.

`src/tools/` modules are modules of a *program*, exactly like
`src/y/std/*.y`, which `PORTING.md` records as "stay Y". There is no twin and
none is wanted. `yv.c`/`yv.h` (see `PORTING.md`'s module map) is the existing precedent for
"no Y twin".

**`PORTING.md` and the layout section of `AGENTS.md` need a line saying so**,
or a later reader will try to port `src/tools/`. That is a follow-up, listed
in §12.

### 5.1 `scan.y` — the tolerant span scanner

One byte-level pass over the buffer that produces a classified span list:

```
{ off: long, end: long, kind: long, line: long, col: long }
```

with `kind` covering at least: line comment, block comment, string, byte
string, char, f-string (with its interior fields delimited separately),
number (int / float / radix), identifier, keyword, contextual keyword,
operator, punctuation, and `error`.

It has three jobs, and two of them exist because the lexer cannot do them:

- **Comments.** `tokenize` discards them entirely. Nothing downstream of the
  lexer can recover them; the AST has no comment representation.
- **Unterminated literals.** `scan.y` reports them as a diagnostic *and*
  returns a **repaired buffer** — the closing quote, or `*/` — so `tokenize`
  is never reached with input that would hit either `exit(1)` in `lexer.y`. The
  repair is for the child process only; the buffer the editor holds is never
  modified.
- **Source spans.** See R2 for why these cannot come from `tokenize`.

`scan.y` and `tokenize` are two classifiers over the same bytes and must agree
on where every token begins. §11 makes that a test, not a hope.

**It is not a formality: the test found two real bugs in `scan.y` on its first
run over the corpus**, both in numbers. A `.` only joins a number when a digit
follows it, so `in 0..1000` is three tokens (`num 0`, `op ..`, `num 1000`) —
without that rule the scanner read `0.` as one number and the range operator
lost its start, in 13 corpus files. And a radix prefix with no digit of its own
radix (`0x`, `0x_`, `0b2`) is not a number: the lexer takes the following word
characters into the bad literal and reports it once, and so must the scanner.

The corpus is 493 `.y` files — `src/y`, `src/tools`, `bench`, `test/y`. Two
regions are excluded from the comparison, and both exclusions are *reasons scan.y
exists* rather than concessions: comments, which `tokenize` discards, and
f-strings, which it desugars. The current result is 0 mismatches over ~407 000
spans and ~423 000 tokens. A ninth file class -- text `tokenize` cannot lex at
all, because an unterminated literal is `exit(1)` -- is checked separately: all 9
such corpus files must be *repaired* into text that lexes, which is what stops
the server dying on the first `"` a user types.

The scanner has no `break` and no `continue` either -- written before Y had
them, so every early exit is still a flag. That is now a choice rather than a
constraint: `scan.y` could use `break`/`continue` (TODO.md §5 is only the
*labelled* form). It has not been converted, because the flags are already
tested against the lexer by `test-agree.sh` and a rewrite would put that
agreement at risk for no gain in speed or size. An unclosed block comment needs
its own `ran_out` state either way: left to the loop condition, `bump` takes
the cursor to the end of the buffer and then takes nothing, and it spins.

---

## 6. Requirements

Severity for diagnostics follows `code`: 1 = error, 2 = warning. VS Code's
`DiagnosticSeverity` numbering is used unchanged.

### R1 — Errors and warnings (M1)

**R1.1** On `textDocument/didOpen`, `didChange` and `didSave`, publish
diagnostics for the document within 300 ms of the last keystroke.

**R1.2** Diagnostics come from `types.check_program` and `lint.lint_unit`, in
that order, with **no code path in between**. `yserve` must not use
`native.emit_program` or `native.compile_unit`, because `compile_unit`
short-circuits: when `len(errors) > 0` it returns before lint ever runs
(`compile_unit`'s error short-circuit). An editor must show both an error and the warnings
around it; the command line never has to.

**R1.3** All diagnostics are reported, not just the first. The checker
guarantees this through its error-poison type: every error site yields
`t_unk()` (`types.t_unk`), and `teq` (`types.teq`) matches `tunk` against
everything, so one root cause produces one message and no cascade. The
server must not deduplicate, and must not apply the same-position filter
the same-position filter in `ycc.y` applies when printing.

**R1.4** A diagnostic is positioned by `(origin_file(line) → path, line,
column)`. The compiler's positions are 1-based with the **column counted in
bytes** (stated in the manual under *Integers*), always in *spliced-line*
space; the
origin map (`native.y`'s `Origin` comment) maps a spliced line back to its file and its
line there. Conversion to LSP positions is §8.

**R1.5** A diagnostic covers a real range, not a point. The end is the end of
the token beginning at the diagnostic's position, looked up in the token list
the server already holds; 1 character when no token starts there (a synthetic
or operator position).

**R1.6** `-w` equivalent: a `y.lsp.warnings` setting maps to `wlevel` 0 or 1.
Level 1 adds the two dropped-value checks and the empty-`else` check, all gated
on `wlevel` in `lint.y`. Off means `wlevel` 0, never "no warnings".

**Delivered, and it needed no server change at all** — which is why this one is
here while R1.8 above was not. `yserve` has always taken `-W` / `--wlevel` on
argv: the flag is parsed before any state exists and it changes what
`check_program` is *asked for*, not how a message is answered, so it belongs on
the command line rather than in `initializationOptions`. The client had simply
never passed it. `client.ts`'s `serverArgs(root, warnings)` now does, and
`activation-check.js` asserts the argv the client actually builds: `--stdio` alone
at default settings, `--root <dir> -W` with both settings on.

**Off by default, deliberately.** `yserve`'s own default is `wlevel` 0, so off is
what every user sees today and what the client passed before this setting existed.
It is worth saying that this is *less* than `ycc`, which warns by default: an
editor that silently shows fewer warnings than the compiler is a small defect of
its own, and this is the switch that fixes it. Changing the default would change
what every existing user sees, which is a decision for the user rather than a bug
fix, so it is documented instead of done.

**R1.7** Diagnostics are published per document. A diagnostic whose origin is
an imported file is published against that file's URI, so a typo in an
imported module is visible without opening it. Publishing for the root
document also publishes empty arrays for files whose diagnostics went away.

**R1.8** `y.lsp.checkOnChange` (default on). With it off, only `didSave`
publishes. Compilation is skipped entirely for unopened changes.

**Delivered**, and the requirement above had been true of nothing for as long as
it had been written. Two independent gaps, and the second is the one worth
remembering:

1. **`initialize`'s params were dropped on the floor.** `dispatch.lifecycle` took
   `(st, id, method)` and nothing else, so there was nowhere for the client to put
   the value. Adding the parameter was the obvious fix and it was **wrong**:
2. **the server forks per request, so the child cannot remember anything.** The
   parent records what must survive (`dispatch.apply_state`) and the child answers
   from a copy and dies (§4.2). A flag read in `do_initialize` lives in the child
   that read it: the client said `false`, the child honoured it, and the *next*
   keystroke got a server that had forgotten — so diagnostics were published on
   every change exactly as before, with a passing-looking fixture if the test
   happened to send both notifications down one connection. The setting is read in
   `apply_state`, in the parent, which is the only side of the fork that survives.
   `t019_checkonchange` drives `apply_state` with a raw frame for that reason, and
   `client-check.js` runs a second real session against a second process because
   the option is read once per session and cannot be re-negotiated.

What "off" means is the other half, and it is **not** "ignore changes": `note_change`
runs in the parent as always, so the buffer is current, and only the *publish* is
skipped. The alternative reading would leave hover, completion, semantic tokens and
formatting answering about text the user has already replaced — worse than the slow
check the switch exists for. `didOpen` and `didSave` still check either way, so an
OFF user is not left without errors.

A missing, `null` or non-`bool` value all mean ON, so a client that says nothing
gets the behaviour the server always had. The client's own default is `true` and
`activation-check.js` asserts **both** directions — every setting `package.json`
offers is read by the client, and every setting the client reads is offered —
because `y.lsp.checkOnChange` is exactly the shape of bug that check exists for: a
setting in the settings UI that does nothing. (Verified: deleting the one line that
reads it turns that check red.)

**R1.9** Unsaved buffer contents are what gets checked. `native_resolve_x`
takes source text, not a path (`native.native_resolve_x`); the `native_resolve_x` call in `ycc.y` is the only
`fs.read_file` in the pipeline. The document arrives from `didChange`.

**R1.10** Non-parsing input is a diagnostic, not a crash. A `ferr` token
(the lexer's `ferr` sites) becomes a parse error (the parser's `ferr` re-raise) and is reported
like any other.

### R2 — Highlighting (M2)

**R2.1** Semantic tokens are the **only** highlighter. The TextMate grammar
is removed from `package.json`'s `contributes`. The grammar file stays in the
repository, unregistered, so re-enabling it is a one-line revert.

**R2.2** Spans come from `scan.y`, never from `tokenize`. f-strings are
desugared *inside the lexer* (`lexer.lex_fstring`): `f"a{x}b"` is emitted as
`(" " + #fmt(x, "") + "b")`, with positions rebased onto the original text
(the position rebasing inside `lex_fstring`) so they stay in range — but several synthesized tokens
share one position and none has an extent. The token stream cannot yield
source spans for an f-string.

**R2.3** The legend covers, at minimum: comment, string, number, keyword,
`self`/`none`, variable, parameter, function, method, type, builtin,
operator, punctuation. **Delivered**, with one honest deviation: `method` is not a
class, because nothing in the language distinguishes one — a method *is* a function
called through a record field, and a name after a `.` is classified `property`
whether or not what it names is callable. 

> **There is no `y.lsp.semantic` setting, and this paragraph used to claim there
> was.** It is not implemented, and it should not be: the grammar is unregistered
> (§10.3a), so semantic tokens are the **only** highlighter, and a switch that turns
> them off would leave the user with no colours at all — which is the exact defect
> §10.3a records having been reported. A user who wants fewer colours has a theme.
> The claim was written before the grammar was unregistered, when the two layers
> really did both paint every identifier.

The legend is 14 entries, the eight syntactic ones at their existing indices and
the five semantic ones **appended** — an editor's theme is keyed on those numbers,
so renumbering repaints every file in the user's project. `t009_proto` asserts the
advertised list against `sem.token_types()` rather than against a literal, and
`t010_sem` asserts each constant against `legend[index]` by name.

Every class is resolved, none is inferred:

| class | decided by |
|---|---|
| `builtin` | `native.intrinsic_names()` — the compiler's own list |
| `type` on a **language type name** — `long`, `str`, `float`, `void`, `mutex`, `sem`, `int` | `parser.type_word_names()` — **the list the parser parses with**, exported for this (§9.2 A8). A mirrored copy here would drift the first time a primitive is added, which is the same argument as the builtins above and the same hazard |
| `parameter` / `function` / `type` | `scope`'s declaration kinds (`D_PARAM`, `D_DEF`, `D_TYPE`) |
| `function` on a `let` | the text after the name: `: (long) -> long` is a function type, `= def (` is a function literal |

The type-name row has a second half, and only one is obvious: a user name that
**happens** to be a type name stays `variable`, so a `let long = 1` is a variable
called `long`. Both halves are pinned, because the other direction is wrong too.

A type name used to be painted as an ordinary variable, which is the plainest way
for a highlighter to say nothing: every type in the language looked like a name
(§11.6).
| `property` | the name is after a `.` — a fact about the text |
| `variable` | everything else, **including every name that resolves to nothing** |

Two limits, both pinned by `t017_sem` rather than left to be discovered. A record
LITERAL's field name is `variable`, not `property`: `a` in `{ a: 1 }` is followed
by `:` exactly as `x` in `let x: T = 1` is, and what tells them apart — that the
brace opens a record and not a block — is not something a span knows. And a
declaration's own token is asked about differently from a *use* of it, because a
parameter is not in scope at its own declaration (`in_scope` compares against the
body's `{`, still to the right), so `nav.find_decl` answers nothing there;
`nav.decl_at` asks the separate question "is this token some declaration's own
name", which is what an editor wants painted.

**R2.4** Tokens are emitted as an LSP delta against the previous document
state, and must survive the round trip: for every fixture, re-deriving
absolute positions from the delta must reproduce the server's own token list
byte for byte.

**R2.5** A buffer that does not tokenize still highlights. `scan.y` is
tolerant, so an unterminated string highlights as a string with an error
marker rather than blanking the file.

### R3 — Formatting (M3)

**R3.1** `textDocument/formatting` returns **one** `TextEdit` replacing the
whole document. Minimal diffs are not attempted; VS Code handles a full
replacement well and it removes the need for a diff algorithm in Y.

**R3.2** The target style is **derived from `src/y/`** — the compiler's own
~20 000 lines. Four-space indent, brace on the same line, spaces around binary
operators, none inside parentheses. The tree staying diff-clean against
itself is the strongest available signal that the formatter is correct.

**R3.3** Formatting never consults the AST. It walks the token stream and the
comment spans from `scan.y`, merged by offset. Consequences, all intended:

- it works on a file that does not parse;
- comments survive, because `scan.y` finds them;
- the f-string spelling survives, because it is never desugared;
- `x!`, `?:` and implicit-return blocks are left as written.

**R3.4** If the buffer does not tokenize, return **no edits**. Never rewrite a
broken buffer.

**R3.5** Idempotent: `format(format(x)) == format(x)`, byte for byte, over
every `.y` file in `test/y/` and `bench/y/`.

**R3.6** At most one blank line is preserved between items, and only where the
input had one. Trailing whitespace is removed -- except the run of spaces
*before a trailing comment*, which is the author's alignment column and is kept.
The file ends with exactly one newline.

**R3.6a** **Author layout is copied through, not normalised.** Two cases:

- *Inside a bracket that spans lines*, every gap is emitted verbatim. src/y/
  lays record literals out in columns --
  `times: [{ name:"a:split", us:t1 - t0, heap:h1 - h0 },` -- and normalising
  that destroys a table. The formatter normalises the spacing of a single line
  and leaves a layout the author built across lines alone.
- *A trailing comment* keeps its column.

This is the difference between a formatter people leave switched on and one they
turn off. It also means the formatter is conservative rather than canonical,
which is the right trade for a language whose own source is hand-aligned.

**R3.6b** What the formatter deliberately does NOT reproduce: src/y/ closes
nested **blocks** tight (`{ ... }};`) but pads nested **records**
(`{ k: v } }`). Telling them apart needs to know what each brace opened, which
is parser knowledge this does not have (R3.3), so the padded form wins -- it
never runs two constructs together. The same goes for the 46 tight-brace
outliers against 1651 padded ones: the formatter writes the house style.

**R3.6c** The measured residue on `src/y/` (29 files, both compilers):
5 byte-identical, 1184 differing lines, of which ~285 are the column-aligned
continuations of R3.6a, ~46 the tight-brace outliers of R3.6b, and the rest
blank-line collapsing and a trailing-newline normalisation (`labels.y` and
`tags.y` ship without a final newline; R3.6 adds one). Idempotence -- the actual
requirement of R3.5 -- holds over every file in the tree that lexes.

**R3.7** Rules live in one table, overridable per `y.lsp.format.*` settings:
indent width, column limit, operator spacing.

**R3.8** Also reachable as `yserve --fmt FILE`, so it is testable and
fuzzable from the shell without a client.

### R4 — Type information / hover (M4)

> **Status: delivered.** Both halves are here. Hover shows the checker's own
> inferred type (§9.2 A2) and, underneath it, the declaration under the cursor
> (its signature as written, plus the comment above it).
>
> It was staged this way on purpose and the staging is worth keeping in mind when
> extending it: the *declaration* half needed no compiler change, and the *type*
> half was left out rather than approximated — a guessed type is worse than no
> type, because the user cannot tell it from a real one. That rule survived the
> change and now decides the edges instead of the whole feature (§9.2.2): where
> the checker indexed nothing the answer is `null`, and where the server cannot
> type a receiver it refuses rather than answering with something adjacent.

**R4.1** `textDocument/hover` returns the type of the expression under the
cursor, rendered with `types.tstr` — the one spelling of a type, the same one
diagnostics print and `typeof` returns, so a hover and an error message read
alike. `x + y` hovers as `long`; `a[i]` as the element type of `a`; `p.field` as
the field's declared type. **Delivered** (§9.2), with the three consequences that
are part of the requirement rather than extras to it:

- an expression that is **not a name** — a literal, an operator, a call's `(` —
  answers too, with no `range`, which the protocol allows;
- a record's **field** answers with its type and **no declaration**, because a
  field is not a binding and there is nothing for the index to find. Asking for
  a declaration *first* is what made the first version answer `null` here;
- where the checker indexed nothing the answer is `null`, and `t016_types` pins
  three such positions.

Three positions that a user reported as answering nothing are now answered, and
they are the same requirement: a name's own declaration, a parameter's own name,
and a call's callee (§11.6). A **parameter** needed a compiler change to be
answerable at all — `Func.params` is a list of bare strings, so a parameter had no
position to record — and a **builtin** needed one too, because an intrinsic is
matched by name and its callee identifier is never visited. Where a declaration's
text already IS the type (a `def`, a parameter), the hover prints it once rather
than twice; where the checker holds no signature at all (a builtin), it prints the
return type rather than inventing one. `t018_reported` pins all of these beside
the positions that must still answer nothing.

**R4.2** Function hover shows the full signature: parameter names, parameter
types, return type. The return type comes from `types.inferred_ret(line, col)`
(`types.inferred_ret`), which is **already exported** and needs no compiler change.

**R4.3** Types come from the checker's own inference, recorded as it runs
(§9.2). The server never re-derives a type. A re-implemented resolver would be
strictly worse than the real checker — the mistake `src/tools/lsp/check.y` already
made.

**R4.4** Hover on a name with no type (a package, a builtin used as a value)
shows the declaration instead, and says which.

### R5 — Go-to-definition (M4)

> **Status: delivered, including cross-file** (R5.1's "including imported
> files"). The single-file index answers for the buffer's own declarations; a
> name from an import is resolved through the SPLICED program the server already
> builds for diagnostics, which is not the compiler's scope but the renamer's
> (§11.4), and the answer can name a file the client does not have open. Resolution is
> `nav.find_decl` over `scope.index_src`'s declarations, with the visibility
> rules that matter: a `let` is visible only after its own line (Y does not
> hoist one), a `def` is visible before it (mutual recursion depends on it), the
> innermost of several visible declarations wins, and at one depth the LATER
> declaration wins — which is what the compiler does with a repeated top-level
> `def` (BUGS.md 3), so a jump cannot land on a definition the compiler
> discarded. `scope` records where each block opens *and* closes; without the
> close a name from one function stayed visible for the rest of the file, and
> because the inner declaration is the deeper one it won.

**R5.1** `textDocument/definition` resolves to the `def`, `let`, `const`,
parameter or `type` alias a name was bound to, anywhere in the compiled
program — **including imported files**.

**R5.2** Cross-file resolution is free once §9.2 exists. `rename_program_x`
(`rename.rename_program_x`) runs over the whole *spliced* program and gives every binding
a unique name `orig$N`, so a use in `main.y` of a `def` in `m133/m.y` already
shares one unique name with its definition. The binding's position is in
spliced space; `origin_file` turns it into a file URI and a
line. No separate cross-file index is needed.

**R5.3** `ycc build` packages are out of scope (see §3). A qualified package
name resolves to its own unit if the package is in `nr.pkgs`, and otherwise
returns nothing rather than guessing.

**R5.4** Definition positions point at the **name**, not the keyword.
Positions today are start-of-construct: a `let` reports at `let`, a `Dot` at
the `.`, a `Call` at the `(` (the parser's `Call` site, `407-408`, `447`, `1649-1650`).
§9.2 adds name positions where they are missing.

### R6 — Auto-complete (M4)

> **Status: delivered for this file's declarations, the builtins, and the string
> methods after a `.`; R6.1's record fields and R6.2's std/package members are
> not, and the list says so** with `isIncomplete: true`, which is the protocol's
> way of saying "ask me again as the user types".
>
> The builtins are `native.intrinsic_names()` — read from the compiler, not
> copied here, so a builtin added to the compiler appears without anything
> updated on this side. Three entries in that list (`opt$test`, `opt$val`,
> `#fmt`) are the compiler's own halves and are filtered out, because a `$`
> cannot appear in an identifier and `#` starts a comment.
>
> The string methods are the second of R6.2's three tables, and they are the one
> that is genuinely answerable without §9.2: `types.str_method(m)` returns the
> method's parameters, arity and result type, and `fn == ""` for a name it does
> not know — a hover after a `.` reads the signature from the compiler's own
> table, and completion offers the whole set. It cannot *enumerate*, because
> `str_method` is a chain of comparisons, so `strm.y` mirrors the names and
> filters them through `str_method` on every use; `t014_strm` is the ratchet.
> The member list is the string methods and ONLY those: a record's own fields
> are the other half of R6.1 and are not claimed. Mixing the two would be worse
> than offering neither, since the user reads the list as "these go here".
>
> `native.unit_iface` is the third table and is still not offered, and reading
> what it actually is is what settles it. It does not enumerate anything:
> `pack_iface` (native.y 11315) packs `len(exports)`, then per export a
> name / label / type-code triple, then the parameter defaults — an
> order-dependent blob built to be COMPARED for equality, which is what the std
> pack and `build/obj` staleness use it for. Asking it for "the std unit exports"
> would mean parsing a fingerprint built for comparison to recover the one thing
> it was derived from: `u.exports`, a `[Sym]` the compiler already has. So the
> honest route is `u.exports` directly, and *that* is Stage B's cross-file work —
> which is the same 84% the coverage measurement puts on Stage B (§11.3), reached
> from the other end. The two are not two tasks: delivering either the index or
> the externs delivers both.

**R6.1** `textDocument/completion` offers, in scope at the cursor: locals,
parameters, `self`, top-level bindings, `type` aliases, and record fields of
the expression before the dot.

**Delivered**, including the record fields (§9.2). Which members a `.` offers is
decided by **the checker's type of the object**, never by guessing:

| receiver | the list |
|---|---|
| a record | its own fields, filtered by the prefix |
| a **module** (an `import` binding) | **its own members** — the linked unit's `exports`, else the spliced names filtered by origin file |
| a `str` | the string methods (`strm.y`) |
| anything else | **nothing** |
| *no type at all* | the string methods — the Stage A answer, honest because the server does not know the receiver |

The last two rows are the requirement as much as the first. A member branch that
answers everything after a dot would look like M4 working while being wrong, so
both non-answers are pinned: `t016_types` for the array that must **not** get the
26 string methods, and `t014_strm` for the unterminated `p.` that still gets them
because nothing is known. A receiver that is not a single identifier (`a.b.c`) is
refused rather than approximated — `serve.object_col` returns −1, because no
position in the type table means "the object of *this* dot".

The module row and the record row were both reported wrong, in one sitting, and
both for the same reason: the string-method fallback fired whenever the record
branch produced nothing, so `math.` offered `byte_at, bytes, center` and so did a
record literal (§11.6). A module is not a record and needs its own source, which
is the linked unit's `exports` when there is a linked unit — a std unit resolved
from a buffer outside the compiler tree often is not, so the fallback is the
spliced top level filtered by **origin file**, which is exact rather than a guess.

One case needs saying out loud because it is the whole reason the row works at
all: **a half-typed line does not typecheck.** `z.` has no name after the dot, so
there is no `Dot` node, no type at that position, and the string-method fallback.
But the *declaration* is not mid-edit — `let z = { z: 1 };` typechecks — so when
the checker has nothing at the use, the object is resolved through the scope index
and asked about at its declaration. Both answers are the checker's; the second is
a **position**, not a re-derivation. That is why `t018_reported` ends its buffer
with a bare `math.` and a bare `z.`, which do not parse.

**R6.2** Global items need no compiler change and come from the compiler's own
tables: `native.is_intrinsic_name` (`native.is_intrinsic_name`) for builtins —
**delivered**, as `intrinsic_names()`; `types.str_method` (`types.str_method`)
for the string methods — **delivered**, as `strm.y`; `native.unit_iface`
(`native.unit_iface`) for std unit exports — **not**, see the status note above;
and `nr.pkgs` for package-qualified names — **not**, same reason. Local scope is
the only part needing §9.2.

The count was 23 in an earlier draft of this line and is 26 now: `str_method`
lists `lstrip`/`trim_start` and `rstrip`/`trim_end` as separate spellings of the
same two helpers, and all four are names a program may write, so all four belong
in a completion list. `length` is *not* among them — `s.length` is a property,
not a method, and `str_method` does not list it.

**R6.3** The list is filtered by prefix, and each item carries `sortText`,
`detail` (the type) and `documentation` (the doc comment above the definition).

**R6.4** Completion must not block. It runs in the same forked child as
everything else and is debounced identically to R1.1.

---

## 7. Protocol surface

| Method | Direction | Milestone | Notes |
|---|---|---|---|
| `initialize`, `initialized` | ↔ | M1 | advertise `textDocumentSync` (full) and `documentFormattingProvider`; full sync for `textDocument/didChange` |
| `shutdown`, `exit` | ↔ | M1 | |
| `textDocument/didOpen` / `didChange` / `didSave` / `didClose` | → | M1 | full-document sync |
| `textDocument/publishDiagnostics` | ← | M1 | **one per file**, so an import's findings land on the import |

### 7.0 Advertise only what you answer

The capability set is a promise, and VS Code keeps it. The first `initialize`
advertised `diagnosticProvider`, which means **pull** diagnostics — the client
asks, via `textDocument/diagnostic`. This server pushes, and push needs no
capability at all.

The result was worse than a log line. VS Code switched to pulling, got `-32601`
for every document, and — having switched — **ignored the `publishDiagnostics`
it was still being sent**. Every file had no diagnostics, while the
hand-written test driver (which never pulled) passed. The advertisement is
removed; the capability set is now exactly `textDocumentSync` and
`documentFormattingProvider`.

`client-check.js` now *behaves like the editor*: if `diagnosticProvider` appears
in the capabilities it issues `textDocument/diagnostic` and fails if that does
not answer, and it separately asserts the advertised set is exactly the two
capabilities the server implements. Restoring the old advertisement was tried,
and the test failed with the same `-32601` the editor reported — which is the
only reason to believe the test would catch it again.

Pull diagnostics are still worth having eventually: a pull report is
version-tagged, so a client can discard a stale one rather than showing it. Until
they exist, do not claim them.
| `textDocument/semanticTokens/full` | ← | M2 | delta-encoded; `semanticTokensProvider` advertised only when it answers |
| `textDocument/diagnostic`, `workspace/diagnostic` | ↔ | not planned yet | **not advertised** — see §7.0. Everything unimplemented is refused with `-32601`, never silence: a client blocked on an unanswered request is a hung editor. |
| `textDocument/formatting` | ↔ | M3 | one full-document edit |
| `textDocument/hover` | ↔ | M4 | |
| `textDocument/definition` | ↔ | M4 | |
| `textDocument/completion` | ↔ | M4 | |

### 7.1 JSON

`yserve` does not have its own JSON. It imports `json` like any other Y
program, from **`src/y/std/json.y`**, specified in **§15**. There is no second
implementation to keep in sync.

Two things §15 does not cover, because they are the *server's* problem and not
the module's:

- **LSP-specific escaping.** `json.emit` escapes `"` `\` and the C0 range,
  which is what a correct JSON emitter must do. Compiler diagnostics are
  routinely multi-line, so if §15's emitter ever omits the control escapes this
  is where it shows up. `yserve` additionally escapes `/` and the U+2028/9
  line separators, which `JSON.parse` accepts but some JavaScript hosts treat as
  line terminators inside string literals.
- **The union trap is paid once, in `json.y`.** Every parse function there uses
  the `let out: Json = …; out` shape, because the VOID law
  (the manual's *Disagreeing `if` arms*; `AGENTS.md`'s "VOID law") means
  the expected type does not propagate into an `if`'s arms, so *no expression in
  Y produces a union value* — only a cast into a position that already declares
  one. Callers narrow with `if let`, which is a normal cast and is fine. Note
  `if let some(x) = o` — lowercase `some`, the constructor; `Some(x)` is not a
  pattern and the parser reads `Some(x) = o` as an assignment. And `else if let`
  is not a form: an `if let` chain is written as consecutive `if let`
  statements.

Numbers in JSON-RPC are small integers (`id`, line, character, `newIndex`);
`tonum` covers every one of them, and no LSP number exceeds 2^53.

### 7.2 Framing

`Content-Length: N\r\n\r\n` then exactly N bytes. Reading is a loop over
`fs.read_some(0, 65536)` (`std/fs.y`'s `read_some`) into a buffer: one `read(2)` can
return a partial frame, and the header must be scanned byte-wise for the
blank line. An empty result is EOF and ends the loop. Writing is one
`syscall(1, 1, msg, len(msg))` per message — `y_put_hstr` (`std/rt.y`'s `y_put_hstr`)
already does exactly this, unbuffered, which is the right shape for a framed
protocol.

Nothing is ever written to stdout that is not a frame. The compiler's own
`puts("error: …")` calls write to **stdout** (the error printer in `ycc.y`), which is why
process isolation matters and why `scan.y` must intercept the unterminated
literal cases before they are reached.

---

## 8. Positions and encoding

LSP positions are **UTF-16 code units**. The compiler's are **1-based bytes**
(stated in the manual under *Integers*), with no UTF-8 awareness anywhere in
the tree.

### 8.1 Byte offsets without touching the lexer

`lexer`'s `Tok` has `{ t, v, line, col }` — **no byte offset and no end
position**. This looks fatal for ranges, token merging and edit construction.
It is not, because the splice is line-preserving (the splicer keeps
whole lines) and the column is a byte offset within the line. So:

```
line_starts(src) -> [long]     // line_starts[i] = byte offset of line i+1
                              // split(src, "\n"), accumulate len(line)+1
off(line, col) = line_starts[line-1] + (col-1)
```

Exact, and it means **M1–M3 require no change to `lexer.y`, `parser.y` or
`types.y`.** The same table converts the other way.

### 8.2 UTF-16 conversion

Server-side, not client-side, because the server has the file text for every
document including imported ones the client may not have open. For a byte
column, walk the line's bytes from its start and count UTF-16 units: a 4-byte
sequence is 2 units, a 2- or 3-byte sequence is 1, ASCII is 1. A file with
non-ASCII source is the case that makes this necessary, and it must have a
test.

CRLF: `\r` is whitespace to the lexer (`lexer.isspace`) and only `\n` advances
the line, so a `\r` counts toward the byte column and must be handled in the
line table.

### 8.3 Per-file text

The spliced text is all `native_resolve_x` returns, and the origin map gives a
path per spliced line. UTF-16 conversion needs each file's own bytes, so the
child keeps `path -> { text, line_starts }`, populated from disk on first need
and from the editor for the root document. Imported files are read from disk;
only the root buffer is live. That is the normal LSP model, and
`workspace/didChangeWatchedFiles` is how it improves.

---

## 9. Compiler changes

**None so far.** M1, M2 and M3 are done with zero edits to `src/y` or `src/c`.
One planned change was found to be unnecessary and one is recorded as a bug.

### 9.1 C1 — two exports: NOT NEEDED

The plan was to export `native.unit_externs` (to build the `ext` symbol list the
checker binds) and `native.origin_file` (to map a diagnostic to its file), and
M0 existed to prove the edit byte-free before building on it.

**M1 does not need either, and so M0 has nothing to prove.** Both were
reconstructed in `diag.y` instead:

* `diag.externs_for` rebuilds `ext` from `std_units(...)`: a unit's exports are
  bound when `std_unit_bound(u.name)` *and* the program named it. Both are read
  off `Unit`, which is reachable through the flattened namespace.
* `diag.file_of` renders `native.origin_at(o, ln, false)` — exported — and takes
  everything before the last `:` as the path.

The cost of the reconstruction is drift, so it is **pinned behaviourally rather
than trusted**: `t007_diag.y` checks that a program calling `readline()` produces
*no* undefined-variable error, which is exactly what a wrong `ext` would break.
The prelude is the only bound unit besides `exec`, so the filter is two cases.

`origin_file` remains the right API and C1 remains the right cleanup, but it is
now a refactor rather than a blocker. Do it when `refs/ycc.ref` is next
reblessed anyway; do not do it to unblock the server.

### 9.1a A compiler bug this work found

`native.norm_path` drops `.` from a path but never collapses `..`, so the same
file reached two ways compares as two files and the import splicer splices
`std/fs.y` twice — 97 duplicate-definition errors. It only bites when a module
is reached by a path containing `..`, which is to say only for code outside
`src/y/`. Full reproduction, cause, suspected fix and the workaround in use are
in **`BUGS.md`**, under *"`import fs;` twice resolves to two files"*. The fix is
about five lines in `norm_path` and is worth doing before any other tool lands in
`src/tools/`.

### 9.2 C2 — the checker's TYPES (M4) — DELIVERED

> **Rescoped by §11.4**, and **delivered**. This section was written as "an index
> of what the compiler already computes", on the belief that cross-file navigation
> needed it. It did not: `diag.y` already runs the renamer over the spliced
> program and already holds the per-line origin map, which is the whole of what
> go-to-definition needs (§11.4 has the measurement). Cross-file navigation was
> built in `xref.y` instead, and what was left here — **types** — is what the
> server now uses.

What was discarded, and what each edit does about it:

```
types.Binding     = { name, typ, kind, fdepth };              ← no line, no col
types.st_bind     (st, name, typ, kind)                      ← no position to record
types.typeof_expr (st, node) -> TcRes                        ← the type flows out, then drops
rename.rn_bind    (st, orig) -> { st, uniq }                 ← the def site drops
```

| | what it is | who reads it |
|---|---|---|
| **A5** `Decl`/`Dot`/`DotAssign` gain `nline`/`ncol` | the NAME's and the KEY's position, beside the keyword's | the type table, `rename` |
| **A1** `Binding` gains `line`/`col`; `st_bind` two arguments | where each binding was defined | a caller's binding index |
| **A3** `rename_program_x2(ast, …) -> { ast, defs }` | `defs`: a `NameIx` of `uniq -> line * 65536 + col` | **nobody yet — see below** |
| **A2** `type_index_on()` / `expr_type(line, col)` | the type inferred for **every expression**, by position | `serve.inferred_at` → hover, and `serve.type_at` → members |
| **A6** `Func.ppos` | each parameter NAME's position, parallel to `params` | the type table, `rename` |
| **A4** a `Decl`'s type at its NAME's column | where a reader puts the cursor | hover |
| **A7** a call's type at its CALLEE's column | a builtin and an imported function | hover |
| **A8** `parser.type_word_names()` | the language's own type names, as the parser decides them | semantic tokens — so `long` is not a variable |

**A5 — the name's position, which `line`/`col` cannot be.** `Decl.line/col` is the
KEYWORD's, because that is where a diagnostic points and where the reader looks. A
go-to-definition and a semantic highlight want the NAME, and one pair of fields
cannot be both, so the name's is carried *alongside*: 29 construction sites in
`src/y` and the same 29 in `src/c`, and every rebuild in `rename.y`/`native.y`
carries the pair through — which is the part that matters, because the renamer is
what hands the tree on. `Dot` gets the same pair for the member's key, and this is
what lets a member's own name carry its own type below.

**A1 — `Binding` positions.** `Binding` is *constructed* in one place (`st_bind`),
so the 15 call sites are the whole of it. A `Decl` passes `node.nline/ncol`; a
parameter passes its own, out of **`Func.ppos`** (below); an intrinsic or an extern
passes −1, which no consumer may read as line 1.

**A6 — `Func.ppos`, added when A1's imprecision turned out to be the bug.** A
parameter was, and still is in this record, a bare string in `Func.params`: no node,
no line, no column. Binding it at the `Func`'s own position was documented above as
"the imprecision it is", and it was not — it was the reason hovering the `p` in
`def g(p: P)` showed **nothing at all** while hovering a *use* of `p` showed `P`,
which is the same name giving two answers. `ppos` is a `[long]` parallel to
`params`, one packed `line * 65536 + col` per name, filled by the parser at the
token it just consumed; an EMPTY list means "not recorded" and every consumer must
read it as no position. It is one more word per parameter and nothing else, and it
is why a go-to-definition on a parameter now lands on the parameter instead of on
the function (`rename.y`'s `rn_func_go` reads it too, for the same reason).

**A4 — a `Decl`'s own name carries its type.** A `let` records its type at the
KEYWORD's column and nowhere else, because that is where the node sits. A reader
puts the cursor on the *name*, so hovering `b` in `let b = 1` showed `b` and
nothing else. Same shape as the member-key note below, same fix, same flag.

**A7 — a call's CALLEE is indexed.** An intrinsic is matched *by name* inside
`typeof_call`, so its callee identifier is never an expression and `typeof_expr`
never visits it: `clock_us` had no entry anywhere. `typeof_call` is now a wrapper
that records the call's own type at an `Id` callee's position. The `!id` arm
records a `Dot` callee's **signature** at the key's position, beside the call —
`math.exp(0.0)` answers `float` and a user's `mk(1, "x")` answers
`mk(a: long) -> P`, which is the asymmetry between an intrinsic (the checker holds
no signature object for it, only its result) and a function (it holds one). The
alternative — recording the call's return type in both places — was tried and
rejected: it made `mk` hover as `{ a: long, b: str }`, the record its *call*
produces, which reads as though `mk` were that record.

**A3 — the def sites.** A SECOND `parser.NameIx` beside the `types.tc_ix` that
already indexes bindings, not a new container, and the packing is the one
`inferred_ret` already keys its table by. `rename_program_x` is now a thin wrapper
returning `ast`, so `ycc.y`, `native.y` and `pkg.y` do not change.

> **A3 has no consumer, and the reason is measured, not guessed.** The obvious one
> was the cross-file definition path, which does re-read the target file and
> re-index it (`scope.index_src` + `nav.find_decl_named`, `serve.y`). The map
> cannot replace that: the answer needs the declaration's **signature and doc
> comment** to render, which a position does not carry, so the map would save a
> *column* the server already had — a no-op a test cannot even distinguish. It is
> delivered and exported because it is the compiler's answer to "where was every
> binding defined", including the locals and parameters no LSP table holds, but it
> is not dressed up as something it is not.

**A2 — the expression types**, which is the whole of R4.1 and R6.1. The table is
shaped exactly like `inferred_ret`'s — 1024 buckets, parallel key/type arrays,
`line * 65536 + col` — because that table is read by `native.y` on every compile
and the shape is therefore proven *at this scale in this codebase*.
`expr_type` returns `tunk()` when nothing is indexed, **not** `tnone`: `tnone` is
a type a program can write, and a consumer must be able to tell "the checker says
none" from "there is nothing here", or it prints a type the checker never gave it.
`check_program` resets the table, and only when the flag is on.

Three things the implementation had to add that the plan above did not name. The
first was found before the first release; the other two by a user, in §11.6.

- **A member access records its type at the key's position as well as the dot's.**
  `a.b` parses with the `Dot` at the `.`, so the field's type lands under the dot
  and nothing lands under the field's own name — which is where an editor puts the
  cursor. A5's `nline`/`ncol` is exactly the position that fixes it. Inside the
  flag, so it costs nothing: measured **+0.00%** on all thirteen benchmarks.
- **`serve.inferred_at` falls back to the dot's column.** Belt and braces: the
  request asks at the word's own position first and only then at the character
  before it. Asking the *dot* first would answer `x.y`'s `y` with whatever `x`'s
  type happens to be — which is why the order is that way round.

### 9.2.1 The cost, measured

```
  arrays +1.25%   closures +1.62%   fib +2.03%   fmath +0.15%   hello +2.46%
  lines +0.36%    maps +0.78%       scan +0.84%  std_io +0.39%  std_struct +0.30%
  strings +1.25%  tmath +0.11%      ycc.y +0.09%
  SCORE 98.88   (AGENTS.md: 100 +/- 2.5 is "no change")
```

`ycc.y` — the real workload, and where the binding list is longest — is **+0.09%**.
The percentage is worst on the *smallest* benchmarks, which is what a per-expression
branch looks like: `hello.y`'s own source is `print(1);` and nearly all of its
4.6M instructions are the std units, so a fixed per-expression overhead is a large
share of a small total. No emitted code changed at all (486 programs, byte-identical),
so this is compile time only.

The first version tested the flag *inside* `tci_note`, so every expression paid a
call. Moving the test to the call site moved `hello.y` only 2.47% → 2.46%: **the
branch, not the call, is the cost.** It is at the call site anyway, because that is
the shape which scales, and the comment in `types.y` says so.

### 9.2.2 What the server does with it, and what it refuses

| capability | answer |
|---|---|
| hover on a name read | the checker's type, then the declaration |
| hover on a name **bound** — a `let`'s or `def`'s own name | the type, then the declaration: §9.2 A4 records it at `Decl.nline/ncol` |
| hover on a **parameter's own name** | its declared type (§9.2 A6; before that, nothing — a parameter had no position to record) |
| hover on a **builtin** | the call's return type, which is the whole of what the checker holds for an intrinsic (§9.2 A7). Not a signature: inventing one would be a second copy of the manual |
| hover on an **imported member** | the checker's own answer at that position, which for a function is its signature |
| hover on a **def** or a **parameter** | the declaration alone — its text IS the signature, and a hover prints a type only when the declaration does not already say it |
| hover on an expression that is not a name — a literal, an operator | the type, with **no `range`**, which the protocol allows |
| hover on a record's **field** | the field's type — and **no declaration**, because a field is not a binding and there is nothing to find |
| completion after `.` on a record | the record's own fields, filtered by the prefix |
| completion after `.` on a **module** | the unit's own members, in the receiver's own spelling — an import is not a record (§11.6) |
| completion after `.` on a `str` | the string methods |
| completion after `.` on anything else | **nothing** |
| an f-string | **not one token**: the literal runs are `string`, and each `{...}` is scanned as code by the same scanner, so `name` is a name and `:<14` is punctuation, operator and number (§11.6) |
| a type name — `long`, `str`, a user's own alias | painted as a `type`, from `parser.type_word_names()`; and a user name that *happens* to be one stays a `variable` (§9.2 A8) |
| hover / completion where the checker has no answer | `null` / omitted |

The last row is the one that matters most and the hardest to hold. A wrong type is
worse than none, because the user cannot tell it from a real one. `t018_reported.y`
pins the non-answers beside the answers for exactly that reason: a string literal,
a line past the end of the buffer, and a name the checker indexed nothing at must
all come back empty, and `serve.type_at` answers `tunk()` — never `tnone`, which
is a type a program can write and would make "no answer" indistinguishable from
"the checker says none".

The last two rows are the honesty rules, and `t016_types` pins each one:

- A **non-`str`, non-record receiver offers NOTHING, not the string methods.** This
  was a real bug in the first version: the fallback fired whenever the record branch
  produced no items, so an array's `.` offered all 26 string methods. A completion
  list is read as "these are the things you can put here", so a wrong entry is worse
  than an empty one. The fallback is now gated on the receiver's type being `str` —
  or on there being **no type at all**, which is the Stage A answer and is honest
  because the server does not know the receiver.
- A member name whose object is **not a single identifier** (`a.b.c`) is refused,
  not approximated: the object of that dot is `a.b`, and no position in the table
  means "the object of *this* dot". `serve.object_col` states the rule and returns
  −1 rather than answering with `a`'s type.
- There is **no unfiltered record-field list**, and its absence is not a bug: a
  member access must be followed by a name for the line to typecheck, so a buffer
  that has one always has a prefix, and the prefix filters the list.

Two coordinates, both of which cost an hour each and are now comments at the site:
an LSP position is **0-based** and `Prepared.mine` is indexed by the compiler's
**1-based** lines, so the line needs `+ 1`; and `pos.from_lsp` **already** returns a
1-based byte column, so the column must **not** have a `+ 1`. Both failed by
answering about *nothing* rather than something wrong, which is the good direction
and still cost the time.

---

## 10. Build and packaging

**Done**, in the `Makefile`:

```make
yserve: $(LSP_SRC) src/y/std/json.y cycc
	@rm -f yserve _yserve0 _yserve1 _yserve1p
	./cycc -o _yserve0 src/tools/lsp/yserve.y
	$(call PACK,_yserve0,yserve)
	$(YREF) -o _yserve1 src/tools/lsp/yserve.y
	$(call PACK,_yserve1,_yserve1p)
	cmp yserve _yserve1p
```

`PACK` is the existing recipe: build, then append the std pack. `yserve` reads it
back from `/proc/self/exe` with its own `ys_self_pack`, framed exactly as
`ycc.y`'s `self_pack` does — `[pack][length, 8 digits][YCCPACK1]`. It is **not**
added to `YCC_SRCS` and never becomes a dependency of `ycc`: it is a program, not
a compiler module.

The `cmp` is the point. `yserve` imports `types.y`, `native.y`, `parser.y`,
`rename.y` and `lint.y` **by path**, so it is the only program in the tree that
exercises the C copy's version of all of them at once. Any divergence between
the copies that no other program reaches shows up here.

### 10.1 The pack, and why the server needs one

Without a pack, `std_units(names, "")` compiles the std units **from source** —
and that happens in *every child*, on *every request*. So the pack is not a
packaging nicety; it is most of the latency.

`yserve --std-pack FILE` compiles the units and writes the frame, then exits
without serving (it is a build step, so no frame is written and stdout stays
empty). `--std-src` ignores an attached pack. Measured on a 400-line buffer with
an import, over three runs:

| | wall clock |
|---|---|
| `--std-src` | 9 ms |
| attached pack | 5 ms |

And the two produce **byte-identical** output, which is the check that matters:
the pack is an optimisation, never a behaviour change.

### 10.2 Std module resolution

`std_resolve` anchors its search on `argv()[0]`'s directory, and one of its
candidates is `<exe dir>/src/y/std/`. So a `yserve` run from the repo root
resolves `import fs;` with no packaging at all; an installed one needs a `std/`
beside it. That is a packaging requirement, not a bug, and it belongs in the
extension's README.

### 10.3 `make test-fast`

`run_all.sh` skips the seven suites that need a built `./ycc`. The `lsp` suite
does **not**: its fixtures compile under `./cycc` and `$(YREF)`, neither of which
needs a build. So `lsp` runs under `make test-fast`, which is intended — it is
the same shape as every other fixture suite.

`make lsp-e2e` builds `yserve` and runs `test-e2e.sh`. It is a separate target
because it needs a process per case.

### 10.3a What "no syntax highlighting" turned out to be

The grammar was unregistered from `package.json` on the strength of R2.1, which
assumes M2 lands next. It did not, so between the two the extension had **no
highlighter at all** and VS Code fell back to bracket matching — which is exactly
what was reported. The sequencing was wrong, not the decision: R2.1 is right, and
`sem.y` now exists, so semantic tokens are the only highlighter as specified. Had
M2 not been reachable, the honest move would have been to put the one-line
revert back rather than leave the user with nothing.

### 10.4 The extension — **done**

`src/tools/lsp/vscode-y-lang/`, extended rather than replaced:

| | |
|---|---|
| `package.json` | `main`, `activationEvents: ["onLanguage:y"]`, the three `y.lsp.*` settings, and **no grammar** (R2.1) |
| `src/extension.ts` | activation: find the server, start it, report its death, gate the unimplemented features on the server's advertised capabilities |
| `package.json` → `contributes.commands` | `y.formatDocument`, `y.restartLanguageServer`, `y.showServerOutput` |

**Almost none of the extension is code.** Diagnostics, formatting, semantic tokens
and the outline are all registered by `vscode-languageclient` from the
capabilities the server advertises, so four of the six features cost **no
TypeScript at all**. The one thing that looks like it must be kept in sync and is
not: the semantic token legend. The library builds the VS Code legend *from the
server's* (`asSemanticTokensLegend(options.legend)`), so the two cannot disagree —
a client-side copy would be wrong, not merely redundant.

`y.formatDocument` exists because "Format Document" is registered automatically
and can still be undiscoverable. A command registered in code but **not declared**
in `contributes` does not appear in the palette and shows no title anywhere: it
works when invoked by id and is invisible to the user. `activation-check.js`
compares the two lists.
| `src/client.ts` | where to find `yserve` and with what arguments — pure logic, so it is testable with no process |
| `README.md` | rewritten for a server-backed extension |
| `y-lang-0.2.0.vsix` | the installable artefact (301 KB) |

Diagnostics and formatting need **no code**: `vscode-languageclient` registers
them from the capabilities the server advertises. Semantic tokens, hover,
definition and completion are gated on the same advertisement, and deliberately
so — registering a provider the server does not implement sends the request on
every hover and fills the log with `MethodNotFound`.

#### Two packaging traps, both caught by a test rather than by a user

1. **`vscode-languageclient` must be in `dependencies`, not
   `devDependencies`,** and `.vscodeignore` must NOT list `node_modules`. Either
   one alone makes `vsce` ship a `.vsix` that cannot `require` anything. The
   first `.vsix` built here was 9.95 KB with no runtime dependency in it — it
   would have failed on activation for every user.
2. **`main` and `activationEvents` were absent.** The extension contributed a
   grammar and never ran.

`activation-check.js` asserts the manifest *before* loading anything, so both
are caught by a test.

#### `yserve` is not shipped inside the `.vsix`

The extension finds the binary at runtime (§10.2, and the search order in
`client.ts`). Baking it in would tie every install to the machine it was built
on, and `std_resolve` already finds `src/y/std/` relative to the executable.

#### Two Node tests, and why a hand-written driver is not enough

`test-e2e.sh`'s python driver speaks the protocol by hand. That proves the server
does what *its author* thinks the protocol says — and it was perfectly happy
with a missing URI slash and a `version: 0` the spec does not allow. So:

- **`client-check.js`** drives `yserve` with **`vscode-jsonrpc`**, the JSON-RPC
  library VS Code itself uses, through the exact sequence an editor sends
  (initialize → didOpen → didChange → formatting → didSave → didClose →
  shutdown → exit). 20 checks.
- **`activation-check.js`** runs the extension's `activate()` against a stub of
  the `vscode` module and asserts it registers its commands, spawns the server,
  reaches `Running`, and says something *useful* when it cannot start. 21
  checks. The stub answers unknown names with a **class**, so a call the library
  makes on something the stub did not model fails loudly instead of returning
  `undefined`; every entry in it exists because `vscode-languageclient`'s feature
  registration really needed it.

Both skip themselves when `node_modules` is absent, so `make lsp-e2e` works in a
checkout that has never run `npm install`.

#### A bug the activation test found

`onDidChangeState` reported `Stopped` as an error. The client passes through
`Stopped` on the way *up*, so every successful start flashed a red status bar for
a moment. It now only reports a stop after a start.

## 11. Testing

### 11.1 Diagnostics sweep — registered in `make test`

`test/sh/test_lsp.sh`, added to `run_all.sh`'s `ALL` and sharded with
`next_case`. For every fixture, drive `yserve` with scripted frames and assert
it reports **every** marker in the file:

- all **144** `test/y/native/e*.y` against their `// expect-error:` lines;
- all **145** `test/y/native/t*.y` against their `// expect-warning:` lines.

The marker syntax is what `test/sh/test_native.sh` already parses: `grep -o`
for `// expect-error: `, a trailing-`LINE:`-anchored `// expect-warning: `, both
substring-matched, with the warning side requiring the count of markers to
equal the count of warnings.

This is ~3 s of CPU — the existing `test_native.sh` takes 3.7 s for the same
289 fixtures across both compilers — and `run_all.sh` runs suites with `-j`
and shards the long ones, so `make test`'s wall clock barely moves. It is a
legitimate gate because it asserts a real compiler property: that the checker
and the linter still report all their diagnostics.

`test/COVERAGE.md` needs a row, or `test_coverage.sh` fails on a manual
section with no coverage.

### 11.2 Formatter — deliberately **not** in `make test`

Idempotence over `test/y/**.y` and `bench/y/*.y` lives in its own
`make test-fmt`. A formatter bug is not a compiler bug and must not block a
rebless of `ycc`. Registering it in `run_all.sh` would couple the two.

### 11.3 Scanner, encoding, tokens

- `scan.y` and `tokenize` must agree on every token start, over the whole
  corpus. A disagreement is a highlighting bug and a parsing bug.
- UTF-16 conversion: fixtures with non-ASCII identifiers, strings and comments
  at known columns.
- Semantic token delta round-trip (R2.4).
- Unterminated `"`, `'` and `/*` in every context — including inside an
  f-string field — must produce a diagnostic and never kill the child.

### 11.4 Fuzzing

`test/fuzz/fuzz.sh` gains the LSP entry points. A crash, timeout,
`runtime error:` trap, `INTERNAL`, or divergence between `yserve` and the
reference becomes a saved finding, as it already does for `ycc`. The
formatter's crash/hang surface is much larger than the compiler's — it runs on
arbitrary bytes — so it gets its own mutations first.

---

## 12. Milestones

Each ends green on `make test`.

| | | Acceptance |
|---|---|---|
| **M-sugar** | C3 then C5: recursive aliases through `[T]`/`T?`/`{K=>T}`, then `json{ }` / `json[ ]` literal syntax (§16) | **The only milestone not done, and it is a compiler feature rather than LSP work** — nothing in this document is blocked on it, and no requirement above needs it. Literals must parse, typecheck as `json.Val`, and agree with `parse`/`stringify` of themselves; **no existing program may change meaning** (`make corpus-diff`, which measured 503 programs and 0 differences for every change in this document); manual + `COVERAGE.md` + fixtures. C3 first: without it `json` cannot appear inside its own type, so the literal has nothing to be. §16.5 has the cost and §16.6 says why C3 is the separable one. |
| **M-json** | `src/y/std/json.y` (§15) | **Done.** All four acceptance criteria are met and each is checkable: parses and emits every shape (`test/y/native/t204_std_json.y`, plus `lsp/test/t001_json_shapes.y` and `t002_json_parse.y`), round-trips losslessly (the same fixtures assert `parse(stringify(v)) == v`), compiles warning-free (`test_fixpoint.sh` builds every `src/y/std` file), and the manual section (`docs/src/09-builtins.tex`, "JSON (the json module)"), the `COVERAGE.md` row and the fixtures all exist. It blocked M1, which is done — M1 could not have landed without it, because `yserve` needs a parser and an emitter and Y programs at large need the same. **Not extended:** §16's `json{ }` / `json[ ]` sugar is M-sugar's C5, not this. |
| ~~**M0**~~ | ~~C1: the two exports~~ | **Dropped** — M1 does not need them (§9.1). Nothing was blocked on this, so no reblessing was needed. |
| **M1** | R1 — errors and warnings | **Done, end to end.** `yserve` answers errors *and* warnings together, live, on an unsaved buffer, for the file **and each import** (one `publishDiagnostics` per file); survives an unterminated literal, a missing import and a 4000-line file; the VS Code extension activates, spawns it and reaches `Running` (`activation-check.js` **26/26**), and the same server is driven by the JSON-RPC library VS Code uses (`client-check.js` **78/78**, and `activation-check.js` **26/26** against a stubbed VS Code). Registered in `make test` as the `lsp` suite. |
| **M2** | R2 — semantic tokens | **Done.** `sem.y` turns `scan.y`'s spans into the protocol's delta encoding; `textDocument/semanticTokens/full` is advertised and answered. The grammar is unregistered from `package.json`, so this IS the only highlighter. `t010_sem` pins the round trip (R2.4) over the whole corpus; `client-check.js` decodes the delta the way an editor does. The **semantic half of the legend is now delivered** (R2.3, M4): parameter / function / type / property / builtin are all resolved, and the language's own type names come from `parser.type_word_names()` so the list cannot drift (§11.6). An **f-string is no longer one token** — each `{...}` is scanned as code, which is what a reader is actually looking at (§11.6). **Nothing is left undone in this row.** There is deliberately no setting to turn the layer off: the grammar is unregistered (§10.3a), so this layer is the only highlighter, and a switch for it would reintroduce the "no syntax highlighting" report. |
| **M3** | R3 — formatting | **Done** (idempotent over every `.y` file in
the tree — `test-fmt.sh` compares the number of files that are NOT idempotent,
which must be zero, and only *prints* the total, so the total moves as `src/y`
moves without anything failing; this row used to quote 487, a number nothing
checks; no edits on an unlexable buffer; no edits when already formatted). The
VS Code command is wired too: `y.formatDocument` is declared in `package.json` and
registered in `extension.ts`, and it exists to be **findable** — the formatter
itself is registered from the server's advertised capability, so "no formatter
available" and a Format Document that silently does nothing are the two reports
this prevents. |
| **M4** | R4–R6 + C2 — hover, go-to-def, completion | **Done.** Stage A and Stage B both, and Stage B did not go the way §11.3 decided it would (§11.4). `scope.y` + `nav.y` answer all three from the declarations of the open buffer: definition points at the name (not the keyword), hover shows the signature as written plus the comment above it, completion offers the visible names and the builtins with `isIncomplete: true`. The builtins come from `native.intrinsic_names()`, which this work added to the compiler so the list cannot drift. `strm.y` answers the member position from the compiler's own `types.str_method`, so a hover on `"a,b".split` shows the signature the checker would use and completion after a `.` offers the methods and only the methods. `t012_scope` pins the visibility rules, `t013_m4` the wire shapes, `t014_strm` the string methods and the mirror's ratchet, and `client-check.js` drives all of it through the JSON-RPC library VS Code uses (**78/78**, including a second real session with R1.8's `checkOnChange` off). `scope-coverage.y` measures what the index resolves over `src/y`: **61%** of identifier tokens, after two bugs that had it at 46% (§11.3), and `request-cost.y` what a request costs on the largest file in the tree — 20 ms, after a bug that had it at 5,499 ms. `xref.y` + `nav.find_decl_named` close the cross-file half: `helper.helper` jumps to `mod.y` at the name, with its signature and doc comment, and `helper.TOP` to the `let` that declares it. `t015_xref` pins the three compiler facts it rests on. §9.2 is **delivered**: the checker keeps its inferred types in a position-keyed table behind a flag (§9.2 A2, +0.09% instructions on `ycc.y`, +0.00% for the member-key addition), so a hover shows the type the checker computed — including on an expression that is not a name, and including a record's field, which has a type and no binding — and completion after a `.` offers a record's own fields. §9.2.2 lists what it refuses. The semantic classes are **delivered** too (R2.3): `sem`'s legend has five more entries and `serve.semantic_overrides` resolves each identifier to one, from `scope`'s declaration kinds and `native.intrinsic_names()`. (It was `serve.classify` until the `bugs-ledger` merge, which put a `classify` into `std/tui.y` — a path import flattens, so the two were one name in one namespace; §5's collision check is what found it.) It needed **no** compiler change — this row's earlier note said it did, on the grounds that what a name denotes is the checker's answer; it is `scope`'s answer about DECLARATIONS, plus a dot's own text, and §9.2's type table is not involved. Three costs were found by measuring rather than by reading, and all three are now in `request-cost.y`: `classify` was **34.5 s** on `src/y/native.y` and is **115 ms**, and the two causes were a per-identifier position lookup that counted newlines from byte 0 (quadratic), and `scope_end` walking all ~7,000 scope pairs per candidate (linear in the file, per identifier). The second also made completion `visible()` **22x** faster, 7,576 us to 347 us on the same file, which nothing had asked about because a completion asks once. `t017_sem` pins the five classes and the four names that must stay `variable`, and `t010_sem` pins the one that was a whole line of tokens missing (§11.5). Cross-file navigation is **not** behind §9.2 as this row previously said — §11.4 measured that the renamer the server already runs produces the pairing it needs. **Six defects a user reported are fixed and pinned** (`t018_reported`, §11.6): a declaration's own name and a parameter's own name now answer, a builtin answers, an imported name answers, an f-string is sub-tokenized, type names are painted as types, and a module or a record literal offers its own members after a `.`. Five of the six were **one bug** — something recorded at one column and asked about at another — and one was *not* a server bug at all and is reported as such rather than as a fix. **Nothing is left undone in this row.** |
| **M5** | packaging and docs | **Done.** All three: `PORTING.md`'s module map carries the LSP row with the reason it is *not* ported and the two checks that keep a path-importing tool from breaking the compiler; `AGENTS.md` gains the layout bullet, the suite-list entry (`test_lsp.sh [lsp]`) and the description of `make yserve`; and the extension README documents `yserve` placement — `make yserve` at the repository root, then the search order, then `y.lsp.serverPath` alone — and **every** setting in a table (`serverPath`, `rootPath`, `trace.server`, which is all three of them). |

### 11.1 Two bugs the work found in the compiler

Both are in `BUGS.md` with reproductions; the second is the expensive one.

1. **`norm_path` does not collapse `..`** (§9.1a), so a module reached through a
   path with `..` in it resolves a by-name std import to a *different string* than
   the program's own, the splicer's dedupe misses, and `std/fs.y` is spliced
   twice — 97 duplicate-definition errors.
2. **A duplicate `def` in the SAME file is not an error; the last one silently
   wins.** `find_dup` only compares across files. A `python` edit that rewrote a
   region of `sym.y` left **two** copies of `symbols` and **three** of
   `add_child`; the compiler said nothing; the stale `symbols` — the version
   *without* the fix — shadowed the new one on every call. Every read of the source
   showed the correct code and every run used the other one.

The second one is why `check-names.py` exists, and why it checks names rather than
just definitions.

### 11.3 The Stage B decision, on the number

"Is Stage A good enough, or does Stage B (the C2 compiler change) earn its
keep?" is a question about a number, so there is now a program that answers it:
`src/tools/lsp/test/scope-coverage.y`, run over `src/y`. It reports what share
of the corpus's identifier tokens `nav.find_decl` resolves, and — the part the
decision turns on — how many of the misses are names that ARE declared, in
another file.

**The first number it gave was 46%, and that turned out to be two bugs rather
than a limit.**

1. **Parameters were never recorded at all.** The parameter branch required
   `depth > 0`, but a parameter list opens *before* the body's `{`, so the brace
   depth at a parameter is the depth of the def's own surroundings — zero at the
   top level. The test threw away exactly what it was looking for, and every use
   of every parameter missed. Measured, the most frequent name the index could
   not resolve was `st`, 5,451 times, then `node`, `k`, `line`, `col`: the
   compiler's own parameters. A parameter's scope is its function's *body*, which
   opens after the list, so the brace stack is empty when the parameter is read;
   the `{` that opens the body is recorded for the pending parameters as it
   arrives, in the same pass.
2. **`pos.to_lsp` rebuilt the whole line index on every call**, and
   `index_src` calls it once per declaration. `line_bytes_from` already existed
   for precisely this trap (see its comment: 4.8 s per call on parser.y), one
   layer too low to catch `to_lsp`. So indexing `src/y/native.y` rebuilt an
   11,000-entry table 3,576 times: **2,604 MB**, which is out of memory against
   the 3.5 GB cap, and so no definition, hover or completion on any file that
   size. `doc_to_lsp` takes the caller's `SrcDoc`; `to_lsp` delegates to it.
   **32.6 MB**, and `sym.y` (the outline) had the same three call sites.

   It was worse than the memory. Every request re-derives the index from scratch
   — the protocol gives no notice that only a few lines changed — so this was
   paid per keystroke. `request-cost.y` measures it per phase
   (`./ycc src/tools/lsp/test/request-cost.y -o /tmp/rc && /tmp/rc`):

   | file | size | `scan` | `index` before | `index` after | heap before → after |
   |---|---|---|---|---|---|
   | `tags.y` | 8 KB | 0 ms | 0 ms | 0 ms | 0.5 → 0.4 MB |
   | `lint.y` | 42 KB | 1 ms | 65 ms | **2 ms** | 43 → 3.2 MB |
   | `types.y` | 191 KB | 5 ms | 973 ms | **7 ms** | 584 → 12.7 MB |
   | `native.y` | 497 KB | 13 ms | **5,499 ms** | **20 ms** | 2,541 → 31.8 MB |

   **275x on the largest file in the tree.** Not because 20 ms is fast, but
   because 5.5 s is not a slow feature, it is a frozen editor — and R1.1 and R6.4
   say the server must not block. The tolerant tokeniser was never the problem;
   `scan` is 13 ms on the same file throughout.

46% → **61%** of 80,949 identifier tokens, and the corpus now indexes in 232 MB
instead of dying.

### 11.4 The premise was wrong: cross-file navigation needs no compiler change

The measurement above says 84% of what Stage A misses is "declared in another
file", and the obvious reading is that closing it needs the compiler's scope —
which is what §9.2 and the Stage B decision assumed. **That reading is wrong,
and the reason is in `diag.y`, which had been read past twice.**

`diag.diagnose` already does, on every buffer it is asked about:

1. `native_resolve_x` — splice the imports in, giving the whole program's text
   (`nr.src`) **and `nr.origin.file`, a per-line map saying which file each
   spliced line came from**;
2. `strip_ns` — drop the module qualifiers;
3. `rename.rename_program_x` — the compiler's own uniquifying pass;
4. `types.check_program` and `lint.lint_unit`.

So the LSP is already holding, per request, the whole program as one text, the
map from every line of it back to a file, and — this is the part that matters —
**an AST in which a definition and all its uses share one name.**

Measured, on `main.y` importing `mod.y`, after step 3 alone:

```
top-level statements after rename: 4
  line 1 kind decl     decl name helper$1      <- mod.y
  line 4 kind decl     decl name TOP$3         <- mod.y
  line 6 kind decl     decl name v$4           <- main.y
  line 7 kind call     callee print @7 args v$4 @7 + TOP$3 @7    <- main.y
origin map:  lines 1-4 -> file 1 (mod.y),  lines 5-7 -> file 0 (main.y)
```

`TOP$3` is *declared* on spliced line 4 and *read* on spliced line 7. One name,
two files, and `origin.file` says which file each line belongs to. **That is
exactly the pairing go-to-definition needs**, and it is produced by a pass the
server already runs and discards.

So the 84% is not behind a compiler change at all. It is behind:

- indexing the **spliced** text rather than the buffer, so the imported
  declarations are in the index;
- the inverse of `origin.file` — a buffer line to its spliced line — to turn a
  request position into an AST position;
- `origin_file` on the declaration's line, to turn the answer back into a file
  and a line in *that* file, and then reading that file to put the name in it.

None of that touches `src/y`. It is all in `scope.y` / `nav.y` / `serve.y`.

**What this does change.** §9.2 keeps its first half and loses its reason for
existing: `types.Binding` line/col and a `(line, col) -> Type` table are still
the only way to get a *type* — an inferred `long` under the cursor, a record's
own fields after a `.` — and neither the renamer nor the splicer carries types.
But "cross-file navigation is Stage B" was wrong, and it was wrong because the
gap was measured on Stage A's index while the data was sitting in the next
function. §9.2 is now scoped to types alone, and its measured cost (§9.2's own
site counts, and the `bench/compile_ir.sh` baseline) stands for that much.

**The lesson, since it cost a milestone's worth of work to get wrong:** a
"missing capability" measured against one implementation is a statement about
that implementation, not about the system. `scope-coverage.y` compares what
`nav.find_decl` resolves; it cannot see what `diag.y` already resolved and threw
away. The next version of that tool should measure the *served* answer — what a
request returns — and not the index underneath it, because the index is not the
product.

**The original measurement stands, with the correction:** of the 832
distinct names Stage A cannot resolve:

| | count | |
|---|---|---|
| declared in another `src/y` file | **699 (84%)** | exactly what Stage B closes |
| a primitive type name | 5 | neither stage declares it — they are built in |
| declared nowhere in the corpus | 128 | not visible to a correct resolver either |

Stage A reads one buffer, so a name from an import is invisible to it by
construction. That 84% is Stage A's ceiling — and it is **not** the system's
ceiling, which is the subject of §11.4, and much smaller.

The order mattered, and the measurement is what set it: fix Stage A's two bugs
first, because that was free by comparison and moved 15 points. **Then check
where the remaining gap actually lives before paying for it** — which is what
§11.4 does, and what this decision got wrong. `bench/compile_ir.sh` is still the
instrument for it, and it says what it says: +0.00% on all thirteen benchmarks,
`ycc.y` at 4,705,071,230 instructions.

### 11.2 Four bugs M4 found in the server

None of these is in the compiler; all four produced answers that were wrong in a
way a reader would believe. Recorded because each one has a shape worth
recognising.

1. **`header_text` dropped every single-word return type.** The span range that
   collects the type after `->` was tested with `last > r + 2`, one token too
   far, so `def f() -> long {` — the common case — contributed nothing and the
   signature read `f()`. Since the language has return types everywhere, every
   hover in the server looked like it was showing a language with none. It was
   not caught for a while because `def f() -> long {` reads plausibly as a
   signature.
2. **`in_params` classified every call argument as a parameter.** The test was
   "the token after the `(` is an identifier", which is true of every call in the
   program — walking back from an argument reaches the call's own `(`. So
   `print(shared)` indexed `shared` as a *parameter* of the enclosing def, and a
   jump on it landed on the use instead of on the `let` a line away. What tells
   a parameter list apart is what comes *before* the `(`: `def`, then the name.
3. **Two position conventions in one field.** `scope_start` was packed from a
   span's 1-based `(line, col)` while every other position in `IdxDecl` is 0-based
   LSP, so a scope's start sat one line below the declaration it belonged to.
   Related: only the *open* of a block was recorded, so a `let` inside one
   function stayed visible for the rest of the file — and since the inner
   declaration is the deeper one, it won. Fixed by recording where each block
   closes as well (`FileIdx.closed`, `scope_end`).
4. **A duplicate key in the test stub.** `vscode-stub.js` listed
   `registerHoverProvider` and `registerCompletionItemProvider` twice, the second
   time as bare no-ops. A duplicate key in one object literal is not a merge: the
   later one wins silently. The recording versions were dead code, so
   `activation-check.js` saw exactly one provider registration for a server that
   registers six, and reported it as "the extension cannot start".

### 12.1 What needed the compiler agent

All four landed, and are part of the working tree:

1. **`import json;` in `test/sh/test_fixpoint.sh`** — so `std/json.y` is compiled
   by the suite that exists to keep std warning-free.
2. **`test/sh/test_lsp.sh` [lsp]**, registered in `run_all.sh`, so `make test`
   runs the fixtures, `check-refs.py` and the formatter.
3. **`test/COVERAGE.md`** rows for the LSP, and `test_coverage.sh` taught to
   recognise `lsp/test/t*.y` as a checked test (it requires the fixture **and**
   its `.expected`, exactly as it does for a native fixture).

`test_lsp.sh` also runs two static checks of its own, because both were once
sources of silent breakage:

- **`check-refs.py`** resolves every symbol `LSP.md` cites, so the design's
  references survive the line-number drift in `src/y`.
- **`check-names.py`** asserts that no two path-imported modules define the same
  name, across the LSP's own modules *and* the compiler's 1 947. A path import
  flattens, so a shared name is either a duplicate-definition error pointing at
  the wrong file or — worse — one definition silently shadowing the other. Five
  times while building the server; the worst shadowed `src/y/lexer.y`'s own token
  type and produced **60 errors inside the compiler**, none in the file that
  caused them.
4. **`make yserve` / `lsp-ext` / `lsp-vsix` / `lsp-e2e`** (§10).

`make yserve` does NOT depend on `make ycc`: the latter is the acceptance gate on
the compiler and rebuilds it, so depending on it would make building the server
fail with whatever the compiler's own state happened to be. It compares against
`$(YREF)` instead.

## 13. Risks

1. **C2's branch in the checker's hot loop.** The one genuinely expensive
   requirement. Measured with `make bench-ir` before anything is blessed.
2. **Two classifiers over the same bytes.** `scan.y` and `tokenize` must
   agree. A fixture sweep over the whole corpus is the mitigation; a
   divergence is a parsing bug, not just a colour bug.
3. **Semantic token cost.** A whole-document token array is re-sent on every
   change as a delta. Large files will need the delta implemented correctly
   rather than approximately.
4. **Server down means no colours.** R2.1 replaces the grammar, so a server
   that fails to start leaves the buffer uncoloured. The grammar file stays in
   the repository precisely so this is a one-line revert.
5. **Imported files are read from disk**, so go-to-definition is only as
   fresh as the filesystem until `workspace/didChangeWatchedFiles` is handled.
   Named as out of scope for v1 rather than discovered later.
6. **`yserve`'s size.** It imports six compiler modules plus `json`; the binary
   will be comparable to `ycc`. If that matters it can be cut by dropping the
   std pack and compiling the std units from the embedded sources instead.
7. **Compiler internals are cited by symbol, not by line** (see the note at the
   top). This is the single biggest ongoing coordination cost between this work
   and anyone else changing the compiler: a document that cites `native.y:NNNN`
   needs reconciling after every refactor, and the reconciliation is always
   somebody's afternoon. `check-refs.py` catches the residue.

## 14. Reference — what exists today

Reusable as-is, no compiler change:

| | |
|---|---|
| `lexer.tokenize(src) -> [Tok]` (its export list) | the parser's lexer. Not usable for spans (R2.2). |
| `parser.parse_program(toks) -> Block` (`parser.parse_program`'s export list) | error-recovering; plants `err` nodes, syncs at `;` and `}` (`parser.sync_stmt`). |
| `types.check_program(ast, ext) -> [Diag]` (`types.check_program`) | all errors at once, via the `tunk` poison (`types.t_unk`, `teq` `:209`). |
| `lint.lint_unit(ast, ast3, ofile, fmods, wlevel) -> [Diag]` | all warnings, sorted and deduped. |
| `types.inferred_ret(line, col)` (`types.inferred_ret`) | exported already; function return types free. |
| `native.native_resolve_x(src, base_dir, …)` (`native.native_resolve_x`) | takes **text**; the unsaved-buffer seam. |
| `native.origin_file` / `origin_at` | spliced line → file + line. |
| `native.strip_ns` (`native.strip_ns`), `rename.rename_program_x` (`rename.rename_program_x`) | the pipeline, in order. |
| `native.std_units` (`:9489`), `unit_iface` (`:10805`), `unit_externs` (`:10817`) | std units and the checker's externs. |
| `native.is_intrinsic_name` (`:2553`), `types.str_method` (`types.str_method`) | the completion item sources. |
| `parser.type_word_names()` (`parser.type_word_names`) | the language's own type names, as the parser decides them. **Added** by §9.2 A8, for R2.3 — a mirrored list in the server would drift the first time a primitive is added |
| `Unit.exports` (a `[Sym]` of name / label / type) | a linked unit's member names, which is what a module offers after a `.` (§11.6). Reached through `Prepared.units`, which is the same `std_units(nr.std, pack)` call the checker needs — the list that was loaded anyway |
| `fork {}`, `wait_pid`, `mutex`, `sem`, raw `syscall` | the isolation and framing primitives. |
| 289 diagnostic fixtures in `test/y/native/` | a ready-made regression corpus. |

Must be built, all under `src/tools/lsp/`: `scan.y`, `json.y`, `rpc.y`,
`pos.y`, `fmt.y`, `sym.y`, `serve.y`, `yserve.y`, the VS Code client, the
Makefile target, `test_lsp.sh`.

The old `check.y` / `check_main.y` / `test_check.y` / `build.sh` that used to sit
here are **gone** (removed 2026-10-04; they targeted `./yboot`,
`src/c/runtime.c` and `../../ycc/lexer.y`, none of which existed, used untyped
parameters the checker rejects, and emitted JSON with no escaping). Their one
sound idea — `check(src) -> [{line, col, severity, message}]` — is just the
shape of `PublishDiagnosticsParams`, which the real pipeline already satisfies,
so nothing is lost. Nothing in this directory is a compiler module: the only
files here are this document and the extension.
---

## 15. `std/json.y` — a JSON module for Y

M-json. `yserve` needs a JSON parser and emitter; Y programs at large need the
same thing, and there is none. So it is a std module, not LSP-private.

### 15.1 Module shape

| | |
|---|---|
| Path | `src/y/std/json.y` — resolved from disk by `std_resolve` (`native.std_resolve`), like `fs`, `net`, `struct`. **Not embedded**, so unlike `str.y` it may use string literals freely (all seven existing disk-resolved modules do). |
| Twin | **none.** A std module stays Y (`PORTING.md`, module map). |
| Sibling precedent | `struct.y` — a pure encode/decode module over `[byte]`, no I/O, no platform. The closest existing thing. |
| Also available | `regex.y` (a Pike VM over bytes) is a peer std module and a good model for a self-contained pure module; `fs`, `net`, `struct`, `crypto`, `x509`, `tls`, `http` and `regex` are the eight importable units. Only `fs` matters to `yserve` beyond the embedded four (`rt`, `str`, `prelude`, `exec`). |
| Warning-free | `test_fixpoint.sh` compiles every `src/y/std` file with no warning. Compiled as a program its unit has no name, so `lint_unit` **does** run on it (`compile_unit`'s lint guard). Unused locals are errors here. |

### 15.2 The value type, and why objects are bare maps

The shape is dictated by one language rule. A union member may not be a bare
map or array, because then the type refers to itself outside a record field:

```y
type Json = { str => Json } | JN;
// error: type 'Json' refers to itself outside any record field or function type
```

Recursion **must** pass through a record field (`parser.y`'s `Node` union `type Node = …`
and `parser.y`'s `Type` union `type Type = …` are both recursive unions over record
members). So `Json` is a union of *records*, and an object needs a wrapper
record inside it.

But a wrapper record is not indexable, and **`o["thing"] = v` on a JSON object
is the whole point**. So the object is kept *outside* the union, as a bare map:

```y
type Num  = { num: str };              // the literal text -- see J6
type Str  = { s: str };
type Bool = { b: bool };
type Null = { nil: long };
type Arr  = { items: [Val] };
type JObj = { members: { str => Val } };  // wrapper: only for objects STORED in a tree
type Val  = Num | Str | Bool | Null | Arr | JObj;

// An object is { str => Val } -- a plain map. Index it directly.
```

**Every member needs its own field name.** This is not a style preference; it is
what makes `if let` able to tell the members apart. A record type *is* its set
of fields, so the obvious `Num = { v: str }` and `Str = { v: str }` are one
type: `if let Str` matches a number, the arms overwrite each other, and
`stringify` prints `{"a":"1"}` for `{"a":1}`. There is no discriminant on a
union and no `typeof` that reveals one — distinct shapes are the only mechanism.
Found by building it; see `src/y/std/json.y`.

Recursion goes through `Arr`'s `[Val]` field and `JObj`'s `{str => Val}` field —
both record fields, so the rule is satisfied. And the object you actually hold is
a map, so this is the whole API:

```y
let o = json.obj();
o["thing"] = json.num(1);          // direct index assignment -- no set()
o["name"]  = json.str("x");
o["flag"]  = json.boolean(true);
o["void"]  = json.nul();

let inner = json.obj();
inner["deep"] = json.num(42);
o["sub"] = json.jobj(inner);      // the one wrap (see below)

let a = json.arr();
a += json.num(1);
a += json.str("two");
o["list"] = json.jarr(a);

json.stringify(o);
// {"thing":1, "name":"x", "flag":true, "void":null, "sub":{"deep":42}, "list":[1, "two"]}
```

Verified to compile and run as written.

**The one unavoidable wrap.** A map's value type is `{ str => Val }`, and `Val`
contains the `JObj` wrapper (that is what makes recursion legal), so a nested
object has to be wrapped by `jobj(map)` on its way into a tree, and `jarr(list)`
for an array. A **top-level** object needs no wrap at all — `json.stringify(o)`
takes the bare map directly. This is the irreducible price of the recursion
rule; there is no encoding that avoids it. §16's C3 would remove it by allowing
the alias to recurse through the map directly.

**Maps pin their value type, so build with `obj()`, never with a literal.**
`let m: {str => Val} = {};` then `m["a"] = …` accepts anything (verified), but
a literal infers from its **first** entry and is then fixed:

```y
let m = {"a": { n: 1 }};
m["b"] = { s: "x" };        // error: map value: expected { n: long }, got { s: str }
```

and the annotation is only *checked against* the literal, never propagated into
it — `let o: {str => Val} = {"a": {v: 1}, "b": {v: "x"}}` still fails. This is
the same rule `e25_map_value_type.y` documents (*"map values are homogeneous"*).
So `obj()` is required, not sugar.

**Keys are ordered.** A map is `{keys: [K], vals: [V]}` — two parallel arrays —
so insertion order survives: `{}` then `"zebra"`, `"apple"`, `"mango"` gives
`keys()` of `[zebra, apple, mango]` (verified). `stringify(parse(s))` therefore
preserves key order, which a hashed map would not.

`JNum` holds the **literal text**, not a number — see J6.

### 15.2.1 Two entry points, not one

`stringify` and `parse` handle the object case, because that is what JSON-RPC
messages and most configuration files are, and because it is the case that can
be a bare map:

| | |
|---|---|
| `parse(s) -> {str => Val}?` | a top-level **object**; the result indexes directly |
| `parse_val(s) -> Val?` | any value, including a top-level array or scalar |
| `stringify(o: {str => Val}) -> str` | an object map |
| `stringify_val(v: Val) -> str` | a scalar or an array |

One function covering all three shapes is not available: a bare map cannot be a
union member (that is the rule this whole section is about), so there is no
single parameter type that accepts an object, an array and a scalar.

### 15.3 Requirements

**J1** `parse(s: str) -> {str => Val}?` — a top-level object, which the caller
then indexes directly. `parse_val(s: str) -> Val?` for any value. Both return
`none` on malformed input, never a trap, never a partial value.
`parse_err(s) -> { ok: bool, value: Val?, err: str, at: long }` carries the
message and the byte offset for callers that want them.

**J2** `stringify(o: {str => Val}) -> str` and `stringify_val(v: Val) -> str`.
Escapes `"` `\` and **the whole C0 range** as
`\n \r \t \b \f \uXXXX`; `\b` and `\f` for 8 and 12. A raw control character in
a string produces invalid JSON, and compiler diagnostics are multi-line, so this
is not optional.

**J3** Round-trip: for every input the fixture accepts,
`stringify(parse(s)) == s` after canonicalisation. Holding the number's literal
text is what makes this exact for floats.

**J4** Numbers: integers via `tonum`, validated against the grammar first
(`-?(0|[1-9][0-9]*)`), so `01`, `1.`, `.5`, `+1` and `1e` are rejected rather
than silently coerced. `as_long(v: Val) -> long?` gives the integer value.

**J5** Strings: `"` and `\` escapes, `\/\b\f\n\r\t`, `\uXXXX` with surrogate
pairs, and rejection of a raw newline or an unescaped control character, per
RFC 8259.

**J6** Floats are carried as text, not as `float`. **Y has no string→float
conversion at all** — `tonum` returns `long` and there is no `tofloat` anywhere
in the tree. `{"x": 1.5}` therefore yields a `Num` holding `"1.5"`, which
round-trips exactly and compares by text. `as_float` is **not** provided in v1.
Producing a real `float` needs either a hand-written mantissa/exponent
reconstruction (imprecise at the edges, and there is no `pow` to lean on) or a
new `tofloat` builtin — a compiler change with a C twin and a rebless. That is a
decision to take on its own merits, not inside M-json. For the LSP nothing is
lost: JSON-RPC numbers here are small integers.

**J7** `\uXXXX` needs a hand-written UTF-8 encoder, because **`chr` is
byte-only**. Measured: `chr(v)` emits exactly one byte, `v mod 256` — `chr(256)`
is `\x00`, `chr(300)` is `,`, `chr(8364)` is `\xac`. There is no codepoint
semantics, so `chr(0xe9)` yields a Latin-1 byte, not the two-byte UTF-8 `é`.
`json.y` encodes U+0080–U+07FF, U+0800–U+FFFF and U+10000–U+10FFFF itself, by
pushing bytes into a `[byte]` and closing with `from_bytes` rather than `chr`.
A lone surrogate is an error; a valid pair becomes one 4-byte sequence.

**J8** Reads are the language's own: `o["k"]` on a map is `Val?`, and `!` or
`is_some` take it. No accessor is needed for an object field, and no `set` is
needed for a write — both are the point of §15.2. For the union members:
`as_str(v)`, `as_long(v)`, `as_bool(v)`, each `-> T?`, which is what
distinguishes "absent" from "present and empty"; and defaulted variants
`get_str(o, k, d)`, `get_long(o, k, d)`, `get_bool(o, k, d)` for the common
one-line read. Unwrapping a nested object costs one narrowing:
`if let JObj sub = o["sub"] { sub.v["k"] }`.

**J9** Names avoid `str`, `long`, `bool`, `float`. A def *may* shadow a
primitive type name (verified — `def str(x: long) -> long` compiles), so this is
not about the type system: an import splices names **flat**
(`native.y`'s header), so `json.str` becomes a bare `str` in the user's program
and then collides with the user's own `def str`, which `find_dup`
(`native.find_dup`) reports as an error. `as_str` is unambiguous where `str` is
not. This bit for real: a first draft of `json.y` defined `keys`, which
shadowed the `keys` **builtin** inside the module itself and produced
`'json.keys' arg 0: expected Json, got {str => Json}` on every call.

**J10** Builders, kept to the minimum the language forces: `obj() -> {str =>
Val}`, `arr() -> [Val]`, the two wraps `jobj(map)` / `jarr(list)`, and the
scalar constructors `num`, `str`, `boolean`, `nul`. `obj()` and `arr()` exist
because of §15.2's inference trap; `jobj`/`jarr` because of the recursion rule.
There is deliberately **no `set`** — object writes are `o["k"] = v`.

**J11** A depth limit, defaulting to 200 (`json_depth_max`), honoured by both
`parse` and `stringify`. Both are recursive, so a document nested a few thousand
deep would otherwise run either off the stack.
The parser is recursive, and a deeply nested document is a stack overflow
otherwise. `stringify_val` is likewise recursive and needs the same bound. This is the
one place where "malformed input must never take the server down" needs an
explicit knob rather than trust.

**J12** Duplicate keys: **last wins**, matching how Y itself reports a duplicate
record field — the warning is templated in `lint.y`: *duplicate `<what>`
`<key>` in a `<kind>` literal; the last one wins*. Consistency with the language beats cleverness.

**J13** A duplicate key must not silently corrupt the order guarantee: the
second `o["k"] = v` overwrites the value in place, keeping the key's original
position.

**J15** `stringify` is **compact** — no space after a colon or a comma. That is
what every JSON producer emits, and it is what makes `stringify(parse(s))`
byte-identical to a canonically written `s` (J3). Verified in
`t002_json_parse.y`.

**J16** A helper that accumulates bytes and can fail must return a status, not
the accumulator. `p_uescape` returned the byte buffer unchanged on a bad escape
and the caller read that as success, so every malformed `\u` escape and every
lone surrogate was silently accepted. Arrays are references and `+=` is in
place, so the buffer can grow in place while the return value carries the
success or the failure.

**J14** Obligations, all enforced:
- a section in `docs/src/09-builtins.tex` beside *The web* and *Cryptography*;
- a row in `test/COVERAGE.md` — the gate fails on a manual section with no row,
  and on a row naming a test that does not exist or does not check output;
- `test/y/native/tNNN_json.y` with a checked `.expected`, covering: every
  scalar type, nesting, empty containers, key order, each escape, each
  `\uXXXX` class, surrogate pairs, a lone surrogate, duplicate keys, every
  rejection case, the depth limit, and a `parse` → mutate → `stringify` round
  trip that proves `o["k"] = v` needs no `set`.

### 15.4 What this saves the LSP

`json.y` replaces the LSP's own encoder and parser outright. `yserve`'s JSON
surface is then `parse`, `parse_val`, `parse_err`, `stringify`, `stringify_val`,
`escape`, `obj`, `arr`, `jobj`, `jarr`, `num`, `str`, `boolean`, `nul`,
`as_str`, `as_long`, `as_bool` and the `get_*` variants — shared with every
other Y program, none of them LSP-specific. Object reads and writes are the
language's own `o["k"]` and `o["k"] = v`, so the LSP payload code reads like
the JSON it is. The only JSON concern that stays in `yserve` is the extra
escaping noted in §7.1.

With M-sugar (§16) the surface shrinks again: `num`, `str`, `boolean`, `nul`,
`jobj` and `jarr` become internal to the desugaring, and `yserve` writes
`json{ "jsonrpc": "2.0", … }` instead.

---

## 16. M-sugar — JSON literal syntax in the compiler

`json.num(1)` and `json.obj()` are the module compensating for the language.
This milestone removes the compensation by changing the compiler, so JSON is
written as literals.

### 16.1 Why the module has to compensate: two independent blocks

**Block 1 — recursion may not pass through an array or map.**

```y
type Json = { n: long } | { str => Json };
// error: type 'Json' refers to itself outside any record field or function type
```

`rename.rn_reaches_go` walks an alias looking for a
self-reference, and in `bare` mode only a **record field** or a **function type**
stops the walk — its record and function arms. Array, fixed-array, option,
map and pointer members all continue it (the array/option/map arms of `rn_reaches_go`), so any of those
makes the alias "recursive on the nose". the `Node` and `Type` unions in `parser.y` get away with it
because their recursion is genuinely through a record field.

**Block 2 — a union may not contain a primitive.**

```y
type V = long | str;
def f(v: V) -> long { … }
// error: parameter 'v' has unpassable type long | str
//        (a void value has no representation, and a type pattern cannot be passed by value)
```

This one is not about recursion at all. It is the **value model**: a union is
passed as one of its record members, so a `long` arm has no representation
besides the value itself, and the void arm has none at all. Putting `long`,
`str` or `bool` directly in a union needs unions to become a tagged,
heap-boxed runtime value — a backend change, and a change to `src/c/yv.h`'s
value model with it.

Block 1 is a rename-layer rule. Block 2 is the language's memory model. They
are not the same size of work and must not be bundled.

### 16.2 Three tiers, in increasing cost

| | Change | Cost | Buys |
|---|---|---|---|
| **C3** | Let a recursive alias pass through an **array, option or map** member. In `rn_reaches_go`, make its `tarr`/`tarrfix`/`topt`/`tmap` arms respect `bare` the way its record and function arms already do. | **Small.** A few lines in `rename.y` plus the 1:1 `src/c/rename.c`. | `type Ids = [Id]` and `type M = {str => M}` become writable. Independent of JSON, and it removes the `jobj` wrap from §15.2 if a union member is ever allowed to be a map. |
| **C4** | Let a union contain **primitives**. | **Language-scale.** Tag words, boxing, `yv.h`, the emitter, the C twin, `make bench`, fuzz. | `type Json = long \| str \| bool \| [Json] \| {str => Json}` — no wrapper records at all. |
| **C5** | **JSON literal syntax** in the parser. | **Medium**, and it is the one that actually removes the noise. | `json{ … }` and `json[ … ]`, so `json.num` / `json.str` / `json.boolean` / `json.nul` / `json.jobj` / `json.jarr` all become internal. |

C3 and C5 are independent. **C5 does not need C3 or C4**, which is the point:
the sugar is syntax, and syntax can desugar to the representation that already
works.

### 16.3 C5 — the syntax

A **sigil**, not a type-directed feature. That is what keeps it unambiguous:
`json{ … }` is a JSON object and `{ … }` stays a record literal, with no type
inference involved and nothing for the checker to disambiguate.

```
json{ "method": "textDocument/hover", "id": 1, "params": json[1, 2, 3] }
```

Inside `json{ … }` the nesting needs no repeated sigil — `{ … }` is an object,
`[ … ]` is an array, and a bare literal is wrapped:

```
json{ "a": { "b": [1, true, null, 2.5] }, "c": json{} }
```

The parser desugars all of it, in the same spirit as `x!` → `unwrap(x)` and
`?:` → an if-chain over synthetic temps (`AGENTS.md`):

```
json{ "a": 1 }        →   tmp = json_obj();  tmp["a"] = json_num(1);  tmp
```

so the generated code is ordinary Y that the existing checker, renamer and
emitter handle with no new cases. `json.num` and friends stay in `json.y` as the
runtime the desugaring targets — they just stop being something a human writes.

### 16.4 C5 requirements

**S1** `json{ … }` and `json[ … ]`, recognised by the lexer as one token each so
a nested `{` is never ambiguous with a record literal.

**S2** Inside a `json` literal, a nested `{ … }` is an object, `[ … ]` is an
array, and `str`, `num`, `bool`, `null` and another `json` literal are the five
element forms. Nothing else is allowed there, and anything else is a parse error
at the offending token — never a silent reinterpretation.

**S3** Keys are `str` literals only, as JSON requires. A key that is not a
literal is an error, not an expression.

**S4** The desugaring targets `json.obj()`, `json.arr()`, `json.num`,
`json.str`, `json.boolean`, `json.nul`, `json.jobj`, `json.jarr`. If `json` is
not imported, the sigil is an error naming it — no implicit import.

**S5** The result of a `json` literal has type `json.Val`, so it can be passed
to `stringify`, stored in an object, and returned. The desugaring is written so
this holds by construction (each step is an ordinary call returning `Val`).

**S6** Trailing commas are accepted, matching JSON practice and the language's
own tolerance elsewhere. A missing value (`json{ "a": }`) is an error.

**S7** Round-trip is unaffected: a literal is exactly what `parse` produces, so
`stringify` of a literal and of its parse are the same bytes.

**S8** Obligations, in full: a `docs/src/02-lexical.tex` and
`docs/src/03-grammar.tex` section; new entries in `tags.y` and `KTAGS` (and the
1:1 `src/c/tags.c`) because this is new syntax; `// expect-error:` fixtures for
every rejection in S2/S3; a `test/COVERAGE.md` row; and `test/y/native/tNNN_*.y`
covering every element form, nesting, empty containers, trailing commas, each
rejection, and agreement between a literal and the equivalent `parse` of its own
`stringify`.

**S9** No existing program may change meaning. A `json{` that used to be a
record literal followed by a block would be a syntax error today, so the sigil
is safe to claim; `make corpus-diff` over `test/y/**.y` and `bench/y/*.y` is
still the gate.

### 16.5 What it costs, honestly

New syntax is not a small change to the compiler even when the semantics are
free. It touches the lexer, the parser, `tags.y` and its C twin, the manual,
and the coverage gates; it needs `make check`, `make bench`, `make bench-ir` and
`make rebless`; and the fuzzer gains a new syntax family to mutate. The
desugaring itself is the easy part — the process is the cost.

**M-json does not wait for this.** §15's design stands on its own with the
explicit constructors, and §15.2's `obj()`-not-a-literal rule and `jobj` wrap
remain true either way. If C5 lands first, `json.y` gets *smaller* (the
constructors become internal) and nothing else changes.

### 16.6 C3 and C4 are separable, and C3 is the one worth doing first

C3 is a real language improvement with a small diff: a recursive alias through
`[T]`, `T?` or `{K => T}` is structurally exactly as sound as one through a
record field, because arrays and options are heap objects with headers just as
records are. It needs validating against the type-level code that consumes
recursive aliases — `teq`'s 64-level unfold limit (`types.teq`),
`tcanon`, `unfold`, and the emitter's record-type hashing
(the emitter's record-hashing check) — plus bench and fuzz numbers.

### 11.5 Five more bugs, from the checker's TYPES and the semantic classes

Same shape as §11.2: each produced an answer a reader would believe, and each was
found by running something rather than by reading it.

1. **The last line of a buffer lost every one of its tokens.** `sem.split_lines`
   bounded its loop with the first line-start past the span's last byte. A file
   that ends with a newline has one more line than it has text, so there *is* a
   start past it and the answer came out right by accident. A file that does NOT
   end with a newline — which is what an editor sends for the line being typed
   right now — has none, so the bound stayed at its initial value and the loop
   never visited that line. A 17-line buffer produced **115 spans and 110 tokens**,
   and the 5 missing were exactly the last line's. In an editor it reads as the
   highlighter going blank on the current line. Every fixture here ended with a
   newline, which is why it survived; a round trip cannot see a token that was
   never produced. `t010_sem` pins both shapes now.
2. **The buffer's own lines were mapped to the spliced program one line late.**
   `Prepared.mine` filtered `origin.file == 0` and counted, but the import
   STATEMENT's line is *replaced* by the imported module's lines, so the origin map
   still has an entry for a line the splice does not. Every hover in a file with an
   import asked about the line *above* the one under the cursor — so hovering the
   blank line between an `import` and a `def` returned the function's own
   signature. The first fixture had no imports, and the offset is 0 for those, so
   it passed; `client-check.js`, whose buffer does import, is what caught it. The
   map is now two line counts — `spliced - buffer + k` for every line at or after
   the first non-import line, and 0 before it (`xref.own_lines`).
3. **A completion list after a `.` offered `print`.** The member branch set a flag
   and the name branch tested it, so a `str` — whose fields are none, so the flag
   stayed false — got the string methods *and* every name in scope: 77 items where
   there are 26. The two lists must be alternatives. Worse, the fallback fired for
   *any* receiver, so an array's `.` offered all 26 string methods; a completion
   list is read as "these are the things you can put here", so that is worse than
   an empty one. It is now gated on the receiver's type actually being a `str`, or
   on there being no type at all — which is the Stage A answer and is honest
   because the server does not know the receiver.
4. **A record field's hover asked for a declaration that does not exist.** The type
   was read inside `if (is_some(found))`, and a field is not a binding — a field is
   a name the program does not bind, so the index has nothing to find. So hovering
   `p.a` showed nothing at all even though the checker had the answer. The type
   answers on its own and the declaration, when there is one, goes underneath.
5. **`classify` — later `semantic_overrides` — cost 34.5 seconds on the largest file in the tree.** Two causes,
   both invisible until something asked about *every* identifier rather than one
   position: the per-identifier position lookup counted newlines from byte 0, which
   is quadratic in the file, and `scope_end` walked all ~7,000 scope pairs for
   every candidate. `34,490 ms -> 115 ms`, and `visible()` — which a completion
   calls once — went `7,576 us -> 347 us` from the same fix. `request-cost.y`
   measures all four phases now, because "it is slow" is not a finding and
   "here is the phase" is.

A sixth, smaller, and worth one line: `pos.from_lsp` **already** returns a 1-based
byte column, and the first version added a second `+1`. Every request then asked
about the character *after* the one under the cursor — on an identifier, nothing
indexed, so the type silently never appeared.

C4 is a different project. It changes what a union *is* at runtime, and it
should be argued for on its own merits rather than as LSP support.

### 11.6 Six reported bugs, and the one that was not a server bug

Six defects a user hit in one sitting. Five were the server's; one was not
reproducible in the server at all and is reported here as what it is rather than
as a fix. All five share one root cause, which is why they looked like six:

> **A position is not a type.** In every case something was recorded at one column
> of a line and asked about at another.

`t018_reported.y` is the fixture, and it drives the same `dispatch.doc_request`
path an editor does — not the internals — so each line below is what a user gets.

1. **A declaration's own name showed no type.** `let b = 1000000000;` — the `Decl`
   sits at the KEYWORD, so the table held `long` at column 1 and nothing at column
   5, which is where the cursor is. A *use* of `b` two lines away answered `long`,
   so the same name gave two answers depending on where you pointed. Fixed by
   §9.2 A4.
2. **A parameter's own name showed no type**, and this one had nothing behind it:
   `Func.params` is a list of bare strings, so a parameter has no node, no line
   and no column, and no consumer *could* have answered. This was documented in
   §9.2 as "the imprecision it is" and was not one. Fixed by §9.2 A6, which also
   fixed go-to-definition on a parameter, which had been landing on the `def`.
3. **No hover for a builtin.** An intrinsic is matched *by name* inside
   `typeof_call`, so its callee identifier is never an expression and nothing was
   ever recorded at it. `clock_us` had no entry anywhere in the file. Fixed by
   §9.2 A7, recording the call's own type at the callee — which is what the
   checker knows, and no signature string was invented for it.
4. **Imported names had no type.** Root cause one level down, in the compiler:
   `diag.xref_for` — the path that *builds* the type index — linked **no std
   units**, passing `externs_none()`, while `diag.diagnose` had always passed the
   real `externs_for(std_units(nr.std, pack))`. So every std name was undefined,
   every expression using one came back `tunk`, and the editor had nothing to
   show. The tell was that `math.pi` *did* answer `float`: a constant needs no
   extern, and a call member did — so the bug read as "imports are not typed"
   rather than as a checker that was never asked. `xref_for` takes the pack now.
5. **An f-string was one colour.** `scan` emits an f-string as one span, so
   `f"{name:<14}: {us * 2.0:7.2f} ns"` was a single `string` token and `name` was
   part of one blob — worse than not highlighting it at all, because the
   interpolation is the part a reader is looking at. `sem.fstring_parts` now
   re-scans each `{...}` with **the same `scan` over the same text** and offsets
   the spans into place, so the inside of an interpolation is classified the way
   the same code is outside a string. A hand-rolled split would have re-implemented
   the scanner and been wrong the first time a construct appeared that it had not
   heard of. Line 15 of the fixture: **5 spans, 26 tokens**.
6. **Completion after a `.` was wrong in two ways.** `math.` offered
   `byte_at, bytes, center` — the string methods — because the string-method
   fallback fired whenever the record branch produced nothing, and a module is not
   a record; `a.` where `let a = { a: 2 }` did the same. Two distinct fixes: a
   module offers its own members (the linked unit's `exports`, else the spliced
   names filtered by origin file), and a record literal offers its fields. The
   second needed one more thing, and it is the useful part:

   > **A half-typed line does not typecheck, so nothing is indexed on it.** `z.`
   > has no name after the dot, so there is no `Dot` node and no type at that
   > position — which is the whole reason the fallback existed. But the
   > DECLARATION is not mid-edit: `let z = { z: 1 };` typechecks and its type is
   > recorded at the name's own column. `serve.type_of_object` therefore asks at
   > the use, and if the checker has nothing, resolves the name through the scope
   > index and asks at the declaration. Both answers are the checker's; the second
   > is a *position*, not a re-derivation.

Three bugs in that last paragraph are worth naming separately, because they were
each invisible until something asked for *every* member position rather than the
one a fixture happened to use, and every fixture sat near the top of a short file:

- **`object_col` passed a column to `nav.ident_at`, which wants a byte offset.**
  The two coincide on line 1 of a buffer, which is why every member case in the
  fixtures passed. On line 26 of a real one it looked up a column as an offset,
  found whatever identifier happened to live there, and returned its column.
- **`object_col` and the two other lookups each re-derived "the identifier before
  the dot"**, and one of them did it without stepping back over the dot. With
  nothing typed after `z.`, `word_start` *is* the dot, and a dot is not an
  identifier — so both silently found nothing. They now all go through one
  `object_hit`.
- **`serve.type_at` answered `tnone` for "no answer"**, and `tnone` is a type a
  program can write, so the caller's "did the checker say anything?" test never
  fired. It answers `tunk()`, for the same reason `types.expr_type` does.

And one the report turned up that is worth more than its size: **the hover printed
a function's return type as though it were the function.** Recording the call's
result at the callee made `mk` hover as `{ a: long, b: str }` — the record that
`mk(1, "x")` produces. The answer was not wrong about anything; it was wrong about
what `mk` *is*. A hover now shows the type only when the declaration does not
already say it, so a def or a parameter's signature is printed once instead of
twice, and a call's callee carries its **signature** (`mk(a: long, b: str) -> P`).
An intrinsic keeps its return type, because the checker holds no signature object
for one — the asymmetry is real and is the honest answer rather than a uniform one
that is half invented.

#### The one that is not a server bug

**Brackets inside a comment were highlighted.** This could not be reproduced in
the server, and the two layers that could have done it both were checked and are
correct:

- `scan.scan_full` returns a `//` comment as **one** `K_comment` span — verified by
  reading the spans, not by looking at the output — and `sem.split_lines` gives it
  one token, so the semantic-token layer cannot be the cause.
- `vscode-y-lang/syntaxes/y.tmLanguage.json` lists `#comments` **first**, which is
  right: TextMate takes the match that starts *earliest*, so for a comment that is
  the only way it wins.

The likeliest cause is **VS Code's own bracket-pair colourisation**
(`editor.bracketPairColorization.enabled`, on by default), which colours matching
brackets anywhere in the line, strings and comments included. That is an editor
feature the server does not participate in, so it is not something a fixture here
can pin. The exact text is worth having if it turns out not to be.

What *did* come out of chasing it is a real grammar bug, and the reason it was
worth chasing: `#comments` before `#strings` is right for a comment and **wrong for
a string containing `//`**, because the comment match starts earlier than the
string's own quote. `let s = "// not a comment";` painted half a string as a
comment. `#strings` now comes first — a comment outside any string still matches,
because nothing starts before it. `t018_reported.y` asserts the ORDER, on the file's
text, because the order is the semantics and reparsing the JSON would only make
the same comparison harder to read.
