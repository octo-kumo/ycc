# ycc — the Y compiler, written in Y

`ycc` compiles Y source **straight to native assembly** (Linux x86_64):
unboxed values, static types, no C involved, no runtime to link.
`ycc` itself is built by the C copy of the compiler (`make ycc`, which
also gates the result against `refs/ycc.ref`).

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
| `std/`        | standard library in Y, spliced into compiled programs      |

See `NATIVE.md` for the backend design (representations, pipeline stages,
pointers, arrays, options, closures) and its known limitations.

## Language subset supported (native target)

Statically-typed Y with unboxed values: `let`/`const`/`def` (param
annotations are optional but poison-tolerant — annotate them; return types
are inferred), `if`/`else`, `while`, `for`, `for x in lo..hi`, `foreach`,
`long`/`int` (same), `bool`, `byte`, `float`, `str`, `*T`, `[T; N]`, `[T]`,
`T?`, `&x`, `*p`, `*p = v`, `a[i]`, `&a[i]`, `len(a)`, fixed arrays
`[v; n]`, heap arrays `[v, ...]` grown in place with `+=`/`*=`, options
`some(v)`/`none`/`is_some`/`unwrap`/`x!`, `void`, `print`, `syscall`,
`b"..."`/`c'a'` byte-string and byte literals, `a[lo:hi]` slices and
`a[lo:hi] = b` slice assignment. Top-level `def`s are hoisted; a nested
`def` that captures is closure-converted. Imports are spliced
inline (no runtime maps); see `NATIVE.md` for the rejection list and why.

Also: `c ? a : b`; `print(a, b, ...)`; a block whose last statement ends
in `;` is void (and `{}` is a legal void block); default parameter values
(`def f(n, acc = 1)`); `x++`/`++x`/`--x` and `x op= e` on numbers, strings
and arrays, all evaluating the target exactly once; `type A = {...}`
aliases and record unions `A | B` taken apart with `match`; `s[i]` (a
`byte`) and `s[lo:hi]` on strings; `{K => V}` maps keyed with `m['k']`
(a read is `V?`); `{a: 1, ...b}` record spread.
