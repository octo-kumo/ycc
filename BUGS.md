# BUGS.md — known defects in the Y compiler

Filed while building the kernel target (`ycc --kernel`, branch `kernel`,
worktree `.worktrees/kernel`).  Every entry has a repro, the observed and
expected behaviour, and — where it was found — the code site that causes it.
**Nothing here is fixed** unless the entry says so.

Each repro is a complete program.  `ycc` and `cycc` (the C twin) agree on
every one of them, so each is a shared semantic/emitter defect rather than a
port divergence.

---

## 1. A closure's captured variable on the RIGHT of a comparison compares the wrong thing

**Severity: high.**  The comparison silently answers the wrong way; nothing
diagnoses it, and the value is right everywhere else, so it reads as a logic
bug in the program.

**Repro**

```y
def lit_left(v: long) -> bool { let g = () => { if (4 == v) { true } else { false } }; g() };
def lit_right(v: long) -> bool { let g = () => { if (v == 4) { true } else { false } }; g() };
print("4 == v (v=4): " + tostring(lit_left(4)));    // prints false, should be true
print("v == 4 (v=4): " + tostring(lit_right(4)));   // true
```

**Observed** `4 == v (v=4): false` — expected `true`.

**What is and is not affected** (all measured, both compilers):

| shape | result |
|---|---|
| `if (4 == v)` inside a closure, `v` captured | **wrong (false)** |
| `if (x == v)` inside a `foreach` closure | **wrong (false)** |
| `if (w == v)` where both are captured | **wrong (false)** |
| `if (x == 4)` (right operand a literal) | right |
| `if (v == 4)` (right operand a literal) | right |
| `let b = (4 == v);` — the value form, not a branch condition | right |
| the same comparison at function scope, no closure | right |
| float comparisons | right |
| `x + v`, reading either operand | right (values are correct) |

So: the bug is the **condition fast path** (`gen_cmp_flags`) whenever the
right operand is a captured identifier, and `<`, `>`, `<=`, `>=`, `==`, `!=`
all take it (`int_cmp_jcc` non-zero).

**Root cause.**  `src/y/native.y`:

* `gen_cmp_flags` (native.y:7012) keeps the left operand in `%rcx` instead of
  pushing it, on the claim that "when the right operand is a leaf it touches
  neither %rcx nor the stack":

  ```
  st = gen(st, node.l);
  if (leaf_expr(node.r)) {
      st = emit_insn(st, insn.F_MOV_R_R, insn.R_RAX, 64, insn.R_RCX, 64, ...);  // left -> rcx
      st = gen(st, node.r);                                                      // clobbers rcx
      emit_insn(st, insn.F_CMP_R_R, insn.R_RAX, 64, insn.R_RCX, 64, ...)          // cmp rax, rcx
  ```

* `leaf_expr` (native.y:4959) answers **true for every `K.id`** — but a
  captured id is not a leaf: `gen_cap_ptr` (native.y:4040) reads it as
  `mov <closure>(%rbp), %rcx; mov <slot>(%rcx), %rax; mov (%rax), %rax`, so
  `%rcx` no longer holds the left operand when the `cmp` runs.

The emitted code for `if (x == v)` inside a `foreach` closure is the proof —
the left operand's load is dead, and the comparison is against the closure
record's own address:

```
mov 16(%rbp), %rax     ; x
mov %rax, %rcx         ; left -> rcx   (the fast path)
mov 24(%rbp), %rcx     ; closure base  (the capture read clobbers rcx)
mov 8(%rcx), %rax      ; the cell
mov (%rax), %rax       ; *cell = the captured value
cmp %rax, %rcx         ; compares 4 against the CLOSURE POINTER, not against x
jne ...
```

**Suggested fix.**  `leaf_expr` needs the environment: an id whose `env_find`
slot has `kind == "capture"` (and `kind == "box"`, which is boxed the same
way) is not a leaf.  Either thread `st` into `leaf_expr` or add the test at
the one call site that matters, `gen_cmp_flags`:

```y
if (leaf_expr(node.r) && !(node.r.k == K.id && boxed_id(st, node.r))) { ... }
```

`gen_float_bin`'s fast path (native.y:4989) shares the `leaf_expr` call but
keeps its left operand in `%xmm0`, which a capture read does not touch — it
was measured right, but the predicate is the same one and a fix should
consider both.  The C twin's `gen_cmp_flags`/`leaf_expr` (`src/c/native.c`)
need the same change.

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

**Why this class is still here.** `test/fuzz/fuzz.sh` cannot find it: it
looks for crashes and for the two compilers disagreeing, and both compilers
agree on this (they share the emitter's logic). It also cannot be found by
comparing against a reference program, because the wrong answer is silent.
It was found by hand, and the shape to test is "a closure with a captured
variable on the right of a comparison in a condition".

---

## 3. A duplicated section in `std/kernel.y` silently wins on the later copy

Not a compiler defect but filed here because the compiler's behaviour is what
makes it a trap: a Y unit with two top-level definitions of one name **warns**
("declared more than once; the last declaration counts") and compiles, using
the *last* one.  In `.worktrees/kernel/src/y/std/kernel.y` a patch meant to
move declarations above their first use re-inserted a ~400-line section, so 32
defs (`sys_fork`, `sys_wait4`, `peek_va8`, `sched_add`, …) exist twice, at
roughly lines 860-1200 and 1240-1560.

Consequence: editing the **earlier** copy changes nothing and produces no
error, and the warning is easy to miss because it appears once per kernel
compile rather than once per build.  The last full `make test` (whose
`fixpoint` suite requires warning-free `src/y` and `src/y/std`) is what would
have caught it; per-round verification on this branch was the kernel suite
alone.

Fix: keep the later copies (they are the newest — the earlier `sys_fork` and
`sys_wait4` predate the exit-status work), delete the earlier section, rebuild,
and run `test/kernel` plus `test_fixpoint`.

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
