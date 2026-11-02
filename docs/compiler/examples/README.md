# Small compiler examples

These are deliberately one-feature programs for use with the
[compiler tour](../README.md) and the [walkthrough](../walkthrough.md). They are
not showcase applications; `examples/` at the repository root has those.

For each file, try:

```console
$ ./ycc --dump=tokens  docs/compiler/examples/04-function.y
$ ./ycc --dump=ast     docs/compiler/examples/04-function.y
$ ./ycc --dump=renamed docs/compiler/examples/04-function.y
$ ./ycc --dump=types   docs/compiler/examples/04-function.y
$ ./ycc --dump=ir      docs/compiler/examples/04-function.y
```

| file | what to look for |
|---|---|
| `01-literal.y` | a `Leaf` node and a generated call to the print runtime |
| `02-expression.y` | `Bin` nesting and operator precedence in the AST |
| `03-variable.y` | a global cell and a compound assignment |
| `04-function.y` | `Decl` -> `Func`, a call, and the callee's machine IR |
| `05-if.y` | `If.has_else`, branch labels in the IR |
| `06-loop.y` | `ForRange`, a loop label and a back edge |
| `07-array.y` | `ArrLit`, the `+=` lowering, and heap/region rules |
| `08-record.y` | `RecLit`, field offsets and `Dot` |
| `09-closure.y` | a captured binding and closure conversion; an escaping closure would need `--gc=auto` or a proved region |
| `10-union-match.y` | `Narrow`/`MatchEnd` and record-union layout |

The programs use the default checked, no-collector mode; none of them repeats
an allocation, so they do not need `--gc=auto`.
