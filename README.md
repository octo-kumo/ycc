# y — the Y compiler

A compiler for **Y**, a small statically-checked systems language, and
its **1:1 copy in C**. Both compilers build on Linux x86-64 and emit
*static* ELF executables using only their own assembler and ELF writer —
no cc, no as, no ld, and no VM: a Y program is compiled straight to
machine code.

```console
$ make            # builds ./cycc, the C copy of the compiler
$ make ycc        # builds ./ycc and verifies it against the reference
$ printf 'print("hello, world");\n' > /tmp/hello.y
$ ./ycc /tmp/hello.y -o /tmp/hello && /tmp/hello
hello, world
```

`make ycc` is the acceptance gate: the C copy must produce a
**byte-identical** compiler to the reference binary in `refs/` (see
`refs/SHA256SUMS`), and `ycc` must self-compile byte-identically.

## The language

Y is deliberately small: `let`/`def`, structural records, dynamic maps,
homogeneous heap arrays, options, pointers, closures, unions with `match`.
Some highlights:

```y
// arrays: + copies, += and *= mutate in place, = aliases
let xs = [1, 2, 3];
xs += 4;              // push:               [1, 2, 3, 4]
xs *= 0;              // prepend:            [0, 1, 2, 3, 4]
xs += [9, 10];        // append elements:    [0, 1, 2, 3, 4, 9, 10]
let ys = xs + [11];   // a NEW array; xs untouched

// the target of an assignment family is evaluated exactly once
let grid = [[1, 2], [3, 4]];
let f = def() -> long { print("called"); 0 };
grid[f()] += 1;       // f() runs ONE time

// records and arrays are reference values
let r = { nums: [1, 2] };
let s = r;
s.nums += 3;          // r.nums sees it

// `null` is gone: `none` is the empty option, `x!` unwraps
let a: long? = none;
print(a == none);
```

The full formal definition — grammar, type system, and the exact
operator/aliasing semantics — lives in **`docs/`** (LaTeX, built with
Tectonic — `cd docs && tectonic -X build`; it was last built with
Tectonic 0.17).

## Usage

```text
ycc [-o OUTPUT] [-S] [-t] [-g] [--no-exec] [-h] FILE
  (no flags)   compile FILE to a native executable (default: a.out)
  -o OUTPUT    output path (executable, or .s file with -S)
  -S           emit assembly only (stdout, or the -o file)
  -t, --time   per-phase timing table on stderr
  -g           add a symbol table, DWARF line info and section headers
               so perf, gdb, valgrind and addr2line show function names
               and source lines (the loaded code is unchanged)
  --no-exec    omit exec() -- the binary cannot reach a shell
  -h, --help   show this text and exit
```

FILE is required: with no input file `ycc` exits 1 with
`error: no input file (see ycc -h)`.

`./cycc` takes exactly the same flags — it is the same compiler.

## Layout

| path | contents |
|---|---|
| `src/y/` | the compiler, in Y (`ycc.y` driver, `lexer.y`, `parser.y`, `rename.y`, `types.y`, `native.y`, `arch_x64.y`, `enc64.y`, `asm.y`, `elf.y`, `dwarf.y`, `std/`) |
| `src/c/` | the 1:1 copy in C (`PORTING.md` is the contract; `yv.c` is the value model) |
| `docs/` | the formal language definition (LaTeX/Tectonic) |
| `refs/` | reference binaries for the byte-identical port gate (currently `cycc`'s own output — see `PORTING.md`) |
| `test/` | `test/sh/` suites + `test/y/` programs (`native/`, `audit/`, `examples/`, `ycc/`) |
| `bench/` | compile-time/runtime benchmarks + `compare.sh` |

## Building and testing

```console
$ make              # gcc -> cycc (the C copy)
$ make ycc          # cycc -> ycc, then: cmp ycc refs/ycc.ref + fixpoint
$ make test         # the port gate + all twelve suites in test/sh/
$ ./test/sh/run_all.sh port native   # a subset (suite names: port native
                                     # native-examples examples audit ycc-units
                                     # ycc fixpoint loops comprehensive debug
                                     # stdin-eof)
```

`make asan` builds an ASan+UBSan `cycc-asan` for crash hunting.

When you change `src/y/*.y`, make the **same change** in `src/c/` (they
are kept in lockstep — that is what "1:1 copy" means, see
`PORTING.md`), then `make ycc` and `make test` must stay green.

## Contributing

`AGENTS.md` is the project guide (workflow, style rules, benchmarking
policy). Performance-relevant changes are proposed, benchmarked on a
branch with `bench/compare.sh`, and decided by the numbers.
