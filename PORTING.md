# Porting the Y code to C (1:1)

The C compiler (`src/c/`) is a **1:1 copy of the Y compiler (`src/y/`)**.
There is no independent C implementation any more — no VM, no C emitter,
no separate parser/typechecker with their own semantics. Every C module
mirrors one Y module; every function mirrors one `def`; the record shapes,
control flow and names match. When a Y module changes, the same change is
applied to its C twin.

The C version is accepted only when it reproduces the reference binary
byte for byte:

```
make cycc                        # gcc builds the C copy
./cycc -o /tmp/ycc-c src/y/ycc.y # the C copy compiles the compiler
cmp /tmp/ycc-c refs/ycc.ref      # byte-identical to the shipped ycc
```

`refs/ycc.ref` is the backup of the real `ycc` binary (see refs/SHA256SUMS).

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
| `src/y/ycc.y`           | `src/c/ycc.c`         | driver + `main`                   |
| —                       | `src/c/yv.c`/`yv.h`   | the Y value model (the one shared runtime) |
| `src/y/std/*.y`         | (stay Y)              | program modules, read from disk   |

`src/y/std/prof_lines.y` is generated from `prof.y` by `make`; the C copy
gets a generated twin (`src/c/prof_lines.c`) the same way.

## Translation rules

1. **Values** (`yv.h`): `null | bool | long | float | str | array | map`.
   Arrays and maps are **reference values** (shared; `push` grows in
   place and returns the same array — exactly the Y rules). Strings and
   numbers are immutable values. The value model lives in `yv.c`; nothing
   else allocates Y values directly.

2. **Type map**: `long` → `long`, `float` → `double`, `bool` → `int`,
   `str` → `Yv *`, every record/array/shape-hole/option type → `Yv *`.
   Boxing at the boundaries: `yv_long(x)` / `yv_l(v)`, `yv_bool(x)` /
   `yv_b(v)`, `yv_float(x)` / `yv_f(v)`.

3. **Records** are insertion-ordered maps:
   `let r = { k: "num", v: x }` → `Yv *r = ym(2, "k", ys("num"), "v", x);`
   (`ym(n, key1, val1, ..., NULL)` — n pairs). Field read `r.name` →
   `ym_get(r, "name")`. The Y code rebuilds records instead of mutating
   fields; do the same.

4. **Arrays**:
   `[a, b]` → `yav(2, a, b)`, `[]` → `yav(0)`, `[v; n]` → `ya_rep(v, n)`,
   `a[i]` → `ya_get(a, i)`, `a[i] = v` → `ya_set(a, i, v)`,
   `a[i:j]` → `ya_slice(a, i, j)`, `push(a, v)` → `ya_push(a, v)` (same
   in-place semantics), `len(x)` → `yv_len(x)`.

5. **Strings**: `"x"` (as a value) → `ys("x")`; `a + b` → `ys_cat(a, b)`;
   `s == "lit"` → `ys_eq_lit(s, "lit")`; `s == t` → `ys_eq(s, t)`;
   `substr(s, i, n)` → `ys_substr(s, i, n)` (C-clamped semantics);
   `tostring(v)` → `ys_tostring(v)` (same formatting as the VM);
   `ord/chr/trim/join/split/index_of/last_index_of` keep their names.

6. **Functions**: `def f(a: long, s: str) -> long` → `long f(long a, Yv *s)`.
   Names are kept exactly as written (the Y modules do not collide).
   `alias.fn(...)` (module call) → `fn(...)` (names are flattened).
   `self(...)` recursion → the function's own name.

7. **Control flow is 1:1**: same `if`/`else if` chains, same `while`/`for`
   loops, same early `return`s, same statement order. The `0;` statement
   tails of Y if-arms become `;`. Do not refactor while porting.

8. **Errors and exits** behave like the Y code: `exit(n)` terminates;
   diagnostics go through `puts`/`eputs` unchanged.

## What the port must NOT do

- No tree-walking interpreter (the VM is gone).
- No independent semantics: where the Y code is quirky, the C copy keeps
  the quirk. Behavior differences are bugs.
