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
./compiler examples/pi.y              # Run in VM
./compiler --compile examples/pi.y -o pi_bin  # Compile to native binary
./pi_bin                              # Run the compiled binary
```

## Usage

```
Usage: ./compiler [OPTIONS] [FILE]

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
./compiler examples/helloworld.y

# Compile to native binary
./compiler --compile examples/helloworld.y -o hello
./hello

# Emit C source for inspection
./compiler -S examples/math.y > math.c

# Compile all examples
for f in examples/*.y; do
  ./compiler --compile "$f" -o "$(basename $f .y)_bin"
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
- **runtime.c/h**: Runtime library for compiled programs (NEW)

### Code generation

The compiler translates the AST into C source code that links against `runtime.c`. The generated code uses:

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
- No module system (single-file programs only)
- Type inference is incomplete for some edge cases
- Closures capture entire scopes, not individual variables

## Testing

```bash
make test              # Run leftfold example in VM
make test-compile      # Compile and run helloworld

# Test all examples
for f in examples/*.y; do
  echo "=== $f ==="
  ./compiler --compile "$f" -o /tmp/test_bin && /tmp/test_bin
done
```

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
