# y compiler

A compiler and VM for a simple C-like programming language with first-class functions, arrays, maps, and type inference.

## Features

- **Parser**: Recursive descent parser producing an AST
- **Type checker**: Hindley-Milner style type inference
- **VM**: Tree-walking interpreter for quick testing
- **Native compilation**: Compiles to C, then to native binaries via gcc

## Quick start

```bash
make
./yboot test/y/examples/pi.y              # Run in VM
./yboot --compile test/y/examples/pi.y -o pi_bin  # Compile to native binary
./pi_bin                              # Run the compiled binary
```

## Usage

```
Usage: ./yboot [OPTIONS] [FILE]

Options:
  -c, --compile [OUTPUT]  Compile to native binary (default: a.out)
  -S, --emit-c [OUTPUT]   Emit C source only (default: stdout)
  -o OUTPUT               Output file path
  -h, --help              Show this help

Without options, runs the program in the built-in VM.
```

### Examples

```bash
# Run in VM (shows AST, type check, and result)
./yboot test/y/examples/helloworld.y

# Compile to native binary
./yboot --compile test/y/examples/helloworld.y -o hello
./hello

# Emit C source for inspection
./yboot -S test/y/examples/math.y > math.c

# Compile all examples
for f in test/y/examples/*.y; do
  ./yboot --compile "$f" -o "$(basename $f .y)_bin"
done
```

## Language

The language is C-like with braces, plus some JS/TS-inspired features:

```js
// Variables
let x = 42;
const y = 3.14;

// Functions (first-class)
def add(a: long, b: long) -> long {
    a + b
};

// Anonymous functions
let square = def(n: long) { n * n };

// Arrays and slicing
let arr = [1, 2, 3, 4, 5];
let first = arr[0];
let slice = arr[1:3];  // [2, 3]

// Maps
let map = {name: "alice", age: 30};
let name = map.name;

// Recursion via `self`
def factorial(n: long) -> long {
    if (n == 0) { 1 } else { n * self(n - 1) }
};

// Higher-order functions
def apply(f: (long) -> long, x: long) -> long {
    f(x)
};

// Built-ins
print("hello");
let s = tostring(42);
let r = range(10);  // [0, 1, 2, ..., 9]
```

See `lang.md` for the full language specification.

## Architecture

### Compilation pipeline

```
.y source → Parser → AST → Type checker → Code generator → C source → gcc → binary
```

### Components

- **parser.c**: Recursive descent parser (1081 lines)
- **ast.c/h**: AST node definitions and utilities
- **typecheck.c**: Type inference and checking
- **vm.c**: Tree-walking interpreter
- **codegen.c**: C code generation backend (NEW)
- **src/c/runtime.c/h**: Runtime library for compiled programs (NEW)

### Code generation

The compiler translates the AST into C source code that links against `src/c/runtime.c`. The generated code uses:

- **GCC statement expressions** `({ ... })` for expression-oriented semantics
- **Heap-allocated values** with a tagged union (`YValue`)
- **Lexical scoping** via linked-list scopes with reference counting for closures
- **First-class functions** as C function pointers + closure environments

The runtime provides:
- Value constructors and destructors
- Arithmetic and comparison operators
- Array/map operations (indexing, slicing, field access)
- Function call machinery
- Built-in functions (print, tostring, typeof, range)

## Limitations

- No garbage collection (manual memory management in runtime)
- Limited error messages
- Modules via source-to-source imports (`import m from "./x.y"`, paths relative
  to the importing file; `export {...}` must be the last statement)
- Type inference is incomplete for some edge cases
- Closures capture entire scopes, not individual variables

## Testing

```bash
make test         # everything: full yboot→cycc→ycc chain + all suites
make test-fast    # all suites except the ycc chain (ycc suites self-skip)
make test-ycc     # full ycc chain + self-hosted check only
make test-compile # tiny smoke: compile + run helloworld
```

Suites live in `test/sh/` (run `./test/sh/run_all.sh [suite ...]` to pick a
subset — e.g. `./test/sh/run_all.sh audit examples`):

| suite          | script                    | what it checks                              |
|----------------|---------------------------|---------------------------------------------|
| loops          | `test_loops.sh`           | loops + precedence/audit regressions        |
| comprehensive  | `test_comprehensive.sh`   | builtins, operators, functions, error cases |
| examples       | `test_examples.sh`        | every `test/y/examples/*.y`, VM vs compiled |
| audit          | `test_audit.sh`           | all 65 `test/y/audit/t*.y`, VM vs compiled  |
| ycc-units      | `test_ycc_units.sh`       | every `test/y/ycc/test_*.y` runs in the VM  |
| ycc            | `test_ycc.sh`             | self-hosted `ycc` matches `yboot` output    |
| native         | `test_native.sh`          | `test/y/native/*.y` → static ELF → run (no toolchain) |

Every suite compares VM (`-q`) vs compiled-binary behavior — a change must
pass in **both**. `test_audit.sh` documents its known divergences inline
(`expect_for`); don't extend that allowlist to hide a new divergence.
The `native` suite instead compiles to real x86_64 assembly
(`ycc -S`, no C, no `YValue`) and checks program output — see
`src/y/NATIVE.md` for the backend roadmap and `test/y/native/` for the corpus.

## Implementation notes

### Why C as an intermediate language?

Generating C instead of assembly or LLVM IR lets us:
- Leverage gcc's optimizer and platform support
- Keep the codebase simple (no complex IR)
- Produce readable intermediate output for debugging
- Support any platform gcc supports

### Expression-oriented compilation

The language is expression-oriented (every construct returns a value). We use GCC's statement expressions to compile this naturally:

```c
// y: let x = if (cond) { 1 } else { 2 };
// C:
YValue *x = ({ YValue *_c = cond; YValue *_r;
               if (_c->data.b) { _r = y_mk_long(1); }
               else { _r = y_mk_long(2); }
               _r; });
```

### Function compilation

Named functions become static C functions. Anonymous functions and closures work via:
1. Emit a static C function with a unique name
2. Wrap it in a `YValue` with a closure scope pointer
3. At call time, create a new scope with the closure as parent

Recursion uses a special `self` binding in the function's scope.

## License

MIT (or whatever yun prefers)

## Credits

Original parser, VM, and type checker by yun.
C code generation backend by hermes.
