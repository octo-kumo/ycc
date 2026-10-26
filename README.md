# ycc — the Y compiler

> ycc might mean 'y code compiler' or 'yun's crappy compiler' or 'y compiler collections'
> The original version is over here: https://github.com/octo-kumo/compiler , it has a VM that interprets Y 

A self-hosting compiler for **Y**, a small, statically checked systems
language. `ycc` compiles a Y program straight to a *static* executable with its
own assembler and its own ELF/PE writers: no cc, no as, no ld and no VM at
run time. The compiler is written in Y; a generated C seed (`bootstrap/ycc.c`)
lets you build it from nothing but GCC.

The same compiler builds:

- **Linux** x86-64 (the default) and AArch64 ELF executables,
- **Windows** PE32+ executables (`--target=win`),
- **WebAssembly** modules for Node or a web page (`--target=web`), with a
  JavaScript host that behaves like a small Linux kernel,
- freestanding **kernel images** (`--target=kernel`), and with them **Y-OS**, a small
  Unix-like operating system written in Y (`os/`).

## Quick start

Requirements: Linux x86-64, GCC and the Boehm collector (`libgc.so.1`, e.g. the
`gc` / `libgc1` package). Python 3, qemu, Node and Tectonic are only needed by
some of the optional targets and test suites.

```console
$ make            # GCC builds ./cycc from the generated C seed
$ make ycc        # cycc builds ./ycc, which must reproduce itself byte for byte
$ printf 'print("hello, world");\n' > hello.y
$ ./ycc hello.y -o hello && ./hello
hello, world
$ ./ycc run hello.y
hello, world
```

A built `ycc` is self-contained: the standard library and the runtime travel
precompiled inside the binary, so you can copy it anywhere.

## The language

Y is deliberately small: `let`/`def`, structural records, maps, homogeneous
arrays, options, pointers, closures, unions with `match`, threads, and
compile-time code generation with `#{ … }#` meta blocks.

```y
// arrays: + copies, += and *= mutate in place, = aliases
let xs = [1, 2, 3];
xs += 4;              // push:               [1, 2, 3, 4]
xs *= 0;              // prepend:            [0, 1, 2, 3, 4]
xs += [9, 10];        // append elements:    [0, 1, 2, 3, 4, 9, 10]
let ys = xs + [11];   // a NEW array; xs untouched

// the target of an assignment is evaluated exactly once
let grid = [[1, 2], [3, 4]];
let f = def() -> long { print("called"); 0 };
grid[f()] += 1;       // f() runs ONE time

// records and arrays are reference values
let r = { nums: [1, 2] };
let s = r;
s.nums += 3;          // r.nums sees it

// there is no null: `none` is the empty option, `x!` unwraps
let a: long? = none;
print(a == none);
```

Memory is managed without a collector by default: the compiler checks
allocation lifetimes, gives temporary work its own regions, and rejects a
repeated allocation it cannot prove is reclaimed (`--gc=auto` opts into a
collector instead).

The full definition (grammar, type system, standard library, targets, Y-OS)
is the manual in `docs/`, built with Tectonic: `make docs`.

## Usage

```text
ycc [OPTIONS] FILE
ycc run [OPTIONS] FILE [-- ARG...]
ycc build [OPTIONS] [DIR]
ycc vendor [DIR]
```

`./ycc -h` prints every option. The most useful:

| option | what it does |
|---|---|
| `-o PATH` / `--output=PATH` | the output file |
| `--target=linux\|win\|kernel\|web` | the OS to build for (default `linux`) |
| `--arch=x64\|aarch64` | the instruction set (default: the host's; Linux only) |
| `--emit=asm\|source\|wasm\|wat` | assembly, expanded source, the wasm module, or a wasm listing (default: the executable; a site on web) |
| `-O speed\|size` / `--optimize=` | the one optimization goal (speed by default) |
| `-g` / `--debug` | symbols, DWARF line tables and section headers for gdb, perf and valgrind |
| `-W`, `--warnings=none\|default\|extra\|all\|fix` | diagnostics, and safe lint fixes applied in place |
| `--gc=never\|auto\|always\|stress` | checked lifetimes without a collector (default), or a collector |
| `-p` / `--pack[=METHOD]` | a self-decompressing executable |
| `--ob[=MODE]` | an obfuscated, sealed and encrypted executable (Linux and Windows) |
| `--time` | a per-phase timing table |

## Projects and packages

A project is a directory with a `y.toml`:

```toml
[package]
name = "app"                  # required
lib = "src/lib.y"             # optional: what importers of app get

[bin]                         # the programs: build/app from src/main.y
app = "src/main.y"

[dependencies]
json = { path = "../json" }
http = { git = "https://example.com/http.git", rev = "v1" }
```

`ycc build` compiles every package once and caches its object until its
source, the compiler, or an interface it depends on changes. Git dependencies
are pinned in `y.lock`; `ycc vendor` copies them into `vendor/`.
`ycc build --target=web` writes a deployable site.

## Examples

`examples/` holds larger programs written in Y. They predate the checked
lifetime default, so build them with the collector:
`./ycc --gc=auto examples/NAME/NAME.y -o NAME`.

| example | what it is |
|---|---|
| `bignum` | arbitrary-precision integers and a calculator |
| `cube` | a rotating wireframe or shaded cube in the terminal |
| `donut` | the spinning ASCII torus |
| `editor` | a vi-style modal terminal editor |
| `httpsrv` | an HTTP server with a live dashboard, and its client |
| `life` | Conway's Game of Life |
| `mandelbrot` | a threaded Mandelbrot explorer |
| `perft` | chess move-tree counting over a pool of threads |
| `raytracer` | a reflective ray tracer in a terminal framebuffer |
| `toolkit-cli` | base64, CSV and JSON tools (`toolkit_cli.y`) |
| `x11` | the X11 wire protocol over a raw socket, no Xlib |

`make os && make run-os` boots Y-OS under qemu with these programs in `/bin`
(`make run-os-gui` for the graphical desktop).

## Repository layout

| path | contents |
|---|---|
| `src/y/` | the compiler (`ycc.y` is the driver) and its runtime assembly (`arch/`) |
| `src/y/std/` | the standard library (`fs`, `net`, `http`, `tls`, `json`, `regex`, `gui`, `tui`, `math`, …) |
| `src/web/` | the JavaScript host for `--target=web` |
| `src/c/`, `bootstrap/`, `tools/bootstrap/` | the generated C seed and its runtime (`PORTING.md`) |
| `src/tools/lsp/` | `yserve`, the language server, and the VS Code extension |
| `src/tools/ytest/` | `ytest`: the test framework, every suite and tool |
| `os/` | Y-OS: kernel modules, userland, filesystem builder |
| `docs/` | the manual (LaTeX) and `TARGETS.md` (target ABIs) |
| `examples/` | example programs |
| `test/`, `bench/` | test corpora and benchmarks |
| `tools/` | obfuscation audit, key server and remote-execution prototypes |

## Building and testing

```console
$ make help             # every target
$ make test             # the 15 fast suites
$ make test-slow        # the 16 slow suites
$ make test-all         # all 31
$ ./ytest list          # the suite names; ./ytest port native runs a subset
```

The first test run blesses the `./ycc` you built as the reference compiler
(`refs/ycc.ref`), which later builds are compared against. Some suites need
extra tools (qemu for `kernel`/`os`/`aarch64`, Node for `web`, an X server or
Xvfb for `gui`) and skip without them. Windows executables are tested on a
real Windows machine (`make pe-test`, configured by `pe-vm.conf.example`).

Every build and test runs under a 4 GB address-space cap
(`test/sh/capped.sh`).

## Contributing

`AGENTS.md` is the contributor guide: the workflow, the code style, the
development loop (`make ynew ytest`, `make rebless`) and the measurement
policy. `PORTING.md` covers the C seed and how to refresh it.

## License

MIT; see `LICENSE`.
