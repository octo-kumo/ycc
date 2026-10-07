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

### Round 50: 24 initializer ranges dropped, including the kernel's own globals

Ran both control images (round 48's comparison was only listings, never runs):
cycc_pre -> "minimal"; cycc_n (control + merged native.c) -> err=5 cr2=0.  So
native.c ALONE is sufficient, with the same std, the same arch asm and the same
driver -- and the two ELFs differ by exactly 438 bytes of text, same entry, same
segment layout.

Round 48 filtered the ygiS_ range labels out of the set difference, which hid
the answer.  Counted properly, the merged emitter DROPS 24 initializer ranges
that the pre-merge one emits, and they are not all dead constants:

    kernel.PHYS_MASK_2M, kernel.PHYS_MASK_1G, CLK_TS,
    kernel.TASK_READY/DEAD/BLOCKED/FREE,
    kernel.cur_task, kernel.need_resched, kernel.next_pid,
    kernel.SYS_READ/WRITE/MMAP/GETPID, kernel.IPC_CALL/RECV/REPLY,
    kernel.SYS_FORK/WAIT4/EXIT_GROUP, ...

`cur_task`, `need_resched` and `next_pid` are MUTABLE globals of the kernel's own
scheduler, and their ranges are deleted as if the cells were dead.  That is the
round-49 hypothesis confirmed in the shape of the data: a shake whose roots were
computed for a HOSTED program, deleting initializer ranges in a KERNEL image
that has no _start.  Dropping a range also drops whatever only that range
referenced (which is why y_clock_us disappears with CLK_TS).

Next: print those globals from a probe in both builds (next_pid is declared 1,
so if its range is gone it reads 0) and, more directly, find where the shake
decides liveness for a kernel target -- that predicate is the thing to fix, and
it is one place in the merged native.c, not a hunt.

## The shake fix, and what it unblocks

Fixed and blessed: `ir_drop_inits` no longer deletes a dead cell's initializer
range for a kernel target (src/c/native.c and src/y/native.y, mirrored), because
the shake's liveness roots are computed for a HOSTED program while a kernel
image has no _start.  24 ranges were being deleted from every kernel image,
including cur_task, need_resched and next_pid.

    test/kernel: 33 passed, 0 failed, 33 total   (merged compiler)
    refs/ycc.ref bb1bd590dd3f461e

M3's first case, re-run with the fix in place, gets FURTHER than it ever did:
"starting the server", S1, C1, S2 -- so delivery works and the server's
ipc_recv returns -- and it then faults with err=5 cr2=0 in the reply/resume
path, which is the round-7 signature.  That is M3 FUNCTIONAL work, not the
shake bug, and it is parked in _ktmp/wip/ until fixed rather than committed as
a failing case.

### Round 54: the IPC fault, instruction by instruction

qemu on the plain two-process program: `v=0e e=0005 cpl=3 IP=0x401542 CR2=0`,
and the -g build (same addresses) disassembles exactly there:

    40153e:  48 8b 40 10        mov 0x10(%rax),%rax     # rax = header->data
    401542:  48 8b 04 c8        mov (%rax,%rcx,8),%rax  # rax = data[0]  <-- FAULT

So the program read `buf[0]` on a `[long; 5]` local whose header's `data`
pointer is 0 -- the array's element block was never allocated (or never
recorded).  The SAME source compiled by the SAME compiler and run NATIVELY
prints `buf0 0 len 5`, so the program's logic and the emitter's handling of a
zero-initialized fixed array are both correct; what differs is the KERNEL.

That narrows M3's blocker to the guest side of allocation: the program's first
y_alloc -> y_alloc_map -> an mmap SYSCALL into this kernel (sys_mmap), and the
array header's data field never being filled in.  Next measurement, and it is
the round-7 technique: have the kernel print sys_mmap's arguments and result for
the program's first mmap, or have the user program print ptr_addr of its own
array to see whether the allocation happened at all.

Also worth a fixture of its own: a -g USER program produces NO serial output in
this kernel (round 21 saw "load failed" for the sibling case), so the -g build
cannot be booted for a RIP measurement -- the plain build is used to run and the
-g build only to symbolise the same addresses.

### Round 55: the guest side is innocent -- it is the IPC path

Smallest possible repro, run in the kernel with no IPC at all:

    let buf: [long; 5] = [0, 0, 0, 0, 0];
    print("len " + tostring(len(buf)) + " b0 " + tostring(buf[0]));
    buf[1] = 7;
    print(" b1 " + tostring(buf[1]));

prints `len 5 b0 0 / b1 7` -- correct.  So the guest side is fine end to end: the
array header, its element block, y_alloc, y_alloc_map, the mmap syscall into
sys_mmap, and both reads and writes of elements.

That leaves the IPC path itself as the thing that leaves that array's data
pointer at 0, and the two kernel-side suspects are the delivery write
(task_deliver -> task_write_word, which translates through the RECEIVER's page
tables and skips silently when the translation fails) and sys_ipc_recv's own
copy into the buffer.  A failed translation there would leave the buffer as it
was -- and if what the program passed was the array HEADER rather than its data,
five message words would overwrite {len, cap, data, front} and set data to 0,
which is exactly the value the fault reads.

Next measurement, and it is the same one that localized this case before: print,
from the kernel, the buffer address the receiver registered and what
vm_translate returns for it.

### Round 56: the fault is INSIDE ipc_recv -- the blocking/resume path

Instrumented the server (same driver, same program otherwise):

    srv: p>0 true len 5          <- the array is valid and len is 5 BEFORE the call
    <blank>
    trap vector=14 err=5 cr2=0

The line printed AFTER `syscall(1025, p)` never appeared, so the fault happens
during that syscall -- and a syscall cannot fault the caller's own instruction
stream, which means the SERVER DID NOT RESUME CORRECTLY: ipc_recv blocked it,
the scheduler switched to the client, the client's ipc_call delivered, and what
came back was not the server's continuation.  `cr2=0` with the header still
intact (p>0 true, len 5 before the call) says the same thing the earlier
disassembly did, from the other side.

That is the last M2 mechanism never exercised before: wait4's blocking works in
the suite (a child's exit completes the parent through task_exit), but ipc_recv
is the first case where the completion comes from ANOTHER TASK'S syscall --
sys_ipc_call -> task_deliver -> task_complete -- with the sender running on the
sender's CR3 and the receiver suspended at its own canonical point.  Everything
else on both sides is now measured innocent: the guest allocation, the array
header and elements, the message contents up to S2, and the delivery write
itself.

Next: instrument task_deliver/task_complete for this path (the receiver's saved
rsp, the value written, and what the switch restores), which is the same shape of
measurement that localized every fault in this file before.

### Round 57: the receiver's frame is wrong, and its RIP slot is a stack address

Instrumented task_complete (khx prints of the target's saved rsp, the word at
+48 and the word at +72) and ran the two-process case:

    C1 ffff888000142f88 ffff888000142fb8 ffff888000142fd0

so task_complete(1, ...) writes the answer at 0xffff888000142fb8 (rsp+48) and
the RIP slot at rsp+72 holds 0xffff888000142fd0 -- a STACK address, not code.
A task resumed from that frame iretqs into its own stack, which is exactly the
"did not resume correctly" the previous round measured from the other side, and
it reproduces round 22's observation that this task's rsp read differently at
the switch (0x...16af90) than at the completion (0x...142f88): two different
kernel stacks for one task.

So the remaining M3 blocker is ONE bug, now with three independent sightings:
the scheduler's save of the outgoing task's frame pointer, which is
`tasks[cur_task].rsp = y_cur_task_rsp_get()` -- a GLOBAL scratch.  Round 9 tried
the obvious defence (consume the scratch, and set it to 0 so a stale value can
never be saved) and it was not sufficient on its own; with the shake fix now in
place and the frame contents visible, that fix plus the freshness guard is the
next thing to apply and test against this same case.

### Round 58: the scheduler SAVE is not the bug

Applied round 9's defence in full: y_cur_task_rsp_set in arch/kernel.s, and the
pick now saves only a FRESH frame pointer (consume it and zero it, so a stale
value can never be attributed to a task).  Built, ran the two-process case: the
same fault, the same missing "after recv" line.  So the save is not what is
wrong.

What that leaves, and it is now a narrow statement: at the moment
task_complete writes the answer, tasks[server].rsp points at a frame whose RIP
slot (+72) holds a STACK address.  The save is fresh and correct, so the FRAME
ITSELF is wrong at that point -- i.e. the server's canonical point is not where
this code thinks it is, or something wrote over it between the syscall entry
and the completion.  The three candidates, in order of how easy they are to
distinguish:
  1. the stub's published rsp is not the frame the completion writes into (the
     stub publishes BEFORE the dispatcher runs, and the dispatcher's own calls
     use that same stack);
  2. the fabricated task frame and the first syscall's frame collide at the same
     address (both are kstack_top - 112: measured in round 9's analysis), so the
     first syscall overwrites the frame the task was started with;
  3. the receiver's kernel stack is not the one its rsp points into.
Next: print, at syscall entry for the receiver and again at completion, the
published rsp AND the stack top, so 1/2/3 separate in one run.

### Round 59: the frame is RIGHT -- round 57's reading was my instrumentation bug

Instrumented both sides (published rsp at ipc_recv, and rsp/kstack/value-at-+72
at completion) and ran the case:

    R  ffff888000142f88 ffff888000143000
    C1 ffff888000142f88 ffff888000143000 000000000040158d

* the PUBLISHED rsp and the SAVED rsp agree (0x...142f88) -- so candidate 1 from
  round 58 is out;
* the kstack agrees (0x...143000) -- candidate 3 is out;
* the word at +72 is 0x40158d, a CODE address -- so the frame is correct, and
  round 57's "its RIP slot is a stack address" was MY BUG: it printed
  tasks[i].rsp + 72 (the address) instead of peek_va64 of it (the value).

So the save is right, the frame is right, the stack is right -- and the server
still never reaches the line after its syscall.  The fault is therefore AFTER a
correct resume, in the resumed code path itself, and the next measurement is the
one that has worked every time: the faulting user RIP plus a disassembly of a -g
build (remembering that a -g USER program cannot be booted in this kernel, so
the plain build runs and the -g build only symbolises the same addresses).

Correction recorded deliberately: two of the last three rounds' hypotheses were
built on a measurement that printed an address where a value was wanted.  Read
the instrumentation before reading the conclusion.

### Round 60: the delivery write lands in the HEADER, not the data

Faulting instruction, from the -g build (plain build run, -g only symbolised):

    4015ea:  mov 0x10(%rax),%rax      # rax = header->data
    4015ee:  mov (%rax,%rcx,8),%rax   # rax = data[0]   <-- FAULT
    4015f3:  call y_long_tostr        # ... inside tostring(buf[0])

From round 54/55's disassembly of the same code, `rax` before `mov 0x10(%rax)` is
the array's HEADER, so `data` is at +16 -- and the program prints "p>0 true"
BEFORE the call, which means data was NON-ZERO then: `&buf[0]` is header->data,
so a zero data would have printed p>0 FALSE.  data becomes 0 during/after the
receive, and `buf[0]` then dereferences it.

So sys_ipc_recv/task_deliver writes five words somewhere other than the buffer
the receiver registered -- and the shape says where: if the five words land
64 bytes or so BEFORE the data pointer (e.g. at a PAGE BASE rather than at
page_base + offset), they overwrite {len, cap, data, front} and set data to the
5th word, which is what the fault reads.  task_write_word does

    phys = vm_translate(cr3, va & -8); poke_va64(DIRECT_BASE + phys + (va & 7), v)

which is correct ONLY if vm_translate returns page base PLUS the offset of the
masked address.  If it returns the page base alone, every delivery write lands at
the start of the page -- which is exactly this symptom.  That is the next thing
to read, and it is a one-line fix in one of those two places.

(Trying buf.ptr instead of ptr_addr(&buf[0]) changes nothing, so the pointer the
program passes was already the element address.)

### Round 61: the pointer transfer is CORRECT -- both sides agree

Instrumented both ends of the same call: the program prints the address it
passes, the kernel prints the buf it receives.

    srv: p=272638088 len 5          <- 0x10402088, a user heap address
    R0000000010402088 ffff888000142f88   <- the kernel received 0x10402088

They are the SAME value.  So the registration is right, the syscall carries it
intact, and round 60's suspicion is dead as well: vm_translate DOES add the page
offset (read in full this round: `(e1 & PHYS_MASK) + v % 4096`, and the 2 MB and
1 GB cases likewise), and task_write_word's arithmetic is therefore right.

What that leaves is a genuine contradiction worth stating plainly: the program
passes the address of its array's ELEMENTS, the kernel receives and writes to
that same address, the array's header is 16 bytes before it and cannot be touched
by a 40-byte write at the element address -- and yet the expression after the
call (`tostring(buf[0])`) dereferences a header whose data field is 0.  Something
between the call and that expression changes which header `buf` reads, and the
one candidate now on the table is the local's own storage: for a fixed [long; 5]
the header may live on the stack while its elements live on the heap, so the
thing to print next is `ptr_addr(buf)` (not buf.ptr, not &buf[0]) before and
after the call -- if the local's header address changes, the frame is being
restored to the wrong place, which would tie this back to the resume path after
all, but with the pointer evidence pointing the other way.

Also measured and worth keeping: the -g disassembly, the received pointer, and
the published rsp all agree, so the instrumentation itself is now trustworthy.

### Round 62: IPC WORKS -- the bug is where the program points the kernel

The decisive run, with the server NOT reading the array after the call:

    p1=... (truncated by the log tail)
    p2=0 len2=21        <- after ipc_recv: len is 21, which is the TAG the client sent
    cli got 42
    srv done            <- the exchange completed and the server exited cleanly

Two conclusions, and they invert the last several rounds:

* The M3 IPC path is FUNCTIONAL.  Registration, the port table, ipc_call's
  queueing, the blocking of both sides, the scheduler switches, task_deliver,
  task_complete, ipc_reply and the resume all work -- the client got its answer
  (42) and the server ran to completion and exited.
* The failure was never "the kernel corrupts the frame".  It is WHERE THE PROGRAM
  POINTS THE KERNEL: the five message words land on the array's HEADER (len
  became the tag, data became 0), so any read of buf[0] afterwards dereferences a
  zero data pointer -- which is exactly the fault disassembled in rounds 54 and
  60.  `ptr_addr(buf.ptr)` and `ptr_addr(&buf[0])` both appear to give the
  header's address for a FIXED [long; 5], not the elements'.

So M3's remaining work is: give the fixture a pointer to the ELEMENTS (or give
the kernel a convention for it), and check whether `arr.ptr` on a fixed array is
a compiler bug worth filing -- the manual says arr.ptr is a *T to the first
element, and if it answers the header instead, that is a documentation or code
mismatch, not a kernel problem.

Everything the last ten rounds eliminated stays eliminated: the shake fix (real,
committed, blessed), the scheduler save, the receiver's frame, the published rsp,
the delivery arithmetic, vm_translate's offset, and the syscall stub's layout.

### Round 63: the CALLEE-SAVED registers are not preserved across a suspension

Native control (the same source, no kernel):

    amp=139985179115528 ptr=139985179115528      <- &buf[0] and buf.ptr are the SAME, element address
    after *p=99: buf0=99 len=5                   <- writing through it reaches buf[0]
    after *q=7: buf0=7                           <- and so does &buf[0]

So the pointer convention is right and the emitter is right: buf.ptr and &buf[0]
both give the ELEMENTS, and a write through them lands in buf[0].

Now put that beside round 62's kernel run: p2=0 and len2=21 after the receive,
where 21 is the TAG the syscall returned.  A local's header pointer reading 0,
and a length expression reading the syscall's return value, is not memory
corruption at a wrong address -- it is the program's LIVE VALUES being clobbered
across the suspension, by exactly the values the kernel was holding.

That is the one thing the syscall frame never saved.  The canonical frame holds
nine slots (r9, r8, r10, rdx, rsi, rdi, rax, r11, rcx) -- the SYSCALL ABI's
caller-saved set -- while the Y ABI also promises rbx, rbp, r12, r13, r14 and r15
across a call.  A syscall that merely traps and returns happens to leave them
alone often enough that wait4 and the preemption fixtures pass; a syscall that
SUSPENDS the task hands the CPU to other code, which uses them freely, and the
resumed program then reads garbage.

THE FIX (four places, one contract): add six slots to the canonical frame --
rbx, rbp, r12-r15 -- pushed by y_syscall_entry and the IRQ stub, popped by both
tails and by y_enter_frame, and initialised by task_frame.  The frame layout is
this branch's own documented contract, so the change is self-contained; the C
twin of the IRQ stub (src/c/arch_x64.c) needs the same six pushes.

### Round 66: why the six slots must go BELOW the nine (the IRQ constraint)

My IRQ attempt pushed the six (r15..rbx) FIRST, so they landed above the nine
register slots -- and that is on the wrong side of the frame, because in an
interrupt the CPU has ALREADY pushed [RIP][CS][RFLAGS][RSP][SS] before the stub
runs.  The layout came out as

    [r9..rcx (nine)] [RIP CS RFLAGS RSP SS (CPU)] [r15..rbx (six)]

while the syscall path produced

    [r9..rcx (nine)] [r15..rbx (six)] [RIP CS RFLAGS RSP SS]

so the two suspension points still did not agree, and the suite went from 29/2/31
to 26/5/31.  No stub can push between the nine and the CPU frame -- the CPU
pushed that part.

Therefore the six must go BELOW the nine in BOTH paths (pushed last, lowest):

    [r15 r14 r13 r12 rbp rbx] [r9 r8 r10 rdx rsi rdi rax r11 rcx] [RIP ... ]

which means the saved switch point moves down by 48, and the coordinated edits
are: y_syscall_entry pushes the six BEFORE the nine (it can, it builds the whole
frame), the IRQ stub pushes them AFTER its nine, y_enter_frame and task_frame
follow, and task_complete's answer slot for the saved frame moves from rsp+48 to
rsp+96.  The dispatcher's own argument offsets are read from the rsp at its call
site, not from the saved frame, so they do not move.

That is the whole change, written down so it can be done in one pass instead of
two half-passes; the reverted version of the fix is in history at cb9be62, and
test/kernel is green (33/33) without it.

### Round 71: the IRQ edit must go INSIDE res_irq_stubs.foreach, not before it

Attempted the whole frame recipe with line anchors.  All edits applied, and the
result was a fault with an IMPOSSIBLE error code (err=100663393, cr2=0x6000638):
the trap/IRQ section of arch_x64.y generates BOTH the exception stubs (vectors
0..31, which push ten registers and never resume) and the IRQ stubs (inside
res_irq_stubs.foreach), and the first `push %rcx` in that region belongs to the
TRAP stubs.  Adding the six there shifted the handler's vector/error offsets, so
the trap report itself printed garbage -- proof the edit landed in the wrong stub
family, since the trap stubs must stay exactly as they are.

Reverted; the committed state is green (33/33).

Corrected recipe, so this is not repeated: the six pushes/pops and the CS check
(80 -> 128) go inside the res_irq_stubs.foreach body (the `y_irq_stub_N` blocks),
NOT in the trap-stub block above it; kernel.s's two 9-pop groups are the syscall
stub's tail and y_enter_frame, and the six go above the nine in the pushes
(before `push %rcx`, located by the unique `mov 56(%rsp), %rax`) and after each
9-pop group; task_frame writes the six between RIP and the nine.

### Round 73: the four parts of the frame change, and what is still unverified

State of the recipe after four attempts (each reverted; the tree is green):

1. `y_syscall_entry` (src/y/arch/kernel.s): the six pushes go before the rescue
   pair `push %rcx / push %r11` -- uniquely located by the `mov 56(%rsp), %rax`
   that follows it -- and the six pops go after each of the TWO nine-pop groups
   (the syscall tail and y_enter_frame), later group first so line numbers hold.
   Both applied cleanly and the emitted listing looked right.
2. `task_frame` (src/y/std/kernel.y): the six are written AFTER the RIP write and
   before the rcx/r11 slots, so from the lowest the frame reads
   [r9 r8 r10 rdx rsi rdi rax r11 rcx][rbx rbp r12 r13 r14 r15][RIP CS RFLAGS
   RSP SS] -- the same shape the stubs produce.
3. The generated IRQ stubs (src/y/arch_x64.y AND src/c/arch_x64.c): the six go
   immediately after the `y_irq_stub_N:` label line and BEFORE `push %rcx`, the
   six pops after the `iretq` block's `pop %rcx`, and the CS check moves from
   80(%rsp) to 128(%rsp).  Critically, this must be anchored to the label line
   (or the iretq tail), because the TRAP stubs -- generated in the same region,
   above res_irq_stubs.foreach -- also contain `push %rcx`, and editing those
   shifts the trap handler's vector/error offsets (round 71 measured exactly
   that: an impossible err=100663393).
4. The switch points: both stubs store y_cur_task_rsp at the SAME place -- the
   nine's lowest slot (r9) -- the syscall one before `call y_sys_dispatch`, the
   IRQ one before `call y_sched_pick`, so the saved frame pointer does not move.

With all four applied, the suite fell to 12/15/27 and the IPC case faulted with
err=6 cr2=0x6000638 -- a user WRITE to its own stack, i.e. an iretq with a wrong
RSP, which means the frame's TOP five words were read at the wrong offset by one
of the two paths.  That is the specific thing to measure next, and it is a
two-value print: the rsp at the moment each stub stores y_cur_task_rsp, and the
rsp each path has at its iretq.  Everything else in the recipe is now verified by
reading rather than by reasoning.

## Full `make test` after the shake fix (round 74)

`JOBS=8 make test` on the merged line, with the shake fix committed and blessed:

    [port]            151 passed, 0 failed / 151      <- the port gate
    [pe-port]         151 passed, 0 failed / 151      <- the Windows half
    [native]          229 passed, 0 failed / 229
    [native-examples]  15 passed, 0 failed / 15
    [examples]         15 passed, 0 failed / 15
    [audit]            65 passed, 0 failed / 65
    [ycc-units]        34 passed, 0 failed / 34
    [debug]            27 passed, 0 failed / 27
    [link]             23 passed, 0 failed / 23
    [treeshake]        54 passed, 0 failed / 54
    [std-suites]        5 passed, 0 failed / 5
    [kernel]           33 passed, 0 failed / 33

The three failures are the KNOWN pre-existing ones: `lsp` (the formatter and the
node-driver environment) and `coverage` (three types.y diagnostics and three
matrix rows untested) -- both documented as pre-existing in master's own commit
message ("make check green except the pre-existing lsp/coverage environment
failures").  The `ycc` suite produced no summary line in the log and is the one
to confirm against the main tree before calling it pre-existing.

So the shake fix -- the guarded `ir_drop_inits` for kernel targets -- is
validated by the whole gate, not just by test/kernel: the port gate at 151/151
(both halves) says the two engines still agree byte for byte on the entire
corpus, and the ratchets say the tree shake's costs did not move.

### Round 75: the ycc suite's one failure, named

Round 74's log grep missed the suite's summary line; run directly, `test_ycc.sh`
is **56 passed, 1 failed / 57**, and the failure is one case:

    FAIL ysh eval compiles and runs through ycc
      got: 1:5: error: undefined function 'exec'
    PASS ysh eval compiles with --no-exec

So `exec` (the builtin std/exec.y provides) is missing for a plain compile while
the --no-exec variant passes.  That is NOT the shake fix: the guard is
`target_is_kernel()`-scoped, hosted compiles are untouched, and the port gate at
151/151 in both halves -- which recompiles the whole corpus with both engines and
compares bytes -- says hosted codegen did not move.  It is either pre-existing on
this branch or something the upstream merges brought; the way to tell is the
control that has settled every such question here: build and run the same suite
against the MAIN tree's compiler.

Everything else in the full gate is green (port 151/151, pe-port 151/151, native
229/229, kernel 33/33, treeshake 54/54, std-suites 5/5), with lsp and coverage
the documented pre-existing failures.

### Round 76: exec works on both trees -- the ycc failure is fixture-specific

The control that settles such questions, run in one command:

    printf 'exec("echo exec-works");\n' > /tmp/e76.y
    main tree : ./ycc /tmp/e76.y -o /tmp/e76a && /tmp/e76a   -> exec-works
    this branch: ./ycc /tmp/e76.y -o /tmp/e76b && /tmp/e76b   -> exec-works

So `exec` is NOT lost, on either tree, for a plain compile.  The ycc suite's one
failure ("ysh eval compiles and runs through ycc" -> 1:5: error: undefined
function 'exec', while its --no-exec sibling passes) is therefore specific to
that fixture's program rather than a general builtin or a regression from this
branch's work.  Next: read the fixture the case builds and see how it reaches
`exec` -- the error is at line 1 column 5, and `exec` as a *value* or a method is
not the same thing as the builtin call that just worked.

### Round 77: what the ycc/ysh failure is NOT, and where it must be

Read the fixture (test/sh/test_ycc.sh, around line 52): it builds
test/y/examples/ysh.y with $YCC_BIN, symlinks that same binary into a temp dir as
`ycc`, and then runs `ysh -c 'eval print(6 * 7)'`, which compiles that STRING at
runtime by forking the symlinked compiler.  The plain case must print 42; the
`--no-exec` case must fail with "undefined function 'exec'".

Measured this round, to rule out the obvious:
* a one-line `exec("echo exec-works")` compiles AND runs on the main tree's
  compiler and on this branch's (round 76);
* the same program compiled by a compiler SYMLINKED into a temp directory, and by
  the tree's own ./ycc, both print `from-tmp` -- so the std pack travels with the
  binary and "a compiler away from its std/" is not the problem.

So `exec` works in every configuration tried, and the failing case is
`ysh -c 'eval print(6 * 7)'` -- an expression with NO exec in it -- reporting an
`exec` error.  The error therefore comes from what ysh COMPILES AROUND the
expression (its prelude / builtins), not from the expression.  Next: read
test/y/examples/ysh.y's eval path -- what it passes ycc (flags, --no-exec, the
prelude it splices) -- and reproduce that exact command line by hand.

### Round 78: the mechanism, named -- ysh compiles every eval with --no-exec

Read test/y/examples/ysh.y's eval path (lines 44-58):

    // --no-exec strips exec() from the evaluated program.
    let rc = exec(YCC + " --no-exec -o " + OUT_PATH + " " + SRC_PATH + " 2>&1");
    ...
    exec(OUT_PATH)

So ysh passes --no-exec for EVERY eval, and the test's two cases differ only in
the expression text: `eval print(6 * 7)` must succeed (its program has no exec)
and `eval exec("true")` must fail with "undefined function 'exec'".  On this
branch the FIRST fails with that message at "1:5", so the program ysh actually
compiles around `print(6 * 7)` reaches exec -- the prelude it splices and the
--no-exec flag it passes are inconsistent for this build.

That is a fixture/pack interaction, not kernel work and not the shake fix, and
the pair (spliced prelude, --no-exec) is the thing to look at: either the prelude
must not use exec (the fixture's intent, since the test asserts the plain case
succeeds), or the flag must not be passed for that path.  The control is to run
the same case against the main tree's compiler, which the ycc suite supports by
environment (YCC/YREF).

### Round 79: the ycc/ysh failure is PRE-EXISTING -- the control proves it

The control, run side by side:

    main tree  : ./ycc -o /tmp/ysh test/y/examples/ysh.y
                 ysh -c 'eval print(6 * 7)'
                 -> 1:5: error: undefined function 'exec' / compile failed (exit 1)
    this branch: same build, same command
                 -> 1:5: error: undefined function 'exec' / compile failed (exit 1)

Identical.  So the ycc suite's single failure is PRE-EXISTING on master (ysh.y
passes --no-exec for every eval while the prelude it splices calls exec -- a
fixture inconsistency, and the upstream repo's to fix), and NOTHING in this
branch's work causes it.

That completes the gate picture for this branch:

    green:  port 151/151 (both halves), pe-port 151/151, native 229/229,
            native-examples, examples, audit, ycc-units, debug, link,
            treeshake 54/54, std-suites 5/5, kernel 33/33
    red:    lsp, coverage (documented pre-existing in master's own message)
            and ycc's one ysh case (pre-existing, proved by the control above)

Every red suite is therefore pre-existing, and the kernel -- the thing this
branch is for -- is 33/33 inside that same run.

## Where to pick this up (end of the current run)

M0, M1, M2: DONE, verified, 33/33 inside the full gate.  Nothing outstanding.
The shake fix that unblocked them is committed and blessed (ir_drop_inits must
not delete a dead cell's initializer range for a kernel target).

M3: HALF DONE, and the hard part works.  os/kernel/ipc.y's ports and
ipc_call/recv/reply are implemented, and round 62 demonstrated the whole path:
the client received its answer, the server ran to completion and exited.  The
one thing between that and a committed fixture is the CALLEE-SAVED FRAME CHANGE
(the Y ABI promises rbx/rbp/r12-r15 across a call; the canonical frame saves only
the syscall ABI's nine).  Its recipe is fully specified above, its four parts are
individually verified by reading, and the ONE measurement left is: with all four
parts applied, print the rsp each stub holds at its iretq.  Applying all four
produces err=6 cr2=0x6000638 (a user write to its own stack, i.e. an iretq with a
wrong RSP), so one of the two paths reads its frame's top five words at the wrong
offset; that print names which.  After that: commit u005_ipc as a fixture
(_ktmp/wip/u005_ipc.{user,driver}.y, with .expected and .exit), then the rest of
M3 -- sys_io and IRQ delivery for the tty, the fd broker, and the YFS1 file
system with its host-side mkfs.

M4: NOT STARTED.  Userland: init, sh, ls, cat, echo, mkdir, rm, rmdir, mv, cp,
pwd, wc, head, ps, halt, the ed editor, and /bin/sh for std/exec.y.

M5: NOT STARTED.  ycc on target: /bin/ycc plus /bin/std, /proc/self/exe for
openat+readlink, /proc/self/environ.

M6: partly done (this file, BUGS.md, the harness and the budget ratchet);
outstanding are the final docs and any remaining ratchets.

Two rules that each cost rounds in this run, both proved here: rebuild BOTH
engines after touching an embedded arch/*.s (make cycc as well as the Y one)
before reading any suite number, and run the main tree's compiler as a control
before believing that something on this branch is broken.

## M3's first acceptance test: u005_ipc (round 81)

    [kernel] 34 passed, 0 failed / 34 total

test/kernel/u005_ipc.{driver,user}.y run two processes through a synchronous
request/reply IPC exchange, and the transcript is the fixture's .expected:

    ports: 1 and 2 / starting the server / S1 / C1 / S2 / C2 / client got 42 /
    S2b / S3 / S4 / client got 10 / server done

Getting here needed the callee-saved frame change (see above), and the last
piece was sys_fork: it copies the parent's canonical frame to the child, and the
frame grew from 14 words to 20, so its `ktop - 14 * 8` and `while (i < 14)` had
to follow.  The rax slot at +48 did NOT move, because the six sit above the nine.

Two process lessons, both of which cost rounds here and are worth keeping:
verify ANY hard-coded frame size or offset when the frame changes (sys_fork was
the last one), and after editing an embedded arch/*.s rebuild BOTH engines before
reading a suite number.

## M3: serial input (round 82)

SYS_READ is now implemented for fd 0, the serial console: it copies up to `len`
bytes from y_serial_getb into the caller's buffer and returns the count, ending
early on a newline or when no byte is ready.  A program therefore polls rather
than blocking inside the kernel -- the scheduler runs at kernel exit, so a read
that blocked there would hold the CPU until the interrupt arrived; making it a
real blocking read (IRQ 4 + a wake) is the follow-up.

Verified by hand, end to end, with qemu's stdin feeding the guest:

    { sleep 1; cat stdin-with-Z; } | qemu -kernel uland.y -initrd u006.prog ...
    -> module bytes: true / it is an elf: true / entering ring 3 /
       read 1 byte 90            (90 is 'Z')

The fixture for it (u006_serialin with a .stdin file, which the harness supports)
is NOT committed yet: my captured transcript and the harness's own comparison
disagree, so the .stdin/driver convention needs sorting first -- the harness
builds the driver its own way and my capture used test/kernel/uland.y directly.
The suite is 34/34 with the implementation in place.

## What the u006 serial-input fixture needs (round 83)

Read the harness rather than guessing, and it is more specific than it looked:

* It globs `$KDIR/[tx]*.y` as KERNEL DRIVERS -- each of those is compiled with
  `--kernel` and booted.  The `u*` cases are handled by a separate path with a
  DEFAULT driver, whose transcript begins "module bytes: true / it is an elf:
  true / entering ring 3"; a `u*` fixture therefore supplies `.user.y` (+ an
  optional `.driver.y`), `.expected` and, for input, `.stdin`.
* `.stdin` is fed one second in, with a comment explaining why: `serial_init`
  clears the UART's receive FIFO, so a byte that arrived first would be
  discarded -- "a person types after the machine is up".

The last u006 attempt captured a CORRECT transcript by hand (module bytes / it is
an elf / entering ring 3 / read 1 byte 90) and the harness still reported a
difference, and the reason is the one thing in the fixture that is not
deterministic: the poll loop was BOUNDED (5,000,000 tries), so a run that fed the
byte a moment later ended with "read 0 byte 0" instead.  The fix is to loop until
a byte arrives (the harness always feeds one) rather than to any try count.

One process note worth more than the fixture: `grep -q "FAIL u006"` silently
found nothing because the harness colours `FAIL`, which took the wrong branch and
left the suite red for a moment.  Strip the colour before matching on harness
output.

Suite: 34 passed, 0 failed / 34 total.

### Round 84: the u006 blocker is the DRIVER, not the program

With the poll made unbounded, the manual run still produced the right transcript
(module bytes / it is an elf / entering ring 3 / read 1 byte 90) and the harness
still differed -- and its "got" is the diagnostic: only THREE lines, ending at
"entering ring 3", with no read line at all.  So the harness's run never got as
far as the read, while the same program under test/kernel/uland.y does.

That is a driver difference, not a program or timing one: u005_ipc passes because
it ships its OWN .driver.y (it spawns the server, talks to it, and stays alive
long enough), while u006 had none and fell back to whatever the harness uses by
default -- which prints the same opening lines but does not keep the machine
around long enough for a program that waits on the console (or does not run the
initrd program the way uland.y does).

Next: give u006_serialin its own .driver.y, modelled on u005_ipc's -- spawn the
program, then stay alive (wait4 or an IPC wait) so the console read can complete.
The program itself is verified by hand and its poll is unbounded, so this is a
harness-shape problem, not a kernel one.

### Round 85: serial input proven with a purpose-built driver

Wrote u006_serialin.driver.y (kernel.init, the module's phys/size, sched_init, a
spawn() built from vm_new_dir + elf_map + elf_setup_stack + pages_alloc_va +
task_frame + sched_add, then task_start and kexit), and the program with the
unbounded poll.  Booting exactly that pair and feeding 'Z' through qemu's stdin
produces:

    waiting for input
    read 1 byte 90

so the kernel's serial INPUT path is proven end to end with a real byte from the
host: UART -> y_serial_getb -> sys_read(fd 0) -> the caller's buffer -> printed
back out through SYS_WRITE.

The committed fixture is still not there: the harness's own run produces a
different transcript from this identical invocation, so the remaining question is
entirely about how the harness drives a u* case that has both .driver.y and
.stdin (u005_ipc passes with a driver and no stdin; u003/u002 have drivers and no
stdin).  The next thing to read is the harness's u* path itself -- which driver
it builds into the image, whether it also compiles .user.y into the initrd, and
whether the stdin feed is attached to the same qemu invocation.

### Round 86: the serial-input fixture is committed

The harness's u* loop runs qemu with `</dev/null`; only the t*/x* loop (cases
built with --kernel and booted without -initrd) attaches a `.stdin`.  So the
fixture belongs there, and it is now test/kernel/t012_serialin.y -- a kernel-only
program that reads one byte with kernel.getc() and reports it:

    .stdin: Z      .expected: read byte 90      .exit: 19  (kexit(9))

test/kernel is 36 passed, 0 failed / 36 total.  M3's console work is now pinned
in BOTH directions -- SYS_WRITE for output, serial input here -- with u005_ipc
covering the IPC path end to end, and the callee-saved frame contract fixed.

## YFS1 -- the on-disk format (the contract mkfs and the fs server implement)

Nothing in os/kernel/ touches files yet, so this is greenfield.  The filesystem
image is the multiboot module the kernel already receives: today module 0 is the
raw program, and with YFS1 module 0 is the DISK, so the kernel stops loading a
loose binary and starts loading /init, /bin/* and /bin/ycc from the filesystem.
Little-endian, 4096-byte blocks:

    block 0                    superblock
      +0   char magic[4] = "YFS1"
      +4   u32 version = 1
      +8   u32 block_size = 4096
      +12  u32 total_blocks
      +16  u32 inode_count
      +20  u32 root_inode = 1
      +24  u32 data_start      (first block of the data area)
    blocks 1..A                inode table, inode_count entries of 64 bytes
      +0   u32 mode            (0 free, 1 file, 2 dir)
      +4   u32 size            (bytes for a file, entries for a dir)
      +8   u32 direct[12]      (block numbers, 0 = none)
      +56  u32 indirect        (single indirect block, 0 = none)
    block A..                  data: file contents, or for a directory an array
                               of entries, each: u16 name_len, u16 type,
                               u32 inode, then the name bytes NUL-padded to a
                               4-byte boundary.  An entry with name_len 0 ends
                               the block.

Kernel side (os/kernel/yfs.y, to be written): yfs_init(phys, size) validates the
superblock and remembers the parameters; yfs_lookup(path) walks from root_inode
and returns an inode or -1; yfs_read(inode, off, buf, len) copies through the
direct and indirect blocks; yfs_readdir(inode, index, name_buf) feeds ls.  The fd
broker then maps an fd to {inode, offset, flags}, which is what makes openat,
read, write, getdents64 and lseek real rather than per-syscall special cases.

Host side: os/tools/mkfs.y packs a directory tree into that image, run during the
build (`./ycc os/tools/mkfs.y -o mkfs && ./mkfs root/ > yfs.img`), so the root
directory is version-controlled as ordinary files and the image is generated.
The first files to carry are /init (a program that spawns the tty and fs servers)
and /bin/sh, so the boot path stops depending on a single raw module.

Order of work, smallest verifiable step first: the format + mkfs on the host, then
yfs_init/yfs_lookup/yfs_read in the kernel with a t* fixture that reads a known
file out of a generated image and prints its contents, then the fd broker, then
the fs server, then /init and /bin/sh.

### Round 89: the kernel-side YFS1 reader

os/kernel/yfs.y now implements yfs_init (validate "YFS1"/version, remember block
size and root inode), yfs_size, yfs_block_of (twelve direct slots then one
single-indirect), yfs_read (copies through the blocks into the caller's buffer,
which is in the CURRENT address space -- the caller's at a syscall, the kernel's
at boot), and yfs_lookup (one component in the root directory).  u16 is read by
hand from two peek8s because the kernel's peek helpers cover 8, 32 and 64 bits.

It compiles (a throwaway --kernel program that imports it builds clean) and the
suite is unchanged at 36/36, but it is NOT yet exercised at runtime, and the
reason is structural rather than an omission: no t* case can receive a filesystem
image, because the harness builds a t* image from the .y source and boots it
WITHOUT -initrd, while a u* case's -initrd is the compiled user program.  So the
image has to arrive one of two ways:

  * a `$KDIR/$base.initrd` convention in the t* loop (a small harness change:
    pass -initrd when the file exists), which is also the general fix for any
    future image-based case; or
  * a t* program that BUILDS a YFS1 image in a scratch page itself (poke the
    superblock, inode and data bytes exactly as os/tools/mkfs.y does) and then
    runs yfs_init/yfs_lookup/yfs_read against it -- self-contained, no harness
    change, and it pins the reader against the writer's format.

The second is the better fixture because it tests the FORMAT CONTRACT between
mkfs and the kernel in one file; the first is the better harness feature.  Both
are small.

### Round 90: yfs_init verified at runtime, yfs_lookup NOT

Built the format-contract fixture (a t* program that lays a YFS1 image into one
page with 256-byte blocks and reads it back).  Result at runtime:

    yfs true ino -1 n 0 c 00
       ^init OK   ^lookup FAILED

so the superblock path is exercised and correct -- "YFS1", version 1, block size
and root inode are all read from the image, which is why yfs_init answers true
and the block size is taken from the superblock rather than hard-wired -- while
yfs_lookup returns -1 on an image whose root inode, entry count, entry block and
entry bytes this program wrote itself, immediately before the call.

The fixture was REMOVED rather than committed, and that is the round's real
lesson: its .expected was captured from the failing run, so it "passed" while
asserting `ino -1`.  Generating an expectation from a run proves nothing unless
the run's OUTPUT is read first; that is the second time this run has bitten (the
u006 fixture with `read -14`), and it is the reason the expectation is now checked
by eye before it is committed.

Next: debug yfs_lookup against this hand-built image.  The candidates, in order:
the entry stride/offset (8 + name_len rounded to 4 vs the 8-byte header), whether
kernel.peek8 inside os/kernel/yfs.y sees the same bytes the fixture wrote with
kernel.poke_va8 (physical peek plus DIRECT_BASE versus a virtual poke -- at boot
low memory is identity-mapped, so they agree, but that is worth confirming rather
than assuming), and string indexing in a kernel program (name[i]).

### Round 91: the YFS format is right; the READER'S STATE is what fails

Measured, not guessed.  First, the peek/poke question: a kernel program writes
89,70 at a page and reads them back -- `peek_va8` and `peek8` both give 89 70, and
a 16-bit read gives 256.  So the fixture's `poke_va8` writes ARE visible to the
physical `peek8` the module uses (at boot low memory is identity-mapped and
page_alloc returned 0x118000), and candidate 2 is dead.

Then every value yfs_lookup depends on, printed in one run from a fixture that
builds the image itself:

    ok=true u32@4=1 u32@8=256 u32@20=1 cnt=1 blk=2 nl=2 len=2 c0=104 n0=104 look=-1
                                                                           ^^^^^^^

Magic, version, block size, root inode, entry count, entry block, name length,
len(name), the byte in the image and the byte in the string are ALL correct --
including string indexing in a kernel program -- and yfs_lookup still answers -1.

So the format contract is not in question and the bug is in the reader's own
state: yfs_lookup does not see what yfs_init established.  The prime candidate is
the module's top-level `let`s (yfs_phys, yfs_ok, yfs_block_size, yfs_root) not
being retained across calls -- or yfs_ok reading 0, which would return -1 on the
first line -- and the way to tell it apart from everything else is to stop
relying on them: give the reader an explicit context (pass the image address,
block size and root inode into each call, or hold them in one record the caller
owns) and re-run this exact probe.  If it then answers 2, module-level state
across calls was the whole bug; if not, the next suspect is the return of
yfs_u32(e + 4) in the match arm.

The probe is the valuable artifact here: it prints every input AND the result, so
the next attempt starts from a known-good image instead of from a guess.

### Round 92: three lines left, and the module is not losing state

The discriminator: the SAME lookup logic, written inline in the fixture, against
the same image, in the same run as the module's call.

    inline=2 mod=-1 base=1

* `inline=2` -- the logic is right: entry count, entry block, name length, the
  two name bytes and the inode field, masked and strided exactly as the module
  does, produce inode 2.
* `base=1` -- yfs_size(1) (the root inode's entry count) reads the right memory,
  which needs yfs_phys AND yfs_block_size to be set and RETAINED across calls.
  So module-level state is NOT the bug, and yfs_ok is presumably set too.
* `mod=-1` -- and yfs_lookup still fails.

That leaves exactly three lines inside yfs_lookup/yfs_name_at that the outside
cannot see:

  1. `if (yfs_ok == 0) { return 0 - 1; };`  -- the only early return that does
     not depend on the image, and the only difference between yfs_size (works)
     and yfs_lookup (fails) that is visible from outside;
  2. `if (nl == len(name) && ...)`  -- len() applied to a STRING PARAMETER (the
     probe only ever measured len("hi") on a literal);
  3. `yfs_name_at`'s `kernel.peek8(addr + i) != name[i]`  -- indexing a string
     PARAMETER (again, only a literal was measured).

The next step is instrumenting the module itself, because external probes cannot
see inside it: a temporary yfs_debug() returning yfs_ok, and a print inside
yfs_name_at's loop showing i, the byte and the compared character.  That is a
five-minute change and it ends the guessing; the alternative -- porting these
three lines into the fixture one at a time -- costs three round trips.

### Round 97: the filesystem-to-ring-3 boot path WORKS (u007_fsexec)

The driver builds a YFS1 image in memory, copies the program's ELF into it as the
file /prog, and loads and runs it OUT OF THE FILESYSTEM: yfs_init,
yfs_lookup_path("/prog"), yfs_size, elf_map on the file's own data block, then
vm_new_dir/task_frame/sched_add/task_start.  The transcript:

    fs ok=true ino=2 size=405
    from the filesystem

So the path a real system takes -- filesystem bytes to a ring-3 process -- is
exercised end to end here, with the ELF coming from YFS1 rather than a raw module,
which is what /init, /bin/sh and /bin/ycc will use.

ONE BUG FOUND, and the fixture is committed without an .exit because of it: the
run ends with qemu status 1, not the 19 that kexit(9) produces, so after a program
loaded from the filesystem prints and exits, the machine does not reach the
driver's kexit(9).  It is the same shape as this branch's first bug (exit_group
returning somewhere unexpected) and it is the next thing to chase; the fixture
keeps its transcript check meanwhile, which is what makes the boot path itself
safe from regressions.

## The whole gate after the kernel work (round 98)

`JOBS=8 make test`, with every kernel change of this run in place:

    port 151/151 (both halves, all shards)      pe-port 151/151
    native 229/229                              native-examples 15/15
    examples 15/15   audit 65/65   ycc-units 34/34   debug 27/27   link 23/23
    pkg 164/164      test_net 31/31             math / gc / kernel / treeshake / std-suites green

The only failing suites are the three PRE-EXISTING ones, each established by
measurement rather than assumed:

  * lsp and coverage -- documented as pre-existing in master's own commit message
    ("make check green except the pre-existing lsp/coverage environment
    failures");
  * ycc -- one case, "ysh eval compiles and runs through ycc", which the MAIN
    TREE's compiler fails IDENTICALLY (round 79): ysh.y passes --no-exec for every
    eval while the prelude it splices calls exec.

So nothing in this branch's kernel work moved a hosted program's bytes or
behaviour: the port gate recompiles the whole corpus with both engines and
compares bytes, in all its shards, and it is 151/151.

### The exit path after a user program, recorded honestly

u007_fsexec (filesystem -> ELF -> ring 3) runs and prints, then ends with qemu
status 1 instead of the 19 kexit(9) produces -- and u005_ipc has behaved the same
way since it was written, which is why IT never had an .exit either.  So this is
not filesystem-specific: after a user program exits, the machine does not return
to the driver, and the shape matches this branch's first bug (exit_group returning
somewhere unexpected).  Both fixtures keep transcript checks, which is what
protects their paths meanwhile; the exit path is the next thing to fix, and it
should be fixed for BOTH cases at once.

### Round 99: the exit path, read rather than guessed -- two defects

Reading `task_start` and `y_sched_pick` settled it, after several rounds of
inferring:

1. `y_sched_pick` RETURNS 0 when no task is runnable (`if (found < 0) {
   need_resched = false; return 0; }`) and BOTH switch sites do `mov %rax, %rsp`.
   A zero stack is a triple fault -- qemu's status 1, exactly what u005_ipc and
   u007_fsexec have shown all along.  After the last user program exits there is
   nothing to resume, so this is the path every one of those runs took.
2. `task_start(i)` calls `y_enter_frame(tasks[i].rsp)` with no save of the
   caller's context, so task 0 -- the boot context that `sched_init` registered
   and that the driver's `kernel.kexit(9)` line lives in -- is never resumable:
   its saved rsp is a plain kernel stack, not a canonical frame, so the pops and
   iretq would land anywhere.

TRIED AND REVERTED: making the pick idle when nothing is runnable turned a triple
fault into an idle, and dropped test/kernel to 43/1/44 -- some cases that
previously exited now never do, so the machine outlives its expected kexit.  The
fix is right in principle but it is not this one line: `found < 0` is clearly
reached in states other than "the last task exited", and which states those are
has to be measured before the pick changes.  Reverted to keep the suite green,
with the diagnosis kept.  (2) is the real reason a driver never reaches
its kexit after starting a task, and it needs a design decision rather than a line
change: either give the boot context a canonical frame at sched_init so the
switch can resume it, or have task_start save a resumable kernel context and
switch through the scheduler like everything else.  Until then, no fixture whose
driver calls task_start can assert an .exit -- which is why u005_ipc and
u007_fsexec have none, and that is a property of the design, not an oversight.
