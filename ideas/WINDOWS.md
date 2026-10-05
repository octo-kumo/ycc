# Windows support

`ycc` runs on Windows, and compiles `.y` to Windows PE executables.

> **No prerequisite.** An earlier draft made [`meta.md`](meta.md) a prerequisite,
> because W5 wanted `#if os == "windows"` for the std split and W4 wanted the `fork`
> diagnostic to say *"guard it with `#if os == \"linux\"`"*. `meta.md` has since been
> cut to v1 — `#{ … }#` and nothing else, **no directives** — so neither of those is
> reachable through it, and making W4/W5 wait would buy nothing.
>
> Both are reachable without it. **W4** gets `os` and `target` as builtin constants in
> the checker, next to `is_intrinsic_name`, and its diagnostic names the constant:
> *`fork` is not available when targeting windows; guard it with `if os == "linux"`* —
> which is exactly as actionable, and is what the user would have written anyway. **W5**
> puts its conditionals in per-target std *modules*, which its own decision to put the
> target switch in the import splicer already provides.
>
> So the two plans are now independent. `meta.md` is worth having on its own; nothing
> here waits on it.

Everything below was read off this tree and audited against it. Line numbers are
current as of the writing; corrections from that audit are folded in.

**On citations.** `src/y/native.y` is in flux (there is an uncommitted refactor in the
tree) and its line numbers have drifted from this document, so references into it are by
**function name** (`native_resolve_seen`, `gen_tail_call`, `compile_unit`, `emit_program`,
`resolve_unit`, …) rather than by line. References into `src/y/arch/*.s`, `asm.y`,
`enc64.y`, `tags.y`, `types.y`, `ycc.y`, `test/sh/*.sh` and `refs/ycc.ref` do carry line
numbers, and those files are stable.

---

## Requirements and constraints

These are repo rules, not preferences (`AGENTS.md`, `PORTING.md`).

| # | Requirement | Enforced by |
|---|---|---|
| R1 | **The C twin is 1:1.** `src/c/` mirrors `src/y/` statement for statement; both compilers emit byte-identical programs. Every line of new compiler code lands **twice**. | `PORTING.md`, `make ycc` (`cmp ycc refs/ycc.ref`) |
| R2 | **The fixpoint holds.** Three generations of self-compilation byte-identical. | `test_fixpoint.sh`, `make ynew` |
| R3 | **`make check` before `make rebless`.** verify → compare (what changed vs `BASE`) → time. | `test/sh/check.sh` |
| R4 | **No warnings** from `src/y` or `src/y/std`. | `test_fixpoint.sh` |
| R5 | **Deterministic output.** No hash-map iteration order; byte-identical from `cycc` and the reference. | `test_port.sh` |
| R6 | **`-g` keeps `.text`/`.rodata` addresses identical** to the plain build. | `test_debug.sh` |
| R7 | **Warnings are not output** — `-w` suppresses, bytes unchanged. | `test_native.sh` |
| R8 | **Every process under `ulimit -v 3670016`.** Needing more address space is a bug, not a reason to raise the cap. | `test/sh/capped.sh` |
| R9 | **Bench at the end.** Compile time, output size and program speed get `make bench` + `make bench-ir`; numbers in the commit. **Caveat on Windows: `perf` and `callgrind` cannot read a PE at all**, so the program-side half of this rule — profiling a compiled program — has no equivalent for any `--target=windows` binary, and only the compiler-side half survives (`ycc --time`, and `make bench` against a Linux-hosted `ycc` that emits PEs). | `AGENTS.md` |
| R10 | **Y code style** — empty blocks void, a block's value is its last statement *without* a trailing `;`, recursion via `self`, no unknown types, records exact, a `type` alias for any record/union used twice, no unused locals. | `AGENTS.md` |
| R11 | **Every diagnostic has a test**, every manual section a `COVERAGE.md` row. **Note `test/sh/test_coverage.sh:70-71` hard-codes the scanned file list** (`lexer.y parser.y rename.y types.y native.y ycc.y pkg.y lint.y arch_x64.y std/*.y`) — a new source file is invisible to it unless that list is edited, so a new diagnostic would ship untested. | `test_coverage.sh` |
| R12 | **No new closures in `src/y`** — the C twin's value model has no function value to store one in. | `yv.h` |

### Tooling that already exists (no new tooling needed)

- `ycc --time FILE` — per-phase elapsed ms, heap KB, `asm_bytes`, `out_bytes`.
- `ycc -g` + `nm` / `addr2line` / `objdump -dl` / `gdb` / `valgrind` / `perf`.
- `make check`, `make bench`, `make bench-ir`, `test/fuzz/fuzz.sh`.

---

## What I read from the repo

The findings that decide how hard this is. Everything below follows from the first
four.

| File | Y lines | C twin | Verdict |
|---|---|---|---|
| `src/y/enc64.y` | 1038 | 1132 | **Reusable as is.** Pure x86-64 encoder; the only OS-flavoured line is `%fs:disp32` (`:330-334`). |
| `src/y/asm.y` | 1363 | 1811 | **Coupled in four places, not 250 lines:** `elf.elf_bss_from_ro` (`:1249`), `elf.elf_build` (`:1313`), `elf_code_off`, and the image base at `:1564`. The rest — parse, labels, fixups, patch — is object-format agnostic. |
| `src/y/dwarf.y` | 261 | 340 | **Reusable.** Imports `elf.y` only for the `ElfSec` alias (`:17-18`, used at `:21`). |
| `src/y/elf.y` | 341 | 384 | **Replaced by `pe.y`.** |
| `src/y/arch_x64.y` | 2181 | 2185 | 34 `syscall` instructions + `arch_exit`; `%fs` TLS at 4 places. Mostly rewritten for Windows. |
| `src/y/native.y` | 11091 | 13231 | **The emitter.** All of the frame/call/entry convention is SysV-shaped. |
| `src/y/std/*.y` | 1470+ | — | 4 units embedded (`rt`, `prelude`, `exec`, `str`); `fs`/`net`/`tls`/… are source-distributed. |

`src/y` ≈ 29k lines, `src/c` ≈ 30k. **R1 means every number below is doubled.**

### The four decisive findings

**1. No relocations, anywhere.** Verified by experiment rather than by counting:
`readelf -r` on a real binary shows no relocation section, and a binary has exactly
two PT_LOADs with the second one's `FileSiz 0`. The structural reason:

- all addressing is RIP-relative;
- **there is no `.data` section at all** — globals are zeroed `.bss` cells
  (`arch_global_cell`, `arch_x64.y:93-95`; emitted in `emit_program`'s globals loop),
  and `asm_link` *rejects* bytes in `.bss` (`asm.y:1232`, `:1242`, `:1267`);
- `.quad` is the only data directive, and it only ever holds a small non-negative
  long: `asm_quad_bad` (`:925-933`) rejects anything non-decimal or negative,
  `asm_quad_go` (`:948-956`) is the only writer, and the only emitter is
  `the `.quad` emitter in `native_resolve`-adjacent link code` (string-header lengths).

The image base `4194304` is the base in exactly three places: `elf.y:61`,
`elf.y:150`, `asm.y:1564`. (It also appears at `src/y/arch/prelude.s:361`/`:366`, but
that is the 4 MiB chunk size, not a base.)

Consequences: a PE needs **no `.reloc`** and can set `RELOCS_STRIPPED`; `pe.y` is
roughly the size of `elf.y`; and nothing has to be fixed up when the image moves.

**2. The emitted calling convention is already Win64-legal, and the whole ABI
delta is caller-side.** Args go on the stack left to right, the caller cleans up,
param *k* lives at `rbp+16+8*(n-1-k)` (the formula in `gen_tail_call`, repeated in
the prologue's comment for the capture record), frames are rounded to 16 bytes
(`arch_frame`, `arch_x64.y:116-121`), and no red zone is used (no negative `%rsp`
offset anywhere in emitted code or the arch prelude). The prologue is
`push %rbp; mov %rsp,%rbp; sub $frame,%rsp` and the epilogue
`mov %rbp,%rsp; pop %rbp; ret` (`emit_one_fn`), so **no callee-saved register is
saved at all** — better news under Win64 than a prologue that pushed `r12`–`r15`,
because there is nothing to convert and the hand-written `src/y/arch/*.s` routines
carry no callee-saved state to spill either. Win64 *permits* all of this.

"Param offsets do not move" is **right about the callee and wrong about the
caller**. The callee's own frame layout is its own choice — a Win64 callee may take
its parameter area out of the caller's shadow space — so `rbp+16+8*(n-1-k)` stands
unchanged. The sharpest proof is the one frameless routine in the tree,
`y_str_eq` (`src/y/arch/prelude.s:8-10`), which reads its two arguments at
`8(%rsp)`/`16(%rsp)`: that is the same address under both ABIs, because Win64's
shadow space occupies exactly the 32 bytes where SysV puts the first stack
arguments. What does move is the **caller's** stack-argument base for calls with more
than 4 arguments: SysV puts stack args at `rsp+0` at the `call` (`rsp+8` in the
callee), Win64 reserves the 32 bytes of shadow space first, so they sit at `rsp+32`
at the `call` (`rsp+40` in the callee). The ABI delta is therefore:

| | change |
|---|---|
| shadow space | the caller reserves 32 bytes, and args 5+ live in it: SysV stages them at `rsp+0` at the `call`, Win64 at `rsp+32` |
| entry | the PE entry point is called with `rcx = hInstance`, `rdx = hPrevInstance`, `r8 = lpCmdLine`, `r9 = nShowCmd`; today `_start` reads `argc`/`argv` off `[rsp]`/`rsp+8` (`emit_one_fn`'s argv prologue) |
| exit | `exit_group(0)` (`_start`'s tail, `arch_x64.y:122-124`) → `ExitProcess` |
| `rdi`/`rsi` | become callee-saved under Win64 — **vacuous here**: nothing holds a live value in a register across a call, and `_start` is never re-entered |

**How much of the emitter the shadow-space row really costs.** The shadow space is
not extra work for an ordinary call: the emitter already stages *every* argument on
the stack, in order (`gen_push_args`), which under Win64 **is** the shadow space a
callee is allowed to read its register arguments out of — and the callee then reads
all of them from its own frame, so args 1–4 never move either. The only calls whose
arguments move are those with 5 or more, and of `native.y`'s 90 `F_CALL_L`/
`F_CALL_IND` sites (88 direct, 2 indirect) the set of 5+-argument calls is **exactly
`gen_syscall`**: it alone pops arguments back into registers. Linux passes syscall args
1–6 in `rdi`/`rsi`/`rdx`/`r10`/`r8`/`r9` (`syscall_reg`, whose comment already lists
them).

**Win64 takes them in `r10`/`rdx`/`r8`/`r9`, and the fifth onward on the stack at
`rsp+0x28`.** That is *one* shuffle, not five: ntdll's stub moves only argument 1, out
of `%rcx` (which `syscall` destroys) into `%r10`, because arguments 2–4 are already in
`rdx`/`r8`/`r9` and arguments 5+ are already in ntdll's own shadow space. Two
independent sources say so, and a layout needing more than one instruction in ntdll's
stub is not the layout ntdll uses:

- ReactOS `sdk/include/asm/syscalls.inc`, `STUBCODE_U`: `mov eax, SyscallId; mov r10,
  rcx; syscall`.
- wine `dlls/ntdll/unix/signal_x86_64.c`, in its source comments: `mov %r10,%rdi /* 1st
  */`, `mov %r11,%rsi`, `mov %r8,%rdx`, `mov %r9,%rcx`, `mov (%r15),%r8 /* 5th */`
  with `r15 = rsp+0x28`.

**Two earlier drafts of this line were wrong** — this one, and the one before it, which
said `r10`/`r9`/`r8`/`rdx`/`rcx` with the sixth on the stack. Both were written from
memory. The register set is load-bearing enough that it is worth reading off a real
`ntdll` stub rather than recalling it, and the cost of getting it wrong is a debugging
session, not a compile error.

So the >4-argument delta lands entirely in the syscall emitter: one `mov` to `%r10`, and
the stack slots 16 bytes lower than a first reading suggests (`rsp+0x28`, not
`rsp+0x20`).

Two items an earlier draft listed here do not survive the measurement. "Pad odd-arg
calls so `rsp ≡ 0 mod 16`" is **not a Windows delta** — SysV and Win64 agree on it —
and the emitter does not honour it today either (`_start` calls leave
`rsp ≡ 8 mod 16`, safe only because no argument is ever passed in an SSE register).
And the emitter's refusal of bare `(%rsp)`/`(%r12)` bases (`emit_one_fn` says so in a
comment) is **policy, not an encoder limit**: `enc64.y:245-255` accepts both, with
the SIB byte they need. That matters here, because Win64's 5th syscall argument
*must* go on the stack at `rsp+0x28`, so the restriction is one of the things W4 has to
lift.

**The std pack is written by one compiler for one target, so nothing baked into a std
unit may depend on the target.** This started as a risk row here and is now a
**demonstrated constraint** (see Risks, "settled"), and it is the strongest argument
for the per-target-module design this document already specifies. `ycc --std-pack` never passes a target, so a conditional
compiled while building `rt.y` is baked into every program made from that pack, and
`--target=windows` on the *consuming* compiler cannot undo it. Measured both ways: with
a conditional in `rt.y`, a PE built from the pack carried the ELF inline `write(2)` and
printed nothing, while `--std-src` (which recompiles) worked.

The consequence is a rule with no exceptions: **a std entry point names a label, it does
not branch.** `os_write` calls `y_os_write`; `y_os_exit` calls `y_os_exit`; the Windows
bodies live in the arch module and the ELF bodies in the arch prelude, and the pack
carries text that is correct for whichever compiler wrote it. Any W5 entry point that
tests `os` inside `rt.y`/`fs.y`/… reintroduces the bug, and the failure mode is a PE
that prints nothing.

**Do not branch on the target in `native.y` for any of this** — it all goes behind
`arch_*` predicates.

**3. The arch seam exists, but a second arch *file* cannot be added.** `arch_x64.y`
exports 18 `arch_*` functions (`:2181`). A second module defining the same names
**cannot coexist**: a module imported by path is *flattened* into the importer's top
level (a path import is flattened into its importer), so `arch_frame` would be defined twice and the second
would win. Hence the design decision below — one module, internal dispatch.

**4. The C copy is the bootstrap.** `src/c/` is an ordinary **glibc** program —
only 12 raw `syscall()` sites (`pkg.c:159-179`, `:928-1001`, `asm.c:1773`,
`native.c:1069`, `ycc.c:165-210`) and `<sys/syscall.h>` at 4 files. So a
mingw-w64 `cycc.exe` is ~250 lines of shims away. And because the image needs no
relocation fixups, **a Linux `cycc` can emit a PE nobody runs** — a Windows
compiler can be produced before any Windows machine is involved.

### Supporting inventory

- **Host primitives** in `arch_x64.y`: `mmap` 9 (`:487`, `:1852`), `mprotect` 10
  (`:1864`), `munmap` 11 (`:1909`), `clone` 56 (`:1878`), `futex` 202 (5 sites:
  1953, 2027, 2050, 2113, 2130), `fork` 57 (`:2139`), `getpid` 39, `exit` 60,
  `exit_group` 231, `write` 1, `close` 6, `lseek` 8,
  `arch_prctl`/`ARCH_SET_FS` 158 (`:1814`).
- **`%fs:24`** in exactly four places — `src/y/arch/prelude.s:345` (`y_alloc_slow`),
  `:403` (`y_heap_used`), `src/y/arch/threads.s:51` (`y_spawn`), `:179` (`y_join`) —
  and nowhere else in the tree (`enc64.y:400-407` is the encoder arm, `asm.y:168-184`
  the parser). **The compiler's own assembly now lives in `src/y/arch/*.s`**, not in
  `arch_x64.y`; that file is 172 lines of arch hooks only.
- **`/proc` in 4 places**: `self_dir`'s `readlink`, `ycc.y:133` (self pack),
  `pkg.y:664` (environ), `pkg.y:844` (self hash). All already document `argv[0]`
  as a fallback.
- **`fs.y` is 291 lines and entirely Linux-shaped**: `openat`/`getdents64` 217
  (`:247-258`, hand-parsed `linux_dirent64`), `newfstatat` with hardcoded
  `struct stat` offsets (`:178-179`, `:199`), `AT_FDCWD = -100` (`:18`),
  `fchmodat` 268 (`:135`), `renameat` 264, `unlinkat` 263, `mkdirat` 258,
  `getcwd` 79, `chdir` 80.
- **No signals anywhere**, and traps are explicit branches the emitter plants
  (`y_cast_trap`, `src/y/arch/prelude.s:309`, reached by two `jmp`s from `native.y`),
  not faults — so there is no trampoline to port. The one "guard page" is an
  `mprotect(PROT_NONE)`, not a signal handler.
- **The std pack is target-independent, and nothing enforces it.** `std_pack`
  serializes `pack_version()` + per-unit `name` + `pack_unit_fields(u)` (renamed
  globals, rodata, externs, iface, init) — **no machine code, no addresses, no
  section layout**, because the pack stores assembly *text*. So one pack serves both
  targets, *provided* the 4 embedded units are target-independent, which is what the
  named syscall layer buys. That "provided" is load-bearing and **unenforced**: one
  inline-assembly string, one hardcoded `/proc` path or one Linux syscall number
  inside `rt.y`/`prelude.y`/`exec.y`/`str.y` is serialized into the Windows pack
  just as happily as the ELF one, and nothing notices until a PE links it. Three
  things follow, none of them a change to `--std-pack` itself: `make ycc` must append
  a **second pack to `ycc.exe`** (the Makefile's `PACK` at `Makefile:71` does this
  once, for one binary); `test_link.sh` needs a **cross-target pack fixture** that
  diffs a PE's std bodies against the ELF's and fails on any difference outside the
  units declared per-target (W5's `std/win/*` overrides); and `test_coverage.sh`'s
  hard-coded file list (R11) does not see the new `std/win/*.y` until it is edited.
- **`exec` is not a builtin** — a std unit spliced in only when mentioned and
  `--no-exec` permits (`resolve_unit`'s std-unit selection; `std/exec.y:1-5`). The
  call then fails with *"undefined function 'exec'"*. **This is the existing
  mechanism for gating a feature off.**
- **Only 4 std units are embedded**: `the four `embed` declarations`, `Makefile:19` (`STD_EMBEDS`),
  `src/c/native.c:94-97` (`Y_EMBED` ×4). `fs`/`net`/… resolve from disk via
  `std_resolve`.
- **`fork`/`spawn`/`wait_pid` are builtins**: `types.y:3353` / `:3371` (binding),
  `the `spawn`/`fork` arm in the mention scan` / `:2181` / `:4718` / `:4722` (emission), name list at
  `is_intrinsic_name`). `target_builtins` does not exist yet.
- **Memory is the standing ceiling.** `MEM_KB=3670016`, `YCC_MEM_KB=2097152`
  (`Makefile:40-43`); `cycc` needs ~1.9 GB for `ycc.y`, `ycc` itself ~1.1 GB.
  Measured: `./ycc --time src/y/ycc.y` → `TOTAL 367.541 ms 820001 KB`,
  `VmPeak 821964 kB`. So **one compiler-scale compile is ~822 MB VSZ** — under the
  cap that is ~4× headroom, not 10×, and a *second* arena is not free.
- **Test harness is Linux-shaped**: bash + `ulimit -v` (`lib.sh:40-47`),
  `readelf`/`nm`/`addr2line`/`gdb`/`as` (`test_debug.sh:107-137`, `:155-177`,
  `:181-208`, `:249-271`), `/tmp`, `stat -c%s`.
- **No target parameter exists anywhere.** The only host/target-ish parameter in the
  whole pipeline is `allow_exec`; arch selection is a compile-time
  `import arch from "./arch_x64.y"` (`the `import arch` line`).

---

## Design decisions

### One compiler with `--target`, ELF the default

Rejected: two separate builds (two reference binaries, and a build-time constant
`src/c` must mirror). Rejected: a separate `wincc.y` front-end (duplicates driver
logic; the parser/checker are shared anyway).

*What that decision costs, stated honestly.* Two builds' only real justification is
finding 4 — the Linux-hosted PE emitter, which lets a Windows compiler be built with
no Windows machine in the loop. But two products would also (a) dissolve the "a
second arch *file* cannot coexist" constraint, which binds only *within* one product:
two `arch_x64.y`/`arch_win_x64.y` files could each define `arch_frame` if they were
never in the same binary; and (b) delete the 5-signature ×2-copies threading that
this document and `meta.md` both call the biggest structural change. `cycc` and `ycc`
already prove two products are tolerable in this repo. The cost of one build is
therefore the threading and the per-phase rebless — not a risk.

Cost: `refs/ycc.ref` must be reblessed, and the ELF path must stay byte-identical —
which `make check`'s compare step proves exactly. Expect a small compile-time cost
from carrying the PE writer in every binary; `make bench` will say how much.

### The target reaches three places, three different ways

This is the part an earlier draft got wrong. The three consumers need three
mechanisms:

**1. The object writer — no special mechanism needed.** `elf.y` and `pe.y` have
distinct names (`elf_build` vs `pe_build`) and distinct types (`ElfSym`/`ElfSec`
vs their PE equivalents), so **both can be linked in** and `asm.y` picks one at
link time on the target. No splicer involvement.

**2. The arch module — one module with internal dispatch.** A second arch *file*
cannot work (finding 3). So `arch_x64.y` grows a Windows half:

```
arch_x64.y
  arch_frame(t, slots) / arch_prelude_lines(t) / arch_exit(t) / …   // dispatch
  arch_*   → the existing Linux implementations, unchanged
  w_frame / w_prelude_lines / w_exit / …                            → the Windows ones
```

and the dispatch reads a **global `res_target`**, which is how this codebase already
passes ambient state (`res_pkgs`, `res_used` are globals in `native.y`). That
matters: **the 25 `arch_*` call sites in `native.y` need no edits at all.** The
Windows names are private (`w_*`), so they never collide, and both preludes coexist
in one binary — which is what makes cross-compilation work from the Linux build.
Cost: ~100 lines in `arch_x64.y`, and its C twin (R1).

Rejected: making the target a *build-time* choice (`make ycc` resolves
`arch_x64.y`, `make ycc.exe` resolves `arch_win_x64.y`). Cheaper, but the Linux build
then has no Windows prelude in it, so there is no cross-compiler and W2 becomes
untestable until a Windows machine exists. Rejected: two products with no
cross-compilation at all.

**3. Std modules — a per-target override table in the splicer.**
`native_resolve_seen` already resolves module paths against a
candidate list; add the target-specific path first. `std/win/fs.y` and `std/win/net.y`
then exist behind the existing `fs`/`net` APIs with **no language surface**, and only
one of the pair is ever spliced, so flattening is not a problem here.
Cost ~15 lines. It is implicit, so it needs a comment and a fixture proving
`--target=windows` really pulled the overridden module in.

**Threading.** The target has to reach `res_target` before anything reads it. The
parameter path, which currently has no such parameter anywhere:

```
ycc.y parse_cli_args
  → native_resolve_x(src, base_dir, depth, allow_exec, root)      `native_resolve_x`
    → resolve_unit(...)                                          `resolve_unit`
      → compile_unit(ast, imports, origin, debug, wlevel, name, base, xt)  `compile_unit`
        → emit_program(ast, nr, debug, wlevel, std, deps)         `emit_program`
          → ycc_assemble(asm_text, debug)                        asm.y:1595
```

Five signatures, ×2 copies under R1. And it must land **before** `build_key`
(`ycc.y:356-379`), which hashes the resolved text plus the compiler id — otherwise
the package object cache (`build/obj`, `ycc.y:449`, `:483-513`) will happily reuse
objects built for the other target.

### NT direct syscalls, not Win32 imports

Keeps the project's raw-syscall, no-libc, static-binary philosophy: no import table,
no IAT, no thunks, self-contained `.exe`. **No PEB walk is needed either** — `syscall`
is a CPU instruction, so `mov %eax, N; syscall` requires no library address at all,
which is the whole point. The real cost is that the numbers are per Windows version
(see Risks).

| today | Windows |
|---|---|
| `clone(56)` + 8 MiB `mmap` stack + guard page | `NtCreateThreadEx`, `NtAllocateVirtualMemory` ×2 |
| `CLONE_CHILD_CLEARTID` | an explicit store before the thunk returns |
| `futex(202)` `WAIT_PRIVATE` / `WAKE` | `NtWaitForAddress` / `NtWakeAddressSingle` |
| `ARCH_SET_FS(158)`, `%fs:24` | **a callee-saved register** (below) |
| `mmap(9)` 4 MiB chunks | `NtAllocateVirtualMemory(MEM_COMMIT\|MEM_RESERVE)` |
| `write(1)` + `exit_group(0)` | `NtWriteFile` + `NtTerminateProcess` |
| `fork(57)` / `wait4(61)` | `CreateProcess` / `WaitForSingleObject` + `GetExitCodeProcess` |
| `clock_gettime(228)` / `nanosleep(35)` | `NtQueryPerformanceCounter` / `NtDelayExecution` |

Two of these are **redesigns, not ports**, and should be sized as such:

- **`getpid` in the mutex.** `arch_x64.y`'s `y_mutex_lock` stores the owning pid in
  word 8 so a lock held across a `fork` can be detected (`:1999-2092`). Windows has
  no cheap per-process id comparable to this without `NtQueryInformationProcess`;
  decide whether to keep the check (and pay per lock/unlock) or drop it (and lose the
  diagnostic at `:1995`).
- **The futex return value in the semaphore.** `post` self-wakes by inspecting the
  syscall's return; `NtWakeAddressSingle` does not report that. Needs a different
  wake discipline.

The `syscall` intrinsic itself is nearly free — one register permutation and one
stack slot, not a new convention (see finding 2 for the register sets and the
`rsp+32` slot). Sites: `types.y:3598` (typecheck), `types.y:4223` (binding),
`gen_syscall`, `syscall_reg`.

**What is *not* nearly free: the status polarity.** Linux syscalls return a negative
errno in `%rax`; **NTSTATUS failure is a *positive* value**, so every `js` / `>= 0` /
`< 0` test that reads a syscall result reads failure as *success* if it is
transliterated. The Windows idiom is `NT_SUCCESS(s) == (s >= 0)`, and every check has
to be **re-derived from the call's semantics, not translated** from its SysV
spelling. The sites, enumerated so that no phase can quietly miss one:
`src/y/arch/prelude.s:395-396` (`test %rax,%rax; js y_alloc_fail`, the `mmap` in
`y_alloc_slow`), `src/y/arch/threads.s:72-73` and `:96-98` (the thread's own stack
`mmap`, and the `clone`), `src/y/std/prelude.y:77` (the `lseek` in `y_stdin_sync`,
tested `syscall(8, 0, 0 - unread, 1) >= 0`), `src/y/std/rt.y:210` (`r < 0`, `wait_pid`'s
`wait4`) — plus every `syscall(` site in `fs.y`/`net.y`/`exec.y`/`tls.y`/`crypto.y`/
`http.y` whose result is compared. Under the named-syscall layer all of those
comparisons move into one layer, which is the single place the polarity then has to
be right; a `js`→`jns` sweep is not enough, because a reversed check is silent.

### The per-thread block pointer moves out of TLS

`%fs:24` (`src/y/arch/prelude.s:345`, `:403`; `src/y/arch/threads.s:51`, `:179`) has no clean Windows
equivalent: `gs:0x00`/`gs:0x60` are stable, but `TEB.ThreadLocalStoragePointer` is
not, across versions.

Instead: **the pointer lives in a callee-saved register** (`%rbx`), installed by
`_start` for the main thread and by the thread thunk for spawned ones; `y_alloc` and
`y_threads_on` read it instead of `%fs:24`. No TLS, no `%gs`, and it works on both
targets.

**This is not free, and it is not quite the shape it looks like.** Three measured
facts, the second of which is good news and the third of which is the actual work.

**Nothing saves `rbx` today.** The emitter never mentions `%rbx` — `rg -c rbx
src/y/native.y` is 0 — and the prologue/epilogue pair is emitted through the IR as
`mov %rsp,%rbp; sub $frame,%rsp` / `mov %rbp,%rsp; pop %rbp; ret`, in **one place**
(`emit_one_fn`). So this is *not* a per-function edit: it is two `ir_push` calls added
to that one emitter, plus whatever `_start` needs (below). Every function still *gets*
the save/restore, but the change is centralised.

**The 216 existing `%rbx` references in `src/y/arch/*.s` (173 in `prelude.s`, 43 in
`threads.s`) stay correct, and reading them as a blocker is a mistake.** They are all
balanced scratch uses — `push %rbx` … `pop %rbx` around a loop or a compare — so under
the new meaning they save and restore *the pointer*, which is exactly right. What they
do **not** tolerate is a `%rbx` write that survives a call, and that is the invariant
worth gating: not "pushes and pops", but **no `%rbx` write across a call**. Extend the
Makefile's existing `asm-check` target (`Makefile:44-52`, which already runs GNU `as`
over `src/y/arch/*.s`) with that check, and assert the same in the emitter. (`y_fmod`,
the routine a review once suspected, is fine: `prelude.s:708` pushes it, `:875` pops
it.)

**`%rbx` must be valid before the first allocation, and `_start` has to establish it.**
The `y_alloc` **fast path** must read the register, not just `y_alloc_slow` — the fast
path is `y_alloc`/`y_alloc_go` (`src/y/arch/prelude.s:318-337`), and `y_alloc_slow`
(`:338`) is only the one that reads `%fs:24` today. So `_start`'s first instruction has
to be `lea y_heap(%rip), %rbx`: the process's own heap block is that static `.bss`
object, which is a valid pointer from the moment the program starts.

`y_threads_on` (`src/y/arch/threads.s:5`) looks like it needs reordering and does not.
It allocates the new block with `call y_alloc` **before** installing anything — which is
already the right order for `%rbx`, because `%rbx` still points at the *calling* thread's
block, so that allocation comes out of it, and only then does `%rbx` switch. Today's code
does the same thing with `%fs` (`mov %rax, 24(%rax)` then `arch_prctl`, syscall 158 /
4098) and the ordering carries over unchanged. Worth stating explicitly, because reading
it cold, `call y_alloc` before the pointer is set looks like a bootstrap cycle and
provokes a pointless rewrite.

### `fork` stays a builtin and is gated in the checker

The target reaches the checker for the first time here. `allow_exec` today only
reaches `resolve_unit`; the existing channel is `externs` / `xt` (`xt.ext`), so add
`xt.os`. Keep the capability set as one list — `target_builtins(os)`, initially
`{fork, wait_pid}` — so a macOS target later is a data change. Diagnostic (draft, in
the house style):

```
fork is not available when targeting windows; guard it with if os == "linux"
```

`wait_pid` is gated with `fork` — it takes a pid only a forked child produces. This
diagnostic names the `os` constant, which the checker binds as a builtin alongside
`is_intrinsic_name` — so it needs no meta pass and no `#if`.

---

## Phases and gates

Every phase that changes the compiler **forces `make rebless`** and puts the port gate
red until it happens — that is the normal loop (R3), but it means the tree is red
between a phase landing and its rebless, so do not stack phases.

**W1 — `cycc.exe` under mingw-w64.** A small host shim for `src/c`'s 12 raw
`syscall()` sites, `chmod` → read-only bit, `S_ISDIR` → `GetFileType`,
`CLOCK_MONOTONIC` → `QueryPerformanceCounter`. `__extension__({…})` and `.incbin`
both work under mingw's gcc (the Makefile's cwd assumption at `:16-18` holds).
*Gate:* `cycc.exe` compiles the corpus to **byte-identical ELF** vs Linux `cycc`.
*Unverified:* no mingw toolchain on this machine, so the byte-identity claim is a
prediction until it runs.

*Scoped wider than it looks.* "~250 lines, all in `src/c`" counted the **C** copy
only, and only its syscalls. W1's actual goal is a `ycc.exe` that self-compiles, and
the Y copy has **69 raw `syscall(` sites** across the compiler and its std — `net.y`
21, `fs.y` 18, `ycc.y` 7, `rt.y` 6, `pkg.y` 5, `exec.y` 4, `tls.y` 2, `prelude.y`
2, `http.y` 2, `crypto.y` 1, `asm.y` 1 — of which **13** (`ycc.y` 7, `pkg.y` 5,
`asm.y` 1) are on W1's own path. Two of those 13 are worse than a port, and neither
is a line-count problem:

- **`self_pack` (`ycc.y:132`)** reads the std pack from `/proc/self/exe`. No
  `/proc`, no pack — and it **fails silently**, returning `""`, so every compile
  quietly falls back to compiling the std units from source (measured ≈2.7× slower)
  with no diagnostic anywhere. A `ycc.exe` that looks perfect and runs at a third of
  the speed.
- **`pk_self_id` (`pkg.y:844`)** reads `/proc/self/exe` as well and calls `pk_die`
  when it cannot, so **`ycc build` is dead** on a self-compiled `ycc.exe` until this
  gets a Windows answer (`GetModuleFileNameW`, or the `argv[0]` path the function's
  own comment already documents as a fallback).
- `getcwd` runs on **every** compile (`asm_cwd`, `asm.y:1586`), so
  `GetCurrentDirectoryW` is not a corner case either.

So W1 is **bigger than W3**, not smaller: W3 is mechanical string data behind a
dispatch, W1 is a per-file port plus two behavioural redesigns. The landing order
below is unchanged (W1 is still independent), but it should not be read as the cheap
one.

**W2 — `pe.y` + `pe.c`, retarget `asm.y`.** DOS stub, `IMAGE_FILE_HEADER`,
`IMAGE_OPTIONAL_HEADER64`, two sections (`.text` R+X holding code+rodata; `.bss`
R+W with `SizeOfRawData = 0`), `ImageBase 0x140000000`, `RELOCS_STRIPPED`, no
`DYNAMIC_BASE`. `elf.y`'s zero-fill trick ports directly — `VirtualSize >
SizeOfRawData` is zero-padded — at `FileAlignment 0x200` granularity instead of
byte-exact. Also the link pass, `debug_syms`, `debug_lines`, and `asm_cwd`'s
`getcwd`. And — decided, not optional — `.pdata`/`.xdata`: `pe.y` writes real unwind
info, because a DWARF debugger that can step but not backtrace is worse than not
shipping `-g` at all. **Build this against a hand-computed hello-world PE before
anything depends on it**, and run it under Wine.
*Gate:* `ycc --target=windows -o t.exe` on hello-world runs under Wine, **and a
second gate on the std syscalls — because from this phase on they are live in every
PE**: `rt.y` carries 6 raw `syscall(` sites (`write` ×2, `clock_gettime` ×2,
`wait4`, `nanosleep`) and `prelude.y` 2 (`read`, `lseek`), all inside the 4 embedded
units, so `print`/`puts`, `clock_us()`, `time_us()`, `wait_pid`, `y_sleep` and
`readline()` execute as `Nt*` calls carrying Linux numbers from the first PE W2
emits — `clock_us()` and `readline()` are broken before any other phase notices. The
gate is one program that calls each of those entry points, checked under Wine, and it
has to land **here** rather than at the end: W5 is what rewrites these sites, so a
`clock_us()` that stayed broken would go unobserved for three phases while every
intermediate PE was quietly wrong.
*Note:* a hello-world gate will **not** exercise `argv` — see W4.

**W3 — `arch_win_x64.y`'s Windows half, inside `arch_x64.y`.** `w_*` allocator,
traps, thread prelude, `fork`→`CreateProcess` plumbing, `_start` shim, dispatched
through `res_target`. Mechanical twin — it is string data, so `make port-check` is
low-risk. **This is the phase to size the two redesigns above in.** It is also where
the Windows number table lands, and it must be **one** table inside
`arch_x64.y`'s dispatch (`arch_sysno`, a 6-arm ladder at `arch_x64.y:51-58` today),
because a wrong number fails silently rather than loudly (see Risks). The mitigation
that comes with it is a **startup self-test**: one `Nt*` call per class — memory,
file, thread, process — with its status checked, so a bad table fails loudly at
`ycc` startup on a Windows build instead of misbehaving hours later.
*Gate:* strings, arrays, closures, threads and `exec` all behave as on Linux under
Wine.

**W4 — `--target`, threading, syscall convention, ABI.** Flag parsing in `ycc.y`;
`res_target` through the five signatures above; `build_key` gains the target; the
`syscall` intrinsic's second register convention; the caller-side shadow-space change
in `gen_syscall` (finding 2's first row — args 5+ move from `rsp+0` to `rsp+32` at the
`call`, and the 5th syscall argument is the first of them); the PE entry point taking `lpCmdLine` out of `r8`; `xt.os`; the capability
list.
*Gate:* **the ELF path stays byte-identical** — `make check`'s compare step.
*No dependency.* The `fork` diagnostic names the checker's `os` builtin.
**`argv()` needs a parser written, not adapted.** The PE entry point is called with
`rcx = hInstance`, `rdx = hPrevInstance`, `r8 = lpCmdLine`, `r9 = nShowCmd`: there is
**no `argc` at all**, and `lpCmdLine` is **one wide (UTF-16) command line**, not a
`char**`. So `argv()` — whose Y-side path (`y_argv_init`, `src/y/arch/prelude.s:1499`)
today reads the two words `_start` pushed off `[rsp]` — needs two things that do not
exist yet: a command-line→`argv` splitter (`RtlCommandLineToArgvW` out of ntdll, or a
hand-rolled parser following the MSVC quoting rules) and a UTF-16→UTF-8 conversion
policy for `y_cstr_to_str`. Both are new code in this phase and both belong in its
size estimate; "don't forget UTF-16 argv" understates them. W2's hello-world gate
cannot catch any of it; W5's can.

**W5 — the std split.** A named syscall layer (`sys_write`, `sys_open`, …) so the 4
embedded units become target-independent and the pack stays target-agnostic.
`fs`/`net` become per-target modules behind their existing APIs; `readline` →
console handles; `exec` → `CreateProcess`.
*Polarity, not transliteration.* NTSTATUS failure is positive, so every status check
the named layer introduces has to be **re-derived** (`NT_SUCCESS(s) == (s >= 0)`) from
what each call means, not translated from its SysV spelling — the site list is in the
NT-syscall section above, and it is enumerated there so this phase can work through
it rather than discover it. A reversed check is silent, and W2's std gate is the only
thing that sees the ones still raw before this phase rewrites them.
*Gate:* `ycc --target=windows` compiles every `test/y/**.y` and every package
fixture; identical binaries from both compilers; the std pack is still shared; UTF-16
argv works.
*No dependency* — the conditionals live in per-target std modules, split only where the
two std trees genuinely differ.

**W6 — the Windows harness.** Reuse the suites under MSYS2/Git-Bash, which already
provide `cmp`, `od`, `stat -c%s`, `timeout`, `mktemp`. Swap `readelf`/`nm`/
`addr2line` for `llvm-readobj`/`llvm-nm`/`llvm-addr2line`. Three gaps, the first
of which an earlier draft called unsolvable and is not:

- **`ulimit -v` has no Windows equivalent, but R8's semantics are reproducible.**
  The objection was that Job Objects bound *commit*, not reservation — true, and
  irrelevant here, because every mapping this compiler makes is read-write committed
  (`NtAllocateVirtualMemory` with `MEM_COMMIT|MEM_RESERVE`, 4 MiB chunks), so the two
  coincide. `JOB_OBJECT_LIMIT_JOB_VM_SIZE` on the job therefore reproduces exactly
  what the OOM fixture checks (`test/sh/test_ycc.sh:239-264`: its own
  `ulimit -S -v 409600` at `:252`, then exit 1, `runtime error: out of memory` on
  stdout and nothing on stderr). What is missing is not an exemption but a ~40-line
  launcher — `CreateJobObject` + `STARTUPINFOEX` with
  `PROC_THREAD_ATTRIBUTE_JOB_LIST`, setting the limit and assigning the child. Write
  it in W6: without it the fixture is skipped on Windows, and R8 becomes the one rule
  a target can quietly opt out of.
- `as` and `readelf --debug-dump=decodedline` have no drop-in; `llvm-mc` and
  `llvm-dwarfdump` cover them.
- `test_debug.sh` is ELF-specific throughout, and this is a **new branch, not a tool
  swap**. Its `readelf`/`nm`/`addr2line`/`objdump` assertions
  (`test_debug.sh:107-137`, `:155-177`, `:181-208`, `:249-271`) are spelled in ELF
  terms — sections, `STT_FUNC` sizes, `decodedline` rows. A PE branch has to assert
  the COFF symbol table, the presence and shape of `.pdata`/`.xdata`, and the section
  layout (`.text` R+X holding code+rodata, `.bss` R+W with `SizeOfRawData = 0`),
  plus that the plain and `-g` builds agree on `.text`/`.rodata` (R6, which must hold
  on PE too). `llvm-readobj` reads all of it; rewriting the file's assumptions is the
  work.
*Gate:* the full 16-suite loop on Windows, or Wine on Linux.

---

## Deferred, with the reason

- **PDB.** WinDbg reads **PDB**, not DWARF, so the PE target's `-g` output — COFF
  symbol table + the same DWARF sections + `.pdata`/`.xdata` — covers `llvm-nm`,
  `gdb` and LLDB-style consumers, and **not** WinDbg stepping or its stack traces.
  PDB is a separate format and a separate can of worms; it stays deferred, and that is
  the honest price of shipping `-g` on PE.
- **`--target=macos`.** Every decision above is a per-target data change
  (`target_builtins`, module paths, the writer, the arch half), but Mach-O is a third
  writer.
- **`.pdata`/`.xdata` — decided, so not really on this list.** `-g` stays for the PE
  target and `pe.y` writes real unwind info (W2); they cannot be optional, because a
  PE without them steps under a DWARF debugger but cannot backtrace, which is worse
  than not shipping `-g` at all. The records come out of frames `pe.y` already knows
  (`arch_frame` gives the size per function), so this is bookkeeping rather than a
  new pass — but two things are not bookkeeping: every emitted function needs a
  `RUNTIME_FUNCTION` entry and the table must cover `.text`, and `RELOCS_STRIPPED`
  does not exempt it.
- **`w_self_test_lines()`'s doc comment describes a function that does not exist.** The
  startup self-test was specified (W3) and the numbers are in `arch_x64.y`'s
  `w_sysno`, but the body is empty. Either implement it or delete the claim — a comment
  that promises a probe nobody runs is worse than no comment.
- **An encoder guard against absolute addresses.** The "no `.reloc`" claim rests on
  nothing ever emitting one, and `enc64.y` has **no `movabs`** — so a 64-bit absolute
  address would be *silently truncated*, not diagnosed. A cheap assertion in `pe.y`
  (or a `pe`-only check that no fixup kind is absolute) is worth adding before W3
  starts needing real data.
- **Program profiling on PE.** `perf` and `callgrind` cannot read a PE at all, so
  R9's program-side half — "profile a compiled program and explain what moved" — has
  no equivalent for any `--target=windows` binary (see R9). What is left on Windows is
  `ycc --time` for the compiler's own phases, plus the Linux-hosted `make bench` that
  compiles PEs and times the Linux reference. Treating that as "the same coverage"
  would quietly drop half a repo rule, so name it instead: the honest substitutes are
  `llvm-mca`-style static estimates and PE-side timing from inside a test run.

---

## Risks

| risk | mitigation |
|---|---|
| **NT syscall numbers drift between Windows versions, and the failure mode is silent-wrong, not loud.** An earlier draft claimed a wrong number yields `STATUS_INVALID_SYSCALL`; it is worse than that. The Windows x64 syscall index range is dense and live, so a leftover Linux number does not land on "no such syscall" — it lands on a *different, real* `Nt*` function, and the symptom is wrong memory or wrong I/O much later, with nothing at the call site to say so. | Pin a documented target version (Windows 10 1607+ / 11) and record it in the manual; keep every number in **one** table in `arch_x64.y`'s dispatch (`arch_sysno`) so a future version is a small diff and a review can see the whole surface at once; and add the **startup self-test** of W3 — one `Nt*` call per class (memory, file, thread, process) with its status checked — so a bad table fails loudly at `ycc` startup on a Windows build instead of misbehaving later. Consider resolving a handful of names through `LdrGetProcedureAddress` if a specific call proves unstable. |
| **`src/c` doubles every line** of W2–W5. | Inherent (R1). The arch half is string data, so its twin is mechanical and `make port-check` is low-risk. |
| **The ABI estimate may be low.** An earlier draft said "7 emitter sites"; the measured set is 90 `F_CALL_L`/`F_CALL_IND` sites, and while only `gen_syscall`'s 5+-argument path has arguments that move, the hand-written `src/y/arch/*.s` routines make their own calls (`call y_alloc`, `call y_arr_push`, …) and are in no count at all. | Do W2 first and hand-inspect a real 4-argument call, a closure call and a 6-argument `syscall` under `--target=windows` before committing to W3's size. |
| **`refs/ycc.ref` must be reblessed per phase**; the tree is red in between. | One phase → `make check` → `make rebless` → commit with numbers (R3). Do not stack. **Not done on this branch**: `refs/ycc.ref` stays the original bootstrap compiler so that `make ynew`'s three-generation fixpoint still means something, and the gate is "the C copy and `./ynew` agree with each other", not "either matches the reference". The measured cost is 272 code-diffs and **0** behaviour-diffs against the reference (`os_write` replaces an inline `syscall` with a call to `y_os_write`); 135 of those code-diffs pre-date this work. `refs/` is a real copy in each worktree, not a symlink, so a stray rebless cannot overwrite the main checkout's blessed binary. |
| **`argv()` on PE needs a command-line splitter, not a UTF-16 fixup**, and the W2 gate cannot see any of it (a hello-world that never calls `argv()` exercises none of it). | Build the parser in W4 — `RtlCommandLineToArgvW` or the MSVC rules, plus the UTF-16→UTF-8 policy for `y_cstr_to_str` — assert it in W5, and size W4 for it rather than leaving it as a footnote. |
| **`ulimit -v` has no equivalent** (W6). | Decided, and cheaper than the exemption it replaces: `JOB_OBJECT_LIMIT_JOB_VM_SIZE` reproduces the fixture, because every mapping here is read-write committed. It costs a ~40-line job-object launcher, not a rule change. |
| **Wine is not Windows.** Good enough to prove a PE loads and runs; not good enough to trust `CreateProcess`, console handles, or the TLS-free thread scheme. | W6 on a real runner; Wine only as a fast inner loop. |
| **The no-`.reloc` claim is load-bearing and silent if violated.** | See the deferred encoder guard. |
| **SETTLED — the std pack bakes ONE target into every program built from it, and no flag on the consuming compiler can undo it.** `ycc --std-pack` never passes a target, so a target test compiled into `rt.y`/`fs.y`/`net.y`/… is baked into the pack and served to every program that links it. Measured both ways: with a conditional in `rt.y`, a PE built from the pack carried the ELF inline `write(2)` and printed nothing, while `--std-src` (which recompiles the units) worked. | **Hard rule, no exceptions: a std entry point names a label and none branches on the target.** `os_write` calls `y_os_write`, `exit` calls `y_os_exit`; the Windows bodies live in `src/y/arch/wsys.s` and the ELF bodies in `src/y/arch/prelude.s`, so the pack carries text correct for whichever compiler wrote it. The corollary for the port: `cycc` carries **no** pack at all, so it compiles the std units from source with its own `res_target` — which is why on the Windows path `cycc` and a pack-carrying `ynew` differ byte-for-byte on the 22 fixtures whose std code still has raw `syscall(` sites, and `cycc` is the correct one of the two. Those raw sites are the W5 work; the divergence disappears when they are gone. |

## Open questions

1. ~~`.pdata`/`.xdata` in W2 or with W6's `-g` work?~~ **Settled: `-g` stays for PE
   and `pe.y` writes real unwind info in W2** — a stepping-but-not-backtracing
   debugger is worse than no `-g`. PDB is the part left open (WinDbg needs it), and
   it is deferred.
2. Should `--target` also be inferred from a `.exe` `-o`, or stay explicit only?
3. The `getpid` mutex check: keep it (pay per lock/unlock) or drop it (lose the
   fork diagnostic)?
4. Does the emitted program ever need to hand a thread id to foreign code? If a
   callback from Win32 is ever wanted, `rdi`/`rsi` stop being scratch and
   `xmm6`–`xmm15` join the callee-saved set.
5. Which Windows version is the pinned syscall-number target?

## Landing order

```
meta.md   (independent — nothing above waits on it)
W1   cycc.exe under mingw-w64      independent
W2   pe.y + asm.y                  independent; de-risk with a hand-computed PE
W3   the arch module's Windows half  needs W2 to test against
W4   --target, threading, ABI      needs W1 for the native story, W2+W3 for output
W5   std split                     needs W2
W6   the Windows harness           needs W5 to be worth anything
```

W2 before W3 before W4, because the writer is the keystone and everything else emits
code that must land in a valid PE.
