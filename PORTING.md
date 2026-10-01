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
| `src/y/native.y`        | `src/c/native.c`      | the emitter                       |
| `src/y/arch_x64.y`      | `src/c/arch_x64.c`    | asm strings + helpers             |
| `src/y/enc64.y`         | `src/c/enc64.c`       | base64/enc helpers                |
| `src/y/asm.y`           | `src/c/asm.c`         | the assembler                     |
| `src/y/elf.y`           | `src/c/elf.c`         | ELF writer                        |
| `src/y/dwarf.y`         | `src/c/dwarf.c`       | `-g` DWARF line table             |
| `src/y/ycc.y`           | `src/c/ycc.c`         | driver + `main`                   |
| —                       | `src/c/yv.c`/`yv.h`   | the value model (no Y twin; the runtime of *compiled* programs is `src/y/std/rt.y`) |
| `src/y/std/rt.y`, `prelude.y`, `exec.y`, `str.y` | (stay Y)  | the std units, compiled separately and linked into programs (std_units; precompiled in ycc's std pack): their sources are native.y's `embed`, the C copy's `Y_EMBED` (rule 10) |
| `src/y/std/io.y`, `net.y`, `struct.y`   | (stay Y)  | optional modules resolved **from disk** by `std_resolve` when a program imports them; not embedded |

## Translation rules

1. **Values** (`yv.h`): `none | bool | long | float | str | array | record`
   (tags `Y_NONE` ... `Y_REC`). Arrays and records are **reference values**
   (shared; `ya_push` grows an array in place and returns the same object —
   the rule `arr += v` follows). Strings and
   numbers are immutable values. The value model lives in `yv.c`; nothing
   else allocates Y values directly.

2. **Type map**: `long` → `long`, `float` → `double`, `bool` → `int`,
   `str` → `Yv *`, every record/array/shape-hole/option type → `Yv *`.
   Boxing at the boundaries: `yv_long(x)` / `yv_l(v)`, `yv_bool(x)` /
   `yv_b(v)`, `yv_float(x)` / `yv_f(v)`.

3. **Records** are insertion-ordered key/value records (`yr*`), and this
   is what a record *literal in the compiler's own source* ports to:
   `let r = { k: "num", v: x }` → `Yv *r = yr(2, "k", ys("num"), "v", x);`
   (n key/value pairs, **no sentinel** — the keys are the field names).
   Field read `r.name` → `yr_get(r, "name")`; `x == none` →
   `yv_is_none(x)`. The Y code rebuilds records instead of mutating
   fields; do the same. Note this is about records the *compiler* builds.
   A record *emitted into the user's program* is not built with `yr`: the
   emitter allocates, stores a shape-table pointer at `+0`, and writes the
   fields at `+8+8*i` (`gen_reclit` in `native.y`).

4. **Arrays**:
   `[a, b]` → `yav(2, a, b)`, `[]` → `yav(0)`, `[v; n]` → `ya_rep(v, n)`,
   `a[i]` → `ya_get(a, i)`, `a[i] = v` → `ya_set(a, i, v)`,
   `a[i:j]` → `ya_slice(a, i, j)`, `a += v` → `ya_push(a, v)` (in
   place), `len(x)` → `yv_len(x)`. (`push` is not a language function any
   more; `+=` is what pushes.)

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

7. **Control flow is 1:1**: same `if`/`else if` chains, same `while`/`for`
   loops, same early `return`s, same statement order. A block whose last
   statement ends in `;` is void (the parser plants a `void` statement);
   an `else` arm written `{ 0 }` or `{ 0; }` ports as the bare `;`/`0`
   form it has — do not refactor while porting.

8. **Smaller mappings**: `next_uid(st)` hands out a unique id for emitter
   labels and table names by bumping the emit state's counter; it ports
   like any other function (`next_uid` in `native.c`), so the produced
   names stay identical. `write_bytes(path, bytes, mode)` takes three
   arguments.

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

## What the port must NOT do

- No tree-walking interpreter (the VM is gone).
- No independent semantics: where the Y code is quirky, the C copy keeps
  the quirk. Behavior differences are bugs.
