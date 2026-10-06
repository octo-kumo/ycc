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
# 0, 1 and 2 are the PEB's StandardInput/Output/Error; anything higher is
# already a real handle (fs.y's y_os_openat returns an NtCreateFile handle) and
# goes through untouched. This used to send every fd above 1 to StandardError,
# which was invisible while the only fds anyone had were 0, 1 and 2 -- writes
# appeared on the console and read never saw the file.
y_os_handle:
    cmp $3, %rdi
    jl yosh_map
    ret
yosh_map:
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
#   - Parameter k of n is at 16+8*(n-k)(%rbp) in a block with a frame: the
#     LAST parameter pushed is the FIRST one, so it sits lowest. n=3 reads
#     32/24/16, n=2 reads 24/16, n=1 reads 16. A frameless block reads the same
#     offsets off %rsp instead (8/16/24), because there the return address
#     pushes everything up by 8 -- which is why y_os_write above uses
#     32/24/16(%rbp) and prelude.s's Linux halves use 24/16/8(%rsp) for the
#     SAME three parameters. Getting this wrong is silent: the block runs, and
#     reads whatever the stack held.
#   - A block that needs scratch registers pushes them AFTER `push %rbp`, so
#     they sit BELOW %rbp (-8, -16, -24, ...) and the epilogue restores them
#     with explicit loads, not pops. `mov %rbp,%rsp; pop %rbp; ret` is only
#     right when nothing was pushed between the frame pointer and the `sub`.
#     The saved registers therefore own the top three words below %rbp, and
#     any local goes below -32.
#
# The argument registers, because getting one wrong is silent: a call that
# writes its second argument through %rsi instead of %rdx still returns
# STATUS_SUCCESS, and the out-parameter it did not write keeps whatever the
# stack held -- a clock frequency read as 1.2e14 and a monotonic clock frozen at
# zero. The set is the one native.y's w_syscall_reg implements and
# gen_syscall stages:
#
#     arg1 %r10   arg2 %rdx   arg3 %r8   arg4 %r9   arg5+ at 40(%rsp), 48, ...
#
# NOT %rsi for argument two (that is the SysV order, and it is the mistake this
# note was written for), and not r10/r9/r8/rdx/rcx/r11.
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
# y_os_lseek(fd, off, whence) -> the new offset, or a negative errno.
#
# NOT a transliteration, because Windows has no lseek. Its two halves:
#
#   SEEK_CUR (1) with a NEGATIVE offset -- which is the only form prelude.y's
#   y_stdin_sync uses, to push back the bytes readline buffered but did not
#   return -- is expressed with NtSetInformationFile (index 13) and
#   FILE_POSITION_INFORMATION { LARGE_INTEGER Offset; ULONG FilePointer; } at
#   -72(%rbp): the NT offset is ABSOLUTE, so the current size comes first, from
#   NtQueryInformationFile (index 23) with FileStandardInformation (1) into a
#   24-byte buffer at -56(%rbp) whose EndOfFile is the LARGE_INTEGER at -48.
#
#   SEEK_SET (0) is the same SetInformationFile with the offset as given.
#   Anything else answers -22 (EINVAL) rather than doing the wrong thing: "works
#   for the one caller" is not a contract a named entry point can make, and a
#   silent wrong answer in a seek is the kind of bug that shows up as corrupt
#   input three layers away.
#
# Both Nt calls take five arguments -- handle, the IO_STATUS_BLOCK, the
# information buffer, its length, the class -- so the class is the fifth and goes
# to 40(%rsp), which is why this block reserves 160 bytes rather than 128. The
# handle comes from y_os_handle, because a "fd" is not a handle.
#=== replace: y_os_lseek ===
y_os_lseek:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $160, %rsp
    mov 32(%rbp), %rbx
    mov 24(%rbp), %r12
    mov 16(%rbp), %r13
    cmp $1, %r13
    jne yol_seekset
    cmp $0, %r12
    jns yol_bad
    mov %rbx, %rdi
    call y_os_handle
    mov %rax, -32(%rbp)
    lea -48(%rbp), %rdx
    lea -80(%rbp), %r8
    mov $24, %r9d
    mov $1, 40(%rsp)
    mov -32(%rbp), %r10
    mov $23, %eax
    syscall
    test %eax, %eax
    js yol_fail
    mov -72(%rbp), %rax
    add %r12, %rax
    jmp yol_set
yol_seekset:
    test %r12, %r12
    js yol_bad
    mov %r12, %rax
yol_set:
    mov %rax, -96(%rbp)
    mov %rbx, %rdi
    call y_os_handle
    mov %rax, -32(%rbp)
    lea -48(%rbp), %rdx
    lea -96(%rbp), %r8
    mov $12, %r9d
    mov $13, 40(%rsp)
    mov -32(%rbp), %r10
    mov $13, %eax
    syscall
    test %eax, %eax
    jns yol_out
yol_fail:
    mov $-1, %rax
    jmp yol_out
yol_bad:
    mov $-22, %rax
yol_out:
    mov -24(%rbp), %r13
    mov -16(%rbp), %r12
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_clock_gettime(clock, ts) -> 0, or a negative errno. Two NT calls, because
# the two clocks Linux offers are two different things here:
#
#   clock 0, CLOCK_REALTIME  -> NtQuerySystemTime (index 90), one argument, the
#     LARGE_INTEGER it fills being 100 ns ticks since 1601-01-01 -- so a tick is
#     100 ns and a second is 10^7 of them. Converted into the caller's struct
#     timespec AND shifted to the Unix epoch, which is
#     why the 11644473600 seconds between the two are built at run time out of
#     three small multiplies rather than one immediate: the difference in 100 ns
#     units is 1.16e17, and this assembler has no movabs (a 64-bit immediate
#     would be silently truncated, which pe.h is explicit about).
#
#   clock 1, CLOCK_MONOTONIC -> NtQueryPerformanceCounter (index 49), the
#     counter at -16(%rbp) and its frequency at -24(%rbp). QPC ticks are in
#     units the frequency gives, NOT nanoseconds, so the conversion is a real
#     division and not a shift. It is done as
#         ns = (ticks / freq) * 1e9 + (ticks % freq) * 1e9 / freq
#     rather than ticks * 1e9 / freq because that product overflows 64 bits;
#     the split form cannot, since the frequency is a 32-bit field, so the
#     remainder is below 2^32 and the product below 2^62.
#
# Writing a struct timespec into the caller's buffer is the whole trick. Nothing
# above the arch module knows that a FILETIME is two 32-bit fields or that a
# QPC tick is not a nanosecond: rt.y allocates { i64 sec; i64 nsec; } and reads
# it back, on both targets, unchanged.
#=== replace: y_os_clock_gettime ===
y_os_clock_gettime:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $48, %rsp
    mov 16(%rbp), %rbx
    mov 24(%rbp), %rcx
    test %rcx, %rcx
    je yoc_realtime
    lea -16(%rbp), %r10
    lea -24(%rbp), %rdx
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov $49, %eax
    syscall
    test %eax, %eax
    js yoc_fail
    mov -24(%rbp), %rcx
    test %rcx, %rcx
    jz yoc_fail
    mov -16(%rbp), %rax
    xor %edx, %edx
    div %rcx
    mov %rax, %rsi
    mov $1000000000, %rdi
    imul %rdi, %rsi
    mov %rdx, %rax
    imul %rdi, %rax
    mov %rcx, %rdi
    xor %edx, %edx
    div %rdi
    add %rsi, %rax
    mov $1000000000, %rdi
    xor %edx, %edx
    div %rdi
    mov %rax, (%rbx)
    mov %rdx, 8(%rbx)
    xor %eax, %eax
    jmp yoc_out
yoc_realtime:
    mov %rbx, %r10
    xor %esi, %esi
    xor %edx, %edx
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov $90, %eax
    syscall
    test %eax, %eax
    js yoc_fail
    mov (%rbx), %rax
    mov $1000000, %rdi
    mov $116444736, %rsi
    imul %rdi, %rsi
    mov $1000, %rdi
    imul %rdi, %rsi
    sub %rsi, %rax
    mov $10000000, %rdi
    xor %edx, %edx
    div %rdi
    mov %rax, (%rbx)
    mov $100, %rdi
    imul %rdi, %rdx
    mov %rdx, 8(%rbx)
    xor %eax, %eax
    jmp yoc_out
yoc_fail:
    mov $-1, %rax
yoc_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_nanosleep(ts) -> 0, or a negative errno. NtDelayExecution (index 52)
# takes a LARGE_INTEGER in 100 ns ticks, and NEGATIVE: the NT field is a
# relative interval expressed as a negative count, the opposite sign to the
# timespec rt.y hands in. ONE TICK IS 100 NANOSECONDS, so the conversion is a
# division by 100 -- multiplied by 10000 instead (which is what an earlier
# revision of this block did) it is 100000 times too long, and a program asking
# for a 50 ms sleep hangs for fourteen hours instead of failing.
#
# The caller's two longs are folded into one interval in a register and stored
# into this frame's own scratch, which is the buffer the call points at. Note
# Three things about that division, all three of which this block got wrong at
# once and in two different revisions:
#
#   - `div` reads the dividend from rdx:rax, so the interval has to END UP in
#     %rax. An earlier revision left it in %rdx and divided 0:%rax, which is a
#     ten-fold short sleep rather than an error.
#   - the high half must be cleared with `xor %edx, %edx`, not `xor %eax, %eax`:
#     leaving the low half of the dividend in rdx is a divide OVERFLOW, which is
#     the same #DE the trap calls "divide by zero" -- so it looked like a hang.
#   - and the DIVISOR cannot be the register being cleared, which is how an
#     intermediate revision divided by zero exactly.
#
# `div` is UNSIGNED, so the interval must reach it as a POSITIVE count of
# nanoseconds -- sec*10^9 + nsec, not nsec - sec*10^9 as an earlier revision had
# it. A timespec with sec = 1 and nsec = 500000000 is half a second, but the
# subtraction makes it minus half, the unsigned division of that by 1000 is
# 1.8e16, and NtDelayExecution is asked to sleep for 54 years: every sub-second
# sleep worked and every one-second sleep hung, which is a symptom worth more
# than the fix. `neg` at the end is where the sign belongs, because the NT field
# wants a negative count.
#
# EINTR is not special-cased: a negative result is what a Linux caller checks
# and rt.y's sleep ignores the return.
#=== replace: y_os_nanosleep ===
y_os_nanosleep:
    push %rbp
    mov %rsp, %rbp
    sub $64, %rsp
    mov 16(%rbp), %rdi
    mov (%rdi), %rax
    mov $1000000000, %rcx
    imul %rcx, %rax
    mov 8(%rdi), %rdx
    add %rdx, %rax
    mov $10, %rcx
    imul %rcx, %rax
    mov $1000, %rcx
    xor %edx, %edx
    div %rcx
    neg %rax
    mov %rax, -8(%rbp)
    lea -8(%rbp), %rdx
    xor %r10d, %r10d
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov $52, %eax
    syscall
    test %eax, %eax
    js yon_fail
    xor %eax, %eax
    jmp yon_out
yon_fail:
    mov $-1, %rax
yon_out:
    mov %rbp, %rsp
    pop %rbp
    ret

#=== replace: y_argv_init ===
# y_argv_init on Windows: the PEB's command line, not the kernel stack.
#
# _start's prologue (native.y, emit_one_fn) is the SysV shape: it pushes the
# register it uses for the array, pushes what Linux reads as argv (rsp+8 at
# the call), and calls here. A PE entry point gets none of that. Windows
# passes ONE WIDE COMMAND LINE in %r8 at entry -- not an argv, and not even an
# argc -- and by the time _start runs, every register that held it has been
# overwritten. So the two words on the stack are dead here and are not read;
# the command line is read where Win64 keeps it:
#
#   %gs:96                     the PEB (x64; the same read y_os_handle makes)
#   PEB+32                     -> ProcessParameters
#                +112          CommandLine.Length, a USHORT in BYTES
#                +120          CommandLine.Buffer, the whole line
#
# (Displacements are DECIMAL because the in-tree number reader is -- see the
# note above y_os_handle. 112 is 0x70 and 120 is 0x78.)
#
# CommandLine.Buffer holds the PROGRAM NAME FIRST, exactly as Linux's argv[0]
# does, so nothing has to be synthesized: this one read is a correct argv[0]
# on Windows, and there is no lpCmdLine the program name would have to be
# prepended to. The read is a load, not a syscall -- the PEB is mapped in
# every process -- so there is no status to check and this cannot fail.
#
# The split is CommandLineToArgvW's, reimplemented below: 2n backslashes
# before a quote are n backslashes and a REAL quote (which toggles quoting);
# 2n+1 are n backslashes and a LITERAL quote; space and tab split only
# outside quotes. These are MSVC's rules, not a shell's -- `"a b"` is one
# argument -- and they are re-derived here rather than transliterated from a
# C parser, which is why a backslash run is counted before the quote that
# ends it is classified.
#
# Each argument becomes the same [str] the Linux half makes: a UTF-8 copy
# carrying a header {len, bytes...}, the array header {len, cap, data} left in
# %r15 and returned in %rax. UTF-16 is converted properly -- 1, 2 or 3 bytes,
# and surrogate PAIRS to 4 -- because the first non-ASCII path on a command
# line would otherwise be silently wrong, and a compiler that cannot open a
# file should say so rather than mis-spell the name. A lone surrogate becomes
# 3 bytes (WTF-8) rather than U+FFFD, so it round-trips.
#
# The argument count is bounded by the line itself: every argument needs at
# least one character and arguments are separated by at least one separator,
# so at most n/2+2 can exist for n wide characters. The data block is
# allocated at that bound and the header's len is the real count.
#
# NOTHING HERE CALLS y_cstr_to_str: that is the SysV char** walker, and it has
# no Windows replacement because this block does not need one. The named call
# is y_alloc, and on Windows that resolves to NtAllocateVirtualMemory.
y_argv_init:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    sub $88, %rsp
# Locals, all %rbp-relative (the frame pointer is stable across the calls
# below; %rsp is not):
#   -48 argc      -56 cap        -64 arg_start   -72 in_quotes
#   -80 nchars    -88 str        -96 cursor      -104 k (backslash run)
#   -112 emit     -120 quote action (0 none, 1 real, 2 literal)
    xor %eax, %eax
    mov %rax, -48(%rbp)
    mov %rax, -72(%rbp)
    mov %rax, -80(%rbp)
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov 112(%rax), %rcx
    mov 120(%rax), %rbx
    and $65535, %rcx
    shr $1, %rcx
    mov %rcx, %r13
    mov $0, %r12
# The data block: one word per possible argument.
    mov %r13, %rdi
    shr $1, %rdi
    add $2, %rdi
    mov %rdi, -56(%rbp)
    shl $3, %rdi
    call y_alloc
    mov %rax, %r14
    mov $24, %rdi
    call y_alloc
    mov %rax, %r15
    xor %ecx, %ecx
    mov %rcx, (%r15)
    mov -56(%rbp), %rcx
    mov %rcx, 8(%r15)
    mov %r14, 16(%r15)

# ── skip separators: the next argument, or the end ──────────────────────
yai_outer:
    cmp %r13, %r12
    jge yai_done
    call yai_char
    cmp $32, %rax
    je yai_sep
    cmp $9, %rax
    jne yai_arg
yai_sep:
    inc %r12
    jmp yai_outer

# ── pass 1: this argument's character span and its character count ──────
yai_arg:
    mov %r12, -64(%rbp)
    xor %eax, %eax
    mov %rax, -80(%rbp)
    mov %rax, -72(%rbp)
yai_a:
    cmp %r13, %r12
    jge yai_a_end
    call yai_char
    cmp $92, %rax
    je yai_a_run
    cmp $34, %rax
    je yai_a_quote
    cmp $32, %rax
    je yai_a_space
    cmp $9, %rax
    je yai_a_space
yai_a_take:
    mov -80(%rbp), %rcx
    inc %rcx
    mov %rcx, -80(%rbp)
    inc %r12
    jmp yai_a
yai_a_space:
    mov -72(%rbp), %rcx
    cmp $0, %rcx
    jne yai_a_take
    jmp yai_a_end
yai_a_quote:
    mov -72(%rbp), %rcx
    xor $1, %rcx
    mov %rcx, -72(%rbp)
    jmp yai_a_take
# A run of backslashes: count it, then classify the quote (if any) that ends
# it. Only a quote changes what the run means, so a run with nothing after it
# copies itself whole.
yai_a_run:
    xor %ecx, %ecx
yai_a_runl:
    cmp %r13, %r12
    jge yai_a_kdone
    call yai_char
    cmp $92, %rax
    jne yai_a_kdone
    inc %rcx
    inc %r12
    jmp yai_a_runl
yai_a_kdone:
    mov %rcx, -104(%rbp)
    mov %rcx, %rdx
    xor %ecx, %ecx
    mov %rcx, -120(%rbp)
    cmp %r13, %r12
    jge yai_a_radd
    call yai_char
    cmp $34, %rax
    jne yai_a_radd
    shr $1, %rdx
    mov -104(%rbp), %rcx
    and $1, %rcx
    cmp $1, %rcx
    je yai_a_rlit
    mov $1, %rcx
    mov %rcx, -120(%rbp)
    jmp yai_a_radd
yai_a_rlit:
    mov $2, %rcx
    mov %rcx, -120(%rbp)
    inc %rdx
yai_a_radd:
    mov -80(%rbp), %rcx
    add %rdx, %rcx
    mov %rcx, -80(%rbp)
# a real quote toggles and is consumed; a literal one is just counted
    mov -120(%rbp), %rcx
    cmp $1, %rcx
    je yai_a_rtog
    cmp $2, %rcx
    jne yai_a_end
    inc %r12
    jmp yai_a
yai_a_rtog:
    mov -72(%rbp), %rcx
    xor $1, %rcx
    mov %rcx, -72(%rbp)
    inc %r12
    jmp yai_a
yai_a_end:
# UTF-8 never exceeds 3 bytes per UTF-16 character (a surrogate pair is
# two characters and four bytes), so this over-allocates and never
# under-allocates. The str's own len is set from what was written.
    mov -80(%rbp), %rdi
    mov %rdi, %rax
    add %rax, %rdi
    add %rax, %rdi
    add $9, %rdi
    call y_alloc
    mov %rax, -88(%rbp)
    xor %ecx, %ecx
    mov %rcx, (%rax)
    mov %rcx, -96(%rbp)
    mov %rcx, -72(%rbp)
    mov -64(%rbp), %r12

# ── pass 2: build the argument, converting UTF-16 to UTF-8 ──────────────
yai_b:
    cmp %r13, %r12
    jge yai_b_end
    call yai_char
    cmp $92, %rax
    je yai_b_run
    cmp $34, %rax
    je yai_b_quote
    cmp $32, %rax
    je yai_b_space
    cmp $9, %rax
    je yai_b_space
# a data character: yai_emit advances %r12 by 1 or by 2 (a surrogate pair)
    call yai_emit
    jmp yai_b
yai_b_space:
    mov -72(%rbp), %rcx
    cmp $0, %rcx
    jne yai_b_data
    jmp yai_b_end
yai_b_data:
    call yai_emit
    jmp yai_b
yai_b_quote:
    mov -72(%rbp), %rcx
    xor $1, %rcx
    mov %rcx, -72(%rbp)
    inc %r12
    jmp yai_b
yai_b_run:
    xor %ecx, %ecx
yai_b_runl:
    cmp %r13, %r12
    jge yai_b_kdone
    call yai_char
    cmp $92, %rax
    jne yai_b_kdone
    inc %rcx
    inc %r12
    jmp yai_b_runl
yai_b_kdone:
    mov %rcx, -104(%rbp)
    mov %rcx, -112(%rbp)
    xor %ecx, %ecx
    mov %rcx, -120(%rbp)
    cmp %r13, %r12
    jge yai_b_emit
    call yai_char
    cmp $34, %rax
    jne yai_b_emit
    mov -104(%rbp), %rdx
    shr $1, %rdx
    mov %rdx, -112(%rbp)
    mov -104(%rbp), %rdx
    and $1, %rdx
    cmp $1, %rdx
    je yai_b_lit
    mov $1, %rcx
    mov %rcx, -120(%rbp)
    jmp yai_b_emit
yai_b_lit:
    mov $2, %rcx
    mov %rcx, -120(%rbp)
yai_b_emit:
    mov -112(%rbp), %rcx
yai_b_emitl:
    cmp $0, %rcx
    jle yai_b_act
    push %rcx
    mov $92, %rax
    call yai_put
    pop %rcx
    dec %rcx
    jmp yai_b_emitl
yai_b_act:
    mov -120(%rbp), %rcx
    cmp $1, %rcx
    je yai_b_actr
    cmp $2, %rcx
    jne yai_b
    mov $34, %rax
    call yai_put
    inc %r12
    jmp yai_b
yai_b_actr:
    mov -72(%rbp), %rcx
    xor $1, %rcx
    mov %rcx, -72(%rbp)
    inc %r12
    jmp yai_b
yai_b_end:
    mov -88(%rbp), %rcx
    mov -96(%rbp), %rdx
    mov %rdx, (%rcx)
    mov -48(%rbp), %rcx
    shl $3, %rcx
    add %r14, %rcx
    mov -88(%rbp), %rdx
    mov %rdx, (%rcx)
    mov -48(%rbp), %rcx
    inc %rcx
    mov %rcx, -48(%rbp)
    jmp yai_outer

yai_done:
    mov -48(%rbp), %rcx
    mov %rcx, (%r15)
    mov %r15, %rax
# r15 is NOT restored: y_argv reads it, exactly as on Linux, which is why
# the Linux block leaves it set too.
    mov -32(%rbp), %r14
    mov -24(%rbp), %r13
    mov -16(%rbp), %r12
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret

# yai_char: the UTF-16 character at %r12 of the line in %rbx, in %rax.
# Clobbers %rsi only. It is read one BYTE at a time on purpose: a 16-bit load
# is not a form the encoder has, and a 4- or 8-byte load at the LAST character
# would read past a buffer whose MaximumLength is exactly Length+2.
yai_char:
    lea (%rbx,%r12,2), %rsi
    movzbq (%rsi), %rax
    movzbq 1(%rsi), %rsi
    shl $8, %rsi
    add %rsi, %rax
    ret

# yai_put: append the byte in %al to the argument being built. Clobbers %rsi
# and %rcx. The cursor is -96(%rbp) and the str's header -88(%rbp).
yai_put:
    mov -88(%rbp), %rsi
    mov -96(%rbp), %rcx
    movb %al, 8(%rsi,%rcx,1)
    inc %rcx
    mov %rcx, -96(%rbp)
    ret

# yai_emit: convert the character in %rax to UTF-8 and append it, advancing
# %r12 by the UTF-16 units it consumed -- one, or two for a surrogate pair. A
# high surrogate followed by a low one becomes one 4-byte sequence; any other
# surrogate becomes 3 bytes so a lone one round-trips. The `add` where an `or`
# would read better is deliberate: the encoder has no `or $imm, %reg`, and
# every one of them sets bits the range guard above has already cleared.
# Clobbers %rax, %rcx, %rdx, %rsi, %r11.
yai_emit:
    cmp $128, %rax
    jl yai_emit1
    cmp $2048, %rax
    jl yai_emit2
    mov %rax, %rcx
    and $63488, %rcx
    cmp $55296, %rcx
    jne yai_emit3
    cmp $56320, %rax
    jge yai_emit3
# a high surrogate: pair it when a low one follows
    mov %r12, %rcx
    inc %rcx
    cmp %r13, %rcx
    jge yai_emit3
    mov %rax, %r11
    inc %r12
    push %rax
    call yai_char
    mov %rax, %rdx
    pop %rax
    dec %r12
    cmp $56320, %rdx
    jl yai_emit3
    cmp $57344, %rdx
    jge yai_emit3
# cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00): a 4-byte sequence
    sub $55296, %rax
    shl $10, %rax
    sub $56320, %rdx
    add %rdx, %rax
    add $65536, %rax
    mov %rax, %rcx
    shr $18, %rcx
    add $240, %rcx
    push %rax
    mov %rcx, %rax
    call yai_put
    pop %rax
    mov %rax, %rcx
    shr $12, %rcx
    and $63, %rcx
    add $128, %rcx
    push %rax
    mov %rcx, %rax
    call yai_put
    pop %rax
    mov %rax, %rcx
    shr $6, %rcx
    and $63, %rcx
    add $128, %rcx
    push %rax
    mov %rcx, %rax
    call yai_put
    pop %rax
    and $63, %rax
    add $128, %rax
    call yai_put
    add $2, %r12
    ret
yai_emit1:
    call yai_put
    inc %r12
    ret
yai_emit2:
    mov %rax, %rcx
    shr $6, %rcx
    add $192, %rcx
    push %rax
    mov %rcx, %rax
    call yai_put
    pop %rax
    and $63, %rax
    add $128, %rax
    call yai_put
    inc %r12
    ret
yai_emit3:
    mov %rax, %rcx
    shr $12, %rcx
    add $224, %rcx
    push %rax
    mov %rcx, %rax
    call yai_put
    pop %rax
    mov %rax, %rcx
    shr $6, %rcx
    and $63, %rcx
    add $128, %rcx
    push %rax
    mov %rcx, %rax
    call yai_put
    pop %rax
    and $63, %rax
    add $128, %rax
    call yai_put
    inc %r12
    ret
# y_os_openat(dirfd, path, plen, flags, mode) -> the handle, or -1.
#=== replace: y_os_openat ===
#
# The other half of the shared entry point (see ideas/WINDOWS.md). std is
# compiled once and the pack is target-free, so this label and its prelude
# counterpart are the SAME name for both kernels and the choice of which kernel
# call that is happens when the arch half is assembled -- never at run time and
# never in std. fs.y computes Linux O_* flags; the Windows half re-derives the
# NT equivalents here, because that translation IS the target-specific part.
#
#   O_RDONLY 0 -> FILE_GENERIC_READ          O_WRONLY 1 -> FILE_GENERIC_WRITE
#   O_RDWR   2 -> read|write                  O_APPEND  -> FILE_APPEND_DATA
#   O_CREAT  -> FILE_OPEN_IF   O_EXCL -> FILE_CREATE   O_TRUNC -> FILE_SUPERSEDE
#
# NtCreateFile takes ELEVEN arguments, four in registers and seven at 40(%rsp)
# upwards, which is why the frame below reserves 2176 bytes: 40(%rsp) lands at
# rbp-2136 and the path buffer stops at rbp-2096 so the two cannot meet. It is
# also why this is an arch label and not a `syscall` in Y -- the intrinsic's
# Windows ceiling is ten arguments (types.y maxargs), and eleven is what
# opening a file costs.
#
# Two limits, both deliberate and both loud rather than silent:
#   * the path must be an ABSOLUTE DOS path ("Z:\..." or "C:\..."). A relative
#     path needs the process's CurrentDirectory, which NT has no call for; it
#     answers -1 instead of handing Nt a name with no root (0xC000003A). The
#     PEB's RTL_USER_PROCESS_PARAMETERS.CurrentDirectory is the fix, and it is
#     the same answer chdir and getcwd need.
#   * the path must be ASCII (bytes < 128); '/' becomes '\'. A byte >= 128 is
#     -1 rather than a mangled name, because NT wants UTF-16 and guessing at a
#     multi-byte sequence would silently open the wrong file.
y_os_openat:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
# 2184, not 2176: five callee-saved pushes after `push %rbp` leave %rsp at 8
# (mod 16), and Windows x64 wants %rsp 16-byte aligned where the syscall
# instruction sits. 2184 is 8 (mod 16), which corrects it. It is also 8 bytes
# more than the arithmetic needs, and those 8 bytes sit below every NT argument
# slot (40(%rsp) lands at rbp-2184), clear of the path buffer at rbp-2096.
    sub $2184, %rsp
    mov 40(%rbp), %r12
    mov 32(%rbp), %r13
    mov 24(%rbp), %rbx
# an absolute DOS path is "X:" -- two bytes at least, a letter then a colon
    cmp $2, %r13
    jl yoa_bad
    movzbq (%r12), %rax
    add $32, %rax
    cmp $97, %rax
    jl yoa_bad
    cmp $123, %rax
    jg yoa_bad
    movzbq 1(%r12), %rax
    cmp $58, %rax
    jne yoa_bad
    cmp $900, %r13
    jg yoa_bad
# the Win32 namespace prefix, as four UTF-16 code units in one store:
# '\' '?' '?' '\' -> 0x5C3F3F5C little-endian
    lea -2096(%rbp), %r14
    mov $1547648860, %rax
    mov %rax, (%r14)
    add $8, %r14
# widen the path: one byte in, one UTF-16 unit out, '/' folded to '\'
    mov $0, %r15
yoa_loop:
    cmp %r13, %r15
    jge yoa_path_done
    mov %r12, %rax
    add %r15, %rax
    movzbq (%rax), %rax
    cmp $47, %rax
    jne yoa_nosep
    mov $92, %rax
yoa_nosep:
    cmp $128, %rax
    jge yoa_bad
    mov %rax, (%r14)
    add $8, %r14
    inc %r15
    jmp yoa_loop
yoa_path_done:
# UNICODE_STRING at rbp-32. Length and MaximumLength are 16-bit and equal, so one
# 64-bit store carries both: Length | (Length << 16). %r14 is already a BYTE
# cursor -- it advanced 8 per character -- so it is not shifted again; the only
# subtraction is the 8-byte prefix, which is part of the name but not part of
# its length. The Buffer points past that prefix, at rbp-2088.
    mov %r14, %rax
    sub %rbp, %rax
    add $2096, %rax
    sub $8, %rax
    mov %rax, %r15
    shl $16, %rax
    add %r15, %rax
    mov %rax, -32(%rbp)
    lea -2088(%rbp), %rax
    mov %rax, -24(%rbp)
# OBJECT_ATTRIBUTES at rbp-208 (48 bytes, rbp-208..rbp-169)
    mov $48, %rax
    mov %rax, -208(%rbp)
    mov $0, %rax
    mov %rax, -200(%rbp)
    lea -32(%rbp), %rax
    mov %rax, -192(%rbp)
    mov $0, %rax
    mov %rax, -184(%rbp)
    mov %rax, -176(%rbp)
    mov %rax, -168(%rbp)
# DesiredAccess from the access mode, unless this is an append. The masks are
# the generic ones with SYNCHRONIZE and READ_CONTROL taken out: asking for
# SYNCHRONIZE obliges the handle to be opened FILE_SYNCHRONOUS_IO_NONALERT, and
# then every read and write must carry its own byte offset, because the file has
# no shared position. y_os_read and y_os_write pass offset NULL, so the handle
# keeps the file pointer and the Linux side's lseek behaviour carries over.
    mov %rbx, %rax
    and $1024, %rax
    cmp $0, %rax
    jne yoa_acc_app
    mov %rbx, %rax
    and $3, %rax
    cmp $0, %rax
    je yoa_acc_rd
    cmp $1, %rax
    je yoa_acc_wr
    mov $415, %rax
    jmp yoa_acc_set
yoa_acc_rd:
    mov $137, %rax
    jmp yoa_acc_set
yoa_acc_wr:
    mov $278, %rax
    jmp yoa_acc_set
yoa_acc_app:
    mov $4, %rax
yoa_acc_set:
    mov %rax, -40(%rbp)
# ShareAccess: FILE_SHARE_READ|WRITE|DELETE, which is what a POSIX open wants
    mov $7, %rax
    mov %rax, -48(%rbp)
# CreateDisposition from O_APPEND, then O_TRUNC, then O_CREAT|O_EXCL, then O_CREAT
    mov %rbx, %rax
    and $1024, %rax
    cmp $0, %rax
    jne yoa_disp_openif
    mov %rbx, %rax
    and $512, %rax
    cmp $0, %rax
    jne yoa_disp_super
    mov %rbx, %rax
    and $192, %rax
    cmp $64, %rax
    je yoa_disp_openif
    cmp $192, %rax
    je yoa_disp_create
yoa_disp_open:
    mov $1, %rax
    jmp yoa_disp_set
yoa_disp_super:
    mov $0, %rax
    jmp yoa_disp_set
yoa_disp_create:
    mov $2, %rax
    jmp yoa_disp_set
yoa_disp_openif:
    mov $3, %rax
yoa_disp_set:
    mov %rax, -56(%rbp)
    mov $64, %rax
    mov %rax, -64(%rbp)
    mov $128, %rax
    mov %rax, -72(%rbp)
# NtCreateFile: rdi handle-out, rsi access, rdx ObjectAttributes,
# rcx IoStatusBlock, r8 AllocationSize(NULL), r9 FileAttributes,
# then ShareAccess, CreateDisposition, CreateOptions, EaBuffer, EaLength
    lea -272(%rbp), %rdi
    mov -40(%rbp), %rsi
    lea -208(%rbp), %rdx
    lea -16(%rbp), %rcx
    mov $0, %r8
    mov $128, %r9d
    mov -48(%rbp), %rax
    mov %rax, 40(%rsp)
    mov -56(%rbp), %rax
    mov %rax, 48(%rsp)
    mov -64(%rbp), %rax
    mov %rax, 56(%rsp)
    mov $0, %rax
    mov %rax, 64(%rsp)
    mov $0, %rax
    mov %rax, 72(%rsp)
    mov $85, %eax
    syscall
    test %eax, %eax
    js yoa_bad
    mov -272(%rbp), %rax
    jmp yoa_ret
yoa_bad:
    mov $-1, %rax
yoa_ret:
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_close(fd) -> 0, or -1. The other half of the shared close above.
#=== replace: y_os_close ===
# A POSIX close(2) returns 0 and leaves errno for the failure; NtClose answers
# an NTSTATUS. The contract fs.close_file asks for is `== 0`, so "not a success"
# is folded into -1 here -- handing back 0xC00000XX would look like a descriptor
# to every caller above. The fd goes through y_os_handle for the same reason
# y_os_read's does: 0, 1 and 2 are descriptors on one kernel and PEB handles on
# the other.
y_os_close:
    push %rbp
    mov %rsp, %rbp
    mov 8(%rbp), %rdi
    call y_os_handle
    mov %rax, %rdi
    mov $15, %eax
    syscall
    test %eax, %eax
    js yocl_fail
    mov $0, %eax
    jmp yocl_ret
yocl_fail:
    mov $-1, %eax
yocl_ret:
    mov %rbp, %rsp
    pop %rbp
    ret
