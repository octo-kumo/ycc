# How to write the docs

This is the writing convention for everything in this repository that explains
something to a reader: the reference manual under `docs/src/`, the markdown
documents at the root and in `src/`, `test/` and `examples/`, and the commit
messages that carry the reason for a change.

It exists because of a measured failure. The `bigint` work landed with three
fixtures, a runtime, a checker, an emitter and no manual entry at all — and
**every one of the twenty-one suites passed**, because every documentation gate
this project has runs in one direction: it checks that the manual's sections
have tests, never that a new feature has a manual section. So the rules below
are not style preferences. The last section lists what nothing checks, which is
where a writer's attention actually has to go.

## The documents, and who reads them

| file | audience | what it is |
| --- | --- | --- |
| `docs/src/*.tex` | everyone; it is the language definition | the normative manual: the complete surface language, its type system, its evaluation semantics |
| `README.md` | someone new to the tree | orientation: what this is and how to build it |
| `AGENTS.md` | an agent or contributor mid-task | the working agreement: the build, the development loop, the suites, the hard Y style rules |
| `PORTING.md` | whoever changes `src/y` | the C↔Y 1:1 contract, as **numbered rules** other files cite by number |
| `src/y/NATIVE.md` | whoever touches the backend | the design of the emitter, the assembler, the value model, the std pack |
| `test/COVERAGE.md` | whoever adds a feature or a test | the feature → test matrix, **read by a suite** |
| `TODO.md` | the compiler's own agenda | wanted language features and known defects |
| `examples/SUGGESTIONS.md` | the examples campaign | findings made while writing programs; a ledger, with a completion rule |
| `examples/ORCHESTRATOR.md` | the examples campaign | the protocol (§8: entry template, dedup, when a finding is a bug) |
| `src/tools/lsp/LSP.md` | whoever touches the language server | the design, **with its citations checked by a script** |

Write in the file whose audience would look there, and say in the document
itself what checks it, if anything does.

## The reference manual

### Structure

The manual is three files, concatenated in this order, and **that order is the
document**:

- `docs/src/_preamble.tex` — the document class, every custom command, and
  `\begin{document}`;
- `docs/src/index.tex` — the title, abstract and table of contents, then one
  `\input` per chapter;
- `docs/src/_postamble.tex` — `\end{document}`.

The chapters are `docs/src/NN-topic.tex`, `01-overview` through `10-errors`, and
a new chapter means a new file plus an `\input` line in `index.tex`. There is
deliberately **no `_all.tex` driver**: the Makefile recipe is the driver, and
`docs/Tectonic.toml` names the same three files so the structure also lives in
the config.

Choose the chapter by *topic*, not by feature: a feature lands in the chapter
about the thing it is (a literal in `02-lexical`, a type and its conversions in
`04-types`, an operator's semantics in `05-expressions`, a function in
`09-builtins`, a new trap in `10-errors`), usually as a new `\subsection` plus a
sentence or two added to the existing conversions or operator-typing lists —
those lists are read as complete, so an omission there is a wrong statement, not
a gap.

### Commands

The preamble defines these; use them instead of hand-formatting:

| command | for | example |
| --- | --- | --- |
| `\ic{...}` | inline code, a name, a call, a literal, an error message | `\ic{tolong("12x")}` |
| `\ty{...}` | a **type** name | `\ty{bigint}`, `\ty{long}` |
| `\y{...}` | plain typewriter text, not code | rare; prefer `\ic` |
| `\bs` | a backslash inside `\ic` | `\ic{long $\bs to$ float}` |
| `\_` | an underscore — **redefined** to `\textunderscore\allowbreak` | `\ic{crypto.is\_prime(n)}` |
| `\lb{...}` | a label that may be longer than the measure | used by the description lists |

`\_` is safe everywhere and is also a **line-break opportunity**: write
`\ic{crypto.is\_prime(n)}` rather than an unescaped underscore, or the name
becomes one unbreakable box. The preamble's own comments record why — a single
23-character `\ic{...}` put a line 190 pt over the measure, and one 90-character
one 433 pt — which is the standard to meet: **the number, not the adjective**.

For a description list whose items are names (the seventeen in
`09-builtins.tex`), use the list setup the preamble installs and the `font=\lb`
key; `label=` is a different key and an error there.

### Typesetting traps

- `%` is a comment: write `\%`.
- A caret is not a character: write `\textasciicircum` or use math, `$2^{63}$`.
- An `\ic{...}` span breaks only at spaces and escaped underscores.
- Reference labels with `\ref{...}` **only if the label exists**. An undefined
  reference typesets as `??` and nothing fails; grep
  `docs/src/*.tex` for `\label{sec:` before you cite one.
- Do not put `\ic{}` in a `\section`/`\subsection` title. The coverage suite
  strips it to compare the row's title, and a title is a key, not prose.

### Building

```
make docs          # -> docs/build/manual.pdf  (needs tectonic; see below)
```

The recipe pipes the three files into `tectonic -` from `docs/src` (so the
chapters' `\input` paths resolve), then **fails on an error and on a warning**:
an overfull or underfull line is counted out of the log. The manual last
typeset with none, and a target that only printed warnings is how one sat
unnoticed. `docs/build/` is gitignored.

Three things to know before you rely on it:

- **`make docs` skips when `tectonic` is not on the PATH** --- it prints `no
  tectonic, skipped` and exits **0**, so `make` calls it a success and nothing
  checks your LaTeX. On this machine the binary is at
  `~/.local/bin/tectonic` (0.17.0) and that directory is not on the recipes'
  PATH, so the form that actually builds is:

  ```
  PATH="$HOME/.local/bin:$PATH" make docs
  ```

  It writes `docs/build/manual.pdf` and `manual.log` (both gitignored) and
  typesets the manual in three XeTeX passes. The verdict it prints is the one
  to quote: size, page count, and whether there were errors or warnings.
- XeTeX is what tectonic runs underneath, and it is a usable fallback when the
  binary cannot be reached --- but **its warning set is not tectonic's**. This
  tree had one overfull line under `xelatex` that `tectonic` does not report at
  all, so use xelatex to find ERRORS in the file you touched, and `make docs`
  for the verdict that counts.

  ```
  cd docs/src
  cat _preamble.tex index.tex _postamble.tex > _tmpcheck.tex
  xelatex -interaction=nonstopmode _tmpcheck.tex
  rm -f _tmpcheck.tex _tmpcheck.aux _tmpcheck.log _tmpcheck.out _tmpcheck.pdf _tmpcheck.toc
  ```

  Run it from `docs/src` or the `\input`s are not found, and **delete the
  artifacts**: a `_tmpcheck.*` left behind is an untracked file in the tree. A
  raw `_` inside `\ic{}` is an error --- write `\_` --- and two of them sat in
  `02-lexical.tex` until 2026-10-06, where `make docs` failed outright with
  `! Missing $ inserted.`
- **To tell whether an error is yours, build the baseline in a throwaway
  worktree**:

  ```
  git worktree add /tmp/base <rev> && (cd /tmp/base && PATH="$HOME/.local/bin:$PATH" make docs)
  git worktree remove /tmp/base
  ```

  That is how the two errors above were shown to predate the change that fixed
  them, and it is the only way to distinguish "my edit broke the manual" from
  "the manual was already broken" --- which matters, because the second is the
  normal reason `make docs` was never run.

### Voice

The manual is a *definition*, and its abstract says what that means: it records
the complete surface language "so that these features are specified rather than
discovered", and where the language is quirky, the quirk is written down. In
practice:

- **Assert, and pin the example that proves it.** Not "conversion generally
  truncates" but "`tolong(-3.99)` is `some(-3)`, not `-4`, which is `floor` and
  not `trunc`".
- **Measure before you write.** Every behaviour in the manual was run before it
  was described; several entries exist only because a probe contradicted what
  the code looked like it did. `ycc run file.y` is the cheapest way.
- **Record the gap instead of claiming.** Where something is not exact, say so
  and give the shape: a chapter states outright that a band of literals between
  about `1e-327` and `1e-367` is mis-parsed into a subnormal, with the count
  (302 of 725) — because a reader who finds it should find it written down.
- **State the "why" next to the "what"**, with the number that motivated it.
  This is the house habit everywhere, not only in the manual: the preamble
  explains its `\ic` definition by the overfull line it caused, and
  `Tectonic.toml` explains which of its keys are inert.
- Em dashes for the aside that gives the reason (`--- ... ---`), `\emph{}` for
  the one word that carries the point, and no decoration beyond that.

## The matrix contract

`test/COVERAGE.md` is the only document here that a suite reads line by line,
and `src/tools/ytest/su_coverage.y` (`make test`, [coverage]) enforces four things:

1. every diagnostic message a compiler site can print appears in some test
   expectation, or is listed in `COVERAGE.md` with a reason it cannot be
   reached;
2. every builtin and string method in `09-builtins.tex` is called by a checked
   test;
3. every keyword the lexer knows appears in a `t*.y` program;
4. **every `\section`/`\subsection` of `docs/src/[0-9]*.tex` has a row**, and
   every test a row names exists and checks its output.

So a new subsection is not finished until it has a row:

```
| 04-types | Big integers | what this row's feature is, in one sentence | `native/t353_bigint_ops.y` |
```

- The **title must be exactly the title in the `.tex`** (after `\ic{}` and
  backslashes are stripped).
- **One section may have many rows** — one per feature or aspect; that is the
  normal case, not an exception.
- **Every test reference must be in its own backticks.** The suite extracts
  them with ``grep -o '`[^`]*`' ``, so `` `a.y, b.y` `` is one reference named
  `a.y, b.y` and fails.
- Accepted references: `native/NAME.y` (a `t*.y` also needs its `.expected`;
  an `e*.y` needs its `// expect-error:` markers), `ytest/su_NAME.y`,
  `lsp/test/NAME.y` (with its `.expected`) and `lsp/test/NAME-check.js`,
  `comprehensive: NAME`, `loops: NAME` (a case whose name starts with NAME).
- A section that specifies nothing a program can do gets one row whose Tests
  cell is ``none: `` and a reason of at least ten characters. **A stale excuse
  fails the suite**, so a `none:` row is a claim to revisit, not a place to
  park something.
- `audit/` and `examples/` programs only check that the two compilers agree, so
  naming one is not evidence that a feature works.

**The builtins check has one trap worth knowing.** Inside a `description`
environment in `09-builtins.tex` the suite enumerates every `\ic{name(...)}` and
`\ic{s.name(...)}` and requires a matching *call* in a checked test. A bare
`\ic{is\_prime(n)}` therefore demands a bare `is_prime(` call that no test makes
and fails, while the qualified `\ic{crypto.is\_prime(n)}` matches the
`crypto.is_prime(` that the test actually writes. **Qualify a module function's
name with its module.** Prose outside a description environment is not
enumerated, which is why a paragraph can name a dozen functions safely.

## The prose documents that are checked

- **`src/tools/lsp/LSP.md`** — `src/tools/ytest/su_lsp.y` runs `ytest check-refs`, which fails
  when the document cites a symbol that does not exist. A rename in the server
  is a documentation change.
- **`src/y/NATIVE.md`** — other documents and code comments cite its sections
  **by name** ("NATIVE.md, 'Compilation units and the std pack'"), so renaming a
  section breaks citations silently. Nothing checks this one.
- **`PORTING.md`** — the rules are numbered and cited by number from
  `src/c/*.c`, `AGENTS.md` and each other. Add a rule at the end and keep the
  number it is given; never renumber.
- **`AGENTS.md`** — the working agreement. Its numbers are measurements (the
  cost of `make rebless`, the count of suites, the fixtures a gate covers), so
  changing one means re-measuring it and updating the sentence that quotes it.

## The ledgers

`TODO.md` is the compiler's agenda. `examples/SUGGESTIONS.md` is the examples
campaign's, and it has its own protocol in `examples/ORCHESTRATOR.md` §8 — the
entry template, the dedup rule, and when a finding is a bug rather than a
suggestion. Two rules from it that a writer will otherwise violate:

- **Check the root `TODO.md` first.** Restating an entry that is already there
  is noise.
- **Delete the entry when it is done**, and record what happened as a dated
  status block instead:

  ```
  ### Status (round 63, 2026-10-06) — NARROWED: the FLOAT half is closed
  ```

  A ledger whose completed items are still in it is a list of things that are
  already true, and the next reader cannot tell which half is real.

## Before you commit a documentation change

1. If you added a `\section`/`\subsection`: a `test/COVERAGE.md` row, with the
   title matching exactly and the tests in their own backticks.
2. If you documented a builtin in a description list: it is **qualified** with
   its module, and a checked test calls it.
3. `./ytest coverage` — the manual ↔ matrix ↔ tests contract.
4. `make docs`, or the XeTeX fallback above; check that no error names the file
   you touched. If you cannot run either, **say so in the commit message** —
   "the manual was not typeset" is a fact the next reader needs.
5. `./ytest lsp` if you touched something the LSP fixtures
   enumerate — the std unit symbol lists in `t018_reported` and
   `t020_sorttext` are golden files that change when a std module gains a
   function.
6. A commit message that says **how the change was verified**, with numbers
   where there are numbers. A docs-only change needs no rebless and no bench:
   nothing about it reaches the compiler.

## What nothing checks

This is the part to read twice, because these are the failures that reach a
reader:

- **A feature with no manual section.** Every gate runs manual → tests. Nothing
  runs tests → manual, and nothing fails when a merged feature documents
  nothing. If you are changing the language, the manual is part of the change,
  not a follow-up.
- **A claim that is wrong.** No check compares a sentence to the behaviour. Only
  running the example does.
- **A dangling `\ref`.** It prints `??` and passes everything.
- **A number that has gone stale.** Suite counts, timings and byte sizes in
  prose are measurements with a date baked in.
- **A `none: reason` row that is no longer true**, and any prose in
  `COVERAGE.md` that understates what the manual now says.
- **A manual that was never typeset**, because `make docs` skips without
  tectonic and the compiler must never depend on a TeX distribution.

When you cannot close one of those gaps, write the gap down — in the commit
message, in a `none:` row, or as a paragraph in the document itself. The house
style has a place for a known defect that is stated as a defect, and no place
for an assurance nobody measured.
