# M1: run a compiled image in a forked child

`src/y/meta.y` holds `run_image`; `ycc run FILE` is built on it. This note
records what was measured and what the design turned out to be, because three
of the four load-bearing facts in it are measurements rather than assumptions.

## The transfer

`run_image` maps the image, then starts it with

```
syscall(56, SIGCHLD, stack_top, 0, 0, 0)   -- clone, Linux x86-64
jmp_at(img + entry)                        -- in the child only
```

**MEASURED, and it contradicts the spec.** `ideas/meta.md` says (M1, step 3)
that the kernel returns the child to user mode with `sysretq`, which pops the
entry address out of the child's own stack — i.e. that the word at
`stack_top` is where the child starts. It does not. gdb on a raw `clone` with a
chosen stack shows the child coming back from the syscall with `%rax = 0`,
`%rsp = stack_top`, and RIP at **the instruction after the syscall, still
running the caller's code**:

```
[pid 1664682] ... rip 0x4005d3 (_start+596)  rsp 0x7ffff7a0ea60  rax 0
0x7ffff7a0ea60:  0x00000000deadbeef  0x0000000000000000
```

(The earlier reading that suggested otherwise was an artefact of a C test
whose `syscall()` wrapper has a `ret` after the syscall: the `ret` popped the
word at the new stack top. Nothing in the kernel does that for us.)

So `sp` is only a *stack*, and the transfer needs one more instruction. It
cannot be a `call`: `_start` reads `[%rsp]` for argc, and a `call` would push
a return address exactly there. Hence the `jmp_at` builtin — a new `jmp *%reg`
form (ir.y `F_JMP_IND`, enc64.y `enc_jmp`), the only new instruction in the
tree. `make ynew` therefore cannot bootstrap itself here (its BOOT is
`refs/ycc.ref`, which predates the builtin), so the build runs in three
generations by hand: one with the `jmp_at` call commented out (that compiler
*knows* `jmp_at`, because it compiles it), then two real ones, and `cmp` on
the last two. Both are byte-identical. The script is not committed; it is a
three-line sequence on `src/y/meta.y` plus `refs/ycc.ref -o _s1 src/y/ycc.y`.

## MAP_FIXED is not usable for the .bss

The spec's plan was two mappings: the image `mmap`ed PROT_READ|PROT_EXEC, and
the `.bss` `mmap`ed MAP_FIXED at `img + bss_delta`. **This kernel refuses the
second one** — `mmap` at a fresh address immediately above an existing mapping
returns EINVAL:

```
mmap(a1 + 0x1000, 0x1000, RW, FIXED|PRIVATE|ANON) -> EINVAL
mmap(0x7f0000000000, 0x1000, RW, FIXED|PRIVATE|ANON) -> ok   (unused address)
mmap(a1,        0x1000, RW, FIXED|PRIVATE|ANON) -> ok        (already mapped)
```

Tested on both a `long`-addressed raw syscall and libc's `mmap`, on kernel
7.2.6. `MAP_FIXED` over an *existing* mapping and at a *constant unused*
address both work, so it is specifically the adjacent-fresh-address case.

One memfd sized to the whole span (`write` + `ftruncate` + one `mmap`, then
`mprotect` the code part R|X) does the whole job instead, with no MAP_FIXED
and one fewer syscall. The `.bss` pages come from the file's zeros past
`filesz`, which is exactly what `elf_build` assumed the loader would supply.

## Gate results

`/tmp/opencode/runcheck.sh` compiles each program, runs the binary, runs
`ycc run`, and compares stdout, stderr and exit status.

| corpus | programs | mismatches |
|---|---|---|
| `test/y/examples/*.y` | 15 | 0 |
| `test/y/native/*.y` | 310 | 0 |

Trap and status cases (`/tmp/opencode/gate/*.y`), all matching the
compiled-then-executed path:

| program | compiled | `ycc run` |
|---|---|---|
| `1/0` | prints `runtime error: division by zero`, 1 | same, 1 |
| `exit(7)` | 7 | 7 |
| index out of bounds | trap, 1 | trap, 1 |
| `jmp_at(0)` | SIGSEGV, 139 | SIGSEGV, 139 |

The compiler survived all four. The guest's own traps go to *the child's*
stdout and its exit status is the child's, which is the whole reason for the
fork.

## Peak memory

`/usr/bin/time -f %M`, whole process, under `ulimit -v 3670016`:

| program | compile | `ycc run` | native binary |
|---|---|---|---|
| `helloworld.y` | 17 324 KB | 18 436 KB | 2 064 KB |
| `test.y` | 18 944 KB | 17 376 KB | 388 KB |
| `src/y/ycc.y` | 1 079 028 KB | 1 079 488 KB | 392 KB |

The fork does **not** double peak RSS on the compiler-scale case: +460 KB on
`ycc.y` (0.04%), and within noise on the others. A forked child shares every
page copy-on-write, so `/usr/bin/time`'s accounting — which sums RSS across the
process and its reaped children — sees the pages once. The cost that is real is
the image mapping itself: one memfd plus one mapping per run, both released in
`map_release` after the wait. A program with blocks pays this once per resolve,
not once per block.

`ycc run` is also slightly *cheaper* than compile on `test.y`, which is the
`heap_used` reading `TOTAL` row: with no `-o` there is no output file, and the
emitted assembly string is dropped as soon as it is assembled.

## Costs paid in the compiler's own build

`src/y/meta.y` is imported by `ycc.y` and by nothing else, so the runner and
`meta_dump` shake out of a binary that does not use them. The only
unconditional cost is `jmp_at` reaching `is_intrinsic_name` and `typeof_call`:
two list/chain entries, zero emitted code. A `-S` listing shows no `jmp *%`
unless a program calls `jmp_at`.