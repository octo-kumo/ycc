# ycc — the Y compiler, written in Y

`ycc` compiles Y source **straight to native assembly** (Linux x86_64):
unboxed values, static types, no C involved, no runtime to link.
`ycc` itself is built by the reference C compiler (`make ycc-selfcontained`).

```bash
ycc -o hello prog.y   # compile to a native executable (no cc/as/ld/libc)
./hello
ycc -S prog.y         # print assembly to stdout
ycc -S -o prog.s prog.y
```

## Layout

| file          | role                                                        |
|---------------|-------------------------------------------------------------|
| `ycc.y`       | driver: flags, import splicing, pipeline, direct ELF output |
| `lexer.y`     | source string → token list                                  |
| `parser.y`    | token list → AST (nested maps) + type nodes                 |
| `rename.y`    | uniquify pass: no scopes/shadowing downstream               |
| `types.y`     | static checker (errors are fatal)                           |
| `arch_x64.y`  | x86_64 emitters + Linux syscall ABI + asm prelude (incl. heap) |
| `enc64.y`     | instruction encoding for our subset                         |
| `asm.y`       | two-pass assembler over our asm dialect                     |
| `elf.y`       | minimal ELF64 writer (static, no libc)                      |
| `native.y`    | AST → assembly text (splice → strip → rename → check → emit)|
| `std/`        | standard library in Y (`io.y`: files over raw syscalls)     |

See `NATIVE.md` for the backend roadmap (representations, pipeline stages,
pointers, stack arrays, what's next).

## Language subset supported (native target)

Statically-typed Y with unboxed values: `let`/`const`/`def` (annotations
required on `def` params/returns), `if`/`else`, `while`, `long`/`int`
(same), `bool`, `str`, `*T`, `[T; N]`, `[T]`, `T?`, `&x`, `*p`, `*p = v`,
`a[i]`, `&a[i]`, `len(a)`, fixed arrays `[v; n]`, heap arrays `[v, ...]` +
`push`, options `some(v)`/`none`/`is_some`/`unwrap`, `print`, `syscall`,
top-level `def` plus capture-free hoisting. Imports are spliced
inline (no runtime maps); see `NATIVE.md` for the rejection list and why.

Also: `c ? a : b`; `print(a, b, ...)`; a block whose last statement ends
in `;` is void; default parameter values (`def f(n, acc = 1)`) and tail
calls through a function's own name; `type A = {...}` aliases and record
unions `A | B` taken apart with `match`; `s[i]` (a `byte`) and `s[lo:hi]`
on strings; `c'a'` byte literals; slice assignment `a[lo:hi] = b` (see
`NATIVE.md`).
