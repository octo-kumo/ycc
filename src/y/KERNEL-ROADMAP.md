# Writing an OS in Y — what works, what is missing, what it will take

`KERNEL.md` is the design of `ycc --kernel`.  This is the honest audit: what
a kernel writer gets today, where the assembly is (and why it cannot move),
what the language cannot express yet, and the order in which the missing
pieces have to land for the goal —

> user/kernel separation, user-space programs written in Y, a filesystem,
> virtual memory, process isolation, single-core multithreading

— with "no assembly, very little code, but every part replaceable".

Everything below was measured in this tree unless it says otherwise.

---

## 1. What a kernel can do today

| layer | where | Y | assembly |
|---|---|---|---|
| boot (Multiboot, long mode, GDT, page tables) | `arch_x64.y` blob, `kelf.y` | — | ~130 bytes, transcribed from `experiments/kernel/boot.s` |
| console (COM1) | `arch/kernel.s` | — | 62 instructions |
| interrupt controllers (8259) | `arch/kernel.s` | — | 44 instructions |
| the Y heap (`y_alloc`) | `prelude.s` + `arch/kernel.s` | — | 10 (the page source) |
| traps (div0, OOB, cast, OOM, unwrap) | `arch/kernel.s` | — | 25 instructions |
| IRQ handlers | `irq N def` + `std/kernel.y` | your handler | generated stubs |
| CPU exceptions | generated stubs + `y_kernel_trap` | the report | generated stubs |
| raw memory access | `std/kernel.y` | 40 lines | 3 (cr2/cr3) + 4 (invlpg) |
| Multiboot info + memory map | `std/kernel.y` | 120 lines | 3 |
| physical page allocator | `std/kernel.y` | 60 lines | — |
| virtual memory (walk, map, unmap, translate, address spaces) | `std/kernel.y` | 150 lines | 4 (cr3 get/set) |
| serial input, echo, timer | `test/kernel/*.y` | ~20 lines each | — |

**The whole kernel runtime is 205 assembly instructions** (`arch/kernel.s`,
measured) and about 512 lines of Y (`std/kernel.y`).  Two of the largest
assembly blocks are init sequences that any OS writes once (the 16550's
23 instructions, the 8259's 32) — not primitives.

Working, booted by `test/sh/test_kernel.sh` under qemu:

* `puts`/`print` to serial, and `tostring`, arrays, records, maps, floats
  (SSE), the allocator — the ordinary language, unchanged;
* `irq N def` handlers on any of the 16 lines, type-checked, with the PIC
  line unmasked automatically (t002 IRQ4 echo, t005 IRQ0 timer);
* CPU exceptions with a real report: vector, error code, CR2 for `#PF`,
  the name for `#GP` (t007 provokes a page fault);
* the Multiboot memory map, a physical page allocator and a 4-level
  virtual-memory walker — `vm_map`, `vm_map_range`, `vm_unmap`,
  `vm_translate`, `vm_new_dir`, `vm_switch` — all in Y (t006 checks 16
  facts, including address-space isolation and 2 MB-page translation).

Three things the language turned out to give a kernel that are not
obvious from outside, and all three are load-bearing:

* **function values** (see limit 1 below): a dispatch table is an array of
  records holding defs, built as a literal and called through the field.
  A syscall table, an IRQ table and a driver table all work today;
* **pointer arithmetic on a global anchor**: raw memory access, and so the
  whole page-table walker, is Y;
* **closures with shared captures**: a handler and its state can travel
  together (`let d = [{name: "ata", state: c, go: ata_irq}]`), as long as
  every entry has one shape.

## 2. Where the assembly is, and why it cannot move

Every assembly instruction in the kernel is one of six things.  None is
"logic"; each is a machine operation with no Y spelling.

| primitive | instructions | why it is assembly |
|---|---|---|
| `in`/`out` (port I/O) | 4 (two forms) | Y has no port statement |
| `mov %crN` (cr2, cr3) | 3 each | the register file is GPRs and XMM; a control register is a new operand kind |
| `invlpg` | 1 | ditto, and it takes a memory operand only |
| `cli`/`sti`/`hlt` | 1 each | no Y statement changes the interrupt flag |
| `iretq` / `lgdt` / `lidt` / `ltr` | 1 each | descriptor-table and return instructions |
| the 32-bit trampoline | ~130 bytes | `enc64.y` is x86-64-only, and the entry runs before long mode |

The escape hatch is `ndef`: `ndef y_cr3_get() -> long = "y_cr3_get";` is how
Y reaches any of them, and a *program* can declare its own `ndef` for a
device the kernel does not know.  That is the "may customize any part"
property, and it works today for anything the assembler can encode — the
one real limit is that a new instruction may have to be added to
`enc64.y`/`enc64.c` first (which is a small, tested change: the kernel's ten
new mnemonics in this branch were ~90 lines across both copies).

**The trampoline is the one piece a kernel writer cannot replace in Y.**
It is a fixed byte blob the compiler emits.  Everything after the far jump
is ordinary Y.

## 3. What the language cannot express yet

These are the real limits, in the order they will bite.

1. **A function type cannot be WRITTEN.**  (The values are first-class;
   only the type syntax is missing, and the difference matters a lot.)
   All of these work today, measured:

       def twice(n: long) -> long { n * 2 };
       let f = twice;                    // bind a def
       let t = [h1]; t += h2; t[0]();    // a growable array of functions
       let tb = [{n: 1, f: sys3}, {n: 2, f: sys4}];   // a dispatch table
       print(tb[0].f(1, 2, 3));          // call through the field
       let cl = [{name: "c", go: () => { c + 1 }}];   // a closure in a table
       def pick(n: long) { if (n == 0) { h1 } else { h2 } };  // returned
       pick(1)();

   What is refused is the *annotation*: `def() -> void` is not a type
   ("expected '}' in a type, got 'def'"), so
   * a parameter cannot be annotated with one -- no `sort(cmp)`, no generic
     `map`, no callback parameter;
   * `type Handler = () -> void` cannot be declared, so a record TYPE with a
     function field cannot be written: only a record LITERAL, with an
     inferred type, and an array of them must agree in signature.  The
     checker prints the very type the parser will not read --
     `array element: expected { name: str, go: () -> void }, got
     { name: str, go: (long, long) -> long }`;
   * an empty array cannot be given a function element type, so a table
     starts from a one-element literal (`let t = [h1]; t += h2;`).

   **For OS work this is much smaller than it looks**: a syscall table, an
   IRQ dispatch table and a driver table all have ONE signature by
   construction, so each is a literal of records with a function field and
   works today.  `irq N def` and the `y_`-prefix override are not
   workarounds for this -- they are ergonomics and type checking.  The gap
   is the general case: a callback handed *in*, a comparator, a table whose
   entries disagree in shape.
2. **No integer-to-pointer conversion.**  A `*T` comes only from `&x` or
   `arr.ptr`, so reaching a physical address means taking the address of a
   global and moving it with pointer arithmetic (std/kernel.y's `mem_word`
   anchor).  It works, but it is a hack: it needs pointer arithmetic to be
   unbounded (it is), and every access pays a subtraction and a division.
   A cast (`*long(addr)`) would delete `mem_word` and make the kernel's
   memory code look like what it is.
3. **Records cannot describe hardware.**  A record is its set of fields,
   laid out by field name, with a type descriptor in front.  A GDT entry, an
   IDT entry, a TSS, an ATA task file, a PCI BAR — all are packed bit
   fields at fixed offsets.  So the kernel builds them with `poke64`/`poke8`
   and hand-computed offsets.  A `@packed`/`@offset(N)` record attribute (or
   even bitfields) would turn that into readable declarations.
4. **`y_alloc` traps on out-of-memory** (`y_alloc_fail` halts the machine).
   A kernel allocating for a *process* wants to fail the request, not die.
   The language's `!` unwrap has the same shape: `none` is a trap by
   default.  A kernel needs fallible allocation and fallible unwrap as
   first-class.
5. **No atomics, no memory-ordering vocabulary.**  Single-core makes it moot
   for the scheduler (interrupts off is enough), but a driver talking to a
   device that also writes memory (DMA) has no way to say "read this
   again" — and the emitter may fold a repeated MMIO read.
6. **No `volatile`.**  Same root as 5, same consequence for MMIO.
7. **Loop and comparison codegen prefers the fast path**, which is what bug
   #1 in `BUGS.md` is: a closure's captured variable on the *right* of a
   comparison answers wrong.  Kernel code hits this shape
   (`if (x == limit)`), so it is worth fixing before anything bigger.

Nothing in this list needs a language *redesign*; each is a small, local
feature.  But #1 and #2 are the two that decide how much of a kernel is
Y and how much is glue.

## 4. What each goal still needs

### User/kernel separation

Have: per-process page directories (`vm_new_dir`, `vm_switch`), an IDT the
compiler generates, `y_kernel_trap`.

Missing, and where it goes:

* **ring-3 GDT + TSS.**  The GDT is 3 entries in the trampoline blob (null,
  ring-0 code, data).  Building a 6-entry GDT *in Y* is just `poke64` into a
  `.bss` array; what needs assembly is `lgdt` and `ltr` (2 instructions),
  and `mov %ax, %ds`/`%ss` (2 more).  The TSS is a 104-byte packed structure
  — poke64 territory (see limit 3), and it is where the ring-0 stack pointer
  for interrupts from ring 3 lives.
* **A ring-3 entry.**  One stub: build an `iretq` frame (SS, RSP, RFLAGS,
  CS, RIP) and `iretq`.  ~15 instructions of assembly, once.
* **A syscall gate.**  `int 0x80` needs one IDT entry with DPL=3 (the
  generated IDT can do that — it is one more field) and a stub that pushes
  the trap frame and calls a Y dispatcher; `syscall`/`sysret` needs
  `wrmsr` for EFER.SCE, STAR and LSTAR (3 instructions plus the MSR
  numbers) and is faster.
* **User pages.**  `vm_map` already takes flags; `PTE_U` is defined.  A user
  program's pages are `PTE_U|PTE_W` mappings of freshly allocated physical
  pages.
* **A syscall table in Y.**  `let syscalls = [{n: 0, f: sys_read}, ...]` as a
  top-level literal, indexed by number and called through the field.  That
  is an indirect call, not a comparison chain (limit 1 costs nothing here:
  every entry has the same signature).

Estimate: **~80 lines of assembly, ~250 lines of Y** for a ring-3 "hello,
world" that makes one syscall.

### User-space programs written in Y

This is a compiler feature, not a kernel one, and the kernel target already
has the machinery: `--kernel` sets `res_target`, and every target-specific
decision in the emitter is behind `target_is_kernel()`.

A `--target=user` would need:

* a **different writer**: an ELF (or flat binary) at a user load address —
  `kelf.y` is a variant of `elf.y` already, so this is a third case in
  `asm_image`;
* a **different runtime**, and this is the good news: the six-line
  replacement of `y_os_write`/`y_os_read`/`y_os_exit` with `int 0x80`
  is all a user program needs.  The string/array/float cores are pure
  computation and work unchanged.  `y_alloc` needs a `brk`-style syscall
  instead of `mmap`;
* **gating**, exactly like the kernel's: no port I/O, no control
  registers, no `irq` declarations, and `std/kernel.y` refused.

The ABI is not a problem: Y passes arguments on the stack, and a syscall
stub can read them from the same place the kernel's `os_call` targets do.

### A filesystem

Nothing in Y blocks it.  What it needs:

* a **block driver** (ATA PIO is port I/O plus Y logic: poll the status
  register, write LBA/command, `rep insw` — the last one is a new mnemonic,
  or a loop of `inb` in Y);
* a **buffer cache** — arrays and maps in Y;
* an on-disk format — Y writes it.

The one structural gap: **there is no way to embed files in the image.**
The clean answer is the Multiboot modules list (`mods_count`/`mods_addr`,
already readable with `peek32`) plus `qemu -initrd`: the boot loader puts a
file in memory and the kernel finds it by address.  From there an initrd
(tar, or a Y-defined simple format) is a read-only filesystem in an
afternoon.

Missing language support: none, beyond limits 4 and 5 (a failing read
should not halt the kernel).

### Virtual memory

Have: 4-level walk, `map`/`map_range`/`unmap`/`translate`, large-page
translation, per-address-space directories, `vm_switch`.

Missing:

* **`free`.** The allocator bumps and never frees, so a long-running kernel
  leaks.  A free list over the region is ~40 lines of Y.
* **Demand paging and copy-on-write**, which need `#PF` to be *resumable*:
  today `y_kernel_trap` halts.  A resumable fault means the stub must
  return through the frame the CPU pushed, and the handler must know whether
  it can fix the fault.  That is ~30 lines of stub work (the frame is
  already saved) plus the Y policy.
* **A higher-half kernel.**  Today the kernel owns `PML4[0]` — the same
  entry user space wants — so `vm_new_dir` has to copy the kernel's PDPT
  entry, and any mapping the kernel makes outside its first gigabyte is
  invisible to a new address space.  Moving the kernel to `PML4[256]`
  (the standard `0xFFFF800000000000` base) removes the copying entirely and
  is a linker/`kelf.y` change (load address and entry), not a redesign of
  the code — every address the emitter produces is rip-relative, which is
  why the current image already boots at 1 MB with no source change.

### Process isolation

Have: separate directories, `vm_switch`, `vm_new_dir`.

Missing: a per-process kernel stack and the TSS `RSP0` update on every
switch (Y), a process table (Y records), ring-3 transitions (the stubs
above), and the higher-half move.  Until the higher half lands, "isolation"
is partial by construction: `PML4[0]` is shared.

### Single-core multithreading

Have: the timer works (t005), the IDT works, the exception stubs already
save and restore a frame.

Missing, and it is small:

* **a context switch**: `y_switch(from: *long, to: long)` — push the
  callee-saved set, save `%rsp` through `from`, load `%rsp` from `to`,
  pop, `ret`.  ~20 instructions of assembly in `arch/kernel.s`.
* **kernel threads in Y**: a task record (stack pointer, state), a queue,
  and a `yield` that calls `y_switch`; the first thread's stack is built by
  pushing a start address onto a fresh page.  ~100 lines of Y.
* **preemption**: the timer stub must call the scheduler and *return into
  whatever stack the scheduler picks*.  Today the IRQ stub restores the
  register set and `iretq`s to the interrupted code.  A scheduler-aware
  stub instead saves the whole register set (not just the caller-saved
  one), calls Y, and reloads `%rsp` from the current task — the same
  `y_switch` machinery, ~40 lines.

A task table can hold its entry points directly -- `let tasks = [{stack: 0,
go: thread_a}, ...]` -- because every entry has the same `() -> void`
signature, so the scheduler is an ordinary Y loop that calls `task.go()`.

## 5. The trade: design freedom given up

The goal says "at the cost of some design freedom".  Concretely:

* **Identity map at 1 MB, kernel in `PML4[0]`.**  Fine for a PoC; the fix
  (higher half) is a load-address change.
* **`y_alloc` is a bump allocator over a 16 MB `.bss` arena** and never
  frees; the Y heap and the physical page allocator are two separate
  allocators today (`phys_alloc` for pages, `y_kernel_end`+ for the heap).
  Unifying them is ~30 lines of Y, and it is the right thing once `free`
  exists.
* **Records are exact and name-laid-out**, so hardware structures are
  hand-poked rather than typed (limit 3).
* **No writable function type**, so a callback cannot be passed in and a
  function-typed record cannot be declared (limit 1) -- tables work, generic
  higher-order code does not.
* **Allocation failure traps** (limit 4).
* **One program per compile**: a kernel and its user programs are separate
  compilations with different targets.  That is the intended shape anyway.

What is *not* given up: the language, the std library's pure-computation
half, the checker, and the ability to replace any hook — `y_os_write` for
the console, `y_alloc_map` for the heap's page source, `y_kernel_trap` for
the fault report, `irq N def` for interrupts, `y_`-named defs for the rest.

## 6. Order of work

Each step is useful on its own and none needs the next.

| # | step | Y | asm | unblocks |
|---|---|---|---|---|
| 0 | fix `BUGS.md` #1 (captured value on the right of a comparison) | — | — | every `if` in kernel code |
| 1 | `free` + one allocator for pages and the heap | 70 | — | long-running kernels |
| 2 | resumable `#PF` (save-the-frame stub + Y policy) | 80 | 30 | demand paging, COW |
| 3 | `*T(addr)` cast in the language | — | — | deletes the `mem_word` hack |
| 4 | ring-3 GDT/TSS/`iretq` + one syscall | 250 | 80 | user/kernel separation |
| 5 | `--target=user` (a third writer + the syscall runtime) | 200 | 20 | user programs in Y |
| 6 | friendly `y_alloc` (fallible) | 40 | — | a kernel that survives OOM |
| 7 | cooperative threads (`y_switch`) | 100 | 20 | multithreading |
| 8 | preemptive threads (timer-driven `y_switch`) | 60 | 20 | real scheduling |
| 9 | Multiboot modules + an initrd (read-only FS) | 150 | — | loading user programs |
| 10 | ATA PIO block driver | 200 | 20 | a real filesystem |
| 11 | higher-half kernel | — | — | real isolation, no PDPT copying |
| 12 | a writable function type (annotations, `type` aliases) | — | — | callbacks, comparators, generic tables |

Steps 3 and 12 are compiler work; 0 is a compiler bug fix; the rest are a
kernel.  Step 12 is smaller than "function values" sounds: the values exist,
the type printer prints them, and what is missing is teaching the type
parser to read `(...) -> T` so it can be written.  The sum is roughly **1,100 lines of Y and 200 of assembly** for
everything in the goal list except the filesystem, which is another few
hundred of Y.
