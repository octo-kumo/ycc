# ycc — the Y-lang to C compiler, written in Y

`ycc` is a **self-hosting** compiler for the Y language. It reads Y source,
and emits C that links against the same `runtime.c`/`runtime.h` ABI as the
reference compiler's codegen — so its output binaries are interchangeable
with those produced by the C-implemented compiler.

The defining property: **ycc can compile its own source.**

    # build ycc using the reference C compiler (bootstrap seed)
    ../compiler --compile ycc.y -o ycc

    # now ycc compiles itself
    ./ycc --compile ycc.y -o ycc2

    # ycc2 is behaviourally identical; it too can compile ycc.y
    ./ycc2 --compile ycc.y -o ycc3

## Layout

| file          | role                                                        |
|---------------|-------------------------------------------------------------|
| `ycc.y`       | driver: arg parsing, import resolution, pipeline, gcc exec  |
| `lexer.y`     | source string → token list                                  |
| `parser.y`    | token list → AST (nested maps)                              |
| `codegen.y`   | AST → C source string (targets `runtime.h`)                 |

## Language subset supported

ycc implements the subset of Y it is itself written in (which is enough to
write a compiler): `let`/`const`/`def`, typed params, `if`/`else if`/`else`,
`while`, `for`, `foreach`, `for i in a..b`, arrays, maps, string concat,
indexing/slicing, index assignment, chained indexing `a[i][j]`, dot access
`m.k` and dot-call `m.f(x)`, closures, the full operator-precedence ladder,
and all builtins. `import`/`export` are resolved by the driver before the
lexer sees them (source-to-source, same as the reference compiler).

## Target ABI

Emitted C uses GCC statement expressions and the `YValue` tagged union from
`runtime.h`. See `codegen.y` for the exact emission patterns.
