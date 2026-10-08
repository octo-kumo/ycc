# Y-OS on the `kernel` branch — full handover

Everything about the microkernel work on this branch: what exists, what is proven, what is
broken, what is parked, and the rules that were learned by breaking them. `src/y/KERNEL.md`
is the chronological log (round by round); **this file is the summary you want first.**

## 1. Where it is

| | |
|---|---|
| worktree | `.worktrees/kernel`, branch `kernel` |
| HEAD at handover | see `git log -1` (the last commit is "u021_rm -- rm from ring 3") |
| kernel suite | **82 passed, 0 failed / 82 total** with the shipped `./ycc` and `./cycc` |
| blessed compiler | `refs/ycc.ref` = `495c8127b96579aa` (re-run `make rebless` after any `src/y/std/*.y` or `arch/*.s` change) |
| pre-merge fallback | `git tag pre-unmerge` (the pre-merge 33/33 line) |

## 2. How to build and run

    # the compiler (C copy) and the Y copy
    make cycc                      # ~5 s
    ./cycc -o ycc2 src/y/ycc.y     # a Y compiler built by the C one (~5 s)

    # the kernel suite: builds every test/kernel case with BOTH engines, compares the
    # images, boots them under qemu, compares serial output and the exit status
    YCC=$PWD/ycc CYCC=$PWD/cycc bash test/sh/test_kernel.sh

    # one case by hand
    ./ycc --kernel test/kernel/u007_fsexec.driver.y -o /tmp/a.img
    ./ycc          test/kernel/u007_fsexec.user.y   -o /tmp/a.prog
    qemu-system-x86_64 -kernel /tmp/a.img -initrd /tmp/a.prog -serial stdio \
        -display none -no-reboot -device isa-debug-exit -monitor none

    # the whole project gate (~90 s) and the 22 suites (~47 s)
    make check ; make test

**Rules that cost rounds here, every one of them:**

* after an embedded `arch/*.s` change rebuild **both** engines before reading a suite number;
* `src/y/std/*.y` is **embedded** in the compiler now, so a std edit needs both engines
  rebuilt too — `make rebless` is how that is checked;
* an instrumented build is only believed if the run that produced the transcript used it:
  a stale image makes a run say anything;
* run the **main tree's** compiler as a control before believing this branch broke something.

## 3. Milestones

**M0 — address layout: DONE.** Heap out of `.bss`, kernel image at `0x100000`–`0x200000`,
direct map at `0xFFFF888000000000` (PML4[273]), one physical allocator (`page_alloc`
returns *physical*; kernel stacks via `pages_alloc_va`), `kexit` through isa-debug-exit.

**M1 — ring 3: DONE.** GDT/TSS, IDT, syscall entry, ELF64 loader, user program at
`0x400000`, user stack at `0x6000000`.

**M2 — processes and VM: DONE.** Tasks, per-task address spaces, `vm_new_dir`, scheduler
with preemption at kernel exit only, `fork`, `wait4`, exit teardown, and the `TASK_BOOT`
mechanism that lets a driver run on after the tasks it started.

**M3 — IPC, console, filesystem: MOSTLY DONE.**

| piece | state |
|---|---|
| IPC over ports (`ipc_call`/`recv`/`reply`, blocking, resume) | **works**, fixture `u005_ipc` shows a full exchange |
| callee-saved frame contract (20-word canonical frame) | **fixed**, see §5 |
| console output | works (every transcript) |
| console *input* | **works**, `t012_serialin` reads a real byte from the host |
| blocking console input (IRQ 4) | **not done** — needs a PIC unmask helper and an `irq 4 def` handler |
| YFS1 format + host `mkfs` | **works**, byte-verified with `od`; multi-block files and the indirect block |
| YFS1 read side | **pinned** by `t013`–`t016` |
| fd broker + syscalls | **works**: `openat` (257, with `O_CREAT`), `read` (0), `write` (1), `lseek` (8), `close` (3), `getdents64` (217), `execve` (59, with argv), `unlinkat` (263) |
| **fs and tty servers** | **not done** — and honestly: the filesystem currently lives *in the kernel*; moving it into a user-space server needs raw device access, which is a design step |

**M4 — userland: WELL UNDERWAY.** A **shell runs programs with arguments**, and every
filesystem operation is reachable from ring 3. The plan's command set is mostly compositions
of what exists (see §6).

**M5 — `ycc` on target: NOT STARTED.** Storage is no longer the blocker (`mkfs` handles any
file size); what remains is `/bin/ycc` + `/bin/std` in the image, `/proc/self/exe`, and
enough memory.

**M6 — docs and ratchets: BEGUN.** `KERNEL.md` (the log), `BUGS.md` (compiler bugs found),
this file, the kernel harness with its image budget, and the fixture set.

## 4. The fixture set (`test/kernel/`)

Driver programs are `t*`/`x*` (kernel-only, no `-initrd`); `u*` cases are a driver plus a
ring-3 program passed as `-initrd`. `.expected` is compared as a **prefix** of the serial
output; `.exit` (optional) is qemu's raw status; `.stdin` is fed one second after boot and
works **only** for the `t*` cases (the `u*` loop runs qemu with `</dev/null`).

| fixture | what it pins |
|---|---|
| `t001`–`t011`, `x001` | boot, traps, kexit, one/two/three-task basics |
| `t012_serialin` | console INPUT: `.stdin` = "Z", output "read byte 90" |
| `t013_yfsread` | magic, version, block size from the superblock, name lookup, one-block file |
| `t014_yfsblocks` | a read crossing a block boundary |
| `t015_yfsdir` | directory entries and the 4-byte stride |
| `t016_yfspath` | nested directories and a full path walk |
| `t018_create` | create a file, write it, find it by name, read it back |
| `t019_unlink` | removal: found before, gone after, in one transcript |
| `t020_mkdir` | a directory, a child inside it, and `/d/child` resolving to it |
| `u002`–`u004` | two processes, preemption, fork/wait4 (all now exit 19) |
| `u005_ipc` | a full multi-round IPC exchange, then the driver's own kexit |
| `u007_fsexec` | filesystem -> ELF -> ring 3 |
| `u008_fsread` | `openat` + read a file from ring 3 |
| `u009_ls`, `u013_lsall` | `getdents64`: one record's layout, then the whole walk |
| `u010_cat`, `u011_wc`, `u012_catfile`, `u014_head` | argv-driven commands, whole-file loops, text contents, a bounded read |
| `u015_exec` | `execve`: a program replaces itself, forever |
| `u016_write`, `u017_grow` | byte-level write, then growing a file (block allocator) |
| `u018_sh` | the shell runs a program by name |
| `u019_args` | **a word crosses `execve`**: `sh n=2 a1=hello` |
| `u020_cp` | `cp` end to end: read + `openat(O_CREAT)` + write; the first userland create |
| `u021_rm` | `rm` from ring 3: `first=3 unlink=0 again=-2` |

## 5. The two fixes that mattered, and the invariants they produced

**(a) The shake fix (`ir_drop_inits`).** The merged compiler deleted the initializer range
of every cell its shake thought dead, and in a **kernel** image that is wrong: the shake's
roots assume a hosted program with `_start`, and a kernel has none. 24 ranges were being
deleted, including the kernel's own `cur_task`, `need_resched`, `next_pid`. The guard is one
line in both copies (`src/c/native.c`, `src/y/native.y`):

    if (target_is_kernel()) { return ir; }

Validated by the whole gate: port 151/151 both halves, native 229/229, kernel 33/33 at the
time.

**(b) The callee-saved frame contract.** A syscall that merely traps and returns often
leaves `rbx/rbp/r12-r15` alone, but one that **suspends** the task hands the CPU to code
that uses them freely. The canonical frame is therefore **twenty words**: nine syscall-ABI
slots, then the six the Y ABI promises, then the CPU's five.

* `y_syscall_entry` pushes the six **above** the nine and the temporary syscall number is at
  `104(%rsp)` (not 56);
* its tail and `y_enter_frame` pop them; the IRQ stubs (in `arch_x64.y` **and** its `src/c`
  twin) push them after their label — told apart from the trap stubs by the `y_irq_stub_N:`
  label — and their CS check is at `128(%rsp)`;
* `task_frame` writes them between RIP and the nine;
* `sys_fork`'s child frame copies **20 words** (the rax slot stays at `+48`).

Layout, from the lowest slot: `r9 r8 r10 rdx rsi rdi rax r11 rcx | rbx rbp r12 r13 r14 r15 |
RIP CS RFLAGS RSP SS`.

**(c) `TASK_BOOT`.** A driver that starts a task publishes a frame for itself
(`y_boot_frame`, reading the context through `%rbp` because Y passes arguments on the stack
and `task_start` has locals) and is parked in `TASK_BOOT`; the scheduler resumes it **only**
from its nothing-else-runnable fallback. That is what makes "back in the kernel" appear in
`u002` and what let the driver's own `kexit` run at all.

## 6. YFS1, the format

Block size is a superblock field (4096 in the drivers, 256 in some `t*` fixtures, so the
reader is provably not hard-wired). Blocks: 0 superblock, then the inode table (`64` bytes
per inode, starting at `block_size`), then data.

    superblock: "YFS1" | version 1 | block_size | total_blocks | inode_count | root_inode | data_start
    inode:      mode (0 free, 1 file, 2 dir) | size (bytes, or ENTRY COUNT for a dir)
                direct[12] | indirect (one single-indirect block) at +56
    dirent:     u16 name_len | u16 type | u32 inode | name bytes, padded to 4

**Rules the fixtures had to learn:** data must not overlap the inode table (with 256-byte
blocks and 8 inodes the table is 256..767, so data starts at block 3 — or declare 4 inodes);
an image must be **zeroed** where nothing was written, because `yfs_create` finds a free
inode by reading `mode == 0`; and a Y `str` is **length-prefixed**, so kernel code reads its
bytes with `byte_at(s, i)`, never `s[i]`.

## 7. Open work, in the order that unblocks the most

1. **`mv`** — `unlinkat` + `openat(O_CREAT)` + read/write, all present; a shell command.
2. **`echo`, `pwd`, `halt`** — trivial; `halt` is `exit_group`.
3. **The elided-syscall compiler fixture** (owed since the growth investigation): a program
   that calls a syscall for its EFFECT and ignores the result must not have the call
   removed. Five rounds were spent on a read-back that failed for exactly this reason.
4. **Blocking console input** — a PIC unmask helper plus an `irq 4 def` handler that buffers
   the byte and completes the blocked reader.
5. **The fs and tty servers** — the architectural step M3 is missing; the filesystem is in
   the kernel today and needs a raw device path to move out.
6. **`/init` and the M4 command set**, then **M5** (`/bin/ycc`, `/bin/std`,
   `/proc/self/exe`), then **M6**.
7. **The qemu status-0 anomaly** in `u020_cp`: three `y_kexit` call sites, none reachable in
   that run — so the number is probably not a kexit at all. Needs a qemu trace, not another
   kernel print. Its `.exit` is deliberately omitted.

## 8. Parked artifacts

`_ktmp/wip/u005_ipc.{user,driver}.y` (the IPC case before it was committed);
`_ktmp/*.driver.y` scratch from earlier rounds. Fixtures are parked with a leading `_` so the
harness's glob ignores them and the work is not lost — that convention exists because three
delete-on-failure guards destroyed fixtures that the next step needed.

## 9. The process lessons (each cost at least a round)

* **Measure, do not infer.** Every capability here landed after instrumenting the actual
  code path. Rounds spent inferring: `yfs_lookup`'s state (wrong), the exit path (wrong
  twice), `yfs_append` (wrong three times until the cursor was printed).
* **Read the reference implementation.** The argv layout took four rounds because I inferred
  it instead of reading `elf_stack`; reading it found both bugs in one command.
* **A guard is an assertion about output** and must be written *from* the output. Four
  literal guards were wrong; the fix is a **relational** guard (`child == deep`,
  `first > 0 && unlink == 0 && again < 0`).
* **Keep the artifact on failure**, and move a failing fixture aside with a `_` prefix rather
  than deleting it or committing it.
* **A missing print means check the build**, not the theory: an instrumented binary that no
  run used shows nothing.
* **Read the harness** rather than assuming it: `.stdin` exists only for `t*` cases, `.exit`
  is qemu's raw status, `.expected` is a prefix.

## 10. File map for this work

    src/y/std/kernel.y       the kernel: allocator, VM, GDT/TSS, syscalls, scheduler,
                             console, user_path, execve, the fd broker's syscall layer
    src/y/std/yfs.y          YFS1: init, read, fetch, store, append, create, unlink, mkdir,
                             readdir, path walking, the free-block allocator
    src/y/std/fd.y           the fd table: open, open_ino, read, write, lseek, close, ino/tell
    src/y/std/elfload.y      PROGRAMS' loader: elf_map, elf_setup_stack, elf_stack (the
                             reference for the argv layout)
    src/y/arch/kernel.s      syscall entry, y_enter_frame, y_boot_frame, serial, PIC, kexit
    src/y/arch_x64.y (+.c)   multiboot, page tables, GDT, kernel IRQ/trap stubs
    src/y/std/*.y            embedded in the compiler: an edit needs `make rebless`
    os/kernel/elfload.y      the program-side loader still lives here (wired through kernel)
    os/tools/mkfs.y          the host-side image builder (direct slots + indirect block)
    test/kernel/             the fixtures, .expected/.exit/.stdin
    test/sh/test_kernel.sh   the harness
    src/y/KERNEL.md          the round-by-round log and every elimination
    BUGS.md (main tree)      compiler bugs found and filed

## 11. The full project gate, run at handover

`JOBS=8 make test` with every kernel change in place:

    port        151 passed, 0 failed      (and 150/150 in the other shard)
    pe-port     151 passed, 0 failed      (and 150/150)
    native      229 passed, 0 failed      (and 228/228)
    kernel       82 passed, 0 failed      <- the work in this file
    pkg         164 passed, 0 failed
    test_net     31 passed, 0 failed
    treeshake    54 passed, 0 failed
    std-suites    5 passed, 0 failed

`make test` still exits non-zero, and the only failures are the three PRE-EXISTING ones,
each established by measurement rather than assumption:

* `lsp` and `coverage` -- documented as pre-existing in master's own commit message
  ("make check green except the pre-existing lsp/coverage environment failures");
* `ycc` -- one case, "ysh eval compiles and runs through ycc", which the MAIN TREE's
  compiler fails IDENTICALLY: ysh.y passes --no-exec for every eval while the prelude it
  splices calls exec.

So nothing in the microkernel work moved a hosted program's bytes or behaviour: the port
gate recompiles the entire corpus with both engines and compares bytes, in every shard, and
it is 151/151.
