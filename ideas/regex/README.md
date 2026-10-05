# std/regex.y — landed

`import regex;` compiles patterns and matches them: a Pike VM (a Thompson NFA
simulated with priority-ordered thread lists) over **bytes**, so a match costs
time linear in the subject times the pattern. `compile` gives `Re?` and `check`
the message, since a pattern is data rather than a caller bug.

    src/y/std/regex.y                   the module
    test/y/native/t191_regex.y         the dialect, every diagnostic, all five limits
    test/y/native/t192_regex_groups.y  groups, names, offsets, replacement templates
    test/y/native/t193_regex_sweep.y   find / split / replace / replace_with
    test/y/native/t194_regex_group_trap.y   a group past the last one traps
    test/y/native/e168_regex_no_import.y    the module needs its import
    test/y/native/t195_regex_corpus.y  178 cases against Python's re (generated)
    docs/src/09-builtins.tex            \subsection{Patterns (the regex module)}
    test/COVERAGE.md                    the row, under Features
    src/y/NATIVE.md                     the Optional std modules paragraph
    ideas/regex/gen.py                  the corpus generator (its provenance)
    ideas/regex/pdiff.py                the per-case diff, when the two disagree
    ideas/regex/run.sh                  drives the corpus half of the check
    ideas/regex.md                      the proposal this was built from

The five fixtures are ordinary ones now: `test_native.sh` runs them, `test_port.sh`
compiles them with both compilers. What `run.sh` adds is the *other* half of the
corpus check — that the expected output still says what Python's `re` says about
the same bytes — which needs Python, so it is not a suite:

    ./ideas/regex/run.sh            check the fixture against the committed output
    ./ideas/regex/run.sh --regen    regenerate the fixture, then check it

## The corpus

`gen.py` holds one list of `(pattern, subject)` pairs and writes both halves: the
fixture the tree runs, and what Python's `re` says about the same **bytes**. They
agree on all 178 cases. Python is the reference because it is a *different* engine
with the same semantics where they overlap (bytes, leftmost-first), so agreement
is evidence rather than a tautology. Where Python is not the reference, `gen.py`
says so and pins our answer in its `PINNED` table:

- a dialect of ours Python has no spelling for — POSIX classes inside `[...]`,
  `\x{...}`, `\z` (Python's `\Z`), `(?<name>)` (Python's `(?P<name>)`), and a
  `{` that does not open a repetition being a literal byte;
- our own diagnostics, which are ours by design (`compile` gives `none` and
  `check` says why);
- `(?-i: … )`, which we reject on purpose;
- where an NFA and a backtracker differ and we are the NFA: the captures of a
  loop whose last iteration took no bytes;
- `find` and `replace` wherever an empty match is in play, since the rules differ
  (Go's adjacency rule, and an empty match replacing nothing).

`pdiff.py` prints a per-case diff when they disagree, which is how the engine's
bugs were found — including one that reported a capture a byte too long, because
the two thread lists shared an array.

## Numbers

Measured on this machine (a shared one; the cap is the tree's 3.5 GiB), an 8.2 MB
subject of log lines, one pass each:

| pattern | work | time | heap |
| --- | --- | --- | --- |
| `status=ok` | `find`, 100 000 matches | 38 ms | 24 MB |
| `\d+` | `find`, 1 100 000 matches | 216 ms | 274 MB |
| `(?i)STATUS=OK` | `find`, 100 000 matches | 51 ms | 24 MB |
| `(\w+)@(\w+)` | `find`, no match | 10 ms | 0 |
| `^\d{4}-\d\d-\d\d` | `search` | 0 ms | 0 |
| `(\d+)-(\d+)` | `replace` over the lot | 899 ms | 64 MB |
| `(a*)*b` | `is_match`, 64 KB of `a` | 0 ms | 0 |
| `(a\|aa)+b` | `is_match`, 64 KB of `a` | 0 ms | 0 |

The `\d+` line is 1.1 M `Match` values — a `caps` array, a `text` copy and a
record each — which is what returning every match costs in a language whose heap
has no free. The two hostile patterns are the point of the engine. The
`(\w+)@(\w+)` line is the required-literal prefilter (`need`).

## What the profile said

Profiled with `valgrind --tool=callgrind` on a `-g` build (exact instruction
counts, one phase per run) over an 8.2 MB subject. The engine was, in one line,
`add` at 38% — the per-byte closure walk interpreting opcodes and pushing onto a
worklist — then `step`, the worklist helpers, the class test and the capture
copies. Four rounds of changes, each measured against the one before:

| what | why |
| --- | --- |
| dead `orig`/`kept` writes removed from `add` | written on every call and every queued thread, read nowhere |
| `seek`'s skip loop split by case, fields hoisted, class bits read in place | it re-read `re`'s fields and called `class_has` (90 Ir) for every byte it skipped |
| `push`/`queue` inlined into `add` | ten million calls a scan at ~30 Ir of call overhead apiece |
| the class-bit test inlined in `step`; its list hoisted | the hottest test in the machine |
| `copy_caps` given a length-matched fast path | the guarded loop measured 14.2 ns a six-slot copy against 9.2 for the bare one |
| the recycle's two `count_holding` passes fused | one call and one pass per list instead of two of each |
| `hit` and `base` sized at birth, per-run reset inlined | the group-free match path writes two slots instead of copying a vector it overwrites next line |

Instructions: `\d+` `replace` 7.38 G -> 6.00 G (-19%), `(\w+)=(\w+)` `find`
29.1 G -> 24.8 G (-15%). Wall clock, min of nine: `(?i)STATUS=OK` -27%, `\d+`
`find` -21%, `(\d+)-(\d+)` `replace` -18%, `(\w+)=(\w+)` `find` -16%, a literal
`find` -12%. Heap unchanged everywhere. Checked against the old engine over 3900
random patterns (three seeds) with every API call dumped: byte-identical.

### The two costs that stay, and why

**The closure walk (`add`).** Precomputing each pc's closure at compile time --
the leaves in priority order, each with the SAVEs and checks on the path to it --
would replace the opcode interpretation and the worklist outright, worth perhaps
another 25%. It is not a small change: the enumeration has to carry *chains*, not
just leaves, and the runtime marks a pc visited only once the path to it has
survived, because a path can fail (a negative lookahead). A pc reachable by two
chains, the earlier of which fails at run time, must be queued by the later one --
so a precomputed list needs every distinct chain per pc, which is where the
enumeration gets fiddly. It is the next thing to do, not something to do in a
hurry.

**The copy on every SAVE.** `take_caps` clones the capture vector at each group,
which is 17% of a group-heavy scan. The obvious fix is copy-on-write -- mutate in
place when only this thread holds the vector -- and it is wrong: a walk's earlier
branch can write a slot, queue nothing (its leaves all already visited), and let
a later branch inherit the write. `(a)|(b)` on `"b"` would report group 1 as
matched-and-empty, which is exactly the bug the always-clone rule was written to
prevent. Doing it properly needs a reference count per vector, kept honest
against the pool; that is a redesign of the capture discipline, not an
optimisation.

## One thing to report

While writing this, a record-field mutation and a `d + 1` threaded through three
calls both failed to reach a *nested* call in this module, with the blessed
compiler, while `p.pos`, `p.groups` and `p.names` behaved and the same statement
inside a one-line helper worked. The write was visible in the writing frame and in
the record's own `tostring`, but the callee read the old value. The module avoids
the pattern (the lookaround count is taken off the parse tree, not the parse
state). It is reproducible in `src/y/std/regex.y`, is recorded here rather than
claimed as understood, and is the one thing in this work I would not call done.
