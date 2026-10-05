# toolkit-cli — JSON, CSV and base64 from the shell

A command-line conversion toolkit written in Y: a strict JSON parser and a
deterministic emitter, an RFC 4180 CSV reader and writer, an RFC 4648
base64 codec, and the bridges between them. It reads a file or stdin,
writes stdout, and has no dependency on the terminal, the clock, the
network or any file outside this folder.

**All three formats are written from scratch.** Y has no JSON module, no
CSV helper, and a base64 *decoder* (`x509.b64_decode`) but no encoder at
all. See *What did not exist* below.

```
$ toolkit_cli csv --op=to-json --header < data/demo.csv | head -4
[
  {
    "name": "Cabbage, green",
$ toolkit_cli json --op=get --path=authors[0].name data/demo.json
"R. Vasquez"
$ echo -n foobar | toolkit_cli base64 --op=encode
Zm9vYmFy
$ toolkit_cli base64 --op=sum data/demo.csv
d38cecbf3107638d4779b5b8e2f6327a46efc7b5248e6b7a1be9c3943c606f37
```

---

## Build

```
cd examples/toolkit-cli
../../refs/ycc.ref toolkit_cli.y -o toolkit_cli
```

`gate.conf` has exactly that line, plus `run=./toolkit_cli demo`.

**Pinned compiler.** Built and verified against
`refs/ycc.ref` sha256
`c53cc41524a7baa2de88d0f56faf5e2c9d006845ab5fa7a1b70edc53f9df6631`.

That pin moves on every rebless. If `python3 ../gate.py toolkit-cli`
reports *"the pin moved"*, rebuild with the command above, re-run
`./toolkit_cli demo` and `./toolkit_cli selftest`, and record the new sha
here. Do not copy the compiler elsewhere: it resolves its `std/` relative
to its own path, so a copy in `/tmp` compiles until a program does
`import fs;` and then fails.

Zero warnings at the default level. Nothing here needs `-w`, `-W 1`, or
any flag.

## Run

```
./toolkit_cli <command> [options] [FILE|-]
./toolkit_cli --help          the full interface, ~90 lines
./toolkit_cli demo            a worked example of every mode
./toolkit_cli selftest        143 property checks, no golden file
```

| command | what it does |
|---|---|
| `json` | `--op=pretty` (default), `compact`, `validate`, `get`, `text`, `keys` |
| `csv` | `--op=to-json` (default), `from-json`; `--header`, `--delim`, `--line-end`, `--num`, `--quote-all` |
| `base64` | `--op=encode` (default), `decode`, `sum`; `--wrap`, `--lenient`, `--checksum` |
| `selftest` | the property checks — see below |
| `demo` | every mode over two documents embedded in the binary |
| `help`, `version` | — |

The `FILE` operand is read when given, otherwise stdin; `-` means stdin
explicitly. `--stats` adds one summary line on **stderr**, so `2>err`
keeps stdout clean for the next stage of a pipe.

### Exit codes

| code | meaning |
|---|---|
| **0** | it worked |
| **1** | bad **input**: a malformed document, a table that does not match its header, a file that is not there, a path that does not resolve |
| **2** | bad **usage**: an unknown command, an unknown or misused flag, a value the flag will not accept |

Two codes, not one, so a script can tell "the data is broken" from "you
asked wrongly". A bare invocation prints the usage on **stderr** and exits
**2** — in this tool stdout is only ever data. `args` supplies the 2 for
its own parse errors; the table above is what this program guarantees on
top of that.

### Determinism

Object keys come out in **input order**, never sorted, unless
`--sort-keys`. Numbers keep the **exact text they were written with**, so
`1.0` stays `1.0` and `1e2` stays `1e2`. Indentation is fixed by
`--indent`. Nothing consults the clock, a random source or the network, so
two runs of the same command produce identical bytes — verified in the
gate, which runs the documented run twice and diffs.

## What to LOOK AT

1. **`golden/selftest.txt`** — the 143 checks, and their output. This is
   the part a golden file cannot do. Read groups [1] (the RFC 4648
   vectors), [4] (the RFC 4180 awkward cases, each against an exact
   expected string), [5] (JSON round-trip identity) and [11] (all 45
   malformed inputs, each run end to end through a forked child).

2. **`./toolkit_cli demo`** — step 9 in particular. It converts
   `data/demo.csv` to JSON and straight back and prints
   `identical to the input file: true`: a **byte-identical** round trip,
   not merely an equivalent one. Step 6 shows `--sort-keys` reordering the
   same document, and step 12 the SHA-256 of the same file that
   `sha256sum` prints.

3. **`jsonval.y`, above `render()`** — a filed compiler bug and its
   workaround, in the place where the workaround lives.

4. **`csvio.y`, the header comment** — trap 2 (`split()` drops one
   trailing empty field) and why this file never calls `split()`.

## The property check

`EXPECTED` proves **determinism**. It cannot prove **correctness** — the
lesson of `examples/cube`, which passed all eight gate items with a
wireframe that filled regions. So the correctness surface is
`./toolkit_cli selftest`, which asserts against **external references and
no reference file at all**:

- **(a) base64 against RFC 4648 §10's own test vectors**, asserted by
  value, and each one round-tripped:

  | input | encoded | decoded back |
  |---|---|---|
  | `""` | `""` | `""` |
  | `"f"` | `"Zg=="` | `"f"` |
  | `"fo"` | `"Zm8="` | `"fo"` |
  | `"foo"` | `"Zm9v"` | `"foo"` |
  | `"foob"` | `"Zm9vYg=="` | `"foob"` |
  | `"fooba"` | `"Zm9vYmE="` | `"fooba"` |
  | `"foobar"` | `"Zm9vYmFy"` | `"foobar"` |

  plus: all **256** byte values round-trip (344 characters, two `=`); the
  encoding agrees byte-for-byte with **`x509.b64_decode`**, a decoder this
  example did not write; and nine malformed encodings are each refused by
  name.

- **(b) CSV per RFC 4180**, each awkward case asserted against its exact
  expected output string: a quoted field holding the delimiter, a quoted
  field holding a doubled quote, a quoted field holding a newline, an
  empty final field, a quoted empty field, a doubled delimiter, a line of
  one delimiter, both of the RFC's own example tables, an empty field in
  the middle, LF in / CRLF out, a bare CR as a terminator, CRLF as one
  terminator not two, and the four cases that are easy to confuse —
  `""` → no records, `"\n"` → no records, `a,b,` → **three** fields, `""`
  → one empty field. Plus `data/demo.csv → json → data/demo.csv` asserted
  **byte for byte**.

- **(c) JSON round-trip identity**: a nested document with objects, arrays,
  strings carrying every escape, numbers in four shapes, booleans and
  null is parsed, emitted and parsed again, and the two parses are asserted
  to be the **same value** — a structural comparison, not a byte one — over
  three emitter paths (compact, pretty, sorted). The values themselves are
  checked against what JSON says they are: `\n` is a newline and not the
  two characters `\` and `n`, `U+1F600` is `f0 9f 98 80`, `U+00E9` is
  `c3 a9`, raw UTF-8 passes through, a raw control character is refused,
  key order is preserved, and a duplicate key is kept in place rather than
  resolved.

- **(d) every malformed input, end to end.** 45 cases — a truncated
  object, a trailing comma in an object and in an array, an unquoted key,
  single-quoted keys, a bad escape, an unbalanced bracket, an unbalanced
  brace, a leading zero, a bare word, two top-level values, an empty
  document, 300 levels of nesting, an unterminated quoted CSV field, text
  after a closing quote, a quote inside an open field, a short row for the
  header, a duplicate header name, `--header` with no records, from-json on
  an object, from-json with a nested value, four bad base64 inputs, an
  unknown command, no command, an unknown option, an unknown `--op`, a
  `--op` from another command, a non-numeric `--indent`, a negative
  `--indent`, a bad `--delim`, a `--delim` that is a quote, a bad
  `--line-end`, a json-only flag given to `csv`, a csv-only flag given to
  `json`, an option given to `selftest`, a `FILE` given to `selftest`, too
  many operands, an unknown `--checksum`, `--get` without `--path`,
  `--keys` on a non-object, a file that is not there, and a path that does
  not resolve. Each is run **in a forked child that execve's this same
  binary**, with its stdin on a pipe and both its stdout and its stderr on
  another, so the check observes the real exit code, the real stderr and
  the real absence of a trap — not an assumption about them.

Two positive controls run through the same harness: good input exits 0
with no output, and `base64 --op=encode` on `foobar` returns `Zm9vYmFy`.

**It found a real bug in my own code.** The `\n` check in (c) failed on
the first run: `p_string` was writing the two bytes `\` `n` instead of the
newline they stand for. The output round-tripped perfectly and was wrong.
Nothing but a value assertion could have caught that.

## Complexity, and where it is linear-scan

There is no hash map, no `keys` lookup in O(1) and no `sort` in Y: a
`{str => long}` is a **linear scan** (ORCHESTRATOR.md §2.8). This example
is built around that rather than pretending otherwise:

| operation | cost |
|---|---|
| `jsonval.j_get(o, key)` | **O(keys in the object)** — a linear scan of the field list |
| `jsonval.lookup` (the dotted path) | O(keys) per segment |
| `jsonval.same_unordered` | O(keys²) over an object |
| `csvio.csv_to_json` duplicate-header check | O(columns²) |
| `jsonval.sort_fields` (`--sort-keys`) | **O(keys²)**, a hand-written selection sort |
| parse, emit, `csv_parse`, base64 encode/decode | one linear pass |

So an object with many keys costs a linear scan per lookup: right for a
document, wrong for a 100 000-key index. That is why `--sort-keys` is not
the default and why there is no `--sort-keys` at all on the CSV side.

Two other honest notes:

- **Nesting is bounded at 200 levels.** Y recursion is cheap (20 000
  frames verified), but a bound is what stops `[[[[[…` from turning a
  4 MB input into a stack overflow, and the diagnostic names the bound so
  it is not a mystery. `examples/toolkit-cli json --op=validate` on 300
  levels says `nested deeper than 200 levels` and exits 1.
- **Memory is linear, and measured.** On a 7.5 MB JSON document with
  360 004 nodes, under the campaign's 3.5 GiB cap:

  | command | wall | peak heap (`heap_used()`) | peak RSS |
  |---|---|---|---|
  | `json --op=validate` | 80 ms | 156 797 864 | 154 028 KiB |
  | `json --op=compact` | 175 ms | 562 302 696 | 546 728 KiB |
  | `json --op=pretty` | 201 ms | **624 840 312** | 603 452 KiB |
  | `csv --op=to-json --header` (1.3 MB, 40 001 records) | 87 ms | 385 429 248 | 378 156 KiB |
  | `base64 --op=encode --wrap=76` (7.5 MB) | 71 ms | 62 492 336 | 60 168 KiB |

  The heap figures are roughly 80× the input, which is the parsed tree:
  ~360 000 nodes at a few hundred bytes each, nothing is ever freed. The
  emitter itself is accounted for in the filed bug below.

## Compiler workarounds

Every one of these is **visible in the code** at the point it applies, and
none of them is silent.

### 1. The emitter accumulates into a `[byte]`, not a `str` — FILED

`examples/BUGS.md`: **"A `str +=` in a value-used position makes its whole
loop O(n²) in heap"**.

A JSON emitter is a tree walk, and its appends live inside an `if`/`else`.
An append written in a **value-used** position — the last statement of a
branch, with no trailing `;` — is desugared to `s = s + t`, which allocates
an exactly-sized buffer. In a loop that destroys the amortised growth of
every other append in the same loop: a 130 KB document cost **2.7 GB** and
died on the cap. `render()` therefore appends to a `[byte]` and calls
`from_bytes` once at the end; array growth is capacity doubling with no
ownership cell involved, and the same document now emits in 201 ms with a
peak heap of 624 840 312 bytes. Making the emitter *iterative* was not
enough and is not the fix — the `;` is what matters, and the filing has the
minimal reproduction, the exact numbers and the assembly.

The workaround is visible in three places: the `WORKAROUND` note above
`render()`, the `let em_out: [byte] = [];` and its comment, and
`em_put()`.

### 2. `s[i]` is a BYTE and `str + byte` segfaults — pre-existing

`examples/BUGS.md`: **"`str + byte` segfaults"** (and two later entries
about what happens when you try to work around it). Nothing in this example
writes `str + byte`. Two consequences shaped the code:

- The base64 alphabet and the hex-digit table are **`[str]` arrays**, not
  strings, because indexing a `str` yields a byte and cannot be typed as a
  character anywhere. See `b64.y`'s `ALPHA` and `jsonval.y`'s `HEXD`.
- Characters are built with `chr(c)` and read with `byte_at(s, i)`, never
  with `s[i]`. `chr(c)` is verified to give exactly one byte for 0..255.

### 3. `split()` drops exactly one trailing empty field

`"a,".split(",")` is `[a]`, so `join(s.split(sep), sep)` does not
round-trip a string that ends in the separator — and CSV *is* that case.
**`csvio.y` never calls `split()`**: records and fields come out of a
character scanner with its own state, because a trailing empty field is a
field. `a,b,` is three fields, `""` is one empty field, and a blank line is
no record at all. The four cases are asserted individually in the
self-test.

### 4. Runtime traps print to stdout

A trap splices itself into the output instead of announcing itself
(ORCHESTRATOR.md §2.6), and in a pipe it corrupts the next stage. So: every
scan loop tests `i < len(s)` rather than reading `byte_at(s, len(s))`;
every error path ends in `die()` with a message on **stderr** and a
non-zero code; `--indent`, `--wrap`, `--delim` and `--line-end` are
bounds-checked before use; and the self-test's group [11] runs 45 bad
inputs through a forked child looking for `runtime error:` on the child's
captured output. 104 hand-run invocations across every flag and bad input
produced **0 traps**.

### 5. The language gaps this had to route around

Not bugs, and not filed — ORCHESTRATOR.md §2.4 and §2.9 list them. Named
here so the next reader knows the odd-looking code is deliberate:

| gap | what this example does instead |
|---|---|
| no `break`, no `continue` | early exit is a guard flag with an explicit terminal assignment; a skip is a positive condition wrapping the body. Every scan loop in `csvio.y` and `jsonval.y` is written this way. |
| no cast syntax at all | `long → byte` happens at exactly two annotated sites, `b64.put_byte()` and `jsonval.putb()` / `put_utf8()`, and nowhere else |
| no `float → long`, no `tolong(tostring(f))` | nothing numeric is done in floating point. CSV numeric recognition is a hand-written check against the JSON number grammar (`csvio.num_token`), and a JSON number keeps its **text**, so `1.5e-3` is never rounded through six decimals. |
| no character literals | `ord("a")` and `chr(65)`; `39` for a single quote |
| no `sort`, no `push`, no `map_get` | `+=` and `*=` are the array interface; sorting is hand-written (`jsonval.sort_fields`, selection sort; `fs.sort_names` in std for a reference shape); lookups are linear scans |
| no JSON, no CSV, no base64 encoder | written here; see below |
| Y string literals have `\n \t \r \xHH` and `\<c>` only — **no `\uXXXX`**, and `\b` is the letter `b` | every non-ASCII and control byte in a literal is `\xHH`, which is also how the self-test states its expected bytes. And a multi-line string literal cannot be line-continued (`\<newline>` *inserts* a newline), so the long help text is an array of lines joined with `\n`. |
| `[0; n]` needs an integer **literal** | the `argv` array for `execve` is grown with `+=` |
| a record is a **reference** | `jsonval.push_object` builds a *new* record for `--sort-keys` rather than assigning through `let src = v`, which would reorder the caller's document |
| a module-level `let` is not visible to code textually above it | all module state is declared at the top of its file |
| a local module is imported by **bare name** | `import jsonval;`, never `from "./jsonval.y"` |
| a forward call needs its return type written | `chk_csv(...) -> void`, `push_object(...) -> void`, `errv(msg) -> JVal` next to the void `fail(msg)` |

### What did not exist

Worth stating plainly, because it is the bulk of the work here: Y has **no
JSON module, no CSV helper, and no base64 encoder**. `x509.b64_decode`
exists and is used — as a cross-check in the self-test, not as the
implementation — but nothing encodes. JSON *literal* syntax is on the
compiler's own roadmap (root `TODO.md` §3), so the hand-rolled parser here
is expected work and **nothing in this example is filed as a missing
feature**. The one bug filed (the `str +=` one) is a defect in code the
compiler generates, not an absent feature.

## Files

| file | lines | what |
|---|---|---|
| `toolkit_cli.y` | 572 | the CLI: commands, flags, exit codes, `demo`, `--help` |
| `jsonval.y` | 1060 | the JSON value, a strict parser, a deterministic emitter, `same` / `same_unordered`, the dotted path |
| `csvio.y` | 475 | RFC 4180 parse and emit, plus the two JSON bridges |
| `b64.y` | 242 | RFC 4648 encode and decode |
| `selftest.y` | 788 | the 143 property checks and the fork/exec harness |
| `data/demo.json` | 1 014 B | the demo document, embedded in the binary |
| `data/demo.csv` | 146 B | the demo table, embedded, in canonical form |
| `EXPECTED` | 5 560 B | the exact stdout of `./toolkit_cli demo` |
| `golden/selftest.txt` | 15.7 kB | the property check's output, for a human to read |

## The std units this uses

Vendored from `examples/_toolkit/` at the revision the campaign table
records, copied in **byte-identically** and **not edited** — only
`args` is needed, since this example has no terminal, no framebuffer and
no trigonometry.

### sha256 of this example's own sources

```
4a4513b38f5295c3025e1b6239f5dd32024d9b5533103c870cfca68b1650ec22  b64.y
1d82bfa62067239dbf87591d8322aca3b855472a0bb676775541d2622168c7a8  csvio.y
fa4e5f2646fd24cae7cdcba1aeb5a4c29a990a712f5dfd3ee64d2feb20214553  jsonval.y
d3fe2b306768f9d901ba159e7db690664da4d9e91b488da36156ec7264f7c2c6  selftest.y
b6ef544159711ee2f0dd2b563828382317411ed7fa7e8bf54a5179ff363b311a  toolkit_cli.y
a19e169000d2a99d25a3f3deee901a1333adf25664633d766b7591a0888a5cf2  data/demo.json
d38cecbf3107638d4779b5b8e2f6327a46efc7b5248e6b7a1be9c3943c606f37  data/demo.csv
a6a810a602c486ae0ca47434b4fa23d8a7904a047ca3ad12d4f3e74ef0607f88  toolkit_cli   (the built binary)
405f65d4cfeb57acb49f0f5cbee2307cbb48fb048f1a2bdd5e28a2538d7ed494  EXPECTED
```

## Verification

```
$ python3 ../gate.py toolkit-cli
...
=== toolkit-cli: 8/8 passed ===

$ ./toolkit_cli selftest | tail -2
checks 143, failed 0, groups 11
RESULT: PASS
```

Hand-run as well, all under `ulimit -S -v 3670016` with `</dev/null`:

| check | result |
|---|---|
| clean compile, zero warnings, `refs/ycc.ref` | 6 files |
| `demo` reproduces `EXPECTED` | 5 560 B, identical over 3 runs |
| `selftest` | 143 checks, 0 failed, byte-identical over 2 runs |
| traps | 0 in 104 hand-run invocations, 0 in the 45 self-test child processes |
| peak heap on a 7.5 MB document | 624 840 312 bytes (see the table above) |
| self-contained | builds from this folder alone, `data/` included |
| pipes | `csv → json → csv` and `encode → decode` both byte-identical |

## Known limits

Stated rather than hidden:

- **Nesting is capped at 200 levels** in JSON. Deeper documents are
  refused by name, not trapped.
- **CSV has one dimension.** A JSON array or object *inside* a field is an
  error, not a silently JSON-encoded blob. `null` becomes an empty string
  in both directions, because CSV has no null — so a JSON round trip
  through CSV is lossy for nulls and numbers become strings unless
  `--num` is given.
- **`--sort-keys` is a selection sort**, so it is O(keys²) and is not the
  default. There is no `--sort-keys` on the CSV side at all.
- **base64 decoding is strict by default**: a character outside the
  alphabet is an error. Whitespace is ignored in both modes, because
  RFC 4648 §3.2 says it may be. `--lenient` skips the rest.
- **`base64 --op=sum` checksums the raw bytes of the input**, which for
  `encode | decode` composition is the thing you want, and for a text file
  is the file's bytes including a trailing newline. `sha256sum` agrees
  byte for byte — checked in the self-test.
- The `str + byte` segfault, the `is_some` postfix form, the missing
  `\uXXXX` in string literals and the missing `break`/`continue` are all
  properties of Y today and are listed above with their workarounds. The
  first is filed; the rest are not bugs and are not filed.
### Pin re-verification

The compiler was reblessed mid-campaign to
`refs/ycc.ref` sha256
`6dcd7071f2fe387585a4fa7a05c92bf7821b68a70449ed5ada732724bfb8898e`.
Rebuilt against it: **zero warnings**, the deterministic run still
reproduces `EXPECTED` byte for byte, no trap on any path, and this
folder's own property check still passes. No source change was needed.
Earlier pins stay listed above as history.

## Pin re-verification: `4a58dd5d` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `6dcd7071` -> **`4a58dd5d3dc88425354854cdb6b153c4b6ec8e54e6c0e65be65a7d0a25483ab8`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. The only thing that had fallen out of date was this sha
record, which is what gate item 0 caught.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `e55fa8d0` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `4a58dd5d` -> **`e55fa8d08a151d2aa8482370b3b79dd2f6a7b99760eecb876b094c90814a76ab`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs, so
the golden, the answers and the property-check result in this README are
unchanged. Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from a single number.

## Pin re-verification: `9ce37629` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`9ce376290e6fbe71629f51c871ff3cae8f498543a8ac3e0d7a0d8049e35946e7`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

## Pin re-verification: `5eba0d66` (orchestrator, 2026-10-04)

`refs/ycc.ref` moved again, `e55fa8d0` -> **`5eba0d66059520a9d28f5cdae57fd99835bb6ae62110bf4d2a794ae5fced484b`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8
all pass and `EXPECTED` is reproduced **byte for byte** over two runs.
Gate item 0 caught the stale record and nothing else did.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should
be able to see the history rather than infer it from one number.

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
