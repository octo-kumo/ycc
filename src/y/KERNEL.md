# `ycc --kernel` — a freestanding Y kernel

*(What is missing, what the language cannot express yet, and how much work
each remaining piece is: `KERNEL-ROADMAP.md`.)*

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

The trampoline sets CR4 to PAE | OSFXSR | OSXMMEXCPT.  The last two are
not optional: without OSFXSR every SSE instruction is `#UD`, and the Y
backend uses XMM for every float operation, so `print(1.0 * 2.0)` stopped
the machine at its first `movq %rax,%xmm0` while `print(7.0)` (a literal,
passed in a GPR) worked.  A hosted program never sees this because Linux
sets both before entering user space.

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
  stop-the-machine default, installs the declared vectors, **unmasks the
  declared lines** (one mask byte per 8259, computed from the program's
  declarations -- `y_pic_remap` leaves them all masked, and a slave line
  also opens the master's cascade) and loads the IDT.

## The CPU's exceptions

Vectors 0..31 get their own generated stubs, not the default: each saves the
caller-saved registers, pushes its vector and the CPU's error code (a dummy
zero where the CPU pushes none) and calls `y_kernel_trap(vec, err)`.  A
fault is not resumed from — the handler reports and stops the machine — so
there is no `iretq` on this path, and `std/kernel.y`'s handler prints the
vector, the error code, CR2 for `#PF` and a name for `#GP`.

`y_kernel_trap` is the one hook a *bare* kernel gets: the compiler emits a
halting default when no unit defines the label, and any def with that name
replaces it (it is a root for the body shaker, because the stub that calls
it is generated text the shaker cannot see).  `test/kernel/t007_fault.y`
provokes a page fault and checks the report.

## Physical and virtual memory

`std/kernel.y` carries both, and neither is assembly:

* **the address layout**, and why it is what it is.  A user program is a
  Linux executable linked at `0x400000`, so that address has to be free in
  a process's address space; the kernel therefore maps **one 2 MB page**
  for itself (image, stack, IDT, all below 2 MB) and reaches every other
  physical byte through a **direct map** at `0xFFFF888000000000`:

  | region | virtual | in every address space |
  |---|---|---|
  | user | `0x400000` and up | per process |
  | kernel image | `0x100000`–`0x200000` (PD[0]) | yes, supervisor |
  | direct map | `0xFFFF888000000000` + physical | yes, supervisor |

  That is why the 16 MB `.bss` heap arena is gone: it put the image's end
  18 MB up, straight through where user space wants to be, and it is why
  every address space is built as "the kernel's `PD[0]`, the direct map,
  and the process's own low half" (`vm_new_dir`).
* **two address conventions**, which is the one thing to keep straight:
  `peek64`/`poke64`/`peek32`/`peek8`/`poke8` take **physical** addresses
  (page tables, the Multiboot structures, another process's pages), and
  `peek_va64`/`poke_va64` take a **virtual** address in the current
  address space (the kernel's own image, and a task's memory while running
  on its `CR3` — what a syscall's user copy needs).  The Y heap's own
  pointers are direct-map virtual addresses, set up that way by
  `y_heap_init`.
* **raw access** is pointer arithmetic on one global anchor (`mem_word`).
  Y has no address-to-pointer conversion (`KERNEL-ROADMAP.md` §3, item 2),
  so this is the workaround until a cast exists.  Two alignment facts are
  load-bearing and commented in the file: the physical-address mask is bits
  12..51 (NOT `2^52-1`, which keeps the low twelve flag bits and makes the
  walk read a misaligned word), and the Multiboot memory map's `u64` fields
  are 4-aligned.
* **physical memory**: the Y heap owns the last 8 MB of RAM and physical
  pages are handed out from the image's end up to the heap's first byte
  (`phys_init`, `page_alloc`, `pages_alloc`, `phys_free_bytes`).  `start`
  clears the loader's **command line** and every **Multiboot module** —
  QEMU puts the initrd in RAM too, and an allocator that starts at the
  image's end hands the initrd out as if it were free (the first version
  handed the command line out as a page; read `cmdline`, `mods_count` and
  `mods_addr`).
* **when the heap is chosen, and the rule that follows from it**: the
  region is picked lazily, by `y_heap_init`, on the *first* allocation —
  because a kernel program's globals can allocate before its top level
  runs.  That first allocation can therefore happen inside ANOTHER
  module's global initializer, before the hoisted global-init code has run,
  so `y_heap_init` and everything it calls must read **no Y global and no
  `const`** — a const's cell is a global like any other and reads zero.
  (The first version read `HEAP_BYTES` as 0, fell into its floor branch,
  and then faulted storing into a page below 2 MB.)  Literals, `y_*_get`
  asm accessors, and functions that obey the same rule only.
* **`kexit(code)`** leaves qemu through the `isa-debug-exit` device
  (port 0x501); the device applies `(code << 1) | 1`, so a `kexit(7)` is a
  runner status of 15.  That is the kernel test harness's verdict path —
  a freestanding payload has nobody to return a status to.
* **virtual memory**: the four-level walk (`vm_slot`, `vm_map`,
  `vm_map_range`, `vm_unmap`, `vm_translate`), address spaces
  (`vm_new_dir`, `vm_switch`, `vm_current`) and `vm_flush`.  Large pages
  are understood, because the kernel's own 1 GB is 512 2 MB pages: a walker
  that reads a `PS` entry as a table address walks into the mapped memory
  itself.  A fresh address space copies the kernel's `PDPT[0]` and starts
  everything above it unmapped — sharing `PML4[0]` itself, which was the
  first version, shares the whole subtree and gives the second space the
  first one's user pages.

The machine primitives under all of it are in `arch/kernel.s`: `y_cr3_get`,
`y_cr3_set`, `y_cr2_get`, `y_invlpg` (four instructions each, three of them
a raw `.ascii` because the encoder has no control-register operand) and
`y_mb_info_get`/`y_kernel_end_get` (three each).

## Known limits

Deliberate for a PoC, and each with its cost in `KERNEL-ROADMAP.md` §4:
the SSE state is not saved across an interrupt (the Y backend only touches
XMM in float code); only the 8259 path is wired (no APIC, no IOAPIC, no
MSI); a fault stops the machine rather than being resumed (so no demand
paging or copy-on-write yet); the physical allocator never frees; the
direct map covers the first 1 GB (a bigger guest needs a second PDPT
entry); a kernel program must call `kernel.init()` (or reach no global
initializer that allocates) before its first allocation, because the heap
region is chosen lazily; there is no ring 3, no scheduler, no filesystem;
and `-g` is refused (the debug writers are ELF64/DWARF64).

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
its `.expected`.  A case with a `.exit` file ends in `kexit` and qemu's
own status is checked too (`x001_kexit`: `kexit(7)` is a status of 15).
Every image is also held to a **256 KB budget** — the kernel must stay
inside its one 2 MB page — and `t008_heap` pins the layout the rest
depends on (the heap in RAM above the image, the page region below it,
nothing overlapping).  `e*` cases are compiled with `--kernel` and must
print every `// expect-error:` line they carry; `h*` are the same without
`--kernel`.  No qemu, or a compiler without `--kernel`, skips.

The hand-written reference for the boot path is
`experiments/kernel/boot.s` + `link.ld`: the same trampoline, IDT and
serial code assembled by GNU as, which is where the trampoline's bytes
come from and how they were validated before any of this was in the
compiler.

## Un-merge, then move changes in one at a time (the plan taken up again)

The branch is reset to `28285c4` -- the last state BEFORE the first upstream
merge -- and the kernel works there: the minimal program prints "minimal".
Everything after it is preserved in the tag `pre-unmerge`.

The order of events, read off the first-parent chain rather than remembered:
round 10's dedup (`28285c4`) -> merge #1 (`76ddb02`, the collector) -> MY M2
work (fork/wait4, preemption, the collector handling, the entry patch) ->
merge #2 (`14938e9`, --gc) -> the rest.  So the reset set my own kernel work
aside too, and that is the point of the tag: it is all recoverable by
cherry-pick.

The plan, which is the one asked for:

1. cherry-pick MY commits back one at a time (they were green before the merges
   and are the kernel's own features), building and running test/kernel after
   each -- that restores M2 on the clean base;
2. then cherry-pick the UPSTREAM commits the two merges brought, one at a time,
   building and running after each -- until the kernel image stops printing
   "minimal".  That commit is the one that breaks it, named rather than
   bisected by guesswork;
3. then either fix that commit's effect (with its src/c twin) or leave it
   unmerged with a note, and resume M3.

This is strictly better than the file-level bisect: every step is a commit that
compiles on its own, so the interdependency that defeated the hunk-level bisect
does not arise.

### Round 41: the culprit is one of FOUR emitter commits, and files cannot be swapped alone

The upstream commits that touch src/c/native.c between the pre-merge base and
master's tip are exactly four, and master's tip is an ancestor of the tag (the
merge-base IS 9078372), so nothing else is in play:

    ee66a02  pointer arithmetic
    51c36a5  whole-heap mark-sweep collector (+ stop linking it where unused)
    64f7556  call a literal closure directly when it captures nothing
    9078372  --gc, so a program that cannot grow does not link the collector

Tried: substitute just the emitter files from 64f7556 into the green base.  It
does not build -- `error: assemble: undefined label 'y_gc_stack_top'` -- because
that commit's emitter expects the arch prelude's y_gc_* cells, which arrive with
51c36a5.  The emitter and the arch prelude move TOGETHER, so the one-file
substitution that worked at FILE level does not work at COMMIT level here.

Next, and it is the reliable form: cherry-pick those four commits onto the green
base one at a time -- each brings its whole file set, so the coupling is
satisfied -- resolving conflicts in favour of this branch's kernel work, and
running test/kernel after each.  The first that turns the kernel image red names
the culprit.  Note that master's tree cannot simply be taken wholesale: `--kernel`
is this branch's, so master has no such flag at all (a wholesale checkout of
src/y or src/c answers "unknown flag '--kernel'").
