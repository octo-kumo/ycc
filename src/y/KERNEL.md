# `ycc --kernel` — a freestanding Y kernel

`ycc --kernel prog.y -o prog.elf` compiles a Y program to an **ELF32
Multiboot-1 payload** that `qemu-system-x86_64 -kernel prog.elf` boots on
bare metal: no Linux, no libc, the serial port for output.  It is a
*target*, not a mode on top of Linux — `res_target` becomes `"kernel"`
(target.y), and everything downstream that would otherwise assume an OS
changes behind one predicate.

```
$ ./ycc --kernel test/kernel/t001_hello.y -o /tmp/hello.elf
$ qemu-system-x86_64 -kernel /tmp/hello.elf -serial stdio -display none
hello from a Y kernel
42
```

## The image

`kelf.y` writes it; `arch_x64.y`'s `kernel_head_text` is its first bytes.

```
file offset 0     ELF32 EHDR (52) + two PHDR (32 each)
       116        Multiboot header (12 bytes: magic 0x1BADB002, flags 0,
                  checksum) -- within the first 8 KB, as the spec wants
       128        _start: the 32-bit trampoline (a byte blob)
       ...        page tables (3 x 4 KB, 2 MB identity pages, first 1 GB)
                  and a flat 64-bit GDT
       ...        y_kernel_entry64: 64-bit, sets the stack, calls
                  y_kernel_main (the program's top level)
       ...        the program: the arch prelude, the bodies, the rodata
       page after  .bss (R+W, no file bytes): globals, the IDT, the kernel
                  stack, the heap arena
```

Two PT_LOAD segments, both mapped at 1 MB.  Multiboot loaders start an
image in 32-bit protected mode, so the entry is 32-bit code that builds
paging, sets PAE/LME/PG and far-jumps into long mode — the one thing that
cannot be written in the in-tree assembly, whose encoder (`enc64.y`) is
x86-64-only.  The trampoline is therefore a byte blob, transcribed from
`experiments/kernel/boot.s` (the same payload assembled by GNU as), with
the page-table, GDT and entry addresses patched to where this image
actually puts them; `kernel_head_text` computes them from the blob's own
length, so moving anything is not a silent miscompile.

An image is ~17 KB, most of it the page tables.

## The runtime

`arch/kernel.s` replaces the blocks of `arch/prelude.s` that reach a
kernel — the same `#=== replace: NAME ===` mechanism `wsys.s` uses for
Windows, applied by `arch_x64.y`'s `arch_replaced_lines`:

| block | kernel version |
|---|---|
| `y_alloc_map` | a bump through `y_kheap`, a 16 MB `.bss` arena |
| `y_os_write` | every byte out COM1 (so `print`/`puts` work unchanged) |
| `y_os_read` | one byte in, blocking on the 16550 |
| `y_os_exit` | `jmp y_kernel_halt` |
| the five traps | print the message to COM1 and stop |

and adds what a kernel has and a hosted program does not: `y_serial_init`
/ `_putb` / `_getb` / `_write_raw`, the 8259 `y_pic_remap` / `y_pic_eoi`,
`y_kernel_sti`/`_cli`, `y_kernel_halt` (`cli; hlt; jmp`) and
`y_kernel_idle` (`sti; hlt; jmp`).

The rest of the prelude — the string, array and float cores — is pure
computation and is used as it is.  A kernel that never allocates never
touches the arena: the tree shaker drops what the program does not call,
exactly as for a hosted program.

## `irq N def` — interrupt handlers in Y

```y
import kernel;

irq 4 def serial_rx() -> void {      // 4 is the 8259 LINE, not the vector
    let c = kernel.getc();
    kernel.putc(c);
};

kernel.init();          // COM1, the PICs, the IDT
kernel.serial_irq_on(); // IER bit 0
kernel.idle();          // sti; hlt; loop
```

`irq` is a top-level declaration that exists **only** in kernel mode:
`parse_stmt` gates it on `target_is_kernel()`, so in every other compile
`irq` is an ordinary identifier and nothing about the parser changes.
`N` is the line, 0..15 — what the hardware numbers, what
`std/kernel.y`'s `IRQ_*` constants name and what a datasheet calls IRQ4 —
and the +32 remap to IDT vectors is the compiler's business.

The path runs through all four stages:

* **parser** (`parse_irq_def`) records `(line, name)` in `target.y`'s
  `res_irqs`; two handlers on one line, or one name on two lines, is an
  error before either reaches the emitter.
* **checker** (`check_irq_def`, types.y) requires **no parameters** and a
  **void** result — the generated stub calls the handler from the
  interrupt entry with nothing to pass and nowhere to put an answer — and
  refuses a handler nested inside another def, which would be emitted at
  its creation site where the stub could not reach it.  An omitted
  `-> void` whose body is void passes.
* **emitter** records the handler's emitted label (`res_irq_stubs`) and
  makes it a **body-shake root**: the stub that calls it is generated
  text the shaker cannot see, so without that root the body is dropped
  and the stub names nothing.
* **codegen** (`kernel_irq_text`, arch_x64.y) writes, per declared line, a
  stub that saves the caller-saved registers, aligns the stack, calls the
  handler, acknowledges the 8259 (slave first for IRQ8-15) and `iretq`s —
  plus `y_kernel_irq_init`, which fills all 256 IDT entries with a
  stop-the-machine default, installs the declared vectors and loads the
  IDT.

Known limits, all deliberate for a PoC: the SSE state is not saved (the Y
backend only touches XMM in float code, and no handler here floats), only
the 8259 path is wired (no APIC/MSI, no IOAPIC), exceptions beyond the
`irq` lines land on the default stub, and `-g` is refused (the debug
writers are ELF64/DWARF64).

## What a kernel cannot import

`native_resolve_seen` refuses the std units that are a Linux syscall away
from working, and `resolve_unit` stops auto-linking `prelude` and `exec`:

    fs net exec prelude crypto x509 tls http tui args random test

Each gets a one-line reason (`kernel_std_why`), because "not available"
without one reads as a compiler limitation.  A deny list, not an allow
list: a std unit that is plain computation (json, regex, math, struct,
utf8) is available in a kernel the day it lands.

`std/kernel.y` is the other direction: it is `ndef`s into
`arch/kernel.s` — assembly only a kernel image has — so a hosted compile
refuses `import kernel` and says so.  Both rules fire only when the file
`std_resolve` found **is** the std one: a program's own `kernel.y` or
`fs.y` beside it shadows std and stays its own business.

`std/kernel.y` also defines one constant per 8259 line (`IRQ_TIMER` …
`IRQ_ATA2`), the surface (`init`, `serial_irq_on`, `eoi`, `sti`, `cli`,
`halt`, `idle`, `putc`, `getc`) and nothing else.

## Cost to a normal compile

Nothing observable.  Everything is behind `target_is_kernel()`:
`make corpus-diff BASE=refs/ycc.ref NEW=./ynew` over the whole corpus
reports 0 programs that compile to different code, and `make ynew`'s
generations 2 and 3 stay byte-identical.  The new encoder arms sit at the
end of `enc_insn`'s string ladder, past `ret`, so a line pays for them
only if it reaches the end without matching.

## Testing

`test/sh/test_kernel.sh` (`test/kernel/`), in `make test` as the `kernel`
suite.  Each `t*` case is compiled by both the built compiler and the C
copy (byte-identical images and `-S` listings), then **booted** under
qemu with its `.stdin` fed a second in, and its serial output compared to
its `.expected`.  `e*` cases are compiled with `--kernel` and must print
every `// expect-error:` line they carry; `h*` are the same without
`--kernel`.  No qemu, or a compiler without `--kernel`, skips.

The hand-written reference for the boot path is
`experiments/kernel/boot.s` + `link.ld`: the same trampoline, IDT and
serial code assembled by GNU as, which is where the trampoline's bytes
come from and how they were validated before any of this was in the
compiler.
