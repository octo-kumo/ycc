# Choices made without asking

Each entry: the question, the options, the choice and why. Goals, in the
user's words: less code overall, general, performance, smaller binary,
less code for the user of Y to write, an intuitive language, syntax
sugar.

## Record/union redesign, stage 1 (2026-10-02)

### 1. What a run-time check of an unknown value compares

A value of unknown type (an unannotated parameter, a field read through
`{k: str}`) going where a record type is declared is checked when the
program runs. Compare what?

- a. The full type tag (descriptor address). Exact, one compare; but a
  record built where no type is declared (`{name: n, typ: t}` with `t`
  unknown) gets its own tag, so correct programs, the compiler's own
  code among them, would trap.
- b. **The field names** (a 31-bit hash of them, kept in the
  descriptor). What a wrong offset depends on; never traps a correct
  program. Chosen.

- COMPLETELY INCORRECT!!!! REMOVE THIS BACKDOOR FROM THE LANGUAGE

### 2. Which cycles a recursive alias may have

The approved design allowed a cycle through a field, array, option, map
or function type.

- a. As designed. `type T = [T]` and `type T = T?` are then types with
  no record in them; printing and `==` unroll at compile time and would
  need generated per-type functions.
- b. **Through a record field or a function type only.** Every real use
  (lists, trees, ASTs, a function returning itself) is covered; records
  already print nested values as their type name, so nothing unrolls
  forever and no per-type printers are needed. Chosen: less code.
  `type T = [T]` is an error at its declaration.

### 3. How a recursive alias is represented

- a. Spell it out a fixed number of levels (the old way: 32, a hole
  after). Exponential for mutual recursion: the old compiler timed out on
  `t149_recursive_aliases.y`.
- b. A cyclic graph unfolded on demand, each use spelling it out once.
  Two uses that start at different members (`Expr` vs `Add`) unroll
  differently and compare unequal: mutual recursion through a union
  breaks.
- c. **One shared node (`tref`) per recursive alias**, every reference
  to it that node; equality of two by their canonical forms. Chosen:
  one representation, so tags and equality do not depend on where an
  alias is met.

### 4. Record literals where a type is declared

The design said a literal going into a union becomes the member with its
field names. How far does that go?

- a. Only a literal written directly where a union is declared.
- b. **Everywhere a type is declared** (a typed `let`, an argument, a
  `return` or a def's tail, an assignment, a field/element/map store,
  `+=`/`*=`, `*p =`), nested literals included, and their values
  convert like any store. Chosen: `let e: Expr = {l: {n: 1}, r: {n: 2}}`
  is the natural way to build recursive data. Consequence:
  `let p: {x: float} = {x: 1}` now stores 1.0 (it was an error;
  e130_record_field_conversion.y keeps only the cases about existing
  records, which still never convert).

### 5. What `{f: v} x` binds when several union members have field f

- a. The first member with those fields (the old rule). Wrong offsets
  when the value is another member.
- b. **The member with those fields, or the union of the members that
  have them**, so `x.f` reads through the union. Chosen: sound.

### 6. Fields through a union

The design allowed reading `u.f` when every member has `f` with one
type. Writing too?

- a. Reads only.
- b. **Reads and writes** (`u.f = v`): the same rule, the same slot
  dispatch. Chosen: general.

### 7. A union whose members share a field-name set

`{k: str, v: long} | {k: str, v: str}`: tell them apart how?

- a. Reject such unions (names would then be enough at run time).
- b. **Allow them: the tag is the full structural type.** Chosen: what
  the approved design says (type numbers structural, membership exact).

### 8. Record layout of a map

Maps are lowered to a `{keys, vals, boxes}` record, now laid out by name:
`boxes`, `keys`, `vals`. Kept that (no special case for maps).

### 9. The std pack and object versions

Records changed layout, so `ycc-std-pack 3` and `ycc-unit 2`: an old
pack or object is rebuilt rather than linked.

### 10. The match-pattern "unknown type" error

`unknown type 'X' in match pattern` was reachable only through the old
32-level alias expansion; unknown names are reported by rename.y. The
branch was removed rather than excused in COVERAGE.md.

## Record/union redesign, stage 2 (2026-10-02)

### 11. Ship a first cut of parameter inference, or wait for the incremental checker

A first cut (argument types joined at direct calls, whole-program passes
while a solution changes) works, but on the compiler's own source it types
14 of 604 unannotated parameters after one pass and 25 after four (their
arguments are `{k: str}` holes or unknown), while typecheck goes from
97 ms to 467 ms (+28% on the self-compile; +8% with two passes).

- a. Bless it with four passes: +28% compile time for little gain.
- b. Bless it with two passes: +8%, 14 parameters typed in src/y.
- c. **Shelve it** (the patch is kept in the session files folder) and
  implement inference with incremental re-checking (re-check only the defs
  whose parameters or callee signatures changed), after or with stage 3,
  which removes the holes that keep src/y's arguments unknown. Chosen:
  performance and binary size come first, and the design's cost target is
  a few percent.

## The file system module, std/fs.y (2026-10-02)

### 12. Keep `read_file`/`write_file`/`write_bytes` as builtins too, or only in fs

The note asks for every file-system operation in std/fs.y, the global
`read_file` included.

- a. Keep the builtins as aliases of the module's functions: no program
  breaks, but two spellings of one thing, and the runtime keeps code that
  every program links.
- b. **Remove them**: `import fs;` and `fs.read_file(...)`. The runtime
  (rt.y) and both checkers lose their file arms, and a program that never
  touches a file carries none of it. A program still calling the old names
  gets "undefined function 'read_file'" at the call (e143). Chosen: less
  code, one way to do it.

### 13. std/io.y

io.y was the old raw-fd layer (`open` with O_* flags, `read`/`write` on
pointers, `chmod`), overlapping fs.y's `open_file`, `read_some`,
`write_data` and `set_mode`.

- a. Keep both modules: two ways to open a file.
- b. **Fold io.y into fs.y and delete it**: its users (t10, t12, t20,
  t102, e34 and the `std_io` benchmark) moved to fs, and raw buffer reads
  are `syscall(0, fd, &buf[0], n)`, which is what io.read was. Chosen:
  "all file-system operations" in one module, less code.

### 14. fs's API

- Names: Python/Go-style verbs (`read_file`, `write_file`, `exists`,
  `is_dir`, `list_dir`, `make_dirs`, `remove_all`, `rename`, `cwd`), each
  with a `_bytes` twin where text and bytes differ: str for text, [byte]
  for anything (binary-safe).
- Failure: a read gives `none` (`str?`, `[byte]?`, `[str]?`, `long?`), a
  write or a path operation `false`, an fd `-1` — no exceptions in Y, and
  `!`/`== none` read well at the call.
- fds take C/Python mode strings ("r", "w", "a", "x", plus "+") rather
  than O_* numbers: what most languages use, and impossible to combine
  wrongly.
- `mode` arguments are permission numbers with -1 meaning "leave it"
  (Y has no octal literals; 420 is 0644, 493 is 0755).
- `list_dir` sorts (a merge sort in the module): directory order is
  filesystem noise, and a sorted list makes programs and tests
  deterministic.
- `read_some` reads at most 65536 bytes a call into a stack buffer:
  no heap buffer to manage, and a loop needs no more.
- `write_text` writes the string itself (no copy into a [byte]); a short
  write finishes through `write_data`.

### 15. Module scope for `import NAME;`

Moving the file builtins into a module exposed the module system's
flattening: `import fs;` put ~30 common names (`exists`, `rename`, `seek`,
`cwd`, ...) into the program's namespace, so a program's own `def exists`
was a duplicate-definition error and even `let cwd = fs.cwd();` broke
(`fs.cwd` was rewritten to `cwd`, which the local then shadowed). The
builtins had cost nothing like that.

- a. Prefix every module name (`fs_exists`): ugly, and every module
  must do it.
- b. Compile each named module as a unit of its own, as packages are:
  the most separation, but a second linking path for plain builds.
- c. **Scope named modules in rename.y**: a module's top-level names are
  bound as `fs.exists` (one identifier the lexer cannot produce), the
  importer's `fs.exists` resolves to it unless a binding called `fs` is in
  scope, and the module's own code finds its names bare, before the
  program's. Path imports (`import x from "path"`) still flatten, so the
  compiler's own sources and every existing program keep working.
  Chosen: general (net, struct and project modules get it too), small
  (rename.y plus the origin map's per-file module), and it fixes the old
  hazard of a local named like a module (`fs.st` read as `st`). Type
  aliases a module declares stay global (a known limit, as for packages).
  Labels keep the `.`, so `-g` shows `fs.exists`.

## Record/union redesign, stage 3 (2026-10-02)

### 16. The k-only node shapes and the hole

Stage 3 types the compiler's AST and type nodes as unions. Some kinds
carry only `k` — the AST `void` node and every primitive type node
(`{k: "tlong"}`, `{k: "tstr"}`, ...: 341 constructions) — so their union
member would be `{k: str}`, which today means "any record" (the hole):
a union with it would accept everything.

- a. Give every k-only node a second field (a dummy, or line/col):
  341 constructions change, every such node grows, and the meaning of
  `{k: str}` stays magic.
- b. Read `{k: str}` as exact inside a union and as the hole elsewhere:
  one spelling, two meanings.
- c. **Spell the hole explicitly, `{k: str, ..}`** (an open record: any
  record, read through its descriptor), so `{k: str}` is an ordinary
  exact record, as stage 4 wants anyway. Mechanical rewrite of src/y's
  395 holes; the marker is a `..` entry in the type's field list, so
  teq, tcanon and the pack encoding carry it unchanged. Chosen: one
  meaning per spelling (intuitive), it unblocks stage 3 with no change
  to any node, and stage 4 can drop `..` or keep it as a general
  "has at least these fields" type.

### 17. A field the record type lacks

Found while planning 16: `{a: 1, b: 2}.c` and `p.z` with `p: {x, y}`
compiled and trapped at run time, because typeof_field asked teq whether
the record "is" the hole, and teq lets any record of another width meet
it. Fixed to test the hole exactly (single_k): a compile error (e145).
No option to weigh: records are exact since stage 1, so the read can
never succeed.
