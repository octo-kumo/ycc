# One program through ycc

This is a complete trace of one deliberately tiny program:

```y
let x = 1 + 2;
print(x);
```

Every intermediate listing below was produced by the compiler in this checkout
with the `--dump` stages and `--emit=asm` described in
[the compiler tour](README.md). The program is small enough that the whole path
fits on one page; the parts that are omitted are runtime code the program links
but does not call directly, and they are marked as such.

The point is not that `1 + 2` is interesting. The point is that every arrow in
the pipeline has a concrete representation you can inspect.

## 0. Source

```y
1  let x = 1 + 2;
2  print(x);
```

There are no imports and no meta blocks, so the resolver's output is the same
text, with an origin map saying line 1 and line 2 belong to `x.y`.

## 1. Tokens

Command:

```console
$ ./ycc --dump=tokens x.y
```

Output:

```text
# stage: tokens (after meta expansion and import splicing)
# line:col  kind    value
1:1  kw      "let"
1:5  id      "x"
1:7  op      "="
1:9  num     "1"
1:11 op      "+"
1:13 num     "2"
1:14 punct   ";"
2:1  id      "print"
2:6  punct   "("
2:7  id      "x"
2:8  punct   ")"
2:9  punct   ";"
2:10 eof     <eof>
```

`print` is an identifier token, not a keyword: it is a builtin resolved by the
checker/emitter, not a reserved word. The lexer has already decoded the values;
the quotes in the dump are the dump's, not the source's.

Entry point: [`lexer.tokenize`](../../src/y/lexer.y#L535).

## 2. AST

Command:

```console
$ ./ycc --dump=ast x.y
```

Output:

```text
# stage: AST (after meta expansion, import splicing and parsing)
# positions are line:col in the spliced source; names are source names
Block 2 statement(s)
├─ Decl let "x" @1:1
│  └─ value: Binary "+" @1:11
│     ├─ left: Number "1" @1:9
│     └─ right: Number "2" @1:13
└─ Call @2:6
   ├─ callee: Identifier "print" @2:1
   └─ arg 0: Identifier "x" @2:7
```

The top-level `Block` has a `Decl` (`let x = ...`) and a `Call` (`print(x)`).
The `Decl`'s value is a `Bin`; the call's callee is a `Leaf` holding the name
`print`. Notice that the parser has not decided that `x` is a global or that
`print` is a builtin. It has only built syntax.

The positions are positions in the expanded source. With imports, the same
line number can belong to a different file; the compiler keeps an `Origin` map
for diagnostics and for `--emit=source`.

Entry point: [`parser.parse_program`](../../src/y/parser.y#L2536). The shape
names come from [`ast_schema.y`](../../src/y/ast_schema.y); see
[generated/ast.md](generated/ast.md).

## 3. Renamed AST

Command:

```console
$ ./ycc --dump=renamed x.y
```

Output:

```text
# stage: renamed AST (after strip_ns and rename.rename_program_x)
# positions are line:col in the spliced source; every binding has a unique $N name
Block 2 statement(s)
├─ Decl let "x$1" @1:1
│  └─ value: Binary "+" @1:11
│     ├─ left: Number "1" @1:9
│     └─ right: Number "2" @1:13
└─ Call @2:6
   ├─ callee: Identifier "print" @2:1
   └─ arg 0: Identifier "x$1" @2:7
```

Only one thing changed: every binding has a unique name. `x` became `x$1`, and
the use of `x` in `print(x)` was rewritten to the same `x$1`. This is what lets
later passes work without carrying lexical scopes around. `print` is not
renamed because it is a builtin, not a program binding.

In a real program you would also see package names normalized by `strip_ns`
(for example, a module-qualified name becomes one internal name) and calls to
functions with default arguments filled in.

Entry points: [`strip_ns`](../../src/y/native.y#L1999) and
[`rename.rename_program_x`](../../src/y/rename.y#L809).

## 4. Types

Command:

```console
$ ./ycc --dump=types x.y
```

Output:

```text
# stage: types (after strip_ns, rename and check_program)
# name : type — the checker's final flat bindings; $N names are rename's
x$1 : long
```

The checker inferred `long` for `x` from the literal `1` (and checked that `+`
accepts the operands). `print` is an intrinsic, so it is not in the program's
binding output; its accepted argument types are checked at the call.

There is no annotated AST rewriting here. The checker returns diagnostics and
leaves a flat binding table (`bind_type` reads it) that later phases and the
dump use.

Entry point: [`types.check_program`](../../src/y/types.y#L4785).

## 5. Escape and lifetime decisions

There are no allocations in this program, so escape/lifetime analysis has
nothing to prove or reject. In a program with a `region`, a loop that allocates,
or a returned reference, this is the phase that decides whether the program is
accepted under the default checked, no-collector mode.

Entry points: [`escape.esc_unit`](../../src/y/escape.y#L1203) and
[`lifetime.life_analyze`](../../src/y/lifetime.y#L355).

## 6. Machine IR

Command:

```console
$ ./ycc --dump=ir x.y
```

Output:

```text
# stage: machine IR (after emit_fns, before final-link optimization)
# each instruction is eight words internally: a form id and seven operands;
# this listing uses ir.y's mnemonic renderer, not the packed numbers.

# function _start
_start:
    mov %rsp, y_gc_stack_top(%rip)
    push %rbp
    mov %rsp, %rbp
    call yfn_4000000202_init
ygiS_yg_0_x$1:
    mov $1, %rax
    add $2, %rax
    mov %rax, yg_0_x$1(%rip)
ygiE_yg_0_x$1:
    mov yg_0_x$1(%rip), %rax
    push %rax
    call y_print_long
    add $8, %rsp
    xor %eax, %eax
yL_2_0:
    mov $231, %rax
    xor %edi, %edi
    syscall
```

Read it as four groups:

1. **Process entry.** `_start` records the stack top, sets up a frame, and calls
   the generated init function. `yfn_4000000202_init` is empty for this
   program; it exists because the program's top level is emitted like a
   function.
2. **Global initialization.** Top-level `let x` becomes a global cell. The
   `ygiS_...` / `ygiE_...` labels bracket the window in which `x` is
   initialized, which matters to the runtime's root tracking.
3. **The expression and the call.** `mov $1,%rax` and `add $2,%rax` compute
   `3`; the store writes it to `x`'s cell. The load, `push`, `call
   y_print_long`, and `add $8,%rsp` are a normal call: the caller pushes the
   argument and pops it after the return.
4. **Exit.** `mov $231,%rax` is `exit_group` on Linux x86-64; `xor %edi,%edi`
   makes the status 0; `syscall`.

The IR is a flat `[long]` stream. For example, the `mov $1, %rax` item is the
form `F_MOV_I_R` followed by its immediate, register and width fields, then
padding to eight words. [`ir.y`](../../src/y/ir.y) is the only thing that turns
those words back into this text. The form table is in
[generated/ir.md](generated/ir.md).

Entry points: [`emit_one_fn`](../../src/y/native.y#L9186) and the generated
dispatch in [`native_dispatch.y`](../../src/y/native_dispatch.y).

## 7. Optimized IR

Command:

```console
$ ./ycc --dump=ir-opt x.y
```

For this program the output is byte-for-byte the same as `--dump=ir`. That is
the honest result: the final-link optimizer has no redundant move, branch or
dead instruction to remove here. Optimization happens in
[`link_units`](../../src/y/native.y#L10837) via
[`optim.optimize`](../../src/y/optimize.y#L232); it is not a separate AST pass.

## 8. Assembly

Command:

```console
$ ./ycc --emit=asm x.y
```

The listing starts with the runtime helpers that `print` needs. The generated
part for this program is at the end:

```asm
y_print_long:
    push %rbp
    mov %rsp, %rbp
    push 16(%rbp)
    call y_os_print_int
    add $8, %rsp
yL_4000000091_0:
    mov %rbp, %rsp
    pop %rbp
    ret
yfn_4000000202_init:
    push %rbp
    mov %rsp, %rbp
yL_4000000202_0:
    mov %rbp, %rsp
    pop %rbp
    ret
_start:
    mov %rsp, y_gc_stack_top(%rip)
    push %rbp
    mov %rsp, %rbp
    call yfn_4000000202_init
ygiS_yg_0_x$1:
    mov $1, %rax
    add $2, %rax
    mov %rax, yg_0_x$1(%rip)
ygiE_yg_0_x$1:
    mov yg_0_x$1(%rip), %rax
    push %rax
    call y_print_long
    add $8, %rsp
    xor %eax, %eax
yL_2_0:
    mov $231, %rax
    xor %edi, %edi
    syscall
```

The omitted part before this contains `y_os_write` and `y_os_print_int`: the
runtime's write and decimal-print helpers. They are ordinary assembly functions
linked beside the program, not compiler magic. The `.text`, `.rodata` and `.bss`
directives at the end of the full listing define the three sections the writer
lays out.

`--emit=asm` is the text form of the final link's IR/text parts. The real build
does not need this text: it feeds the same parts to the in-process assembler.

Entry points: [`link_units`](../../src/y/native.y#L10837) and
[`asm.ycc_assemble`](../../src/y/asm.y#L2532).

## 9. Instruction bytes

With `-g`, the writer keeps section headers and symbols, so a disassembler can
show the bytes. The code is the same as the default build; only debug metadata
is added.

```console
$ ./ycc -g x.y -o xg
$ objdump -d --start-address=0x400177 --stop-address=0x4001bb xg
```

Relevant lines:

```text
400187: b8 01 00 00 00        mov    $0x1,%eax
40018c: 48 83 c0 02           add    $0x2,%rax
400190: 48 89 05 49 20 00 00  mov    %rax,0x2049(%rip)   # <x>
400197: 48 8b 05 42 20 00 00  mov    0x2042(%rip),%rax   # <x>
40019e: 50                    push   %rax
40019f: e8 b5 ff ff ff        call   400159 <y_print_long>
4001a4: 48 83 c4 08           add    $0x8,%rsp
4001a8: 31 c0                 xor    %eax,%eax
4001aa: b8 e7 00 00 00        mov    $0xe7,%eax
4001af: 31 ff                 xor    %edi,%edi
4001b1: 0f 05                 syscall
```

The encoder chose the shortest forms:

* `b8 01 00 00 00` is `mov $1,%eax`. Writing `%eax` zero-extends into `%rax`;
  no REX prefix is needed.
* `48 83 c0 02` is `add $2,%rax` with an 8-bit sign-extended immediate.
* `48 89 05 ...` and `48 8b 05 ...` are the RIP-relative store and load. The
  four-byte displacement is the only part the linker has to patch, because the
  final address of `x` is known when the section is laid out.
* `0f 05` is `syscall`.

This is where the IR stops being a data structure and becomes machine opcodes.
The x86-64 encoder is [`enc64.y`](../../src/y/enc64.y); the assembler's layout,
label fixups and section placement are in [`asm.y`](../../src/y/asm.y).

## 10. The executable

The default Linux build writes a static ELF with two `PT_LOAD` segments and,
without `-g`, no section table:

```console
$ ./ycc x.y -o x
$ readelf -l x
```

```text
Elf file type is EXEC (Executable file)
Entry point 0x400177
There are 2 program headers, starting at offset 64

Program Headers:
  Type           Offset             VirtAddr           PhysAddr
                 FileSiz            MemSiz              Flags  Align
  LOAD           0x0000000000000000 0x0000000000400000 0x0000000000400000
                 0x00000000000001bb 0x0000000000001000  R E    0x1000
  LOAD           0x0000000000000000 0x0000000000402000 0x0000000000402000
                 0x0000000000000000 0x00000000000001e8  RW     0x1000
```

The first segment maps the file's code and read-only data executable. The
second maps zero-filled `.bss` writable; that is where `x` and the runtime's
cells live. The entry point is `_start`; the kernel enters there with the
process's initial stack, and the program exits through the `exit_group`
syscall above.

The default build is 443 bytes. Running it prints the expected value:

```console
$ ./x
3
```

With `-g`, the file also carries `.symtab`, `.strtab`, `.shstrtab`,
`.debug_info`, `.debug_abbrev` and `.debug_line`. The code and data are
unchanged; only the metadata and section headers are added.

Entry point: [`elf.elf_build`](../../src/y/elf.y#L46). For the other targets,
the same handoff goes to [`pe.pe_build`](../../src/y/pe.y#L234) or
[`kelf.kelf_build`](../../src/y/kelf.y#L69); for web, to
[`wasm_link.wasm_assemble`](../../src/y/wasm_link.y#L626).

## 11. The same program on the web target

The front end and IR are the same. Only the final link differs:

```console
$ ./ycc --target=web --emit=wat x.y | head
```

The web backend lowers the machine IR to WebAssembly instructions and emits a
module. [`wasm_link.y`](../../src/y/wasm_link.y) classifies code vs. data and
lays out chunks; [`wasm_lower.y`](../../src/y/wasm_lower.y) maps IR forms to
wasm; [`wasm_enc.y`](../../src/y/wasm_enc.y) writes the binary sections. The
page or Node launcher supplies the host functions through
[`src/y/web/yhost.js`](../../src/web/yhost.js).

## The whole trace in one table

| stage | representation | produced by | inspect with |
|---|---|---|---|
| source | text + origin map | resolver / meta pass | `--emit=source` |
| tokens | `[Tok]` | `lexer.tokenize` | `--dump=tokens` |
| syntax | `Block` of `Node` | `parser.parse_program` | `--dump=ast` |
| resolved names | `Block` with qualified names | `strip_ns` | `--dump=renamed` |
| unique names | `Block` with `$N` bindings | `rename.rename_program_x` | `--dump=renamed` |
| checked program | diagnostics + binding table | `types.check_program` | `--dump=types` |
| machine IR | `[long]`, eight words/item | `emit_one_fn` + `gen_go` | `--dump=ir` |
| optimized IR | the same packed stream | `optim.optimize` at link | `--dump=ir-opt` |
| linked parts | `[LinkPart]` | `link_units` | `--emit=asm` |
| bytes | `[byte]` | `asm.y`, `enc64.y` | `objdump -d` with `-g` |
| image | ELF/PE/kernel/wasm | `elf.y`, `pe.y`, `kelf.y`, `wasm_link.y` | `readelf` / `file` |

If you can follow this table for a program you wrote, you can find the code
responsible for each transformation. That is the intended payoff.
