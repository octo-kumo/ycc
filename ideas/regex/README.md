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
| `status=ok` | `find`, 100 000 matches | 52 ms | 24 MB |
| `\d+` | `find`, 1 100 000 matches | 321 ms | 274 MB |
| `(?i)STATUS=OK` | `find`, 100 000 matches | 76 ms | 24 MB |
| `(\w+)@(\w+)` | `find`, no match | 11 ms | 0 |
| `^\d{4}-\d\d-\d\d` | `search` | 0 ms | 0 |
| `(\d+)-(\d+)` | `replace` over the lot | 1.29 s | 64 MB |
| `(a*)*b` | `is_match`, 64 KB of `a` | 0 ms | 0 |
| `(a\|aa)+b` | `is_match`, 64 KB of `a` | 0 ms | 0 |

The `\d+` line is 1.1 M `Match` values — a `caps` array, a `text` copy and a
record each — which is what returning every match costs in a language whose heap
has no free. The two hostile patterns are the point of the engine. The
`(\w+)@(\w+)` line is the required-literal prefilter (`need`).

## One thing to report

While writing this, a record-field mutation and a `d + 1` threaded through three
calls both failed to reach a *nested* call in this module, with the blessed
compiler, while `p.pos`, `p.groups` and `p.names` behaved and the same statement
inside a one-line helper worked. The write was visible in the writing frame and in
the record's own `tostring`, but the callee read the old value. The module avoids
the pattern (the lookaround count is taken off the parse tree, not the parse
state). It is reproducible in `src/y/std/regex.y`, is recorded here rather than
claimed as understood, and is the one thing in this work I would not call done.
