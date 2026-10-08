# BUGS.md — known defects in the Y compiler

Filed while building the kernel target (`ycc --kernel`, branch `kernel`,
worktree `.worktrees/kernel`).  Every entry has a repro, the observed and
expected behaviour, and — where it was found — the code site that causes it.
**Nothing here is fixed** unless the entry says so.

Each repro is a complete program.  `ycc` and `cycc` (the C twin) agree on
every one of them, so each is a shared semantic/emitter defect rather than a
port divergence.

---

## 2. Kernel-mode gaps found while building the target

These are not compiler bugs so much as the kernel target's own limits, and
they are listed in `src/y/KERNEL.md` under "Known limits".  Repeated here so
the bug list is the one place to look:

* the SSE state is not saved across an interrupt (fine today: no handler
  floats);
* only the 8259 path is wired — no APIC, no IOAPIC, no MSI;
* CPU exceptions other than the `irq` lines land on a stub that stops the
  machine: no `#PF`/`#GP` diagnostic, no error-code-aware entry;
* `y_alloc_map` bumps through a fixed 16 MB `.bss` arena and never frees, and
  the multiboot memory map is not read, so a kernel cannot see the RAM it has;
* `-g` is refused for a kernel image (the debug writers are ELF64/DWARF64);
* there is no user mode, no syscall entry, no scheduler, no filesystem.

**Why this class is still here.** `ytest fuzz` cannot find it: it
looks for crashes and for the two compilers disagreeing, and both compilers
agree on this (they share the emitter's logic). It also cannot be found by
comparing against a reference program, because the wrong answer is silent.
It was found by hand, and the shape to test is "a closure with a captured
variable on the right of a comparison in a condition".

---

## 4. WITHDRAWN — `CLK_TS`'s missing initializer is correct

**This entry's cause was wrong; kept for the record.** The cell IS defined and
its initializer is legitimately dropped: `CLK_TS`'s only reader is `clock_us`,
which is itself dead in a kernel program, and the linker's marks exist exactly
to delete the range for a dead cell.  Also checked and cleared while chasing
this: the loader maps `memsz` pages and explicitly zeroes the `[filesz, memsz)`
tail (`os/kernel/elfload.y:elf_segment`), so the program's new two-page
text segment (`FileSiz 0x1054`, `MemSiz 0x2000`) and its larger RW segment
(`0xc0`) are both handled.

What survives as fact and is worth keeping: a kernel `-S` from the pre-merge
compiler contained four `CLK_TS` mentions (cell + `ygiS_`/`ygiE_` range), master
at 9078372 contains one (the cell), and the kernel image also no longer contains
`y_clock_us` at all — i.e. the shake is consistent, not broken.

The real cause of `trap vector=14 err=5 cr2=16` (a user-mode read at 0x10, from
a program that prints nothing first) is still open.  Ruled out with evidence so
far: the allocator (an allocation-free program fails), the collector (excluded
from kernel images by `--kernel` forcing `--gc=never`), the heap-cell split,
`task_frame`/the fabricated frame, the argv path (a three-element argv is
correct in a kernel), the loader's segment copy and bss zeroing, and delivery
in the IPC path (the server's `ipc_recv` demonstrably returns).  The next
measurement that pays: qemu `-d int` on `u001_hello` to get the faulting USER
RIP, and disassemble a `-g` build there — that is what identified the previous
one (a returned `exit_group`) within a single round.

---

## 5. WITHDRAWN — `FileSiz 0x150` is normal for that program

**Wrong, kept for the record.** `FileSiz 0x150` (336 bytes) looked impossible
for a program whose `-S` listing is long, but the control settles it: the MAIN
tree's compiler (upstream master, untouched by this work) emits the *identical*
segment layout for the same program, and the resulting binary **runs correctly
natively** -- both from the main tree's compiler and from this branch's.  A
program whose only work is `puts` links almost no runtime, so 336 bytes of text
is right.

The lesson, which cost a round and a wrong bug report: **run the main tree's
compiler as a control before filing anything.** It is one command and it
immediately separates "this branch's change" from "upstream behaviour".  The
previous erroneous entry (§4) would also have been caught by it.

What DOES survive and is worth keeping: with the POST-merge kernel image a
program faults (`err=5`, cr2 = 0/0x10/0x20), and the pre-merge kernel image
runs the SAME post-merge program correctly (measured in round 14: "old kernel +
new program" printed `minimal`).  So the fault is in the kernel IMAGE the
post-merge compiler emits, not in the program -- and among the kernel cases
only the ones that ENTER USER MODE fail (`t011_ring3` plus the four `u*`),
which points at that path in the kernel image.
