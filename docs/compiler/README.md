# How ycc works

This is the compiler tour: one page that tells you what happens between a `.y`
file and an executable, where each step lives, and what to read next. It is for
someone who can program and knows a little about systems, but has not written a
compiler before. Nothing here changes the language specification or the
compiler's behavior; it is a map of the real implementation.

If you only remember one thing:

> ycc is a self-hosting compiler with a small front end, a generated AST/type
> model, a compact eight-word machine IR, and its own assembler plus
> ELF/PE/kernel/wasm writers. The phases are explicit in the source; the
> generated code only hides *boilerplate*, not the architecture.

## The whole pipeline

The main native path is:

```text
  source text (.y)
        |
        |  import splicing, meta-block expansion (meta.y)
        v
  one expanded source string + an Origin map          resolve.y: native_resolve_x
        |
        |  lexer.tokenize
        v
  [Tok]                                               lexer.y
        |
        |  parser.parse_program
        v
  Block of Node                                      parser.y, ast_schema.y
        |
        |  infer_params.infer_program
        v
  Block (missing parameter types filled)             infer_params.y
        |
        |  native.y strip_ns
        v
  Block (module-qualified names)                      native.y
        |
        |  rename.rename_program_x
        v
  Block (unique $N names, aliases resolved)           rename.y
        |
        |  types.check_program
        v
  diagnostics + the checker's binding table           types.y
        |
        |  escape.esc_unit, then lifetime.life_analyze
        v
  region/lifetime decisions + diagnostics             escape.y, lifetime.y
        |
        |  lint.lint_unit
        v
  warnings (never part of the emitted bytes)          lint.y
        |
        |  emit_one_fn -> gen_go dispatch -> IR builders
        v
  packed machine IR: [long], 8 words per item         native.y, ir.y
        |
        |  link_units: prune, relabel, optimize, obfuscate
        v
  linked [LinkPart] (IR or text + relocations)        native.y, asm.y
        |
        |  asm.y / enc64.y (x86-64) or enc_a64.y (AArch64)
        v
  bytes
        |
        |  elf.elf_build / pe.pe_build / kelf.kelf_build
        v
  ELF / PE / kernel image
```

The web target uses the same front end and the same IR, then a different final
stage:

```text
  linked [LinkPart]
        |
        |  wasm_link.wasm_assemble
        |     wasm_link pass 1/classify/chunk
        |     wasm_lower.wl.lowering (IR forms -> wasm instructions)
        |     wasm_enc.we (module sections)
        v
  WebAssembly module  ->  src/web/yhost.js (Node/browser host)
```

Two deliberate details that surprise new readers:

* **There is no separate parse-only AST file.** `Node` is generated from
  [`src/y/ast_schema.y`](../../src/y/ast_schema.y) by the meta block in
  [`src/y/ast_nodes.y`](../../src/y/ast_nodes.y). The schema is the thing to read.
* **There is no separate IR object hierarchy.** IR items are flat `[long]`
  records, eight words each (`IR_W` in [`src/y/ir.y`](../../src/y/ir.y)).
  [`src/y/ir_schema.y`](../../src/y/ir_schema.y) describes the forms and
  [`src/y/ir.y`](../../src/y/ir.y) renders them back to mnemonics.

## The front end, step by step

### 0. Resolve imports and expand meta blocks

**Input:** a path and its text. **Output:** one expanded source string, the
imports, the std units to link, and an `Origin` map from expanded lines back to
files.

The driver reads the root file, then calls
[`native_resolve_x`](../../src/y/resolve.y#L59). That calls
[`resolve_unit`](../../src/y/resolve.y#L77), which:

1. handles a `NAME.TARGET.y` overlay,
2. runs [`meta_prepare`](../../src/y/native.y#L127), which invokes the meta pass
   in [`src/y/meta.y`](../../src/y/meta.y) and splices imports,
3. records which std units the program names (`fs`, `json`, ...),
4. returns a `Resolved { src, imports, origin, std, pkgs, ogen }`.

Read: [`native_resolve_x`](../../src/y/resolve.y#L59),
[`meta_prepare`](../../src/y/native.y#L127), and then
[`meta.y`](../../src/y/meta.y). `--emit=source` prints this stage. The rest of
`resolve.y` is the source overlay, the word scan that decides which std units a
program names, and the origin map; the meta pass itself is in `native.y`.

### 1. Lexing

**Input:** expanded source text. **Output:** `[Tok]`, where
`Tok = { t, v, line, col, off, end }`.

[`lexer.tokenize`](../../src/y/lexer.y#L535) drops comments, decodes string,
byte-string, character and f-string literals, and turns a malformed literal into
a `ferr` token so the parser can report it at the right place. The language
server uses `tokenize_lsp`, which keeps comments and spans.

Read: [`lexer.y`](../../src/y/lexer.y), then inspect a tiny stream with
`./ycc --dump=tokens file.y`.

### 2. Parsing

**Input:** `[Tok]`. **Output:** `Block`, whose `stmts` are `Node`s.

[`parser.parse_program`](../../src/y/parser.y#L2536) is a hand-written
recursive-descent parser. It handles declarations, statements, expressions,
types, match arms and the desugarings for `?.`, `!`, arrow functions and
`spawn { ... }`. The AST shape names (`Bin`, `Call`, `Decl`, `Func`, ...) come
from the schema, not from a hand-written class hierarchy.

Read: [`parser.y`](../../src/y/parser.y), the node table in
[`ast.md`](generated/ast.md), and `./ycc --dump=ast file.y`.

### 2b. Parameter type inference

**Input:** the syntax `Block`. **Output:** the same tree with missing
`Func.ptypes` filled where the source implies them.

A def may omit a parameter annotation:

```y
def add(a, b) -> long { a + b };
print(add(2, 3));
```

[`infer_params.infer_program`](../../src/y/infer_params.y) is the post-parse
pass that fills those types. A missing type can come from a literal at a call
site or from a body expression whose other operand is a literal (`a + 1` implies
`long`). Body hints are applied first, call-site hints in source order, and a
type is never overwritten. A `=>` arrow is the exception: its parameters are
typed by the call context, not by hints in its body (`Func.arrow` records the
distinction). The parser calls this once at the end of
`parse_program`, so the tree handed to the next phase is already inferred; the
pass is still separate code with its own tests.

Read: [`infer_params.y`](../../src/y/infer_params.y) and
[`literal_type.y`](../../src/y/literal_type.y). The parser's former
parameter-inference globals and helpers no longer exist.

### 3. Namespace normalization (`strip_ns`)

**Input:** parsed `Block`. **Output:** `Block` with package references rewritten
into the compiler's internal qualified names.

[`strip_ns`](../../src/y/native.y#L1999) is not name resolution yet. It makes
module references unambiguous (`json.parse` stays qualified as one internal
name), strips type names out of the namespace too, and leaves the tree otherwise
alone. It is in `native.y` because that is where the import set and the target
are known.

Read: [`strip_ns`](../../src/y/native.y#L1999), then
`./ycc --dump=renamed file.y` to see the combined effect with the next pass.

### 4. Name resolution and uniquification (`rename`)

**Input:** `Block` from `strip_ns`. **Output:** `Block` in which every binding has
a unique name.

[`rename.rename_program_x`](../../src/y/rename.y#L809) walks scopes once, gives
each definition a name like `x$7`, rewrites every reference to that binding,
resolves type aliases, drops `type` declarations that are no longer needed, and
fills in default arguments at call sites. The checker and emitter can then use a
flat name space and never re-implement lexical scope.

Read: [`rename.y`](../../src/y/rename.y), and run
`./ycc --dump=renamed file.y`.

### 5. Type checking

**Input:** renamed `Block` and the symbols of imported units. **Output:** a list
of `Diag` errors and the checker's final binding table.

[`types.check_program`](../../src/y/types.y#L4785) is the static checker. It
first collects top-level signatures so mutual recursion works, then checks the
program against those signatures. The checker is also where `none`, option
narrowing, array homogeneity, record exactness, pointer rules and the
`const`/place rules are enforced. It does not rewrite the tree; later phases ask
the checker for types through `bind_type`/`expr_type`.

Read: [`types.y`](../../src/y/types.y), and run
`./ycc --dump=types file.y`.

### 6. Escape and lifetime analysis

**Input:** checked `Block`. **Output:** region/lifetime diagnostics and the
summaries used by later units.

[`escape.esc_unit`](../../src/y/escape.y#L1203) proves whether references made
inside an explicit `region` can escape it and wraps eligible loop bodies
automatically. [`lifetime.life_analyze`](../../src/y/lifetime.y#L355) proves that
repeated allocations can be reclaimed; with `--gc=never` (the default), an
unproved reclamation is an error rather than a leak.

Read: the comments at the top of [`escape.y`](../../src/y/escape.y) and
[`lifetime.y`](../../src/y/lifetime.y). This is the phase most readers should
treat as "advanced" and come back to after the core pipeline is clear.

### 7. Linting

**Input:** checked `Block` plus the checker's bindings. **Output:** warnings.

[`lint.lint_unit`](../../src/y/lint.y#L52) produces warnings only; it never
changes the bytes. It is also the source of `--warnings=fix`'s safe edits.

Read: [`lint.y`](../../src/y/lint.y) when you need a diagnostic, not while
learning the pipeline.

## The back end, step by step

`native.y` is still the backend's main file: it owns unit preparation,
emission and linking. Source resolution and overlays were the first split out
(`resolve.y`); the top of `native.y` has a section map, and the steps below say
which part owns each transition. There is no need to finish a directory
reorganization before reading it.

### 8. Emission to machine IR

**Input:** checked, named `Block`. **Output:** `EmitSt`, whose `bodies` are
`[[long]]` IR streams and whose `labels` name the functions.

[`compile_unit`](../../src/y/native.y#L10047) hoists functions, assigns labels,
collects globals, fixes return types, then calls
[`emit_one_fn`](../../src/y/native.y#L9186) for each function. Expression
emission goes through the generated dispatch in
[`src/y/native_dispatch.y`](../../src/y/native_dispatch.y): check the node's `k`,
cast to its exact shape, call `gen_bin`, `gen_call`, `gen_if`, and so on.

The IR is built by [`src/y/ir.y`](../../src/y/ir.y): every item is a form id plus
seven operand words. The schema in
[`src/y/ir_schema.y`](../../src/y/ir_schema.y) defines each form's operand
kinds. Generated `F_*` and `O_*` constants live in `ir_forms.y`.

Read: [`native.y`](../../src/y/native.y), [`ir.y`](../../src/y/ir.y), the
[dispatch table](generated/dispatch.md), and
`./ycc --dump=ir file.y`. The generated
[`ir.md`](generated/ir.md) is the complete form list.

### 9. Linking the units and optimizing

**Input:** the program's `Unit`, the linked std/package units, and the target
settings. **Output:** `[LinkPart]`, the final mixture of IR and raw text.

[`link_units`](../../src/y/native.y#L10837) computes the reachable bodies,
relabels, applies [`optim.optimize`](../../src/y/optimize.y#L232) to each body,
optionally runs the obfuscation layer, and adds the architecture's prelude/text
blocks. The std pack already contains compiled `Unit`s; the runtime assembly is
stored as IR/text blocks in `src/y/arch/*.s` and decoded by `arch_blocks`.

Read: [`link_units`](../../src/y/native.y#L10837),
[`optimize.y`](../../src/y/optimize.y), and the top of
[`src/y/arch_x64.y`](../../src/y/arch_x64.y). `--dump=ir-opt` shows one unit's
bodies after this optimization.

### 10. Assembling

**Input:** `[LinkPart]`. **Output:** machine-code bytes and relocation results.

For x86-64, [`asm.ycc_assemble`](../../src/y/asm.y#L2532) drives
[`asm_assemble`](../../src/y/asm.y#L564): it classifies parts, lays out sections,
fixes labels, and calls the encoder in
[`src/y/enc64.y`](../../src/y/enc64.y). AArch64 uses
[`src/y/enc_a64.y`](../../src/y/enc_a64.y) and `a64_listing`.

Read: [`asm.y`](../../src/y/asm.y) and just enough of
[`enc64.y`](../../src/y/enc64.y) to see one instruction's bytes.

### 11. Writing the executable

**Input:** code bytes, rodata, bss length, symbols and debug sections. **Output:**
a file.

[`asm_assemble`](../../src/y/asm.y#L564) selects the writer:

* [`elf.elf_build`](../../src/y/elf.y#L46) for Linux ELF,
* [`pe.pe_build`](../../src/y/pe.y#L234) for Windows PE32+,
* [`kelf.kelf_build`](../../src/y/kelf.y#L69) for a kernel image.

`-g` adds symbols, DWARF (via [`dwarf.y`](../../src/y/dwarf.y)) and section
headers. Without `-g`, the ELF still has program headers but deliberately no
section table; `readelf -l` works, `readelf -S` reports none.

Read: [`elf.y`](../../src/y/elf.y) first. PE and kernel images are variations on
the same handoff.

### 12. The web backend

**Input:** the same `[LinkPart]`. **Output:** a `.wasm` module plus a site.

[`wasm_link.wasm_assemble`](../../src/y/wasm_link.y#L626) classifies code and
data labels, chunks the program, and lowers IR forms through
[`src/y/wasm_lower.y`](../../src/y/wasm_lower.y); the module is encoded by
[`src/y/wasm_enc.y`](../../src/y/wasm_enc.y). The JavaScript side is
[`src/web/yhost.js`](../../src/web/yhost.js), which supplies the runtime,
filesystem, network and browser APIs the Y program expects.

Read: [`wasm_link.y`](../../src/y/wasm_link.y) and
[`TARGETS.md`](../TARGETS.md). `--emit=wat` prints the module's text listing;
`--emit=wasm` writes the binary.

## Data structures you will meet

| name | where | what it is |
|---|---|---|
| `Tok` | [`lexer.y`](../../src/y/lexer.y) | token tag, text, line/column, byte span |
| `Node` | generated by [`ast_nodes.y`](../../src/y/ast_nodes.y) from [`ast_schema.y`](../../src/y/ast_schema.y) | exact-record union for every AST shape |
| `Type` | generated by [`type_nodes.y`](../../src/y/type_nodes.y) from [`type_schema.y`](../../src/y/type_schema.y) | exact-record union for every type shape |
| `Origin` | [`resolve.y`](../../src/y/resolve.y) | expanded-line -> source-file/line map used by diagnostics |
| `Unit` | [`native.y`](../../src/y/native.y) | a compiled unit: exports, bodies, labels, rodata, summaries |
| `EmitSt` | [`native.y`](../../src/y/native.y) | emitter state: current body, label table, frame, functions |
| `[long]` IR | [`ir.y`](../../src/y/ir.y) | flat instruction stream, 8 words per item |
| `LinkPart` | [`asm.y`](../../src/y/asm.y) | one linked piece: IR + text, or raw assembly text |
| `Diag` | [`types.y`](../../src/y/types.y) | `{ msg, line, col }` used by errors and warnings |

## Reading order

If you have never written a compiler, read in this order:

1. [`src/y/resolve.y`](../../src/y/resolve.y) — imports, overlays and the
   origin map (read the entry points, not every helper).
2. [`src/y/lexer.y`](../../src/y/lexer.y) — characters to a token list.
3. [`src/y/ast_schema.y`](../../src/y/ast_schema.y) — what a node can be.
4. [`src/y/parser.y`](../../src/y/parser.y) — tokens to those nodes.
5. [`src/y/infer_params.y`](../../src/y/infer_params.y) — post-parse
   parameter type hints.
6. [`src/y/rename.y`](../../src/y/rename.y) — one scope, unique names.
7. [`src/y/types.y`](../../src/y/types.y) — what the checker proves.
8. [`src/y/ir_schema.y`](../../src/y/ir_schema.y) and
   [`src/y/ir.y`](../../src/y/ir.y) — the eight-word machine IR.
9. [`src/y/native.y`](../../src/y/native.y) — AST to IR (start at
   `emit_one_fn`, then follow `gen_go`).
10. [`src/y/asm.y`](../../src/y/asm.y) and
   [`src/y/enc64.y`](../../src/y/enc64.y) — IR to bytes.
11. [`src/y/elf.y`](../../src/y/elf.y) — bytes to an ELF file.

You do not need to understand meta blocks, escape analysis, obfuscation, the
pack format or the LSP before you understand that path. They are features built
around it, not prerequisites.

## Inspecting the pipeline

The compiler can print every major intermediate stage:

```console
$ ./ycc --dump=tokens  example.y
$ ./ycc --dump=ast     example.y
$ ./ycc --dump=renamed example.y
$ ./ycc --dump=types   example.y
$ ./ycc --dump=ir      example.y
$ ./ycc --dump=ir-opt  example.y
$ ./ycc --emit=asm     example.y
$ ./ycc --emit=source  example.y    # after meta expansion and import splicing
```

`--dump` prints to stdout and writes no executable. It is intentionally separate
from `--emit`, which writes the compiler's actual output (assembly, source, wasm
or the executable). The `--dump` views are implemented in
[`src/y/dump.y`](../../src/y/dump.y); they consume the same structures the
compiler consumes and do not change code generation.

The generated pages beside this one are produced from the schemas:

* [`generated/ast.md`](generated/ast.md) — every `Node` shape and field.
* [`generated/types.md`](generated/types.md) — every `Type` shape and field.
* [`generated/ir.md`](generated/ir.md) — every IR form and operand encoding.
* [`generated/dispatch.md`](generated/dispatch.md) — AST kind -> handler.

Regenerate them with `make compiler-docs`; verify they are current with
`make compiler-docs-check`.

## One program, all the way through

[`walkthrough.md`](walkthrough.md) traces `let x = 1 + 2; print(x);` from source
text through tokens, AST, renamed AST, types, IR, assembly, instruction bytes and
the final ELF's program headers. Read it with this page open.

[`examples/`](examples/) has ten one-feature programs (literal, expression,
variable, function, if, loop, array, record, closure, union/match), each with the
stage to inspect first. They are small enough to read beside a dump.

## Tests that are also small lessons

Several existing fixtures are shorter than a tutorial and already assert the
representation they show:

* [`test/y/ycc/test_parser.y`](../../test/y/ycc/test_parser.y) — tokenize a tiny
  program, parse it, and walk `Decl`, `Func`, `Call`, `Leaf` and `Bin` nodes.
* [`test/y/ycc/test_lexer.y`](../../test/y/ycc/test_lexer.y) — the token stream
  for declarations, calls and operators.
* [`test/y/ycc/test_ir_wire.y`](../../test/y/ycc/test_ir_wire.y) — the packed
  eight-word IR and its renderer.
* [`test/y/ycc/test_parser_params.y`](../../test/y/ycc/test_parser_params.y) —
  where parse-time parameter inference stops and `=>` arrows differ.
* [`test/y/ycc/test_optimize.y`](../../test/y/ycc/test_optimize.y) — a small IR
  body before and after the final-link optimizer.

They are run by the `ycc-units` suite, so they stay honest while you read them.

## Where to make a change

| you want to change... | start here |
|---|---|
| tokens, literals, comments | [`lexer.y`](../../src/y/lexer.y) |
| grammar or parse-time desugaring | [`parser.y`](../../src/y/parser.y) |
| imports, overlays, source-origin maps | [`resolve.y`](../../src/y/resolve.y) |
| an AST shape | [`ast_schema.y`](../../src/y/ast_schema.y), then regenerate/rebuild |
| a type or type rule | [`type_schema.y`](../../src/y/type_schema.y), [`types.y`](../../src/y/types.y), [`type_rules.y`](../../src/y/type_rules.y) |
| missing parameter type inference | [`infer_params.y`](../../src/y/infer_params.y) |
| name resolution / shadowing | [`rename.y`](../../src/y/rename.y) and `strip_ns` in [`native.y`](../../src/y/native.y) |
| a region or lifetime rule | [`escape.y`](../../src/y/escape.y), [`lifetime.y`](../../src/y/lifetime.y) |
| a warning | [`lint.y`](../../src/y/lint.y) |
| how one AST node is emitted | [`native.y`](../../src/y/native.y), the `gen_*` for that node |
| an IR form | [`ir_schema.y`](../../src/y/ir_schema.y), then [`ir.y`](../../src/y/ir.y), [`enc64.y`](../../src/y/enc64.y) and the web lowering |
| an optimization | [`optimize.y`](../../src/y/optimize.y) |
| x86-64 encoding | [`enc64.y`](../../src/y/enc64.y) |
| AArch64 encoding | [`enc_a64.y`](../../src/y/enc_a64.y) |
| ELF sections/headers | [`elf.y`](../../src/y/elf.y) |
| PE images | [`pe.y`](../../src/y/pe.y) |
| kernel images | [`kelf.y`](../../src/y/kelf.y) |
| wasm module | [`wasm_link.y`](../../src/y/wasm_link.y), [`wasm_lower.y`](../../src/y/wasm_lower.y), [`wasm_enc.y`](../../src/y/wasm_enc.y) |
| the JS host | [`src/web/yhost.js`](../../src/web/yhost.js) |

Before changing compiler behavior, read [`AGENTS.md`](../../AGENTS.md): it has
the build/test loop, the 4 GB cap, the bootstrap rules and the verification
targets.

## A note on generated code

`ast_nodes.y`, `type_nodes.y`, `ir_forms.y`, `native_dispatch.y` and the other
`*_dispatch.y` files are short because a meta block expands into ordinary Y
declarations. That is not a trick to avoid learning the model; it is how the
compiler keeps one schema as the source of truth. When a generated file looks
empty, read the schema it imports and the generator it calls:

* `ast_nodes.y` -> `ast_schema.y` + `shape_codegen.y`
* `type_nodes.y` -> `type_schema.y` + `shape_codegen.y`
* `ir_forms.y` -> `ir_schema.y`
* `native_dispatch.y` -> `dispatch_schema.y` + `dispatch_codegen.y`
* `check_dispatch.y`, `lint_dispatch.y` -> the same dispatch generator

The generated Markdown pages are there so you do not need to expand a meta block
in your head to see the result.
