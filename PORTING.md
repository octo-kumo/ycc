# Porting the Y code to C (1:1)

The C compiler (`src/c/`) is a **1:1 copy of the Y compiler (`src/y/`)**.
Every C module mirrors one Y module; every function mirrors one `def`; the record shapes, control flow and names match. When a Y module changes, the same change is applied to its C twin.

The C version is accepted only when it reproduces the reference binary
byte for byte:

```
make cycc                        # gcc builds the C copy
./cycc -o /tmp/ycc-c src/y/ycc.y # the C copy compiles the compiler
cmp /tmp/ycc-c refs/ycc.ref      # byte-identical to the golden reference
```

`refs/ycc.ref` is the golden output for the current sources (see
`refs/SHA256SUMS`). **Provenance (2026-09-30):** it is `cycc`'s output —
`cycc -o refs/ycc.ref src/y/ycc.y` — not a Y bootstrap. The previous
reference was unusable (it trapped with "index out of bounds" on every
input, so the old `ref → s1 → s2 → s3` Y-bootstrap chain could not be
run at all); the replacement was accepted only after the self-compile
fixpoint was verified across three generations (`cycc → y1 == y2 == y3`,
`test/sh/test_fixpoint.sh`). Consequence for the gate: `cmp ycc
refs/ycc.ref` now proves the C copy reproduces *its own* last
self-consistent output, not that it reproduces a separately bootstrapped
compiler — the twin agreement itself is what the port gate rests on
(`test_port.sh` compiles every test program with both compilers and
requires byte-identical binaries).

## Module map

| Y                       | C                     | notes                             |
|-------------------------|-----------------------|-----------------------------------|
| `src/y/lexer.y`         | `src/c/lexer.c`       | token stream                      |
| `src/y/parser.y`        | `src/c/parser.c`      | AST as Y records                  |
| `src/y/rename.y`        | `src/c/rename.c`      | uniquifying pass                  |
| `src/y/types.y`         | `src/c/types.c`       | the checker                       |
| `src/y/lint.y`          | `src/c/lint.c`        | warnings                          |
| `src/y/native.y`        | `src/c/native.c`      | the emitter                       |
| `src/y/labels.y`        | `src/c/labels.c`/`labels.h` | the label identity table: a label is a long (one id per name) |
| `src/y/ir.y`            | `src/c/ir.c`/`ir.h`   | the instruction IR: a body is a flat `[long]` of items, one form and its field words per item (ir_render prints an item back as the text it replaces, which is what `-S` shows) |
| `src/y/arch_x64.y`      | `src/c/arch_x64.c`    | asm strings + helpers             |
| `src/y/enc64.y`         | `src/c/enc64.c`       | base64/enc helpers                |
| `src/y/asm.y`           | `src/c/asm.c`         | the assembler                     |
| `src/y/elf.y`           | `src/c/elf.c`         | ELF writer                        |
| `src/y/dwarf.y`         | `src/c/dwarf.c`       | `-g` DWARF line table             |
| `src/y/ycc.y`           | `src/c/ycc.c`         | driver + `main`                   |
| `src/y/pkg.y`           | `src/c/pkg.c`         | `ycc build`/`vendor`: y.toml, graph, git, y.lock, hashing; `exec` is fork + execve(`/bin/sh`, envp NULL) like std/exec.y, `syscall` openat/mkdir the libc calls |
| —                       | `src/c/yv.c`/`yv.h`   | the value model (no Y twin; the runtime of *compiled* programs is `src/y/std/rt.y`) |
| `src/y/std/rt.y`, `prelude.y`, `exec.y`, `str.y` | (stay Y)  | the std units, compiled separately and linked into programs (std_units; precompiled in ycc's std pack): their sources are native.y's `embed`, the C copy's `Y_EMBED` (rule 10) |
| `src/y/std/fs.y`, `net.y`, `struct.y`   | (stay Y)  | optional modules resolved **from disk** by `std_resolve` when a program imports them; not embedded |

## Translation rules

1. **Values** (`yv.h`): `none | bool | long | float | str | array | record`
   (tags `Y_NONE` ... `Y_REC`). Arrays and records are **reference values**
   (shared; `ya_push` grows an array in place and returns the same object —
   the rule `arr += v` follows). Strings and
   numbers are immutable values. The value model lives in `yv.c`; nothing
   else allocates Y values directly.

2. **Type map**: `long` → `long`, `float` → `double`, `bool` → `int`,
   `str` → `Yv *`, every record/array/union/option type → `Yv *`.
   Boxing at the boundaries: `yv_long(x)` / `yv_l(v)`, `yv_bool(x)` /
   `yv_b(v)`, `yv_float(x)` / `yv_f(v)`. A `type` alias is `Yv *` too,
   spelled `typedef Yv *Name;` in the `.c` file where it helps (`pkg.c`,
   `lint.c`), never in a header; a Y `import` kept only for an alias
   needs no `#include` (a comment at the top says so).
   What only types a value in Y has no C twin: an annotation, a cast
   through a typed `let` (`let c: Call = node;` reads `c.callee` as
   `yr_get(node, "callee")`), and the identity helpers that give a
   literal its type (`normnode`, `normtype`, `type_node`; `tc_res(t, st)`
   is `yr(2, "typ", t, "st", st)`).

3. **Records** are insertion-ordered key/value records (`yr*`), and this
   is what a record *literal in the compiler's own source* ports to:
   `let r = { k: "num", v: x }` → `Yv *r = yr(2, "k", ys("num"), "v", x);`
   (n key/value pairs, **no sentinel** — the keys are the field names).
   Field read `r.name` → `yr_get(r, "name")`; `x == none` →
   `yv_is_none(x)`. The Y code rebuilds records instead of mutating
   fields; do the same. Note this is about records the *compiler* builds.
   A record *emitted into the user's program* is not built with `yr`: the
   emitter allocates, stores its type descriptor's address at `+0`, and
   writes the fields at `+8+8*i`, slot `i` in field-name order
   (`gen_reclit` in `native.y`, "records at run time").

4. **Arrays**:
   `[a, b]` → `yav(2, a, b)`, `[]` → `yav(0)`, `[v; n]` → `ya_rep(v, n)`,
   `a[i]` → `ya_get(a, i)`, `a[i] = v` → `ya_set(a, i, v)`,
   `a[i:j]` → `ya_slice(a, i, j)`, `a += v` → `ya_push(a, v)` (in
   place), `len(x)` → `yv_len(x)`. (`push` is not a language function any
   more; `+=` is what pushes.)

   `yav`'s count is **not checked against its arguments**, in either
   direction. Too few and the missing slots are uninitialised pointers; too
   many and the tail is silently dropped. Same trap as `yr` in rule 6, but
   the symptom differs — a dropped `ys(...)` reads as an array that is
   mysteriously shorter than the Y literal, and it surfaces far from the
   edit. One hit us exactly this way: adding `jmp_at` to
   `is_intrinsic_name` without bumping `46` → `47` stopped `#fmt` being a
   builtin, and the only symptom was `error: assemble: L1357: unexpected
   comment (backend bug)` from a checker that no longer recognised a name.
   gcc says nothing.

5. **Strings**: `"x"` (as a value) → `ys("x")`; `a + b` → `ys_cat(a, b)`;
   `s == "lit"` → `ys_eq_lit(s, "lit")`; `s == t` → `ys_eq(s, t)`;
   `s[a:b]` → `ys_slice(s, a, b)`, `s[a:]` → `ys_slice_from(s, a)`,
   `s[:b]` → `ys_slice(s, 0, b)` (clamped like the native slice);
   `tostring(v)` → `ys_tostring(v)` (the same formatting the native
   runtime's `tostring` produces);
   `ord/chr/trim/join/split/index_of/last_index_of` keep their names;
   `byte_at(s, i)` → `ys_byte_at(s, i)` (traps out of bounds, like the
   native builtin). Nothing outside `yv.c` reads a string's bytes directly.

6. **Functions**: `def f(a: long, s: str) -> long` → `long f(long a, Yv *s)`.
   Names are kept exactly as written (the Y modules do not collide).
   `alias.fn(...)` (module call) → `fn(...)` (names are flattened).
   `self(...)` recursion → the function's own name.
   A `bool` flag parameter is `int`: `def parse_func(toks: [Tok], p: long,
   isnat: bool)` → `Yv *parse_func(Yv *toks, long p, int isnat)`, the call
   sites passing `0`/`1`. A record gained a field (`Func.label`) is read and
   written with `yr`/`yr_get` at every construction site in *both* copies —
   `block_func`, `parse_func`, `rn_func_finish`, `rn_decl_native_go` and
   `native.c`'s `strip_ns` all rebuild the whole record, and a `yr(n, ...)`
   whose `n` no longer matches the field pairs silently drops the tail (a
   `col` of 0 in a diagnostic is what that looks like).

7. **Control flow is 1:1**: same `if`/`else if` chains, same `while`/`for`
   loops, same early `return`s, same statement order. A block whose last
   statement ends in `;` is void (the parser plants a `void` statement);
   an `else` arm written `{ 0 }` or `{ 0; }` ports as the bare `;`/`0`
   form it has — do not refactor while porting.

8. **Smaller mappings**: `next_uid(st)` hands out a unique id for emitter
   labels and table names by bumping the emit state's counter; it ports
   like any other function (`next_uid` in `native.c`), so the produced
   names stay identical. The compiler's file calls go through std/fs.y
   (`import fs;`, `fs.read_file(path)`, `fs.write_bytes(path, bytes,
   mode)`); the C copy calls yv.c's `read_file`/`write_bytes` (three
   arguments) of the same behavior instead of porting the module.

   `foreach (x in xs) { ... }` ports as an index loop over the array,
   with the body unchanged: `long i = 0; while (i < yv_len(xs)) { Yv *x
   = ya_get(xs, i); ...; i = i + 1; }` (as in `asm.c` and `elf.c`).

9. **Errors and exits** behave like the Y code: `exit(n)` terminates;
   diagnostics go through `puts`/`eputs` unchanged.

10. **Embedded files**: a top-level `embed NAME from "./std/rt.y";` (a str
    const holding the file, read when the compiler is built) →
    `Y_EMBED(NAME, "src/y/std/rt.y")` (yv.h: the assembler's `.incbin`,
    path relative to the repo root, where the Makefile runs gcc), read as
    `NAME()`. The Makefile lists the files in `STD_EMBEDS` so cycc rebuilds
    when one changes.

11. **Assembly files**, the same mechanism and the same reason: `src/y/arch/
    *.s` holds the machine code (arch_x64.y `embed PRELUDE_ASM from
    "./arch/prelude.s";` → `Y_EMBED(PRELUDE_ASM, "src/y/arch/prelude.s")`).
    Unlike the std units this is not text either compiler reads — it is text
    the compiler *emits*, line for line — so the asm exists ONCE instead of
    once per copy, and the twin of `arch_prelude_lines` is a loop over the
    embedded text, not 1500 string literals. Only `arch_asm_lines` (the split)
    is ported; the lines themselves are not in the C source at all. Two
    consequences: the Makefile lists them in `ARCH_EMBEDS` (every rule that
    *builds* a compiler needs them, since they are read at build time), and a
    `#` comment line in a `.s` file is legal and dropped by `arch_asm_lines`,
    so the in-tree assembler never sees one. `make asm-check` reads them with
    GNU `as`.

12. **`syscall` is an instruction in Y and a function call in C.** The Y
    builtin compiles to a bare `syscall` instruction; libc's `syscall()` is a
    *call*. That is fine for everything rule 8's table describes — `openat`,
    `mkdir`, a write that returns a value — and wrong for any ported code that
    relies on the syscall **changing the machine's state for the instructions
    that follow it**:

    - a `clone`/`fork` that sets the child's `%rsp`. With a helper function,
      or with libc's wrapper, the child's `ret` pops a return address off the
      *new* stack and jumps into the compiler's BSS.
    - a jump that must leave `%rsp` exactly where it found it. `jmp_at` was
      first a `static` function, so at `-O0` gcc emitted `call`, dropping
      `%rsp` by eight and making the image's entry read the return address as
      its `argc`. It is now a macro expanding to `jmp *%reg` at the call site
      (`mg_jmp_at`, `src/c/meta.c:452`).

    So such a syscall must be inline asm at the point of use, not wrapped in a
    helper. This is the one place `src/c/` reaches for inline asm, and the
    reason is in the comment at `run_image_fork` in `src/c/meta.c`. Rule 8's
    "`pkg.c` uses libc calls" is right for everything else and silent about
    this.

## What the port must NOT do

- No tree-walking interpreter (the VM is gone).
- No independent semantics: where the Y code is quirky, the C copy keeps
  the quirk. Behavior differences are bugs.
