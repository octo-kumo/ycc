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


## Open: the merged compiler, not the kernel

Measured 2026-10 on the `kernel` branch:

| compiler | test/kernel |
|---|---|
| `refs/ycc.ref` (blessed before the upstream merges) | **33 passed, 0 failed, 33 total** |
| `./ycc` (after merging `51c36a5` and `9078372`) | 12 passed, 15 failed, **27 total** |

Two things follow, and both change what to work on:

1. **The kernel itself is green.** Every case passes -- M0's layout and `kexit`,
   M1's ring 3 and the ELF loader, M2's fork/wait4/preemption -- when the
   compiler that builds them is the pre-merge one.  Nothing in `arch/kernel.s`,
   `arch_x64.y`, `std/kernel.y` or `os/` is the problem the last several rounds
   were chasing.
2. **The merged compiler breaks kernel programs**, and it breaks them twice
   over: six cases are missing entirely (33 -> 27), which means they no longer
   COMPILE, and the rest misbehave (a user-mode read at `cr2=16` from a program
   that prints nothing).  A missing case in this harness is a compile failure,
   not a skip -- the earlier "28 total" readings were this same effect.

Prime suspect is the second merge (`9078372`, `--gc`, "so a program that cannot
grow does not link the collector"), because 23/28 was measured after the first
merge (`51c36a5`) and the number fell after the second.  `--gc=never` for a
kernel target was tried and is NOT the cause (removing the forcing changed
nothing).

Next: compile one case with each compiler and read the DIFFERENCE, in this
order -- (a) the compile failure that loses six cases, (b) the `-S` diff of a
kernel driver's entry and its `y_gc_*`/allocator region.  (a) is the bigger
lever: six cases do not even build.

### Round 25: what it is NOT, and the next single diff

* Every kernel program still COMPILES with the merged `./ycc` -- `t001`..`t011`
  all build cleanly (`-o` to a real path; `-o /dev/null` fails with "writing
  '/dev/null' failed", which is a red herring that cost a round).  So the
  33 -> 27 case count is not a compile failure, and the six absent cases are
  something else in the harness's counting.
* What fails is every case that BOOTS: 15 of 15 (`t001`-`t009`, `t011`,
  `u001`-`u004`, `x001`).  The 12 that pass are `t010` and the `e*`/`h*` reject
  cases, which never run a kernel image.  So the difference is entirely in the
  kernel IMAGE the merged compiler emits.
* Do NOT instrument inside `y_heap_init`: `print` allocates, allocation
  re-enters the heap, and the kernel stops booting altogether (measured -- the
  probe printed nothing at all).  The instrumented run must go through the asm
  side or through a cell read after the fact.

Next, and it is one command: `-S` the SAME kernel driver with `refs/ycc.ref` and
with `./ycc`, and diff the emitted body of `y_heap_init` and its callers.  The
asm is identical, the values the probe reads back are wrong, and the kernel
program's own arithmetic (`mem_upper_kb` = 129920, i.e. a correct 128 MB) is
right -- so the miscompile is in the Y-level code that computes `start`/`top`
and calls `y_heap_region_set`.

### Round 26: the "15 failures" were a STALE ./ycc, and what that cost

The kernel suite builds each case with BOTH engines and fails the case when the
two images differ.  `./ycc` is the blessed binary, so after a `src/y` change it
is stale until `make rebless`; `./cycc` is rebuilt by `make cycc` from `src/c`
and is therefore current.  Comparing the two then reports "cycc and ycc images
differ" for EVERY case that runs a kernel image -- 15 of them -- which reads
exactly like a broken kernel and is not one:

    FAIL t001_hello: .../cycc and .../ycc images differ

Both engines' `-S` listings showed why in one diff: the C listing had
`mov %rsp, y_gc_stack_top(%rip)` and the new allocator's text, the Y listing did
not -- because the Y binary predated those commits.

ALWAYS `make rebless` before reading a kernel-suite number after touching
`src/y`, `src/y/std` or `src/arch`.  Two rounds were spent diagnosing a
staleness artifact, including a "the merge regressed it" conclusion.

After `make rebless` (refs/ycc.ref f484a534): 23 passed, 5 failed, 28 total,
with both engines agreeing -- and the 5 are the real ones (t011 and the four
`u*` cases, the user-mode `cr2=16` family).  For comparison, the PRE-merge
blessed compiler builds all 33 cases and all 33 pass, which is what pins the
remaining regression on the post-merge compilers rather than on the kernel.

### Round 27: the five are a truncated text segment (BUGS.md 5)

`t011_ring3`, `u001`-`u004` are one bug, and it is in the compiler, not here:
the ELF writer emits `FileSiz 0x150` for a program whose code is longer, so
everything past it is zero-filled and the program executes zeros.  The fault
signature follows: `err=5` is "present + user" on a read, and since the kernel
maps 0..2 MB for itself with `U/S = 0`, dereferencing a null pointer lands in
the kernel's identity page with exactly that error (cr2 = 0, 0x10 or 0x20 --
the offset of the field being read).  An allocation-free program
(`puts("minimal\n")`) fails identically, and it printed correctly before the
merges, which is what rules out the heap, the collector and the loader.

Do NOT re-derive this: check `readelf -lW` on any program the current compiler
builds, and compare `FileSiz` with the emitted code's size.

### Round 28: BUGS.md 5 withdrawn, and the control to use first

`FileSiz 0x150` is normal: the MAIN tree's compiler (upstream, untouched) emits
the identical layout for the same program, and both binaries run correctly
natively.  A `puts`-only program links almost no runtime.  Always run the main
tree's compiler as a control before believing a compiler bug on this branch --
it would have caught this one and the earlier `CLK_TS` entry too.

What survives: the post-merge kernel IMAGE faults a program that the pre-merge
kernel image runs correctly (round 14: "old kernel + new program" printed
`minimal`), and among the kernel cases only those that ENTER USER MODE fail
(t011_ring3, u001-u004).  So the next thing to diff is the kernel image's
user-entry path -- y_enter_user / y_syscall_entry / the GDT+IDT setup and the
`enter_user` wrapper in std/kernel.y -- between a pre-merge build and the
current one.

### Round 29: the program's FIRST syscall does nothing

RIP for the minimal program's fault is `0x400137` -- the instruction right
after the `syscall` in `_start` -- and a print added at the top of
`sys_exit_group` NEVER FIRED.  So the syscall instruction entered the kernel and
the kernel returned to the program without calling the handler at all: no
output from the program's `write`, no dispatch of `exit_group`, and then the
program runs off the end of its own text into zeroed bytes and faults reading
address 0 (err=5, cr2=0).

That is the strongest lead yet, and it fits every remaining case: the five
failures are exactly the cases that ENTER USER MODE, `t011_ring3`'s expected
output literally begins "syscall entry: true", and the pre-merge kernel image
runs the same post-merge program correctly.  So the merged compiler builds a
kernel image whose SYSCALL path is broken -- `y_syscall_entry` (arch/kernel.s,
shared by both engines) or its setup (`syscall_init`'s MSRs, in std/kernel.y,
which the merged compiler emits).

Next: make the asm stub store the received syscall number into a cell and read
it from the kernel after the fact, or build a pre-merge compiler from git in a
scratch worktree (`git worktree add /tmp/pre 28285c4 && make -C /tmp/pre cycc`)
and diff the emitted `syscall_init`/`enter_user`/stub region -- the control that
has settled every real question on this branch.

### Round 31-32: the compiler is the bug, and the extra prologue line

The control finally ran clean, cheaply (src-only extract, 6 MB):

    pre-merge compiler (/tmp/pre3/src/y/cycc_pre) + CURRENT sources
        -> kernel boots, ring 3, prints "minimal"     WORKS

    current compiler + the same sources
        -> trap vector=14 err=5 cr2=0                 FAILS

So every source on this branch -- arch/kernel.s, arch_x64.y, std/kernel.y,
os/kernel/elfload.y, the drivers, the fixtures -- is correct, and the merged
COMPILER builds the broken kernel image.  That also retires the remaining
suspicion of my own code.

Two emission differences found by diffing the two kernel images routine by
routine (asm bodies identical; all kernel constants correct at runtime:
TASK_READY 2, TASK_DEAD 3, TASK_BLOCKED 4, PHYS_MASK_2M 4503599625273344,
USER_LIMIT 140737488355328, E_NOSYS -38):

1. `y_kernel_main` -- the kernel program's own main, not `_start` -- gains
   `mov %rsp, y_gc_stack_top(%rip)` in the current build.  That is _start-only
   prologue code (native.y's is_main block) being emitted into a KERNEL
   program's main, and with `--kernel` forcing `--gc=never` the collector is
   not linked at all.  Prime suspect: a kernel target should not get that line.
2. `elf_stack`'s emitted `mov $24, %rdi` became `mov $32, %rdi`, which is a
   source change of mine (the multi-argument argv rewrite), not a compiler bug.

Next: make the compiler skip the _start prologue for a kernel target (or emit
it only when the collector is actually linked) and re-run test/kernel.

### Round 33: eliminated, one by one

Still standing: pre-merge compiler + CURRENT sources works; current compiler +
the same sources faults (err=5, cr2=0).  Sources are correct; the merged
compiler's kernel image is not.  Eliminated this round, each by running it:

* the extra `mov %rsp, y_gc_stack_top(%rip)` in y_kernel_main -- suppressed for
  kernel targets and the fault is unchanged, so it is harmless;
* the dropped global-initializer ranges (49 ygiS_ ranges) -- every kernel
  constant reads correctly at runtime (TASK_READY 2, TASK_DEAD 3, TASK_BLOCKED
  4, PHYS_MASK_2M 4503599625273344, USER_LIMIT 140737488355328, E_NOSYS -38);
* the syscall-path asm -- y_syscall_entry, y_enter_user, y_enter_frame,
  y_syscall_entry_addr, y_cur_kstack_set are IDENTICAL between the two compilers;
* the closure bodies that differ -- both are the same `mov $24 -> $32`, which is
  my own multi-argv source change, not a compiler bug.

What is left uncompared is the .bss/cell section and the ORDER of emitted
blocks: `arch_heap_cells()` plus the kernel's own `arch_kernel_bss()`.  A cell
that moved, or a block emitted in a different order, would break assumptions
the shared asm makes about those cells without changing any routine's body.
That is the next diff: compare the two images' data/cell sections, not their
code.

Note: merge #1 alone cannot bisect this -- `--gc` arrives with merge #2, so the
branch at 76ddb02 links the collector and dies with "out of memory" instead,
exactly as it did in round 11.

### Round 34: every allocation request grew by 8 -- and a latent double-count

The systematic difference in the two kernel images is ONE instruction repeated
in every initializer and closure: `mov $24, %rdi` became `mov $32, %rdi` before
`call y_alloc`.  That is the compiler sizing allocation requests to include the
collector's 8-byte block header ("the request must cover them, since y_alloc
hands out at most the bytes asked for").  It is not one source change of mine --
it is in gdt_cells, gdtr_cells, tss_cells, tasks and the closures alike.

Consequence, and it is a real latent bug in this branch: `y_alloc` computes
p = (n+15) & -8, writes the header at the block base and returns base+8, so p
ALREADY covers the header.  arch/kernel.s's bump had been adding 8 of its own
(round 12), double-counting it and shifting every allocation the kernel itself
makes -- its GDT/TSS cells, its task table.  Removing that `add $8` is correct;
it did NOT fix the fault, so it is not the cause, and it is reverted here to be
made deliberately rather than in the middle of a hunt.

Next: the fault survives with the double-count removed, so the remaining
difference is in how the merged compiler's emitted kernel image interacts with
the shared asm at entry -- and the cheapest discriminator left is to compile the
SAME driver with the current compiler and with the pre-merge control, both with
`--gc=never` (the control has no --gc), and diff the .data/.bss sections rather
than the routines.

### Round 35: the bug is in native.c (the emitter) -- bisected by file

Two results, both cheap, and together they end the search for WHERE:

* the current compiler fails in EVERY --gc mode (never, auto, always), while the
  pre-merge control works -- so this is not the collector policy at all;
* taking the WORKING pre-merge control and swapping in the current
  `src/c/arch_x64.c` still WORKS (prints "minimal"), and swapping in the current
  `src/c/native.c` makes it FAULT (err=5, cr2=0).

So the emission bug lives in `src/c/native.c` -- the emitter -- and nowhere else
tested.  Next: diff `/tmp/pre3/src/c/native.c` (extracted from 28285c4) against
the branch's, hunk by hunk, and bisect within that file the same way: copy
hunks in until the control breaks.  The control BINARY (cycc_pre, built before
any substitution) is still pristine even though its source tree now has the
swapped files.

This is the first time the search has been bounded to a single file, and the
method that got there -- extract the src-only tree, build, swap one file,
rebuild, run -- costs about thirty seconds per file.

### Round 36: also eliminated, and the hunk plan

* the shared asm's own collector no-op replace-blocks (my round-15 workaround):
  with --gc=never the COMPILER substitutes stubs for the collector's three
  entry points via arch_nogc_lines, so those blocks are redundant -- removing
  them changes nothing (same fault), and the tree is restored to the verified
  23/28 state rather than carrying an unverified simplification.
* the gc POLICY in every form: never, auto and always all fault with the current
  compiler, while the pre-merge control works.

Where that leaves the search: the bug is in src/c/native.c (proved by swapping
one file into the working control).  The --gc commit's emitter change is a
loop-detection analysis (ir_has_loop) plus bnames/brefs in the link result, and
the collector's three entry points become stubs.  434 changed lines across ~20
hunks.  The mechanical way through it is the same bisect one level down: copy
hunks from the current native.c into the control's copy until it breaks --
about thirty seconds per step -- rather than reading 434 lines.

### Round 37: the bug is in merge #1's emitter hunks, not --gc

Deduction, from a test already run: the current compiler fails with
--gc=always as well, so the --gc DECISION code is not the cause.  Splitting the
emitter's changes by merge gives merge #1 (51c36a5, the collector) 19 hunks and
merge #2 (9078372, --gc) 7 hunks -- and arch_x64.c is PROVEN innocent by the file
swap.  CORRECTION to the first version of this note: the line counts do NOT
implicate merge #1 specifically -- measured, merge #1 changed 208 lines of
src/c/native.c and merge #2 changed 218, so neither is the small one and the
suspect set stays the whole 434 lines / 26 hunks.  What IS ruled out is the
--gc SEMANTICS (all three modes fault), not the --gc code as a location.

Next: the same swap-bisect, one level down -- start from the pre-merge
`git show 28285c4:src/c/native.c` and pull merge #1's 19 hunks in, half at a
time, rebuilding the C compiler in the control tree each step (~30 s) until the
kernel image it builds stops printing "minimal".  That lands on the hunk.

### Round 38: the positional bisect does not compile

Tried it: split src/c/native.c's 26 change-blocks in half and take the first 13
from the current file into the pre-merge one.  It does not build -- the changes
are interdependent (a signature change lands without its callers, and so on),
so a positional bisect of this file cannot be made to compile and the method
that worked at FILE level does not work at HUNK level here.

What that implies: the next step has to be a SEMANTIC bisect -- revert one
INDEPENDENT change in the current tree and see whether the kernel image starts
printing "minimal" again.  The independent candidates, in the order worth
trying, are the ones with no partner:

1. the $24 -> $32 allocation sizing (arr_alloc_size / the collector's header --
   self-contained, and the only change that touches every kernel allocation);
2. bnames/brefs added to the link result;
3. the stub substitution for the collector's three entry points (whose
   arch_x64.c half is already PROVEN innocent, so if this is it, it is the
   native.c half);
4. ir_has_loop (already effectively ruled out by --gc=always failing).

The control tree in /tmp/pre3 has been restored to the pristine pre-merge
sources; its cycc_pre binary was never overwritten.

### Round 39: the array header grew 24 -> 32, and it is not the cause

Candidate 1 from the semantic list, measured: `arr_header_size()` returns 32 in
the current emitter and 24 in the pre-merge one -- upstream added the header's
fourth word (`front`; the header is {len, cap, data, front}, NATIVE.md).  That
is the `$24 -> $32` seen in every initializer and closure.  Forcing the
C emitter back to 24 and rebuilding DOES NOT fix the fault (same err=5, cr2=0),
so the header size is not the cause on its own -- and the doctored emitter was
reverted immediately (src/c/native.c restored from backup, verified).

Still worth an audit independently: any kernel code or shared asm that computes
an array/record header by hand (16/24/32 offsets) should be checked against the
four-word layout.  But it is not what breaks the image.

Status with one round left: the regression is bounded to src/c/native.c (file
swap), the positional hunk bisect does not compile (interdependent changes), and
the semantic candidates tried so far -- gc policy, the prologue line, the
allocation sizing/header, the no-op blocks -- are all eliminated.  Remaining
untried: bnames/brefs in the link result and the native.c half of the stub
substitution.

## State of the branch (end of the 40-round run)

WHAT IS DONE AND VERIFIED.  The kernel itself: M0's address layout and `kexit`,
M1's ring 3 / syscall entry / ELF64 loader, and M2's processes, address spaces,
scheduler, timer preemption, `fork`, `wait4` and exit teardown.  Every one of
these was green -- `test/kernel` 33 passed, 0 failed, 33 total -- with the
pre-merge blessed compiler after the last real change to them.  The suite is
self-driving (`test/sh/test_kernel.sh`), the fixtures are committed (t001-t011,
x001, u001-u004), the C twin is maintained (PORTING.md), and this file plus
BUGS.md record the design, the dead ends and the open questions.

WHAT IS BLOCKED.  After merging upstream twice (51c36a5 the collector, 9078372
--gc), the CURRENT compiler emits a kernel image that faults a user program:
`trap vector=14 err=5 cr2=0` (or 0x10/0x20), from a program that prints nothing
first.  `test/kernel` is 23 passed, 5 failed, 28 total; the five are exactly the
cases that enter user mode (t011_ring3, u001-u004).  Measured, not inferred:
the same sources compiled by the pre-merge compiler work, so the sources are
right and the emitter is wrong.

WHERE IT IS.  `src/c/native.c`.  Proved by substituting one file at a time into
a working pre-merge control: `arch_x64.c` -> still works, `native.c` -> faults.

WHAT IS ELIMINATED (each by running it): the gc policy (never/auto/always all
fault); the `y_gc_stack_top` prologue line emitted into a kernel `main`; the
allocation sizing and the array header's growth 24 -> 32; the collector no-op
replace-blocks in arch/kernel.s; the syscall-path asm (identical between the
compilers); the kernel constants (all correct at runtime); the 49 dropped
global-initializer ranges (all for dead globals); the ELF loader's segment copy
and bss zeroing; the physical allocator (an allocation-free program fails too);
and the program's `FileSiz 0x150` (the main tree's compiler emits the same and
both binaries run natively).

WHAT IS LEFT.  Two untried candidates inside src/c/native.c: `bnames`/`brefs`
added to the link result, and the native.c half of the stub substitution for
the collector's three entry points (its arch_x64.c half is already innocent).
The positional hunk bisect does NOT compile -- the changes are interdependent --
so it has to be done semantically: revert one independent change at a time and
watch for the kernel image to print "minimal" again.

HOW TO START.  `git archive 28285c4 src | tar -x -C /tmp/pre3` (src ONLY -- a
full-repo extract filled the host disk once), then the gcc line in this branch's
Makefile for cycc, built into `src/y/` so std resolves.  That control builds the
current sources into a WORKING kernel image; any change that makes it stop
printing "minimal" is the bug.  Always `make rebless` before reading a
kernel-suite number after touching src/y (a stale ./ycc cost two rounds).
Run the main tree's compiler as a control before believing a compiler bug on
this branch (it would have caught two wrong bug reports).

### Round 46: publishing the region into the runtime's heap cells does not fix it

Tried, measured, reverted.  The runtime's allocator reads its own cells
(`lea y_heap(%rip); cur = (%rcx); end = 8(%rcx); used = 16(%rcx)`), and this
branch's y_heap_region_set publishes the region only into its own cells
(y_heap_bias/limit/next), so the runtime sees {0,0,0} and takes the slow path for
every allocation.  Making y_heap_region_set fill the runtime's cells too (cur =
the region's start, end = its top, used = 0) changes nothing: the same
`err=5 cr2=0` remains, so the read-at-0 is NOT the allocator's cell pair.

Also re-learned the assembler rule the hard way (again): a `#` comment inside an
asm block BODY is `error: assemble: L2209: unexpected comment (backend bug)` --
comments go in the block header, above the `#=== add: ===` marker's body.

Standing: round 45's fix DOES hold (the extra 8 is gone from the bump, and the
kernel image's fault is the reduced `err=5 cr2=0` rather than the write at 0x18).
The remaining read-at-0 is the next thing to find, and it is not the heap cells.

### Round 47: the symptom, the file and the commit now agree

qemu's interrupt log on the merged tree: `v=0e e=0005 i=0 cpl=3
IP=0023:0000000000400137 ... CR2=0`, and objdump has NO instruction at
0x400137 -- it is past the end of the program's text.  The program's last
instruction is `syscall` (exit_group) at 0x400135, so 0x400137 is where the
kernel RETURNED to it; the program then executes the zeros beyond its own text,
which dereference %rax (= 0), and the fault follows.

That is the same finding as rounds 16 and 29 -- a syscall that reaches the
kernel and returns without dispatching (round 29's print at the top of
sys_exit_group never fired) -- and it now sits in a tree where three things are
measured rather than inferred:

* the FILE is src/c/native.c (round 34: swapping it into a working pre-merge
  control makes that control fail, while swapping arch_x64.c does not);
* the COMMIT is 51c36a5 (round 43: merging master at that commit alone, onto the
  green un-merged base, reproduces "runtime error: out of memory"; with --gc the
  same commit's stubbed entry points turn that into this read-at-0);
* the SOURCES are correct (round 31: the pre-merge compiler builds the SAME
  sources into a kernel image that works).

So the work left is one emitter change inside 51c36a5 that breaks a kernel
image's syscall path -- and the shared stub is provably identical between the
two compilers (round 31 diffed y_syscall_entry, y_enter_user, y_enter_frame,
y_syscall_entry_addr and y_cur_kstack_set), so what is miscompiled is the
dispatcher or its setup on the Y side: y_sys_dispatch or syscall_init, both in
std/kernel.y, as emitted by that commit's native.c.

### Round 48: the pure emitter diff is only THREE semantic items

Built the apples-to-apples comparison the earlier diffs were not: two C
compilers that differ ONLY in src/c/native.c (the pristine pre-merge cycc_pre,
and cycc_n = control + the merged native.c), both reading the SAME
src/y/std/kernel.y and the same driver.  Their -S listings:

* no routine is missing from the bad one -- the only labels it adds are the 16
  y_gc_* cells (harmless .bss words);
* y_sys_dispatch is present and BYTE-IDENTICAL (23 lines), as is y_enter_user;
* the semantic differences are exactly three:
    1. `mov %rsp, y_gc_stack_top(%rip)` added at the kernel program's main
       (tested in round 33: suppressing it changes nothing);
    2. the `ygiS_...CLK_TS` global-initializer range is DROPPED (the merged
       emitter's link step deletes a dead cell's range -- CLK_TS's only reader
       is clock_us, itself dead here);
    3. `y_alloc(24)` became `y_alloc(32)` (the array header grew to its fourth
       word; forcing 24 back in round 39 changed nothing).

So no single one of them is the cause, and the bad configuration is still
reproducible (control + merged native.c fails; control + old native.c works).
The next step is therefore a bisect of exactly these three IN THAT
configuration -- patch them out of the control's native.c copy one at a time
(they are independent: a prologue push, a shake predicate, and a size constant)
-- rather than any further source or commit hunting.  Note the size constant and
the shake are the two that can interact with round 45's bump fix, which is why
neither was a fix on its own.

### Round 49: the header size is an INVARIANT, not a knob

Tested item 3 of the three-item pure diff -- arr_header_size back to 24, with
round 45's bump fix already in place (a combination never tried before).  The
COMPILER segfaults: with the merged runtime, 24 is not a smaller header, it is
an inconsistent one, and the emitter crashes building any program.  So the
"three semantic items" are really two plus an invariant: the array header IS 32
(the fourth word, front), the prologue line is provably harmless (round 33), and
what remains is item 2 -- the merged link step DROPPING the ygiS_...CLK_TS
initializer range.

That item deserves the next look, and the mechanism to check is concrete: with
the range dropped the CELL still exists (yg_...CLK_TS is emitted, zeroed), so
any surviving reader sees an array header of {len 0, cap 0, data 0, front 0} and
`&CLK_TS[0]` hands a data pointer of 0 to whatever reads or writes it -- which
is exactly the shape of a read at 0.  The question to answer is whether
clock_us/CLK_TS is genuinely dead in a kernel image or merely looks dead to a
shake whose roots were computed for a hosted program (a kernel has no _start).
