# std/regex.y — a regular expression module for Y

A proposal: a plain-Y `std/regex.y` with a **Pike VM** (Thompson NFA simulated with
priority-ordered thread lists), **byte** semantics, and `compile -> Re?` plus
`check(pattern) -> str` for a pattern that does not compile.

> **Status: landed.** The module is in the tree (`src/y/std/regex.y`), with its
> fixtures beside the other std modules' (`test/y/native/t191_regex.y` through
> `t195_regex_corpus.y`, `e168_regex_no_import.y`), a manual section
> (`docs/src/09-builtins.tex`, "Patterns (the regex module)") and a row in
> `test/COVERAGE.md`. It agrees with Python's `re` on all 178 cases of the
> differential corpus (`ideas/regex/gen.py` generates the fixture, `run.sh` the
> check), where Python's answer is the reference. This document is the proposal
> it was built from, with what the build changed marked in place; the last
> section is what it taught, none of which was visible from reading the design.
> `ideas/regex/README.md` says where every piece landed and how to run the
> corpus half of the check.

Three decisions are settled and the rest of this document follows from them:

| Question | Answer | Why |
|---|---|---|
| Which engine? | Pike VM, linear time, **no backreferences** | a backtracker recurses in Y, and Y's frames live on a fixed 8 MB machine stack; `.*` over a large subject would want ~100 K frames. A Pike VM's only recursion is compile-time (pattern nesting) and lookahead nesting. |
| Bytes or code points? | **Bytes** | strings are bytes everywhere in Y (`len`, slicing, `byte_at`), `.upper()` is ASCII-only (`str.y:194-209`), and no other std module knows what a character is. |
| How does a bad pattern speak? | `compile -> Re?`, `check -> str` | a pattern usually comes from a config file or argv, so it is *data*, not a caller bug. `x509.verify_chain` already establishes `""` = fine (`x509.y:430`). |

## The north star

```y
import regex;

let line_re = regex.compile("^(?<host>\\S+)@(\\S+):(?<port>\\d+)$")!;

foreach (line in fs.read_lines("/etc/app.conf")!) {
    let m = regex.search(line_re, line);
    if (m == none) { continue };                     // no such shape, skip it
    print(regex.named(m!, "host")!, " on port ", regex.named(m!, "port")!);
};

// sweep a log for anything that looks like an address, and rewrite it
let ip = regex.compile("\\b(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\.(\\d{1,3})\\b")!;
foreach (hit in regex.find(ip, text)) {
    if (regex.group(hit, 1)! != "10") { continue };
    print(hit.start, "..", hit.end, " ", hit.text);
};
print(regex.replace(ip, text, "$0:$0"));             // $0 $1.. $9 ${name} $$
print(regex.replace_with(ip, text, def (x: regex.Match) -> str { "[" + hit_text(x) + "]" }));
```

---

## What Y gives us, and what it takes away

Everything below is a fact about the tree, not a preference, and each one decided
part of the API above.

| Fact | Where | What it decided |
|---|---|---|
| Strings are **bytes**; `len`, slices and `byte_at` count them | `AGENTS.md`; `arch_x64.y:977` (`y_str_slice` allocates and copies) | byte engine; `.` is one byte; a group text is a copy, so offsets are worth having too |
| `s[a:b]` **copies** | `arch_x64.y:977-1011` | `Match.text` is a field (one copy per match, wanted 90% of the time) *and* `caps` is public (offsets, no copy) |
| Records are **exact**; a type used in two places gets an alias declared in the module that owns it | `AGENTS.md`, "Y code style"; `m16: a type has one spelling` | `type Re` / `type Match` in `regex.y`, reached as `regex.Re` / `regex.Match` |
| A module's aliases are `m.T`, read by the parser in a type **and in a type pattern** | `NATIVE.md:836-851` | programs may annotate `re: regex.Re` and a lambda `(regex.Match) -> str` |
| `import name;` resolves `std/name.y` then `src/y/std/name.y` then beside the `ycc` binary | `native.y:491` (`std_resolve`) | **no compiler change at all** — dropping the file in is the whole integration |
| Optional modules "stay Y", resolved from disk; no C twin | `PORTING.md:48` | no porting work, and no std-pack entry |
| An imported module's uncalled defs are tree-shaken | `AGENTS.md` §"Pipeline" (`prune_bodies`, link across units) | one module may hold both the hot and the cold API; but a **top-level `let` is a shake root** and would be inlined at `_start` in *every* binary that imports it (`crypto.y:131-134`) → no top-level tables; build a table inside a def |
| Failure is `T?`; a "why not" is `str` | `fs.read_file -> str?`, `http.Response.err` (`http.y:32-35`), `x509.verify_chain -> str` | `compile -> Re?`, `check -> str`, `group -> str?`, `named -> str?` |
| An offset past the end **traps** | `struct.y:15-16` ("an offset past the end trips the runtime's index trap and exits 1") | a group number past the pattern's last one traps; an unknown group *name* is `none` (a map read's rule) |
| **No `break`/`continue`** | grammar, `03-grammar.tex:239-253` | the loops are `let go = true; while (go)` and early `return`, as in `rt.y`/`str.y` |
| **No new closures** — the C twin's `yv.h` has no function value to store one in | `AGENTS.md` "Y code style" | `Match` is plain data: no method fields, no closure per match, `replace_with` takes a function *argument* (the caller's own lambda) rather than building one |
| `[T; N]` works as a local, a parameter **and a record field**, written in place | `crypto.y:719` (`out: [long; 4]`), `fs.y:244` (a 32 KB `[byte]`), and a spike (`{ bits: [byte; 32], n: long }` round-trips through a field) | the byte-set bitmaps are `[byte; 32]` locals and parameters |
| No free: the heap is a bump allocator | `AGENTS.md` ("`cycc` never frees"), no `free` in the runtime | **every** scratch array is hoisted out of the per-position loop and kept across steps — the thread lists are two persistent arrays with a live count, the walk's stack lives in the `Run`, the captures come off a pool — because a heap that never frees makes an allocation per step a budget problem, not a style one |

## Requirements

Repo rules, and what each one means here.

| # | Requirement | Concretely |
|---|---|---|
| R1 | **No compiler change.** | the file lands in `src/y/std/`; `std_resolve` already finds it |
| R2 | **No C twin** (`PORTING.md:48`) and **no porting work** | unlike `src/y/*.y`, a std module is not mirrored in `src/c/` |
| R3 | **Not used by the compiler itself.** | `src/y/pkg.y` and `src/y/ycc.y` import `fs` only because the C twin can too; a `regex` import in compiler source would need a C twin and break the port gate (`make ycc`) |
| R4 | **No string methods and no record methods** (`s.match(re)`, `re.match(s)`) | `str_method` (`types.y:2624-2646`) maps a method to a builtin or a fixed `y_` label, and an imported module has no label a program is guaranteed to have. A record method would have to be a **closure** (`x.f(...)` is a field read), which the C twin's value model cannot hold — so `regex.search(re, s)` it is |
| R5 | **No warnings** from `src/y/std` (`test_fixpoint.sh`) | every parameter annotated, no unused local, no unknown type |
| R6 | **Both compilers agree, byte for byte** (`test_port.sh`) | every `test/y/**.y` fixture compiles identically with `cycc` and the reference, so the module is plain Y with no undefined behaviour and no hash-map order dependence (`fs.list_dir` sorts; a `find` over `keys(m)` does not need to) |
| R7 | **The module never prints and never exits.** | all failure is `none`, `""`, or the language's own index trap. It differs from `crypto.arg_error` (`crypto.y:20`) on purpose: a pattern is data |
| R8 | **Fixtures**: `test/y/native/t191_regex*.y` + `.expected` (next free number is t191), compiled by both compilers with identical output | `t*.y` asserts stdout and exit status; there is no `e*.y` fixture because nothing here is a *compiler* diagnostic |
| R9 | **Manual**: a `\subsection` in `docs/src/09-builtins.tex`, `\label{sec:builtin-regex}`, every name in a `description` list as `\ic{regex.foo(…)}` | `test_coverage.sh` check 2 requires every `\ic{regex.*(}` in the manual to be **called by a checked test**; a missing one fails the suite |
| R10 | **`test/COVERAGE.md` row** under `## Features` naming the fixtures (check 4) | a manual section with no row fails the suite |
| R11 | **Every exported name and every `check` message is exercised** by a fixture | check 1 only *scans* `runtime error: ` literals and per-file site forms (`test/sh/coverage_diag.awk:154-188`), so `check`'s messages are not sites — but a message no fixture ever sees is a message nobody knows works, and the COVERAGE.md row should say they are all covered |
| R12 | **No new closures** | see the table above. A `[T; N]` record field turned out to be legal, but the sets live in one flat `classes: [byte]` anyway (32 bytes per set, one array for the whole pattern) |
| R13 | **`make check` then `make test`** before it is blessed | `make check` also prints the corpus diff, which must list nothing but intended changes |

---

## The API

### Module level

```y
regex.compile(pattern: str) -> Re?      // none when it does not compile
regex.check(pattern: str) -> str        // "" when it does, else why not
regex.escape(s: str) -> str             // QuoteMeta: "a.b*c" -> "a\.b\*c"
```

`compile` does all the work eagerly (no lazy first-match compile), so its cost is
paid once, up front, and every later match is a straight run over `Re.prog`.
There is no `purge` and no cache: two `compile` calls with the same text are two
objects, and `==` on them is identity like any record.

`check` is the same compiler with its result turned into a message, so a program
that must *handle* a bad pattern reads it:

```y
let why = regex.check(pattern);
if (why != "") { puts("bad pattern: ", why, "\n"); exit(1); };
```

### On a `Re`, through the module

Every call takes the compiled pattern as its first argument, so it reads
`regex.search(re, s)` rather than `re.search(s)`. That is not a stylistic
choice: `x.f(...)` in Y is a **field** of the record `x` (`types.y`'s record
read), and a `Re` cannot carry a method, since a method would have to be a
closure and the C twin's value model has no function value to store one in
(R4, `AGENTS.md` "Y code style"). Module-qualified calls are what the rest of std
does for the same reason (`net.listen_tcp(port, f)`, `http.get(url)`), and they
read the same at the call site.

```y
regex.match(re, s) -> Match?           // anchored at 0
regex.match_at(re, s, at) -> Match?    // anchored at `at`
regex.full(re, s) -> Match?            // the whole subject: \A … \z
regex.search(re, s) -> Match?          // leftmost, anywhere
regex.search_at(re, s, at) -> Match?   // leftmost at or after `at`
regex.is_match(re, s) -> bool          // search(s) != none
regex.find(re, s, limit = -1) -> [Match]      // [] when nothing matches
regex.split(re, s) -> [str]            // cut at every NON-empty match
regex.replace(re, s, rep) -> str       // $0, $1..$9, ${name}, $$
regex.replace_with(re, s, f) -> str    // f: (regex.Match) -> str
```

The same ten, written as they were first proposed (the `re.` spelling the spike
in step 1 of the work plan was meant to confirm — it does not parse, because a
record field is a field):

```y
re.match(s: str) -> Match?              // anchored at 0
re.match_at(s: str, at: long) -> Match? // anchored at `at`
re.full(s: str) -> Match?               // the whole subject: \A … \z
re.search(s: str) -> Match?             // leftmost, anywhere
re.search_at(s: str, at: long) -> Match?// leftmost at or after `at`
re.is_match(s: str) -> bool             // search(s) != none
re.find(s: str, limit: long = -1) -> [Match]   // [] when nothing matches
re.split(s: str) -> [str]               // cut at every NON-empty match
re.replace(s: str, rep: str) -> str     // $0, $1..$9, ${name}, $$
re.replace_with(s: str, f: (regex.Match) -> str) -> str
```

`match` is Python's `re.match` (anchored at the start, not "find anywhere") and
`full` is `re.fullmatch`. `at` out of range (`at < 0` or `at > len(s)`) gives
`none` — no trap, since a caller scanning windows computes the next offset.
`limit <= 0` means every match, the `-1` convention `fs.write_file`'s `mode = -1`
and `y_str_repeat` already use.

`replace` returns `s` itself when nothing matched (no copy, like `y_str_replace`'s
`if (start == 0) { s }` at `str.y:185`).

### On a `Match`

```y
regex.group(m: Match, n: long) -> str?   // none = the group took no part
regex.named(m: Match, name: str) -> str? // looks the name up in m.names
regex.start(m: Match, n: long) -> long   // -1 = the group took no part
regex.end(m: Match, n: long) -> long     // -1 = the group took no part
```

A group that matched nothing is `some("")`; a group that took no part is `none`
and offsets `-1`. The two are never conflated — that distinction is the whole
reason an optional is in the return type.

Group `0` is the whole match in every one of these, so `group(m, 0)` is `m.text`.

### Public fields

Only what a caller has a use for; anything else is private to the module.

```y
re.pattern     // str: the pattern as written
re.groups      // long: capturing groups, not counting the whole match
re.names       // {str => long}: group name -> its number, in pattern order
re.anchored    // bool: starts with ^ or \A, so only position 0 can match
m.text         // str: the whole match
m.start, m.end // long: its byte offsets in the subject
m.subject      // str: the string searched (a reference, not a copy)
m.caps         // [long]: 2 per group, group 0 first; -1,-1 = took no part
m.names        // the Re's own map, shared
```

`m.caps` is public so an offset needs no call: `m.caps[2 * 1]` is group 1's
start. `regex.start(m, n)` is the checked spelling of the same thing.

`re.prog`, `re.classes`, `re.nclass`, `re.first`, `re.literal` and `re.need` are
the engine's own data. They are fields because Y records are exact (a hidden
field does not exist), so the manual says they are there and means it. `need` is
the one that earned its keep: it is a literal every match must contain
*wherever* it is (`required_of`), and one `index_of` over the subject settles the
whole question when the subject does not have it — which is what keeps
`(\w+)@(\w+)` over an 8 MB subject with no `@` in it at 11 ms and 0 bytes
instead of running the machine at every word byte, allocating a capture vector at
each.

### Names

| Name | Why |
|---|---|
| `compile`, `check`, `escape` | plain verbs; `check` is the repo's word for "look and report" (`fs.is_dir`, `x509.system_roots`) |
| `match`, `full`, `search`, `find` | Python's four, which are the ones a reader arrives with; Go's `MatchString`/`FindAllString` are wordier and encode the anchoring in the name |
| `is_match` | a `bool` where the caller only wants a yes; `re.search(s) != none` is the same answer in eight more characters |
| `group`, `named`, `start`, `end` | "named" rather than `group_by_name`: it takes a `str`, not a number, and one word says which |
| `find`, not `find_all` | `find` returns every match, as `fs.remove_all` says what it does without a second word |
| `Match` | one word for "one match"; `Re` because `Regex` is a typo waiting to happen in a namespace called `regex` |

---

## The two types

```y
// One match. Group 0 is the whole match; caps[2n] / caps[2n+1] are a group's
// start and end, -1 for a group that took no part.
type Match = {
    subject: str, text: str, start: long, end: long,
    caps: [long], names: {str => long}
};

// A compiled pattern. prog is 3 longs per instruction; classes is 32 bytes per
// byte set; first is the set a match can begin with (-1 = any byte); literal is
// bytes every match must contain ("" = none) — both are the scan's prefilter.
type Re = {
    pattern: str, prog: [long], classes: [byte], nclass: long,
    first: long, literal: str, anchored: bool,
    groups: long, names: {str => long}
};
```

No `icase`, `dotall` or `multiline` fields: `(?i)` and `(?s)` are folded into the
byte sets while compiling, and `(?m)` picks a different assertion opcode. A
flag field would be a second place the same fact lives.

---

## The pattern language

### Supported

| Syntax | Meaning (bytes) |
|---|---|
| `x` | the byte `x` |
| `.` | any byte but `\n`; with `(?s)`, any byte |
| `[abc]`, `[a-z0-9_]` | a set; ranges are by byte value |
| `[^…]` | its complement over all 256 bytes |
| `[[:alpha:]]`, `[[:^digit:]]` | POSIX classes: alnum alpha ascii blank cntrl digit graph lower print punct space upper word xdigit |
| `\d \D \w \W \s \S` | ASCII: 0-9; letters, digits, `_`; space `\t\n\v\f\r ` |
| `\b \B` | a word boundary (and its negation), ASCII words as `\w` |
| `\n \r \t \f \v \a \0 \xHH \x{H+}` | the byte, or those bytes: `\x{263A}` is UTF-8 encoded at compile time |
| `^ $` | the subject's start/end; with `(?m)`, the line's start/end |
| `\A \z` | the subject's start/end, whatever `(?m)` says |
| `a\|b` | alternation, left to right |
| `( … )`, `(?: … )` | a capturing group, and one that is not |
| `(?<name> … )` | a named capturing group; `(?P<name>` is **not** accepted (one spelling, `m16`) |
| `* + ? {n} {n,} {n,m}` | repetition, greedy; a trailing `?` makes it lazy (`a*?`, `a{2,4}?`) |
| `(?i) (?s) (?m)` | a flag for the rest of the enclosing group |
| `(?is: … )` | a flag for that group only |
| `(?= … ) (?! … )` | lookahead, positive and negative |
| `(?<= … ) (?<! … )` | lookbehind, **fixed width only** |

### Not supported, and why

| Not | Why |
|---|---|
| `\1`, `\k<name>` | a NFA simulation has no single path to compare against; RE2 refuses them for the same reason. A backtracking engine could, and then a bad pattern would hang |
| `(?R)`, `\g<…>` | pattern recursion needs a machine stack; Y's is 8 MB and fixed |
| `\p{…}`, `\P{…}` | Unicode tables, and nothing else in std has one |
| Unicode case folding | `str.upper`/`lower` are ASCII (`str.y:194-209`); `(?i)` matches that |
| `.` over code points | decided: bytes. `.` is one byte, so `.` on `"é"` matches half of it; `(?s)` does not change that, and `[\x00-\xff]` is the whole byte range |
| atomic `(?>…)`, possessive `a*+` | both need backtracking to be meaningful |
| `(?-i)` and friends | turning a flag *off* mid-pattern would have to re-fold an already-emitted set. A compile error names the fix: put the flag on the group it applies to |
| `[[:name:]]` outside a class, `\p` | would need a context-sensitive escape table; inside a class is where they mean anything |

### Two rules worth stating because Python has them

- Inside a class `\b` is `\x08`, not a word boundary (`\x08` spelled out works
  anywhere). Outside a class it is the boundary.
- A `{` that does not open a valid `{n}`, `{n,}` or `{n,m}` is a literal `{`, and
  a `}` with nothing to close is a literal `}`. `a{,3}` is a literal `a`, `,`, `3`.

### Leftmost-first, not leftmost-longest

The engine answers as a backtracking search would: `search("ab")` with `a|ab`
gives `"a"`, and `"a+"` on `"aaa"` gives all three. This is Perl, PCRE and Go —
**not** POSIX `regcomp`, which would give `"ab"`. Greedy and lazy decide only
*within* one path, and `*` on `"aaa"` gives `"aaa"` while `*?` gives `""`.

---

## The engine

### The program

Three longs per instruction: `prog[pc]` is the opcode, `prog[pc+1]` and
`prog[pc+2]` its operands. `pc` advances by 3.

| Op | a | b | Meaning |
|---|---|---|---|
| `CLS` | set | — | consume one byte in `classes[set*32 … set*32+31]` |
| `SPLIT` | pc1 | pc2 | try pc1 first, then pc2 — alternation, `?`, and the greedy/lazy order |
| `JMP` | pc | — | continue at pc |
| `SAVE` | slot | — | record the current position in `caps[slot]` |
| `ASSERT` | kind | — | zero-width: `BOL EOL BOL_ML EOL_ML WORDB NWORDB` |
| `LOOK` | kind | target | zero-width: `LAHEAD NLAHEAD LBEHIND NLBEHIND`, the sub-program ending at `target` |
| `MATCH` | — | — | the match ends here |

Everything consuming is a `CLS`, never a "literal byte" instruction: one byte
set per set of alternatives, so `a|b|c` is one set and one instruction, and
`(?i)` is folded into it while compiling.

`{n,m}` expands at compile time (`x{2,5}` → `xx(x(x)?)?`) so the VM needs no
per-thread counters — the same choice RE2 makes. A lookahead's sub-program is
compiled as its own little program ending in its own `MATCH`; the `LOOK`
instruction runs it in a nested simulation whose recursion depth is the
lookahead nesting depth.

### The step

A thread list is an array of pcs; every thread in a list is at the same input
position. Per input byte:

1. for each thread in order: a `CLS` that takes this byte walks its zero-width
   closure into the next list, and a `MATCH` records the capture vector. The walk
   is **depth-first**, pushing pc2 before pc1 so pc1 is popped first, and it
   stops at a `MATCH` — everything behind one is lower priority and can never win
2. the closure dedupes by pc with a generation stamp (`seen[pc] == gen`), which is
   what keeps a run O(n·m) instead of exponential. The generation moves on once per
   step **and once per run**: a run whose first closure finds nothing never steps,
   and a stamp that did not move would leave the next start position finding every
   pc already visited — `\b\w+` against `"  hi"` would fail at 0 and 1, never step,
   and so never try 2, where it matches
3. swap the two list buffers (never alias them — see the build notes)

A `MATCH` found mid-run is a **fallback**: the threads already queued outrank it,
so the run keeps stepping them and a later match from one of them replaces it.
That is what makes a greedy `x+` take the longer run, and stopping at the first
match instead would break it.

Leftmost comes from the outer loop: `search` runs the anchored match at each start
position from `at` and takes the first that hits. Priority inside one position
comes from list order, which is the order the threads were added, which is the
order the pattern wrote them.

### Captures

Each path in a walk carries its own capture vector and a `SAVE` **always**
clones — copy-on-write was tried and dropped: sharing one vector between sibling
paths leaks a failed branch's captures into a sibling that skipped the group
(`(a)|(b)` against `"b"` reporting group 1 as matched-and-empty), and the
copy-on-write bookkeeping to avoid that costs more than the copy does. The
vectors come off a **pool** instead: a vector a step's threads were the last
holders of (one thread held it, no queued thread took it — both counted by
address) goes back, which is what keeps a scan with groups inside the memory cap.
A pattern with **no** groups never reaches a `SAVE` at all and so never allocates
one.

The one honest caveat: a clone is O(g) for g groups, so a pattern with many
groups can still cost O(g²) per step. It cannot blow up exponentially, and the
subject length never enters any recursion depth.

### Prefilters

Two fields keep the common cases cheap without a second engine:

- `anchored` — a pattern starting with `^` or `\A` (and not `(?m)`) can only match
  at 0, so `search` skips the per-start loop entirely.
- `first` — the set a match can begin with, computed at compile time by walking
  past zero-width assertions. When it is a **single byte**, `search` uses
  `index_of(s, chr(c))` to jump from one candidate to the next, so `\d+` over a
  10 MB log touches the bytes it must and not the ones between.
- `literal` — a fixed byte string every match must **begin** with (a leading run
  of single-byte sets). `search` uses `index_of` on it and tries the VM only at the
  hits. `compile("nginx/1.2")` is a single `index_of` and no VM.
- `need` — a fixed byte string every match must contain **wherever** it is (the
  first mandatory single byte reachable through groups and `{n,}` repetitions,
  not into an alternation). One scan of the subject answers the whole question,
  and it is what stops a pattern that cannot match from running the machine at
  every position: `(\w+)@(\w+)` over 8 MB with no `@` in it is 11 ms and no
  allocation, where `first` alone would run at every word byte and, having groups,
  allocate a capture vector at each.

All four are computed once, at compile time, and are `""` / `-1` / `false` when
they do not apply — never a wrong answer, only a missed optimisation.

Both are computed once, at compile time, and are `""` / `-1` when they do not
apply — never a wrong answer, only a missed optimisation.

### Limits, each with a message

| Limit | Value | Why there is one |
|---|---|---|
| repetition count | 1000 | `{n,m}` expands; `a{1000}{1000}` must not become a million instructions |
| program size after expansion | 4096 instructions | same reason, from the other side |
| capture groups | 200 | the caps vector is per thread |
| lookarounds per pattern | 32 | it bounds the nesting of the only run-time recursion, and a total can be refused while compiling — where the answer is a message rather than a wrong match |
| `\x{…}` value | `0x10FFFF` | beyond it there is no UTF-8 encoding |

### Complexity

Per match attempt: O(n·m) in the subject and the program. `search` over a subject
that does not match: O(n²·m) worst case with a non-trivial pattern — the same
bound RE2 has, and the reason the two prefilters above matter. No exponential
case exists, and nothing recurses on the machine stack in proportion to the
subject.

---

## Semantics that have to be pinned down

These are the places where "what does regex do" has more than one honest answer.
Each is a decision, not an accident.

| Case | Decision | Why |
|---|---|---|
| an empty match in `find` | yielded, but an empty match **abutting the previous match's end is skipped**, and the scan then advances one byte | Go's `allMatches` rule. `find("a*", "baab")` gives `""`, `"aa"`, `""` — the empty match at 3 abuts `"aa"`'s end and is skipped, and the one at 4 is a new one. CPython 3.7+ instead yields `""`, `"aa"`, `""`, `""` with `""` at 1 as well; the two rules differ and this one is Go's because it is the simpler rule to state |
| an empty match in `split` | splits nothing; only a match of width > 0 cuts | a pattern like `a*` would otherwise cut a string into one piece per byte, and `split` exists to be `str.split` with a pattern in place of a separator |
| an empty match in `replace` | replaces nothing (the text is copied through) | same reason |
| captures in `split`'s output | **not** included | Python's `re.split` does include them, and they surprise everyone once; a `find` loop is two lines |
| `at` out of range in `match_at`/`search_at` | `none` | a caller scanning windows computes the next offset, and a trap there would be a bad trade |
| a group number past `re.groups` | **traps** (the runtime's index trap, exit 1) | it is a caller bug, and `struct`'s readers set the precedent: slice first for untrusted input |
| an unknown group name | `none` | it is a map read (`m["k"]`), and `none` is what a map read gives |
| `$5` in a template, 2-group pattern | the `$5` stays **literal text** | nothing is silently dropped; a typo is visible in the output |
| `escape` output | every byte outside `[A-Za-z0-9_]` gets a backslash, `_` included | `_` needs no escape in any position; being conservative costs nothing |
| `full` with `(?m)` | still `\A` … `\z` | `full` means the whole subject, whatever the anchors mean elsewhere in the same pattern |

---

## Diagnostics

`check` returns these; `compile` returns `none` for any of them. None of them
prints (R7), so `test/sh/coverage_diag.awk` does not see them as sites — but each
one gets a line in a fixture, because a message nobody has seen is a message
nobody knows works (R11). Byte offsets are into the pattern, 0-based, and every
message ends with the offset so a program can point at the offending byte.

| Message | Fixture line (`t191_regex.y`) |
|---|---|
| `unterminated character class at byte 2` | `[a` |
| `unterminated group at byte 3` | `(ab` |
| `unbalanced ) at byte 2` | `ab)` |
| `nothing to repeat at byte 0` | `*a` |
| `two repetitions in a row at byte 2` | `a**` |
| `a repetition cannot be possessive at byte 3` | `a*+` |
| `pattern ends with a backslash at byte 1` | `a\` |
| `unknown escape \q at byte 2` | `a\q` |
| `unknown escape \Z at byte 4` | `abc\Z` (ours spells it `\z`) |
| `a backreference is not supported at byte 4` | `(a)\1` |
| `bad repetition count at byte 4` | `a{2,x}` |
| `a repetition count is out of order at byte 6` | `a{5,2}` |
| `a repetition count must be at most 1000 at byte 9` | `a{1,2000}` |
| `the pattern needs more than 4096 instructions` | `a{1000}` five times |
| `more than 200 capture groups` | 201 `(` |
| `more than 32 lookarounds in one pattern` | 33 `(?=` |
| `pattern nested more than 200 deep at byte 603` | 201 `(?:` |
| `lookbehind must be a fixed width at byte 9` | `(?<=a+)b`, `(?<=a\|ab)c` |
| `a group cannot be inside a lookaround at byte 7` | `(?=(a))a` |
| `a range needs two bytes` | `[\d-x]` |
| `a range is out of order` | `[z-a]` |
| `unknown class [:foo:] at byte 1` | `[[:foo:]]` |
| `a group name must start with a letter or _ at byte 3` | `(?<1n>a)` |
| `a group name must end with > at byte 4` | `(?<n x)` |
| `duplicate group name 'n' at byte 9` | `(?<n>a)(?<n>b)` |
| `a flag cannot be turned off at byte 6` | `(?i)(?-i:a)` |
| `unknown flag 'q' at byte 2` | `(?q)a` |
| `unknown (? construct at byte 0` | `(?P<n>a)` (ours spells it `(?<n>`) |
| `a \x needs two hex digits at byte 2` | `\xZZ` |
| `a \x{} needs at least one hex digit at byte 3` | `\x{ d}` |
| `a \x{ is not closed at byte 5` | `\x{41` |
| `a \x{} value must be at most 0x10ffff at byte 4` | `\x{110000}` |
| `a \x{} value must not be a surrogate at byte 5` | `\x{d800}` |

Thirty-two, one line each in `t191_regex.y`, all produced by the blessed
compiler. Two things the table did not predict and the build changed: a **total**
lookaround count rather than a nesting depth (a lookaround's walk nests inside the
walk around it, so a total of 32 bounds the nesting too — and refusing it at
compile time means the answer is a message, where refusing it at match time would
mean a wrong match), and a **bare digit is a literal byte** (PCRE's rule), so
`a{,3}` is those four bytes and only `\1`..`\9` is a backreference.

---

## What changed in the tree

| File | What it is |
|---|---|
| `src/y/std/regex.y` | the module: ~2040 lines --- the parser/compiler, the VM, the API, `export { … }` at the end (`fs.y:291`) |
| `test/y/native/t191_regex.y` + `.expected` | the dialect end to end, every diagnostic, all five limits, every exported name (R9, R11) |
| `test/y/native/t192_regex_groups.y` + `.expected` | groups: numbering, names, `none` vs `some("")`, offsets, nesting, templates, `replace_with` |
| `test/y/native/t193_regex_sweep.y` + `.expected` | `find`/`split`/`replace`/`replace_with` with the empty-match and adjacency rules pinned |
| `test/y/native/t194_regex_group_trap.y` + `.expected` + `.exit` | a group number past the last one traps (the `struct` precedent, made a fixture) |
| `test/y/native/t195_regex_corpus.y` + `.expected` | 178 cases against Python's `re` over the same bytes, generated by `ideas/regex/gen.py`; where Python is not the reference, our answer is pinned in its `PINNED` table |
| `test/y/native/e168_regex_no_import.y` | without `import regex;` there is no `compile`, and `re.is_match(s)` is a field (mirrors `e143_fs_module.y`) |
| `docs/src/09-builtins.tex` | the `\subsection{Patterns (the regex module)}` + `\label{sec:builtin-regex}`, before `\subsection{Pointers}` |
| `test/COVERAGE.md` | the row, under Features |
| `src/y/NATIVE.md` | a paragraph in §"Optional std modules", with the measured speeds |
| `AGENTS.md` | the `src/y/` layout list gains `regex.y` |
| `test/sh/test_fixpoint.sh` | `import regex;` joins the std-module import list |
| `ideas/regex/` | the corpus's provenance: `gen.py` (the generator), `pdiff.py` (the per-case diff), `run.sh` (the check) |
| `src/c/` | **nothing** |
| the compiler | **nothing** |

The six fixtures are ordinary ones: `test_native.sh` runs them and `test_port.sh`
compiles them with both compilers. `ideas/regex/run.sh` adds the corpus's other
half --- that the committed expected output still says what Python's `re` says
about the same bytes --- which needs Python, so it is not a suite.

Nothing here changes a compiler diagnostic, so `test_coverage.sh` check 1 has
nothing new to match, and the compiler is untouched: `regex.y` is not one of the
four units in the std pack (`std_unit_names()`), so `make ycc` still produces the
blessed bytes exactly. Measured on top of `HEAD`: `make check` gives every
instruction count `+0.00%` and a SCORE of 99.75 (100 ± 2.5 is no change), and all
sixteen suites pass.

---

## Work plan (every step done)

0. **Done, with one correction.** A module-qualified alias works in a function
   type, in a lambda's parameter, and as a record field in program code
   (`def take(f: (Match) -> str, re: Re) -> str` and `let h: m1.Holder = { r: re, tag: "t" }` both compile), so the API is as proposed there — but **`re.match(s)` does not**: `x.f(...)` is a field read, and a `Re` cannot carry a method without a closure. Every call is `regex.match(re, s)`.
   `[byte; 32]` as a record field also turns out to be **legal** (the table
   below said no record field in the tree is one; that was a fact about the tree,
   not the language). The design avoids it anyway — one flat `classes: [byte]` is
   better for locality and needs no second type.
1. ~~**Spike the two unknowns** before anything else~~ — folded into 0.
2. **The compiler**: parse → validate → emit, returning the message. No VM yet:
   `compile`, `check`, `escape` and the `Re` fields, tested through
   `t191`'s first half and every diagnostic in the table above.
3. **The VM**: `CLS SPLIT JMP SAVE ASSERT MATCH`, anchored matching, `match`,
   `full`, `is_match`. No groups yet (so no captures: the caps-free path is the
   first thing that works, and it is the common case).
4. **`search`** with the `anchored` and `first` prefilters.
5. **`SAVE` and capture vectors**, copy-on-write; `group`, `named`, `start`,
   `end`; `t192`.
6. **`find`**, then `split`, `replace`, `replace_with`; `t193`.
7. **Lookahead and lookbehind** (the only run-time recursion — last, because it
   is the only part that can be wrong in a way the earlier steps cannot show).
8. The manual section, the COVERAGE.md row, the NATIVE.md paragraph with
   **measured** speeds (`\d+` and a literal over a 10 MB string, a
   backtracking-hostile pattern like `(a*)*b` — the point of the Pike VM is that
   the last one is linear, and the number is worth having in the commit message).
9. `make check` (every listed change intended; the corpus diff empty), then
   `make test`. **Done.** The gate needed one thing said plainly, because the
   tree was carrying someone else's unported `src/y/native.y` edit: it makes
   `make ycc` fail on its own (the C copy compiles `src/y` from disk, so an
   edit there moves the compiler's bytes and `cmp ycc refs/ycc.ref` fails at
   byte 25). Run on `HEAD` plus this change alone, `make check` and `make test`
   are both green; the two facts were established by building `HEAD` with and
   without that edit, in a scratch tree.

## What the build taught

None of this was visible from the design; all of it is in the code or in
`ideas/regex/README.md`.

**The engine.** The Pike VM is small; getting the *priority* right is not. Three
bugs, each of which a plausible reading gets wrong:

- The closure walk must be **depth**-first. Breadth-first reaches a split's
  second branch before the first branch's item, so `x*` records its empty match
  and stops before trying `x`, and a loop holding a group never queues its body.
- A match recorded mid-run is a **fallback**, not the answer: the threads already
  queued outrank it, so one of them matching later replaces it — that is what
  makes a greedy `x+` take the longer run. Stopping at the first match is wrong
  for greediness; never replacing it is wrong for laziness. Both showed up as
  `a{2,3}?` matching three when it should match two.
- Every path in a walk needs its **own** capture vector, and a `SAVE` always
  clones. A shared one leaks a failed branch's captures into a sibling that
  skipped the group: `(a)|(b)` against `"b"` reports group 1 as matched-and-empty
  instead of as never having taken part.
- The lists must **swap, not alias**. Holding `cur` and `nxt` in one array and
  writing `nxt[i]` while reading `cur[j]` has them overwrite each other
  mid-step. The symptom is quiet and wrong: `(\S+)@` against `"root@x"` reported
  group 1 as `"root@"`, one byte too long, because a queued thread's vector had
  been overwritten under a thread that had not been stepped yet. Nothing in the
  164-case corpus caught it; the case that did is a greedy loop whose own
  character class overlaps what follows it, which is why those are in the corpus
  now.

**A Y-level thing worth knowing**, found the hard way and recorded rather than
claimed as understood: a record-field mutation and a `d + 1` threaded through
three calls both failed to reach a *nested* call in this module, with the blessed
compiler, while `p.pos`, `p.groups` and `p.names` behaved and the same statement
inside a one-line helper worked. The write was visible in the writing frame and in
the record's own `tostring`, but the callee read the old value. The module avoids
the pattern (the lookaround count comes off the parse tree, not the parse state);
it is reproducible in `src/y/std/regex.y` and I could not minimize it further.

**Memory.** No free, so every allocation is for the life of the process. The first
working version took 3.5 GB on an 8 MB subject — over the cap. Three changes
brought the worst case (a two-group `replace` over the whole subject) to 64 MB:

- the thread lists are two **persistent** arrays with a live count, not fresh
  arrays per step and records per thread (16 million thread records over 8 MB);
- the capture vectors come off a **pool**, recycled when a step's threads were
  their last holders (counted by address — a vector is only freed when one thread
  held it and no queued thread took it);
- `need` stops the scan before it starts for a pattern that cannot match.

`\d+` over 8 MB is 321 ms and 274 MB, and that is 1.1 M `Match` values — each a
`caps` array, a `text` copy and a record — which is what returning every match
costs here. The two backtracking-hostile patterns answer 64 KB in under a
millisecond, which is the reason for choosing this engine at all.

## Risks

| Risk | What happens if it is real |
|---|---|
| ~~a module-qualified alias in a **function type** does not parse~~ | **retired**: it parses (step 0), as does a lambda parameter and a record field. What does not parse is the *method* spelling `re.search(s)`, which is a field read |
| ~~`[byte; 32]` as a **record field** is rejected~~ | **retired**: it is legal, and the design avoids it for locality, not necessity |
| ~~no free, and `find` over a large file clones a lot~~ | **retired, measured**: a group-free `\d+` `find` allocates its results and nothing else (321 ms / 274 MB for 1.1 M matches over 8 MB); with groups the worst case measured is a two-group `replace` at 1.29 s / 64 MB |
| the corpus diff shows `t191`+ changing anything but itself | stop; an imported module must not shift another program's bytes |
| `import regex;` is compiled by `cycc` too (the port gate) | pure Y with no undefined behaviour, so the bytes agree — but the *warnings* must agree too (R6), so no unused local slips in |

## Open questions

None blocking. These are the calls I made that a different reader might make
differently, listed so they are easy to overrule:

- `replace_with` takes the caller's own function, `(regex.Match) -> str`. The
  alternative is a callback taking `(subject, start, end, caps)` — uglier at the
  call site, and it would put the caller's own lambda behind four arguments. It is
  a function *argument*, never a closure the module builds (there is nowhere in a
  `Match` to put one).
- `Match.text` is a **field**, so every match costs one string copy. The
  alternative is `regex.text(m)` everywhere; `m.text` is what callers want and
  the copy is bounded by the match's own length.
- `find`'s limit is a default parameter (`limit: long = -1`), not a second
  function. Two spellings of one thing is what `m16` argues against.
- A pattern that matches empty **splits nothing**, where Python's `re.split`
  splits at every position. The empty-match cases in `t193` pin this down, so
  changing it later is a one-line fixture edit.
- `replace` replaces nothing for an empty match, where Python's `re.sub` inserts
  at every one. `replace_with` is the way to insert between matches, and the
  empty-match cases in `t193` pin this down too.
- Where an NFA and a backtracker differ and we are the NFA, the difference is
  documented rather than papered over: the captures of a loop whose last
  iteration took no bytes are the last one that did (`(a*)*` against `"aa"`
  reports group 1 as `"aa"`, where PCRE reports it empty), and `(|a)*` against
  `"aa"` matches `"aa"` rather than the empty string. Both are in the corpus's
  pinned table with the reason.