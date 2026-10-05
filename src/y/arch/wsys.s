# wsys.s -- the Windows half of the arch prelude: the blocks of prelude.s
# that reach the kernel, rewritten for NT direct syscalls.
#
# WHY THIS FILE IS A SEPARATE SET OF BLOCKS rather than a second prelude: a
# path import is flattened into its importer, so a second arch_x64.y could not
# coexist (arch_frame would be defined twice and the second would win). So the
# module is one file with internal dispatch (arch_x64.y arch_windows_lines),
# and this file is the data that dispatch substitutes: each block below
# REPLACES the same-named block of prelude.s when the target is Windows. The
# blocks are named exactly as the ones they replace because prelude.s's own
# code calls them; the extra helpers (y_os_*) are private and are only ever
# called from inside the replacement blocks, so the tree shaker keeps them
# when -- and only when -- the block that calls them is kept.
#
# THE CONVENTION, once, for every block below:
#   mov  $number, %eax          the syscall's index
#   arg1 %r10  arg2 %rdx  arg3 %r8  arg4 %r9   arg5+ on the stack at 40(%rsp),
#   48(%rsp), 56(%rsp)...
#   the result is an NTSTATUS in %rax, and FAILURE IS THE POSITIVE SIGN BIT
#   of its low 32 bits: `test %eax,%eax; js` is the failure test. Carrying a
#   SysV `js`/`>= 0` over would read failure as success, and testing %rax
#   instead of %eax would too -- writing EAX clears the high half, so a
#   failure status arrives as a POSITIVE 64-bit value.
#
# WHY THOSE REGISTERS, since "r10/r9/r8/rdx then rcx/r11" is a natural
# mistake and an earlier revision of this file made it: the caller of a
# syscall is ntdll, and ntdll is a Win64 function.  Its own generated stubs
# expand to exactly
#       mov $number, %eax
#       mov %rcx, %r10
#       syscall
# ONE shuffle, because `syscall` destroys %rcx (so argument one must move out
# of it) and leaves everything else alone.  Arguments two, three and four are
# already in %rdx, %r8, %r9, and argument five onwards are already in ntdll's
# shadow space at 40(%rsp) and up -- which is where the kernel reads them,
# because they are the same slots ntdll's caller wrote them into.  Any other
# register set would mean shuffling arguments ntdll has already placed
# correctly, which is the test: if a layout needs more than one instruction in
# ntdll's stub, it is not the layout ntdll uses.
#
# ARGUMENTS FIVE AND UP are on the stack at 40(%rsp), 48(%rsp), ... (see the
# convention above), which is this runtime's own frame -- the 32 bytes below
# that are the shadow space a Win64 callee may read its register arguments
# out of, and nothing here is a real Win64 callee, so nothing has to reserve
# that part for a callee to read.
#
# There is no second opinion encoded here. An earlier revision of this file
# duplicated every argument into both a register and a stack slot "because
# wine needs it"; that is contorting Windows code around a runtime that is
# not the target, and it cannot even be self-consistent (it would put arg5 at
# arg7's slot). It is gone. If a call here is wrong, the call is wrong.
#
# The numbers are the Windows 10 1607 / 11 x64 table, pinned in
# arch_x64.y w_sysno (one arm per call, so a future Windows is a small diff).
# They were read off the syscall stubs in a real ntdll's .text, not written
# from memory: a leftover Linux number silently calls a different, real Nt
# function, which is why that table is one list a review can read at once.
#
# THE FRAME, once, because every block below that calls another one needs it:
# y_os_write and y_os_exit take their arguments ON THE STACK (see y_os_write),
# and so does every Y function, so the two agree and the emitter's pushes land
# where the callee looks. The trap stubs, which are reached by a `jmp` and so
# arrive on the SysV register set, marshal by hand.
#
# THE PUSH ORDER, which the trap stubs below must match exactly: the
# descriptor, then the bytes, then the count -- so the COUNT is the lowest of
# the three and lands at 16(%rbp) inside y_os_write, the bytes at 24 and the
# descriptor at 32. This is the order the emitter's os_write uses (native.y),
# which is the definition; a stub that pushes the other way round hands
# y_os_write the byte count as the file's HANDLE, which is silent -- the call
# returns some other status and the program exits having printed nothing.
#
# y_os_exit takes its status ON THE STACK too (see its own comment), so these
# stubs push it and pop afterwards rather than leaving it in %rdi.
#
# NO `push $immediate`: the in-tree assembler has no push-immediate form --
# ir.y gives F_PUSH_R kinds [O_REG] and nothing else -- so a `push $1` in one
# of these blocks is "push needs r64" at assembly time, a diagnostic that names
# the instruction rather than the missing form. The trap stubs go through %rax
# for it, which is what every other call site in the tree does.
#
# A block here must NOT assume a callee-saved register survives it. Win64 makes
# %rbx, %r12, %r13, %r14 and %r15 callee-saved; these blocks push and pop their
# own, and y_os_write's own prologue pushes %r13 -- which is why the byte
# counts below are 16/24/32(%rbp) and not the SysV registers. Getting that
# wrong is silent: the block runs, and reads a count of 2 because it read back
# a return address.
#
# y_os_handle: fd (%rdi, 0/1/2) -> the process's standard I/O handle. %gs:0x60
# is the PEB on x64 -- stable, unlike TEB.ThreadLocalStoragePointer across
# versions -- PEB+0x20 is ProcessParameters, and RTL_USER_PROCESS_PARAMETERS
# holds StandardInput/Output/Error at +0x20/+0x28/+0x30. This is the one PEB
# read in the tree, and it exists because a "fd" is not a handle on Windows.
# A syscall per write, which is the cost of having no imports at all.
#=== add: y_os_handle ===
# Every displacement below is DECIMAL (96, 32, 48) and not the hex a reader
# would expect, because the in-tree assembler's number reader is decimal
# (parse_num in asm.y). A hex literal here is a "bad operand" with a
# diagnostic naming the instruction rather than the literal, and it cost a
# session to find because the block had never been reachable: until `print`
# went through y_os_write, nothing a program could call reached y_os_handle.
# 96 is the PEB on x64; PEB+32/+48 are ProcessParameters->StandardInput and
# ->StandardOutput. (Whole-line `#` comments are allowed in this file only
# because the arch module strips them; an indented one reaches the assembler,
# which has no comment syntax of its own.)
y_os_handle:
    mov %gs:96, %rax
    mov 32(%rax), %rax
    cmp $1, %rdi
    jl yosh_in
    je yosh_out
    mov 48(%rax), %rax
    ret
yosh_in:
    mov 32(%rax), %rax
    ret
yosh_out:
    mov 40(%rax), %rax
    ret
# y_os_write(fd, buf, len) -> bytes written, or -1. This REPLACES the
# prelude's write(2) version rather than adding a second one, because it is the
# same entry point: rt.y's y_put_hstr reaches it through the os_write
# intrinsic, so shared std code names one label and the arch module decides
# which kernel call it is. (It was an `add:` block before y_os_write existed in
# prelude.s, when only the trap stubs called it.)
# NtWriteFile takes NINE arguments, which is why it is the call that needs the
# stack slots: handle, event, ApcRoutine, ApcContext, IoStatusBlock, buffer,
# length, offset, key. Four go in registers and the last five at 40(%rsp)
# upwards -- which is why the frame reserves 128 bytes below %rsp here.
# Offset and key are NULL, which is what a console or a pipe wants; the byte
# count comes back in the IO_STATUS_BLOCK's Information field, not in the
# status.  The IO_STATUS_BLOCK lives at -16(%rbp), Information at -8(%rbp).
# y_os_write's three arguments are on the STACK, not in %rdi/%rsi/%rdx: the
# emitter pushes them (os_write in native.y) and a `call` does not put
# arguments in registers. The emitter pushes them left to right, so the COUNT
# -- pushed last -- is the lowest of the three and sits just above the return
# address: 16(%rbp) is the count, 24(%rbp) the bytes and 32(%rbp) the
# descriptor. That is the same rbp+16+8*(n-1-k) layout every Y function uses,
# read right to left, and getting it backwards is silent -- y_os_write still
# runs, and writes a descriptor-sized chunk of whatever the stack held. The
# prelude's version reads the same three off %rsp directly, which is why its
# numbers are 8 lower: it has no frame.
# y_os_write's epilogue restores the three saved registers with explicit loads
# rather than pops. They were pushed AFTER `push %rbp`, so they sit BELOW %rbp
# (-8, -16, -24) while the return address and the three stack arguments sit
# above it -- and a pop-based epilogue after `mov %rbp,%rsp` walks up from the
# saved frame pointer instead, handing %r13 the old %rbp, %rbp %r12, and
# returning into %r13. The symptom is why this is written down: the program
# printed its whole output correctly and then faulted executing address 1,
# which is %r13 holding a stack address. `mov %rbp,%rsp; pop %rbp; ret` is
# right for the two other blocks here, which push nothing between the frame
# pointer and the `sub`.
#=== replace: y_os_write ===
y_os_write:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $128, %rsp
    mov 32(%rbp), %r12
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r13
    mov %r12, %rdi
    call y_os_handle
    mov %rax, %r10
    xor %edx, %edx
    xor %r8d, %r8d
    xor %r9d, %r9d
    lea -16(%rbp), %rax
    mov %rax, 40(%rsp)
    mov %rbx, 48(%rsp)
    mov %r13, 56(%rsp)
    mov $0, 64(%rsp)
    mov $0, 72(%rsp)
    mov $8, %eax
    syscall
    test %eax, %eax
    jns yow_ok
    mov $-1, %rax
    jmp yow_out
yow_ok:
    mov -8(%rbp), %rax
yow_out:
    mov -24(%rbp), %r13
    mov -16(%rbp), %r12
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_exit(status) -- NtTerminateProcess(-1, status). `div` by zero after it:
# the call does not return, and if it somehow does the program must stop
# loudly rather than run on past its own exit. `div` by zero is the trap the
# rest of the prelude already uses for an impossible condition (y_long_tostr);
# the encoder has no ud2.
# y_os_exit(status) replaces the prelude's exit_group version rather than adding
# a second one, for the reason gen_exit's comment gives: rt.y calls exit() and
# rt.y is compiled into the std pack, which one compiler writes for one target.
# The argument arrives on the stack (the emitter pushes it), so 16(%rbp) is the
# status -- pushed last, so lowest.
#=== replace: y_os_exit ===
y_os_exit:
    push %rbp
    mov %rsp, %rbp
    mov 16(%rbp), %rdx
    mov $-1, %r10
    mov $44, %eax
    syscall
# NtTerminateProcess does not return, and if it somehow does the program must
# stop loudly rather than run on past its own exit -- so there is no `ret`
# above and this trap is what actually follows the syscall. `div` by zero is
# the trap the rest of the prelude already uses for an impossible condition
# (y_long_tostr); the encoder has no ud2.
    xor %eax, %eax
    div %rax
# The trap stubs. Each writes its message to the standard output and ends the
# process with status 1, which is what the SysV version does (write(1, ...)
# then exit_group(1)).
#=== replace: y_div_zero ===
y_div_zero:
    lea ystr_divzero(%rip), %rsi
    mov $ystr_divzero_end-ystr_divzero, %rdx
    mov $1, %rax
    push %rax
    push %rsi
    push %rdx
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp
#=== replace: y_oob ===
y_oob:
    lea ystr_oob(%rip), %rsi
    mov $ystr_oob_end-ystr_oob, %rdx
    mov $1, %rax
    push %rax
    push %rsi
    push %rdx
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp
#=== replace: y_cast_trap ===
y_cast_trap:
    lea ystr_cast(%rip), %rsi
    mov $ystr_cast_end-ystr_cast, %rdx
    mov $1, %rax
    push %rax
    push %rsi
    push %rdx
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp
#=== replace: y_alloc_fail ===
y_alloc_fail:
    lea ystr_oom(%rip), %rsi
    mov $ystr_oom_end-ystr_oom, %rdx
    mov $1, %rax
    push %rax
    push %rsi
    push %rdx
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp
#=== replace: y_opt_unwrap ===
y_opt_unwrap:
    lea ystr_opt(%rip), %rsi
    mov $ystr_opt_end-ystr_opt, %rdx
    mov $1, %rax
    push %rax
    push %rsi
    push %rdx
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
    add $8, %rsp
# y_alloc_map: the allocator's mapping request. The size arrives in %rsi,
# the same register the SysV mmap call it replaces takes it in (y_alloc_more
# sets it). NtAllocateVirtualMemory takes six arguments: four in registers,
# the last two at 40(%rsp) and 48(%rsp) (see the file header), which is what
# the 128-byte frame is for:
#   NtAllocateVirtualMemory(-1, &BaseAddress, 0, &RegionSize,
#                          MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)
# with MEM_COMMIT|MEM_RESERVE = 0x3000 and PAGE_READWRITE = 0x04. The address
# comes back through BaseAddress and a failure is 0, which is what the caller
# (y_alloc_slow) tests for. The two out-parameters live BELOW %rbp: rbp+0 is
# the saved frame pointer and rbp+8 the return address, so nothing above %rbp
# is this frame's, which is why the frame is reserved at all.
#=== replace: y_alloc_map ===
y_alloc_map:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp
    mov $0, -8(%rbp)
    mov %rsi, -16(%rbp)
    mov $-1, %r10
    lea -8(%rbp), %rdx
    xor %r8d, %r8d
    lea -16(%rbp), %r9
    mov $12288, 40(%rsp)
    mov $4, 48(%rsp)
    mov $24, %eax
    syscall
    test %eax, %eax
    jns y_alloc_map_go
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
y_alloc_map_go:
    mov -8(%rbp), %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# ── the rest of the named syscall layer ─────────────────────────────────
# The same names types.y's os_call_names lists, Windows bodies. The rule that
# governs all of them: std code says os_call("y_os_read", fd, buf, len) and
# compiles to a `call y_os_read`, so the four embedded std units are the same
# bytes on both targets even though they are compiled once and serialized into
# one pack. What differs lives HERE, and nowhere else.
#
# Two conventions, both forced by the same fact -- a `call` does not put
# arguments in registers, so every block takes them off the stack:
#
#   - A block with a frame reads its parameters at 16(%rbp) (the LAST one
#     pushed is the FIRST parameter, so it sits lowest). A frameless block
#     reads them at 8(%rsp), just above the return address. y_os_write above
#     uses 16/24/32(%rbp); the frameless blocks below use 8(%rsp).
#   - A block that needs scratch registers pushes them AFTER `push %rbp`, so
#     they sit BELOW %rbp (-8, -16, -24, ...) and the epilogue restores them
#     with explicit loads, not pops. `mov %rbp,%rsp; pop %rbp; ret` is only
#     right when nothing was pushed between the frame pointer and the `sub`.
#     The saved registers therefore own the top three words below %rbp, and
#     any local goes below -32.
#
# NTSTATUS polarity: every Nt* call returns a signed status, NEGATIVE meaning
# failure, while the Linux caller wants a negative errno and reads the return
# with `< 0`. So each block tests the high half -- `test %eax, %eax; js` -- which
# is what makes it work: STATUS_SUCCESS is 0, a failure is negative in its low
# 32 bits, and no Nt call this file makes returns a positive non-zero status.
#
# The failure value is -1, matching y_os_write above, and NOT the negated
# status. Two reasons, one of them a trap I fell into: an Nt stub returns the
# status in EAX, and a 32-bit register write ZEROES bits 63:32, so the status
# arrives in %rax as a POSITIVE 0x00000000C0000005 and a 64-bit negate of it
# would be -3221225477 rather than an errno; getting a signed 32-bit negate
# needs `neg %eax`, which the in-tree assembler does not accept ("unary form in
# 'neg'" -- `make asm-check` cannot see it, because GNU as does). And nothing
# reads the magnitude: every caller above tests `< 0` or `>= 0` and nothing
# prints an errno, so a table from NTSTATUS to errno would be machinery with no
# reader.
#
# Decimals, not hex, wherever a displacement is a number: the in-tree
# assembler's number reader is decimal-only (parse_num in asm.y), and a hex
# literal here is "bad operand" with a diagnostic naming the instruction.

# y_os_read(fd, buf, len) -> bytes read, or a negative errno. read(2) on the
# other side. NtReadFile has NtWriteFile's nine-argument shape and the same
# four-registers-then-40(%rsp) split, so the frame reserves 128 bytes and the
# byte count comes back in the IO_STATUS_BLOCK's Information field at
# -8(%rbp). `offset` is the AbsoluteOffset pointer: 0 means "use the file
# pointer", which is what read(2) on an ordinary descriptor does. NtReadFile
# blocks rather than returning STATUS_PENDING for a console or a pipe, so no
# event and no APC routine are needed -- a caller that wanted overlapped I/O
# would have to pass both, and none of them does.
# The descriptor is a handle, so it goes through y_os_handle like y_os_write's.
#=== replace: y_os_read ===
y_os_read:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $128, %rsp
    mov 32(%rbp), %r12
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r13
    mov %r12, %rdi
    call y_os_handle
    mov %rax, %r10
    xor %edx, %edx
    xor %r8d, %r8d
    xor %r9d, %r9d
    lea -16(%rbp), %rax
    mov %rax, 40(%rsp)
    mov %rbx, 48(%rsp)
    mov %r13, 56(%rsp)
    mov $0, 64(%rsp)
    mov $0, 72(%rsp)
    mov $6, %eax
    syscall
    test %eax, %eax
    jns yor_ok
    mov $-1, %rax
    jmp yor_out
yor_ok:
    mov -8(%rbp), %rax
yor_out:
    mov -24(%rbp), %r13
    mov -16(%rbp), %r12
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_wait4(pid, status) -> the pid that changed state, or a negative errno.
#
# NOT IMPLEMENTED, and the comment says so rather than pretending: Windows has
# no wait-for-a-pid, because a pid is not a handle and there is no Nt call that
# opens a process object by id (NtOpenProcess is a Win32-era call that exists
# only behind the win32u bridge). Resolving a pid to a handle needs either that
# bridge -- which this image cannot use, having no import table at all (pe.y
# writes none) -- or a handle the forking side handed over, which means a fork
# implementation that does not exist yet either (see y_os_fork).
#
# So the answer is ECHILD (-10), which is exactly what the Linux caller expects
# when there is no such child: rt.y's y_wait_pid turns it into -1, and a program
# that checks for a failed wait sees a failed wait. What it must NOT do is block
# forever, because the handle does not exist to block on.
#
# The block exists NOW rather than when the work lands, and that is the whole
# point of the named layer: rt.y's call site is now `os_call("y_os_wait4", ...)`
# and compiles to the same bytes for both targets, so finishing this is a change
# to wsys.s alone, with no target branch anywhere above it to remove.
#=== replace: y_os_wait4 ===
y_os_wait4:
    mov $-10, %rax
    ret
# y_os_fork() -> 0 in the child, the child's pid in the parent, or a negative
# errno.
#
# NOT IMPLEMENTED, for the reason the shape of the thing makes unavoidable: a
# Windows process has ONE address space, and its threads share it, so "parent
# and child then see the same heap" cannot be true of anything Windows has.
# What Windows has is a clone -- NtCreateThreadEx -- which is exactly what
# `spawn` already maps onto, so the honest mapping is spawn-with-a-body and a
# join, and the honest answer here is ENOSYS (-38), which a Linux program
# already checks for. exec.y's fallback (fork fails -> exec in place) is what
# keeps that usable rather than a dead end.
#=== replace: y_os_fork ===
y_os_fork:
    mov $-38, %rax
    ret
# y_os_execve(path, argv, envp) -> does not return on success; a negative errno
# on failure.
#
# NOT IMPLEMENTED, same answer and nearly the same reason. The NT-level
# equivalent is NtCreateUserProcess (index 60), and it takes a command line and
# an environment block in Win32 structures -- UNICODE_STRING, and the
# RTL_USER_PROCESS_PARAMETERS the PEB already points at -- not three C arrays.
# Building those is real work (it is the argv work in B6, which has to happen
# anyway for `argv()`), so it is left for that rather than faked here.
#=== replace: y_os_execve ===
y_os_execve:
    mov $-38, %rax
    ret
