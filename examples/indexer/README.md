# indexer — a file indexer over `fs`

Walk a directory tree, build an index of what is in it, then query that
index: by extension, largest first, by substring, with a per-extension
summary. Plain text to a pipe, colour on a terminal.

```
$ ./indexer --no-tty --head 40 data/tree
indexer    1.0
root       data/tree
entries    9 dirs, 18 files, 992 bytes, 0 symlinks, 0 unreadable, 0 capped
hash       fnv1a-64
order      path: case-folded, raw bytes break ties
symlinks   not followed
view       head 40 cols, strict off

ext           files  bytes      largest   path
(none)              2         65        55  Makefile
bin                 1          7         7  blob.bin
c                   2        323       283  src/main.c
gz                  1         43        43  ARCHIVE.TAR.GZ
h                   1         60        60  src/util.h
log                 1          0         0  empty.log
md                  5        367       178  README.md
txt                 3         60        29  src/deep/a/b/c/leaf.txt
y                   2         67        40  tests/test_a.y
extensions  9 of 9

size  hash                ext    path  first line
    100x52bedc6b30a20725  (none) .gitignore  *.tmp
    430x3580c346bb83500c  gz     ARCHIVE.TAR.GZ  not really gzip, but the name has two do
     70xad2ecdb41ed2117a  bin    blob.bin  [no newline] <binary>
    570x5a8a749a1e338f5a  md     café menu.md  non-ASCII bytes in the name, and an uppe
    180x42cd2013af8b4d3  md     docs/api.md  # api
    730x6ea54ee55dc33d8b  md     docs/guide.md  # guide
     00xcbf29ce484222325  log    empty.log  <empty>
    550x79915cac24697ca5  (none) Makefile  all:
    410x9addffc44c5165a3  md     notes/no-eol.md  [no newline] this text file's only line has no newlin
    200xa79a2ca264935969  txt    odd name.txt  a space in the name
    178x0deea72249afb949  md     README.md  # widget
    290xcf1ea6e049cebe4b  txt    src/deep/a/b/c/leaf.txt  the deepest file, at depth 5
    110x5866d39aa3b0b0e2  txt    src/deep/a/mid.txt  at depth 3
    283x11ee9e60db544c79  c      src/main.c  /* the largest file in the tree, so --la
    400x21c568a73b4612ce  c      src/util.c  int add(int a, int b) { return a + b; }
    600xde7ffff0dd90c954  h      src/util.h  #ifndef UTIL_H
    400xd079d9c44fe89cb6  y      tests/test_a.y  def main() -> long { 0 };
    270x1064f90e9b9efd0d  y      tests/test_b.y  def helper() -> long { 1 }
18 files
```

## Build

```
cd examples/indexer
../../refs/ycc.ref indexer.y -o indexer
```

Nothing else. All four `.y` files compile standalone and with zero warnings.

**Compiler pin.** `refs/ycc.ref`, sha256
`5eba0d66059520a9d28f5cdae57fd99835bb6ae62110bf4d2a794ae5fced484b`.

The pin moved during this example's build, from
`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7` to the
above. `EXPECTED` reproduced byte for byte under both, and every number in
this README was re-measured under the new one. The hex16 and FNV vectors in
`selftest.y` are the reason a compiler change is *unlikely* to move the
golden: the hashes are specified against published constants, not against
this program's own arithmetic.

## Run

```
./indexer                        # the report, colour if stdout is a terminal
./indexer --no-tty --head 40 data/tree     # THE GOLDEN RUN (gate.conf run=)
./indexer --check                # the property check, 186 assertions
./indexer --largest 5 data/tree            # the five biggest
./indexer --ext md data/tree               # one extension
./indexer --find src/ data/tree            # paths containing a substring
./indexer --follow-symlinks --strict data/tree
./indexer --bench 5 data/tree              # throughput and arena (reads the clock)
./pty_check.py                   # 52 assertions: the pty path and every exit code
./inject.py                      # 40 injected defects, and whether --check notices
python3 gen_tree.py              # regenerate data/tree
```

`--help` lists every flag. Exit codes: **0** indexed, **1** usage error,
**2** bad root, **3** `--strict` and something was unreadable or capped.

## What to look at

1. **`ix.y`'s header comment on `cmp_path`.** There is no `sort` in Y, so
   the order is hand-written, and the interesting property is not "it sorts"
   — it is that the order is a **strict total order**. Three stages, and the
   third exists only to break case ties, because a comparator that
   case-folds and then returns 0 when the shared prefix runs out treats `B`
   and `a` as equal and leaves their order to the sort. For merge sort that
   is *deterministic and wrong*: two files can swap places between one walk
   and the next and the golden will faithfully record the swap.

2. **`S1` in `selftest.y`.** Antisymmetry, irreflexivity and **strictness**
   over all 26 × 25 ordered pairs of a hand-picked name list, transitivity
   over all 26³ triples, then the specific pairs with their signs, then 25
   shuffles and a reversal that must all give the identical order. Six of
   those 26 names exist to pin down where case-folding stops mattering: `` `a ``
   and `A~` sort either side of the punctuation depending on which way the
   fold went, so a `lower_byte` that folded *upwards* would produce a
   different order — and `inject.py`'s `lowerfoldswrong` is caught by exactly
   those two.

3. **`ix.read_dirs`, and why it is not `fs.list_dir`.** `fs.list_dir`
   allocates a 32 KiB `getdents` buffer **per call**, and the heap is an
   arena, so a 201-directory tree costs 6.3 MB of arena that is never freed.
   `read_dirs` uses one module-level buffer. Measured in "Allocation" below.
   This is filed as `examples/SUGGESTIONS.md` #22.

4. **`S9`, and the defect this example shipped.** The report builder appends
   to one `str` in a loop. Written as

   ```y
   if (WANT_HASH) { out += "0x" + hex16(e.hash) + "  " } else { out += "  " };
   ```

   the `;` sits **after** the arm's closing brace, which makes the append
   value-used, which drops it out of the in-place amortised append, which
   makes the whole loop **O(n²) in arena with byte-identical output**. The
   first draft of this example shipped exactly that. See "The quadratic" below.

5. **`S6` and `pty_check.py`.** Every hostile input is a message and a
   non-zero exit, and that is asserted twice: once by forking a child inside
   `--check` and reading its exit status and its log, and once by running the
   shipped binary from Python and reading its exit status and its stderr.

6. **`inject.py`.** 40 single-token defects, one at a time, each applied to a
   copy in a scratch directory. 37 are caught, 0 are missed, and 3 are
   *provably* no-ops and are shipped as such with the proof in the defect's
   own description.

## No toolkit is vendored

`test/std/` holds `fx.y tui tui args tui. **This folder
vendors none of them, and that is deliberate, not an omission.**

- `tui` — indexer does not own a terminal in the raw-mode sense; it takes
  the frame pacer and nothing else.
  It prints lines and exits; there is no mode to set, nothing to restore, and
  no signal path. The only terminal question it has is "is stdout a tty",
  which is one `ioctl(TCGETS)` (see below).
- `tui` — nothing here is interactive, so there is no frame deadline to
  own. `--bench` reads `clock_us()` directly, twice, and is behind a flag
  precisely so the clock cannot reach `EXPECTED`.
- `fx.y` — no trigonometry and no square roots. `head_of` truncates a string;
  nothing needs a fixed-point divide.
- `args` — seven flags and a positional root, all hand-parsed in `cli.y`.

So the folder is `ix.y cli.y selftest.y indexer.y` plus two Python drivers
and a generated `data/tree`. Nothing is imported across folders at run time,
which is what gate item 5 checks by building with no sibling present.

## The four traps this example walks into, and what it does about them

**`def main()` is not called for you.** It is an ordinary function. A file
ending in a `def main()` the runtime never invokes compiles clean, runs,
exits 0 and **prints nothing** — which looks exactly like success. The last
line of `indexer.y` is `exit(main())`, and `main`'s header says why: `main();`
would exit 0 even when main "returned" 1, turning every error path in main
into a success to any caller.

**Runtime traps print to stdout.** Every filesystem refusal — ENOENT,
ENOTDIR, EACCES, ELOOP, ENAMETOOLONG, a dangling symlink, a FIFO — becomes a
count, a diagnostic, or a non-zero return. `ix.walk` returns 2 for "no such
path" and 3 for "not a directory" and 0 for everything else, and a code
outside that set is *reported as itself* rather than swallowed by an `else`.
The seven hostile inputs the brief names are all covered in `S6`:

| input | what happens | asserted by |
|---|---|---|
| nonexistent path | exit 2, "no such path" | S6 forked child + `pty_check.py` |
| a file, not a directory | exit 2, "not a directory" | both |
| permission-denied subdirectory | warned, counted, exit 0; **exit 3** under `--strict` | both |
| symlink loop | cycle detected by `(dev,ino)`, walk terminates | both (`--follow-symlinks`) |
| empty directory | 0 files, no error, exit 0 | S6 |
| binary file, no trailing newline | `<binary>` + a `[no newline]` flag, exit 0 | S4 |
| spaces and non-ASCII in a name | indexed byte-for-byte, exit 0 | S4, and the golden's `café menu.md` |

**Maps are a linear scan.** `ix.y` has two open-addressed tables: extension
→ bucket (4096 slots) and visited `(dev,ino)` (65 536 slots), both FNV-1a
with linear probing and a probe counter kept as a first-class number. `S2`
asserts that every inserted key is findable, that absent keys are not, that
**a saturated table reports instead of spinning**, and that the mean probe
count is under 3 at 15 % load — a broken hash that always returned slot 0
would read 300 there.

The visited set is keyed on `(dev, ino)` rather than on the path, which is
the point: `/a/link → /a` is two names for one inode, so a path-keyed set
walks straight into the loop.

**No `sort`.** Hand-rolled bottom-up merge sort over two preallocated
scratch arrays, so **a sort allocates nothing per pass** — a recursive merge
sort cannot say that, because every `xs[0:mid]` is a fresh slice in an arena
that never frees.

## The comparator is a first-class value

The wave-2 briefing said "there is also no way to pass a comparison as a
value, so plan how you dispatch a comparator before you need it". **That is
not true on the pinned compiler**, and the whole sort is built on the truth
instead: `ORCHESTRATOR.md` §2.15 records that a `def` is a value typed
`(parameter type) -> return type`. Verified here:

```y
type Cmp = (str, str) -> long;
let CMPS: [Cmp] = [cmp_path, cmp_bytes];        // an array of comparators
let names = sort_str(NAMES, CMPS[0]);            // dispatched as a value
```

What is still missing is **generics**, so a comparator over records cannot
have the same type as one over strings. `ix.ent_cmp` and `ix.bkt_cmp` are
therefore `(long, long) -> long` over *indices*, with the ordering chosen by
a module-level `SORT_KEY`. Two consequences worth knowing:

- `ix.order_paths()` and `ix.order_buckets()` are the **only** places an
  ordering is chosen, and both `listing()` and `selftest.y` go through them.
  A check that re-derived the selection would be testing its own copy of it.
- There is an exported comparator nobody was using: `cmp_bytes` is the raw
  byte order, handed out as `CMPS[1]`. An injected defect in it passed every
  check until `S1` gave it the same total-order treatment — which is the
  honest limit of a suite that only tests what it happens to call.

## The property check: 186 assertions, no reference file

`./indexer --check` reads no golden and compares against no reference.
Nothing in `selftest.y` can see `EXPECTED`. Its actual output is in
`golden/check.txt`; the tally is:

```
indexer --check: 186 ok, 0 failed, 0 skipped
```

| section | what it owns |
|---|---|
| **S1** | `cmp_path` and `cmp_bytes` are strict total orders; the specific case and prefix pairs with their signs; `ext_of`'s rules as a literal table; the order is the same from 25 shuffles and from the reversal |
| **S2** | the two hash tables: insert/find, absent keys, saturation reports, mean probes, `(dev,ino)` identity |
| **S3** | FNV-1a-64 and `hex16` against **published vectors**, negatives included |
| **S4** | the walk against a tree built from a spec written in the check: file count, directory count, byte total, the **hand-written sorted path list**, the per-extension table, the queries, binary/no-newline/empty, a non-ASCII name |
| **S5** | idempotence, order-independence of the sort, and change detection |
| **S6** | every hostile input, each through a real forked process |
| **S7** | the parser's rejections, and the **rendered** report's shape |
| **S8** | the check's own honesty: that its own literals are non-empty and conserve |
| **S9** | that the report's accumulator is still amortised |

`./indexer --only N` runs one section, which is how the forked hostile cases
get a child that asserts a process exit status without running the whole
battery.

### The counts come from outside the code under test

The recurring failure this campaign keeps hitting is the **vacuous pass** —
comparing two values that are both *absent*. Three rules are enforced
mechanically here, not by good intentions:

1. **Every expected count is a literal, or is summed from `SPEC_PATHS` /
   `SPEC_BODIES`**, which are the tree's *construction*, written by hand in
   `selftest.y`. Nothing is read back out of the indexer. `S4` asserts the
   file count against **both** the literal `11` and `len(SPEC_PATHS)`, and
   the byte total against **both** `115` and `sum(SPEC_BODIES)`.
2. **Every "found N" assertion is preceded by one that N > 0.** `S4` opens
   with "the indexer found something" before it compares anything, and `S9`
   refuses to compute a ratio out of a measurement it has not first shown to
   be non-zero.
3. **Every message assertion requires the message to be non-empty first.**
   `eqs()` has a branch for "equal but empty" that reports it as *a vacuous
   comparison, not a match* — so two absent messages cannot pass. That branch
   earned its keep immediately: `inject.py`'s `emptymessage` defect keeps the
   exit code and drops the text, and the check says so by name.

The **sorted path list** is checked against a list written out by hand, one
name per line, in the order `cmp_path`'s rules say it must come out. Because a
hand-written list can itself be wrong, the check *also* runs an insertion
sort (a different algorithm from `ix.sort_idx`'s bottom-up merge) over the
same set and requires the two to agree — so a miscount in the hand list shows
up as a disagreement between two independent statements rather than as a
silent pass. **Both of them were wrong on the first attempt** (four positions
in the hand list, and 115 bytes rather than 113 in the total), which is
precisely why the cross-check exists.

### Injection

`./inject.py` breaks the engine on purpose, one defect at a time, in a
scratch copy. It checks the unmutated `--check` passes first, so "caught"
means something.

```
40 defects: 37 caught, 0 missed, 3 provably equivalent, 0 harness errors
```

**The 3 proven equivalents** are shipped as `equivalent*` and are argued, not
dropped:

- **`equivalentreclen`** — drops half of `read_dirs`' record guard. The guard
  can only fire for a record the kernel did not write: `getdents64` always
  reports `d_reclen >= 19` for a record it emits (19 is the size of the fixed
  part), so the *other* half is the one that can fire on a short final read.
- **`equivalentarithshift`** — `hex16` uses the arithmetic `>>` instead of the
  logical `>>>`. The loop runs exactly 16 times and masks with `& 15` each
  pass, so pass *k* reads bits 4*k*..4*k*+3, all at or below bit 63; the two
  shifts differ only in bits *above* the sign bit, which are never masked in.
  This is the one place `>>>` **looks** load-bearing and is not, which is worth
  having proven rather than argued — and my first attempt at proving it was a
  probe that got the argument order wrong and appeared to show a difference.
- **`equivalentwarnrefactor`** — `warn_once` scans without its early exit.
  `WARNED` is only ever appended to, so a full scan finds the same answer.

**Two of the 37 caught are not "a check said no".** `probeunbounded` and
`mergelosesrun` make `--check` *not finish at all* within 120 s, which the
harness reports as CAUGHT with that wording — a saturated hash table that
never laps, and a merge whose run cursor never advances. Both are worse than
a wrong answer.

### Five defects this example found in itself

Injection is not the only source. Four of these were found by the harness and
one by measurement, and **all five are fixed, not just noted**:

1. **A quadratic report (found by measurement, pre-gate).** 462 MB of arena to
   print an 18-row report over 2 000 files, growing linearly *per file*. See
   "The quadratic" below.
2. **`is_tty()` was dead.** It read `syscall(16, 1)` — no `TCGETS` request and
   no `struct termios` buffer — which returns `-ENOTTY` on a pipe **and on a
   real terminal**. So automatic colour detection never worked; only an
   explicit `--color` turned colour on, and nothing in `--check` could see it
   because `--no-tty` is the golden. `pty_check.py` found it by stripping the
   SGR sequences off a real pty capture and finding none. Fixed to
   `syscall(16, 1, 21505, &TTYBUF[0])`.
3. **`ext_of` was exported and wrong for a path.** It took a *base name*, so
   a caller passing `"dir.d/file"` got the extension `d/file`. Found by `S1`'s
   new rule table. Fixed by taking the base name inside `ext_of`.
4. **`cli.parse` was order-dependent.** It did not reset the option state, so
   the result of one call depended on the previous one. Found because
   `inject.py`'s `tworootsok` defect **passed**: a leftover `--largest 0` from
   an earlier case was supplying the non-zero exit code the check was looking
   for. Fixing the order-dependence then exposed a real gap underneath it —
   `--bench abc` was silently accepted, because `--bench` took any value and
   fell back to one round. Both fixed.
5. **`--only N` was unreachable.** `cli.parse` rejected it before
   `selftest.run` could read it. Fixed: it is a first-class flag now.
6. **The check's own summary line could not add two numbers.** `S8` read
   `N_OK + tostring(N_BAD)`, and `long + str` **coerces and concatenates**
   rather than refusing, so it printed `1720` instead of `172` — silently,
   because the line was only a detail string. Fixed, and the sum now goes
   into a `let` first. Worth knowing generally: this language has no cast
   syntax and `+` will not stop you concatenating a number onto a string.

## The quadratic, in full

`ORCHESTRATOR.md` §2.10 both warn that `str +=` as the last
statement of a braced block is quadratic in heap, and that the `;` has to go
**inside** the braces. **This example shipped that bug**, in the report
builder, and the output was byte-identical while the arena went from 2.9 MB
to 462 MB.

How it was found: not by the `-S` audit. The audit counts `call y_str_app`
(the in-place amortised append) against `call y_str_cat` (the exact-size
copy), and `ix.listing` showed 16 app / 7 cat — which looks fine. The audit
cannot tell you *which* `cat` is on the accumulator. What settled it was
building trees of 50 / 200 / 800 / 2 000 files and reading
`heap_used()` around one `report()` call.

| files | arena per report, before | arena per file, before | after | per file, after |
|---|---|---|---|---|
| 50 | 359 848 B | 7 197 B | 85 064 B | 1 701 B |
| 200 | 4 813 648 B | 24 068 B | 295 472 B | 1 477 B |
| 800 | 73 906 952 B | 92 384 B | 1 135 592 B | 1 419 B |
| 2 000 | 462 403 344 B | 231 202 B | 2 832 824 B | 1 416 B |

Flat per-file cost after the fix is linear; the growth before it is quadratic.
**A factor of 161 at 2 000 files**, with the golden unchanged to the byte.

The four constructs, measured in isolation (same compiler, `>>` where the
`;` is outside the arm, `>>>` where it is inside):

| form | n=200 | n=400 | n=800 | n=1600 | verdict |
|---|---|---|---|---|---|
| `if (f) { o += a } else { o += b };` | 652 800 | 2 585 600 | 10 291 200 | 41 062 400 | **quadratic** |
| `if (f) { o += a; } else { o += b; };` | 8 224 | 16 424 | 32 816 | 65 592 | linear |
| `if (i % 2 == 0) { o += a };` | 492 000 | 1 944 000 | 7 728 000 | 30 816 000 | **quadratic** |
| `if (i % 2 == 0) { o += a; };` | 8 224 | 16 424 | 32 816 | 65 592 | linear |

So this is the **already-filed** `str +=` in a value-used position bug in
`examples/BUGS.md` — not a new one, and it is cited rather than refiled. The
one-character fix it names is the fix. What is new here is `S9`, which
asserts the property, because the fix is invisible to `-S` unless you trace
which `cat` is on the accumulator, and invisible to every other check in the
file because **the output does not change at all**. `S9` measures the arena
one report costs at 100 / 200 / 400 files and requires the growth ratio to
be under 3×; linear is ~2×, quadratic is ~4×. `inject.py`'s `valueusedarm`
puts the semicolon back and `S9` fails, which is the point of it.

## The quadratic audit, for the record

`../../refs/ycc.ref -S indexer.y -o /tmp/ix.s`, counting the two symbols per
`yfn_` function:

| function | `y_str_app` | `y_str_cat` |
|---|---|---|
| `ix.listing` | 16 | 7 |
| `ix.ext_table` | 13 | 4 |
| `ix.hdr` | 3 | 0 |
| `ix.report` | 2 | 18 |
| `ix.report_with_diag` | 1 | 2 |

The `cat` counts are all **value constructions of a fixed-size piece**
(`"0x" + hex16(h) + "  "`, `code + s + C_OFF`, and the f-string spec helpers),
never a copy of the accumulator. `S9` is what establishes that, by
measurement. Whole program: 37 `app`, 398 `cat`, 44 functions — which on its
own says nothing, and is exactly why the number that matters is per-file arena
at three tree sizes.

## Allocation and throughput

`heap_used()` deltas, all under `ulimit -S -v 3670016`, on the pinned
compiler. Reproduce with `./indexer --bench N ROOT`.

**Content hashing is O(1) in arena.** One 20 MB file, three indexes:

```
heap growth 4 432 B over 3 rounds      (1 478 B per round)
per round 33 031 us                    throughput 605 MB/s
```

The file's 20 MB never enters the arena: `ix.hash_file` streams it through
the one module-level 32 KiB `RBUF`. A 20 MB file costs **4 KiB**.

**A walk is O(1) in arena apart from the entries.** 2 000 files in 201
directories, three walks, hashing off:

```
heap growth 5 313 616 B over 3 rounds   (1 771 205 B per walk, 886 B per file)
per round 2 286 us                     per file 1 us   throughput 56 MB/s
```

886 B per file is the `Entry` record, the path string and the name from
`getdents` — all irreducible. The **directory count does not enter it**,
which is the whole point of `read_dirs`. The same walk through
`fs.list_dir` costs 8.04 MB per walk, 6.56 MB more, and that difference is
32 KiB × 201 to three significant figures (`SUGGESTIONS.md` #22).

The golden's own tree: 18 files, 992 bytes, 5 rounds, 247 us per round,
13 us per file.

## Filings

Two suggestions, both in `examples/SUGGESTIONS.md`, neither a compiler bug:

- **#21 `eputs` writes no newline, `puts` does.** Cost this example three
  diagnostics run together on one line before it read the manual. Worked
  around by appending `\n` at every call site, with a comment saying why.
- **#22 `fs.list_dir` allocates 32 KiB per call.** Cost a 201-directory walk
  6.3 MB of arena. Worked around by `ix.read_dirs`.

`examples/BUGS.md` — **nothing new filed.** The one real compiler defect this
example ran into is the `str +=` in a value-used position bug, already filed;
it is cited in `ix.listing` and in "The quadratic" above, and not refiled.

## Files

```
indexer.y        the CLI: bench, wiring, and the exit-status idiom
cli.y            argument parsing and the program's own diagnostics
ix.y             the engine: comparators, hash tables, the walk, the report
selftest.y       the property check (S1..S9, 186 assertions)
gen_tree.py      regenerates data/tree, the golden's input
pty_check.py     52 assertions: the pty path and every process exit code
inject.py        40 injected defects and whether --check notices
EXPECTED         the exact stdout of the gate.conf run= line
gate.conf        build= / run= / check=
data/tree/       18 files, the golden's fixture (see gen_tree.py's docstring)
golden/          check.txt, largest5.txt, ext-md.txt, find-src.txt,
                 pty-coloured.txt, pty-100x30.txt
```

## Pin re-verification: `625efd81` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `5eba0d66` -> **`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `1d28b3db` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `625efd81` -> **`1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 36 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `31808ddc21adfa31` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3` -> **`31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `289cf022002903a6` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`289cf022002903a695c1ca339816b0f8f478aa3ef9f00643a93c3a95947f979c`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.

## Pin re-verification: `dad3564d3bcdf6df` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `e39a5e21785f599184f55deafad3ff17b4d05edb01cebc0a513e0cb7907f517d` -> **`dad3564d3bcdf6df889d017e88660dd8e7e0637a1e046acc45539f515e361d3e`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
