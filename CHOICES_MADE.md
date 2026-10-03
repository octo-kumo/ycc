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

**User's ruling:** there is no unknown type at all ("the whole
compilation is known"; "if type cannot be inferred just ANNOTATE"). The
question goes away with the backdoor: see 18-24.

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

**User's ruling:** if all the shared fields are at the start, no mapping
is needed, because a shared field has one offset whatever the member is;
and "a union type is different from a normal type: if C = A|B, an A value
of C need not have the memory structure of an A on its own; an assignment
from one to the other is a cast, and a cast can move memory". See 21 and
25.

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

**Superseded** by the user's ruling ("if type cannot be inferred just
ANNOTATE"): parameters are annotated, not inferred from calls (18). The
patch stays shelved.

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

**Superseded** — the user: `..` is the same backdoor respelled. Open
records are gone (cycc cb89e46); `{k: str}` is an ordinary exact record,
and the compiler's nodes get precise union types (22).

### 17. A field the record type lacks

Found while planning 16: `{a: 1, b: 2}.c` and `p.z` with `p: {x, y}`
compiled and trapped at run time, because typeof_field asked teq whether
the record "is" the hole, and teq lets any record of another width meet
it. Fixed to test the hole exactly (single_k): a compile error (e145).
No option to weigh: records are exact since stage 1, so the read can
never succeed.

## No unknown types (2026-10-02, after the user's rulings on 1, 5, 11, 16)

The user: no type backdoors; make them errors immediately; change cycc,
then fix the compiler's own source until cycc accepts it; where a type
cannot be inferred, annotate. Done in cycc first (cb89e46, 7eec451,
f1b147f), then src/y (annotations, by a gpt-6-luna sub-agent as the
user asked), then the Y checker.

### 18. What "cannot be inferred" covers

- a. Infer parameters from call sites (2a, entry 11): order effects, a
  whole-program fixpoint, 4x typecheck time.
- b. Demand-driven checking (check a def when first called): its body
  needs the environment of its definition, not of the call.
- c. **Local inference only.** A parameter is always annotated ("parameter
  'x' has no type (annotate it)"). A `let` takes its initializer's type,
  but `[]` and `none` need a declared type where they are bound ("the type
  of 'xs' is not fully known (annotate it)"). A return type is inferred
  from the body, so a call made before the body is checked -- a forward
  call -- needs it written ("'f' is used before its return type is known
  (annotate it)"). Chosen: predictable, one pass, no new cost. A def's
  signature is its documentation anyway.

### 19. A def calling itself

- a. Require its return type (simple, but `def fact(n: long)` needs
  `-> long` for no reason the reader sees).
- b. **Infer it soundly**: check the body with the self call's type
  unknown, take the type the rest of the body gives, then check the body
  again as if `-> T` were written (only defs that call themselves pay the
  second pass). Chosen: keeps the common recursive def annotation-free,
  with no unchecked use of the self call. A body whose only value is the
  self call gets "the return type of 'f' is not fully known".

### 20. `[]`/`none` versus error poison

Both were tunk. **`[]` and `none` now mark their unknown part as free**
(t_free); only a free part makes a binding an error. Poison after a
reported error stays quiet, so one mistake gives one message.

### 21. A union value where a member is declared

The user: "an assignment from one to the other is a cast".

- a. Only `match` reaches a member's fields: sound statically, but every
  `k` dispatch in the compiler would become a match.
- b. **An implicit cast at every store** (typed let, argument, return,
  field, element): legal when the declared type is a member of the union,
  or a union of some of its members; the program checks the value's tag
  and stops on a mismatch (y_cast_trap). Chosen: the user's model, and it
  makes annotations enough to type the compiler. Unions that merely
  overlap do not convert.

### 22. The compiler's own nodes

`Node` is a union of one record type per AST node shape, each with `k`,
`line`, `col` (so those read straight through any Node); `Type` likewise
for type nodes (`k` shared). The few k-only AST nodes (`void`, `optarg`)
and three line-less blocks get a line and col. A function that builds
both AST and type nodes splits its result type (`Parsed`/`PType`).

### 23. Bootstrapping through the C copy

The blessed reference treats `{k: str}` as the hole even inside a union
(a `match` on such a union fails), and rejects union-to-member casts, so
it cannot build the annotated compiler correctly. The migration is
checked with compilers that cycc builds, which must produce byte-identical
binaries to the reference on every test program; the bless goes through
cycc (`make rebless`), not `make ynew`.

### 24. Messages

"parameter 'x' has no type (annotate it)"; "the type of 'x' is not fully
known (annotate it)"; "the return type of 'f' is not fully known
(annotate it)"; "'f' is used before its return type is known (annotate
it)"; a failed cast stops with y_cast_trap's message.

### 25. Shared fields first (the user's ruling on 5)

Today a record is laid out by field name, so a field every member of a
union has can sit at a different offset in each member, and reading it
through the union dispatches on the tag (the compiler's `node.line` would
compare up to 31 tags).

I proposed making the written field order part of a record type (so a
programmer could put the shared fields first). **The user rejected it:
`{a, b}` and `{b, a}` are one type, always.** Record types stay sets of
fields.

**The user's model, to be implemented** (after the no-unknown-types
migration, before the bless):
- A standalone record keeps its layout: fields sorted by name.
- A value of a union type lays out its member with the union's shared
  fields first (the fields every member has with one type, sorted by
  name), then the member's other fields (sorted by name). A shared field
  is then one load at a fixed offset through the union, whatever the
  member.
- A conversion between a union and a member, either way, or between two
  unions, is a cast. When the layouts differ, the cast copies the record
  into the other layout (a new record); when they agree it is the same
  record. Casts from a union are checked against the tag (21).
- The tag (descriptor) names the member type and its layout, so match and
  casts tell `Bin` in a `Node` from a standalone `Bin` when their layouts
  differ.
- Consequences, accepted with "a cast can do the memory movement": a write
  through a copy is not seen through the original (the compiler's own
  code must not write through a cast -- the C copy shares records, so the
  port gate would catch it); each copying cast allocates (no collector).
  If the copies show in the profile, the hot dispatchers can read member
  fields with destructuring patterns (`Bin { op, l, r } => ...`), which
  read the union value in place.
- Refinement (mine): a `match` arm's binding (`Rect r => ...`) is the union
  value itself, its fields at the union layout's offsets -- "an A value of
  C", in the user's words -- not a copy; it is copied only when it goes
  where a standalone member is declared. So `match s { Rect r => r.w =
  5.0 }` changes `s`, as a reader expects. A cast through an annotation
  (`let r: Rect = s;`, a parameter typed `Rect`) is the conversion that may
  copy.
  **Dropped when implementing.** The binding's static type is the member
  (`Rect`), whose layout is the standalone one; keeping the union's layout
  on it would need a layout-carrying type (a "Rect held in Shape") handled
  at every place the emitter reads, stores, converts, prints or passes a
  record -- and an `if` whose arms are a view and a plain `Rect`, or a
  def returning the view with an inferred return type, would mix layouts
  under one static type. Options: (a) the binding is a cast, as every
  other assignment from the union to a member (the user's model taken
  literally: "an assignment from one to other is a cast"); (b) the view
  type above; (c) a view only for `r.f` reads and writes, a copy at every
  other use (`r == r` would be false). Chosen: (a) -- least code, one
  rule for every assignment, no new type. A destructuring pattern
  (`Rect { w, h } => ...`, a record pattern `{f: v}`) reads the fields in
  place (native.y gen_narrow_field), so reading member fields in a hot
  match never copies. Consequence: a field only some members have cannot
  be written in place through the union; the manual (04-types, Unions)
  shows cast, write, store back.
- In src/y, three writes go to a union member after a conversion:
  types.y set_inferred_ret (`fnode.ret = ret`, a Func in Node) and the two
  tref patches (rename.y rn_tref, native.y tdecode: `r.to = ...`, a TRef
  in Type). Done: set_inferred_ret became a table (types.inferred_ret,
  dc1c1b3); a TRef's layout in Type is its own (k sorts first), so the
  tref patches write the record the union holds.
- **Implemented** (e70fcdb): native.y "union layouts" (union_shared,
  union_lay, ty_desc_in, gen_convert, gen_copy_rec, gen_narrow_field) and
  the C twin; the copy is inline (a tag dispatch, a word move per slot),
  not the y_rec_conv slot-map routine first planned -- the same work
  without a call. Node shares {col, k, line}: about half its members
  (those with a field sorting before `line`) copy on a cast; Type shares
  {k}: TRec, TFunc, TFree and Err copy.

## http prerequisites (task 3)

### 26. Optional record fields

The http client's options record (`http.get(url, { headers: h })`,
future.y) needs fields a literal may leave out. How?

- a. Any field of an option type may be left out of a literal (none), and
  a plain T given for it is wrapped. No syntax; but every `T?` field would
  silently become omissible, and "a plain T does not widen to T?" would
  have an exception nobody wrote.
- b. **`name?: T`, the mark optional parameters use** (`b?: T`): the
  field's type is `T?`; a literal where the record type is declared may
  leave it out (none) or give a plain T (wrapped, as `some` would), a
  `T?` or none. Chosen: one mark, one meaning, for parameters and fields;
  explicit where it matters.

Is the mark part of the type? **No**: `{a?: long}` and `{a: long?}` are
one type (one layout, one tag; values pass between them freely), and only
a literal sees the difference, through the declared type it is checked
against. Making it part of the type would make two records with the same
fields different types, against "a record type is its set of fields".

Around it:
- In a union, a literal that leaves optional fields out is the member
  with exactly its field names, else the only member it fits; two fits
  are an error (the literal is ambiguous).
- A field store (`r.f = 5`) still needs `some(5)`: the field's type is
  `T?`; the wrap is literal sugar, as an optional parameter's body sees a
  `T?`.
- `some({...})` where `T?` is declared creates the literal as `T`: an
  optional parameter of a record type is passed as `some(arg)` (rename),
  so `get("/", { url: "x" })` needs it.
- A left-out field stores nothing: y_alloc's memory is never reused and
  zeroed (the runtime already counts on it for array headers), and none
  is 0.

### 27. The wall clock

TLS checks a certificate's validity period and HTTP dates need the time
of day; `clock_us()` is CLOCK_MONOTONIC, good for intervals only.

- a. **A builtin `time_us()`**: CLOCK_REALTIME microseconds since the
  Unix epoch, the twin of `clock_us()` (same unit, same type, rt.y
  `y_time_us` beside `y_clock_us`). Chosen: the task asked for a builtin,
  and the pair reads as one family.
- b. A std module (`import time; time.now()`): no compiler change, but
  a second spelling for the same kind of thing `clock_us` already is.

Calendar arithmetic (UTC dates from it, and back) lives with what needs
it, in std, not in the compiler.

### 28. Name resolution

- Where: **in `std/net`** (`resolve`, `resolve_with`), not a new module:
  `connect_tcp` is its first user (it now takes a host name), and the
  http client will import net anyway. net imports fs for /etc/hosts and
  /etc/resolv.conf (a std module importing another works like a
  program's import).
- What: /etc/hosts, then the resolv.conf nameservers in turn, with
  `search` domains for a name without a dot (what glibc does with the
  default `ndots:1`); an A query over UDP (two tries, 2 s each), over
  TCP when the answer is truncated. IPv4 only: the socket layer is
  AF_INET throughout, and AAAA plus IPv6 sockets can come together.
- Failure is `[]` -- no address -- for every cause (NXDOMAIN, timeout, a
  malformed packet), never a trap: the answer is untrusted input.
  `connect_tcp` turns it into -2 (ENOENT).

### 29. A module's type aliases

Found while writing std/crypto.y: a module imported by name kept its
defs and lets to itself, but its `type` aliases joined the program's
one table, and the last declaration of a name won -- a program's own
`type Pt` after `import crypto;` retyped crypto's points and broke its
code. And a program could not name a module's type at all (`crypto.Hash`
was a syntax error).

- a. Leave them unscoped and give std's aliases unlikely names. Fragile:
  every module's names are every program's problem.
- b. **Scope them as defs are**: a module's alias is `m.T`; inside the
  module a bare name is its own alias first; the program writes `m.T`
  (the parser reads a dotted name in a type and a type pattern). Chosen:
  the same rule as the module's functions, and the http client's
  response type needs a name its users can write.

### 30. TLS: what the client does and does not

- **TLS 1.3 only.** Every server worth reaching speaks it; 1.2 would
  double the protocol code (another key schedule, RSA key exchange or
  ECDHE-RSA, CBC suites).
- **X25519 only, and no HelloRetryRequest.** Servers take X25519
  nearly everywhere; P-256 ECDH would need scalar multiplication on top
  of the verification code, and HRR a second ClientHello. A server that
  insists says so in the error.
- **Three suites**, ChaCha20-Poly1305 offered first: in plain Y it runs
  at about twice AES-GCM's speed (13 vs 7 MB/s).
- **Verification is on by default** (system anchors, host name),
  `insecure: true` turns off only the chain check; signatures and
  Finished always hold. Revocation, name constraints and policies are
  not checked (no OCSP/CRL fetching): the common client trade-off.
- **Modules, not builtins**: crypto, x509 and tls are plain Y in std,
  so nothing in the compiler grew; a program that does not import them
  pays nothing.

### 31. Walking a map: `keys(m)`

The http client takes request headers as a map and must send each; the
language had no way to visit a map's entries.

- a. **A builtin `keys(m)` -> [K]**: the keys in insertion order, a copy
  of the map's own keys array (so growing it cannot break the map).
  Chosen: one name, works with foreach, `m[k]!` reads each value.
- b. `foreach (k, v in m)`: nicer, but new syntax in the parser, the
  checker and the emitter of both copies.
- c. `m.keys` as a property: the map's own array, which `+=` on it would
  corrupt.
A user def named `keys` still wins over the builtin (as with `len`).

### 32. The http client's API (future.y asked for options)

future.y sketched both a global `http.header(...)` that sets a header
"for the next request" and a fetch-style `http.get(url, { headers })`,
and asked for a choice fitting few unique requests and many similar
ones.

- a. Global state (`http.header` for the next request): short, but
  action at a distance -- which request gets the header depends on
  call order, and two parts of a program trip over each other.
- b. **Fetch style for one request**: `http.get(url, opts?)`, the
  options a record of optional fields (`{ headers: {...}, timeout: 5 }`),
  nothing left behind. Chosen.
- c. **A session for many similar ones**: `http.session({ base,
  headers, ... })` returns a record of functions (`s.get("/users")`,
  `s.post(path, body)`, `s.header(k, v)` for later requests,
  `s.close()`), sharing a base URL, headers, kept-alive connections
  and cookies. Chosen alongside b: the state lives in a value the
  program holds, not in the module.
- The response is a record (`status`, `headers` as a map, `size`,
  `url`, `err`) with `read(n)`/`text()` as function fields, so
  `res.text()` reads like future.y's sketch; the body is read as it
  arrives, not buffered first. HTTP errors are responses (404 has a
  status); only a missing response sets `err` (status 0).
