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
# fd >= 3 is already a real handle (fs.y's y_os_openat returns one): hand it
# back. This used to `ret` with %rax holding whatever the caller left there,
# so every read, write, lseek and close on a FILE went to a garbage handle --
# the open worked and nothing after it did.
    mov %rdi, %rax
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
# y_os_random(buf, len) -> a negative errno.
#
# NOT IMPLEMENTED YET. The PLUMBING is in and verified -- the import table, the
# .bss IAT cells the code calls through (deterministic offsets: the block is
# the first thing in .bss) and `call *%rax` -- and the call path is proven: a
# body that called y_iat_GetCurrentProcessId returned the process id under wine
# with no fault.
#
# WHAT THE BCrypt ATTEMPT ESTABLISHED, so the next one does not re-learn it:
#   * the three-call sequence is required. The documented pseudo-handle
#     (BCRYPT_USE_SYSTEM_PREFERRED_RNG = 2) page-faults inside wine's
#     bcrypt.dll, which dereferences it as a real handle.
#   * L"RNG" must be built on the stack, and with DECIMAL immediates: the
#     in-tree assembler's text parser takes no 0x literals (every 0x in these
#     files is inside a comment) and no 32-bit register-to-memory form
#     ("bad operand" for both).
#   * the status test must be `jne`, not `js`: success is 0 in both the
#     NTSTATUS and the Win32 convention, and a small positive error code is
#     not a sign-bit failure.
#   * and the frame offsets: args arrive at 16(%rsp)/8(%rsp), so after
#     `push %rbp; mov %rsp, %rbp` they are 24(%rbp) and 16(%rbp).
# The body below got as far as building and running, and then faulted inside
# bcrypt on a handle of -1: BCryptOpenAlgorithmProvider returned 0 (success)
# and the slot it was handed still held nothing, which says THE CALL THAT RAN
# WAS NOT THE FUNCTION THE LABEL NAMES -- i.e. the cells and the offsets
# disagree somewhere, and that is the first thing to prove or disprove next
# (dump the cell's contents, or the address `objdump -p` resolves).
#=== replace: y_os_random ===
y_os_random:
    mov $-38, %rax
    ret
#=== add: y_w_path ===
y_w_path:
    push %rbp
    mov %rsp, %rbp
    sub $64, %rsp
    mov %rsi, -16(%rbp)
    mov %rcx, -24(%rbp)
    movb $92, (%rdi)
    movb $0, 1(%rdi)
    movb $63, 2(%rdi)
    movb $0, 3(%rdi)
    movb $63, 4(%rdi)
    movb $0, 5(%rdi)
    movb $92, 6(%rdi)
    movb $0, 7(%rdi)
    add $8, %rdi
    mov $4, %r8
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov 64(%rax), %rsi
    mov 56(%rax), %r11
    and $65535, %r11
    shr $1, %r11
ywp_cwd:
    cmp $0, %r11
    je ywp_sep
    movzbq (%rsi), %rax
    movb %al, (%rdi)
    movzbq 1(%rsi), %rax
    movb %al, 1(%rdi)
    add $2, %rsi
    add $2, %rdi
    add $1, %r8
    sub $1, %r11
    jmp ywp_cwd
ywp_sep:
    movzbq -2(%rdi), %rax
    cmp $92, %rax
    je ywp_rel
    movb $92, (%rdi)
    movb $0, 1(%rdi)
    add $2, %rdi
    add $1, %r8
ywp_rel:
    mov -16(%rbp), %rsi
    mov -24(%rbp), %rcx
    cmp $0, %rcx
    je ywp_e_empty
    xor %r9d, %r9d
ywp_loop:
    cmp %rcx, %r9
    jge ywp_done
    movzbq (%rsi,%r9,1), %rax
    cmp $47, %rax
    je ywp_adv
    cmp $92, %rax
    je ywp_adv
    jmp ywp_comp
ywp_adv:
    add $1, %r9
    jmp ywp_loop
ywp_comp:
    mov %r9, %r10
ywp_scan:
    cmp %rcx, %r9
    jge ywp_have
    movzbq (%rsi,%r9,1), %rax
    cmp $47, %rax
    je ywp_have
    cmp $92, %rax
    je ywp_have
    add $1, %r9
    jmp ywp_scan
ywp_have:
    mov %r9, %rdx
    sub %r10, %rdx
    cmp $1, %rdx
    jne ywp_two
    movzbq (%rsi,%r10,1), %rax
    cmp $46, %rax
    je ywp_loop
ywp_two:
    cmp $2, %rdx
    jne ywp_pre
    movzbq (%rsi,%r10,1), %rax
    cmp $46, %rax
    jne ywp_pre
    mov %r10, %rax
    add $1, %rax
    movzbq (%rsi,%rax,1), %rax
    cmp $46, %rax
    je ywp_pop
ywp_pre:
    movzbq -2(%rdi), %rax
    cmp $92, %rax
    je ywp_copy
    movb $92, (%rdi)
    movb $0, 1(%rdi)
    add $2, %rdi
    add $1, %r8
    cmp $1000, %r8
    jg ywp_e_long
ywp_copy:
    xor %r11, %r11
ywp_copyc:
    cmp %rdx, %r11
    jge ywp_loop
    mov %r10, %rax
    add %r11, %rax
    movzbq (%rsi,%rax,1), %rax
    cmp $128, %rax
    jge ywp_e_hi
    cmp $47, %rax
    jne ywp_copyk
    mov $92, %rax
ywp_copyk:
    movb %al, (%rdi)
    movb $0, 1(%rdi)
    add $2, %rdi
    add $1, %r8
    cmp $1000, %r8
    jg ywp_e_long
    add $1, %r11
    jmp ywp_copyc
ywp_pop:
    cmp $7, %r8
    jle ywp_loop
    sub $2, %rdi
    sub $1, %r8
ywp_popscan:
    cmp $7, %r8
    jle ywp_loop
    movzbq -2(%rdi), %rax
    cmp $92, %rax
    je ywp_loop
    sub $2, %rdi
    sub $1, %r8
    jmp ywp_popscan
ywp_done:
    movb $0, (%rdi)
    movb $0, 1(%rdi)
    mov %r8, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
ywp_e_empty:
    mov $-2, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
ywp_e_hi:
    mov $-3, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
ywp_e_long:
    mov $-4, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_stat(dirfd, path, len, stbuf, flags) -> 0, or -1. The caller's buffer is
# Linux-shaped and fs.y reads exactly two fields: st_mode at byte 24 and
# st_size at byte 48. Both are written; the rest is left as the caller zeroed
# it.
#
# FIVE ARGUMENTS, FRAMELESS in the ELF body, so arg5 (flags) is at 8(%rsp),
# arg4 (stbuf) at 16, arg3 (len) at 24, arg2 (path) at 32 and arg1 (dirfd) at
# 40 -- which after `push %rbp; mov %rsp, %rbp` become 16, 24, 32, 40 and 48.
# dirfd and flags are ignored: NT resolves an absolute name without either.
#
# The path itself comes from y_w_path, which is where the `\??\` prefix, the
# PEB's current directory and the separator translation live.
#
# NtQueryFullAttributesFile (196), NOT NtQueryAttributesFile: only the "full"
# form returns FILE_NETWORK_OPEN_INFORMATION, which carries EndOfFile -- the
# size. The attributes-only form has no size in it, so file_size would have to
# lie. The number is in w_sysno in both copies, and wselftest.s calls it at
# startup, because 62 is what the public Windows 10 table suggests and 62
# answers STATUS_INVALID_HANDLE.
#
# Frame layout, rbp-relative, inside `sub $2304`: the UTF-16 path at -2304
# (y_w_path writes upward from there and refuses past 1000 units), the
# UNICODE_STRING at -304, the OBJECT_ATTRIBUTES at -288 (48 bytes, Length must
# say 48), FILE_NETWORK_OPEN_INFORMATION at -240 (56 bytes: four times, then
# AllocationSize at +32, EndOfFile at +40, FileAttributes at +48).
#=== replace: y_os_stat ===
y_os_stat:
    push %rbp
    mov %rsp, %rbp
    sub $2304, %rsp
    lea -2304(%rbp), %rdi
    mov 40(%rbp), %rsi
    mov 32(%rbp), %rcx
    call y_w_path
    cmp $0, %rax
    jl yostat_fail
    mov %rax, %r8
    add %r8, %r8
    mov %r8, %rax
    movb %al, -304(%rbp)
    shr $8, %rax
    movb %al, -303(%rbp)
    add $2, %r8
    mov %r8, %rax
    movb %al, -302(%rbp)
    shr $8, %rax
    movb %al, -301(%rbp)
    lea -2304(%rbp), %rax
    mov %rax, -296(%rbp)
    mov $48, %rax
    mov %rax, -288(%rbp)
    mov $0, %rax
    mov %rax, -280(%rbp)
    lea -304(%rbp), %rax
    mov %rax, -272(%rbp)
    mov $64, %rax
    mov %rax, -264(%rbp)
    mov $0, %rax
    mov %rax, -256(%rbp)
    mov $0, %rax
    mov %rax, -248(%rbp)
    lea -288(%rbp), %r10
    lea -240(%rbp), %rdx
    mov $196, %eax
    syscall
    test %eax, %eax
    jne yostat_fail
    mov 24(%rbp), %r9
    movzbq -192(%rbp), %rax
    and $16, %rax
    cmp $0, %rax
    je yostat_reg
    mov $16877, %rax
    mov %rax, 24(%r9)
    jmp yostat_size
yostat_reg:
    mov $33188, %rax
    mov %rax, 24(%r9)
yostat_size:
    mov -200(%rbp), %rax
    mov %rax, 48(%r9)
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
yostat_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_openat(dirfd, path, len, flags, mode) -> a handle, or -1.
#
# The handle is what fs.y passes back as an "fd"; y_os_handle hands anything >=
# 3 straight through, which is what makes its comment about "fs.y's y_os_openat
# returns an NtCreateFile handle" true.
#
# FIVE ARGUMENTS, FRAMELESS in the ELF body: mode (arg5) at 8(%rsp) -> 16(%rbp),
# FLAGS (arg4) at 16 -> 24, len at 24 -> 32, path at 32 -> 40, dirfd at 40 -> 48.
# dirfd is ignored (y_w_path builds an absolute name) and so is mode: NT has no
# mode bits, an ACL is a different mechanism, and fs.y's 0o644 default is not
# expressible here.
#
# TWO ATTEMPTS, because of what wine's NtCreateFile actually does. The
# documented create dispositions are FILE_OPEN_IF (3) and FILE_OVERWRITE_IF (5),
# and wine answers STATUS_OBJECT_NAME_NOT_FOUND (0xC0000034) for BOTH when the
# file does not exist -- measured, with FILE_CREATE (2) on the identical call
# succeeding. So the first attempt is the disposition that fits the flags if the
# file is already there (FILE_OVERWRITE (4) for O_TRUNC, else FILE_OPEN (1)),
# and only a NAME_NOT_FOUND with O_CREAT set triggers the second, FILE_CREATE
# (2). The third shape -- FILE_CREATE losing a race and answering
# STATUS_OBJECT_NAME_COLLISION (0xC0000035) -- retries the first disposition,
# which by then is the right one. Writing it this way keeps the common case
# (opening a file that exists) on exactly the code path it had when it worked.
#
# The two NTSTATUS values are written as NEGATIVE immediates (-1073741772 is
# 0xC0000034): the in-tree assembler's number reader rejects anything that does
# not fit in 32 SIGNED bits, so the way a 0xC00000xx constant is spelled here is
# its two's-complement negative.
#
# THE OPTIONS CARRY FILE_SYNCHRONOUS_IO_NONALERT (32). Without it the handle is
# asynchronous, NtWriteFile answers STATUS_PENDING instead of writing, and a
# program that creates a file and writes to it gets a zero-byte file with the
# create having succeeded and no error anywhere obvious. FILE_DIRECTORY_FILE (1)
# is added for O_DIRECTORY.
#
# NtCreateFile (85) takes five arguments in registers and SIX on the stack at
# 40(%rsp) and up, which with this frame is rbp-2960 -- so the frame is big
# enough that the path buffer's growth (1000 units from -2200, i.e. to -200)
# cannot reach the objects: they are BELOW the buffer's start, at -2300 and
# down, where an upward-growing write never goes. (The first cut put them above
# its start, inside the range it grows into.)
#
# The access mask is copied OUT of %r9 into %rdx BEFORE %r9 is reloaded with
# &iosb: they are arg2 and arg4, and the other order passes the IO_STATUS_BLOCK
# address as the access mask. It is also saved in the frame, because the retry
# sets EVERY argument again rather than only the disposition: a second syscall
# cannot assume the stack area below rsp survived the first, and the second
# attempt answering STATUS_INVALID_PARAMETER while the first answered
# NAME_NOT_FOUND is exactly what a clobbered 48(%rsp) -- FileAttributes -- looks
# like.
#
# Every comment in this block is ABOVE this marker on purpose: a `#` line inside
# a replaced region reaches the in-tree assembler, which has no comment syntax
# and reports `unexpected comment (backend bug)`.
#=== replace: y_os_openat ===
y_os_openat:
    push %rbp
    mov %rsp, %rbp
    sub $3000, %rsp
    lea -2200(%rbp), %rdi
    mov 40(%rbp), %rsi
    mov 32(%rbp), %rcx
    call y_w_path
    cmp $0, %rax
    jl yoap_fail
    mov %rax, %r8
    add %r8, %r8
    mov %r8, %rax
    movb %al, -2320(%rbp)
    shr $8, %rax
    movb %al, -2319(%rbp)
    add $2, %r8
    mov %r8, %rax
    movb %al, -2318(%rbp)
    shr $8, %rax
    movb %al, -2317(%rbp)
    lea -2200(%rbp), %rax
    mov %rax, -2312(%rbp)
    mov $48, %rax
    mov %rax, -2380(%rbp)
    mov $0, %rax
    mov %rax, -2372(%rbp)
    lea -2320(%rbp), %rax
    mov %rax, -2364(%rbp)
    mov $64, %rax
    mov %rax, -2356(%rbp)
    mov $0, %rax
    mov %rax, -2348(%rbp)
    mov $0, %rax
    mov %rax, -2340(%rbp)
    mov 24(%rbp), %r11
    mov $1048704, %r9
    mov %r11, %rax
    and $3, %rax
    cmp $1, %rax
    je yoap_wonly
    cmp $2, %rax
    je yoap_rdwr
    or $1, %r9
    jmp yoap_acc_done
yoap_rdwr:
    or $1, %r9
yoap_wonly:
    mov %r11, %rax
    and $1024, %rax
    cmp $0, %rax
    je yoap_wwrite
    or $4, %r9
    jmp yoap_acc_done
yoap_wwrite:
    or $2, %r9
yoap_acc_done:
    mov %r9, %rdx
    mov %r9, -2208(%rbp)
    mov $1, %r11
    mov 24(%rbp), %rax
    and $512, %rax
    cmp $0, %rax
    je yoap_disp1
    mov $4, %r11
yoap_disp1:
    mov $0, 40(%rsp)
    mov $128, 48(%rsp)
    mov $7, 56(%rsp)
    mov %r11, 64(%rsp)
    mov $32, %rax
    mov 24(%rbp), %r11
    and $65536, %r11
    cmp $0, %r11
    je yoap_opt1
    or $1, %rax
yoap_opt1:
    mov %rax, 72(%rsp)
    mov $0, 80(%rsp)
    mov $0, 88(%rsp)
    lea -2300(%rbp), %r10
    lea -2380(%rbp), %r8
    lea -2400(%rbp), %r9
    mov $85, %eax
    syscall
    test %eax, %eax
    je yoap_ok
    cmp $-1073741772, %eax
    jne yoap_collide
    mov 24(%rbp), %r11
    and $64, %r11
    cmp $0, %r11
    je yoap_fail
    mov $2, %r11
    jmp yoap_again
yoap_collide:
    cmp $-1073741771, %eax
    jne yoap_fail
    mov 24(%rbp), %r11
    and $64, %r11
    cmp $0, %r11
    je yoap_fail
    mov $1, %r11
    mov 24(%rbp), %rax
    and $512, %rax
    cmp $0, %rax
    je yoap_again
    mov $4, %r11
    jmp yoap_again
yoap_again:
    mov %r11, 64(%rsp)
    mov $0, 40(%rsp)
    mov $128, 48(%rsp)
    mov $7, 56(%rsp)
    mov -2208(%rbp), %rdx
    mov $32, %rax
    mov 24(%rbp), %r11
    and $65536, %r11
    cmp $0, %r11
    je yoap_opt2
    or $1, %rax
yoap_opt2:
    mov %rax, 72(%rsp)
    mov $0, 80(%rsp)
    mov $0, 88(%rsp)
    lea -2300(%rbp), %r10
    lea -2380(%rbp), %r8
    lea -2400(%rbp), %r9
    mov $85, %eax
    syscall
    test %eax, %eax
    jne yoap_fail
yoap_ok:
    mov -2300(%rbp), %rax
    test %rax, %rax
    je yoap_fail
    mov %rbp, %rsp
    pop %rbp
    ret
yoap_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_close(fd) -> 0, or -1. One argument and frameless, so the fd is at
# 8(%rsp). NtClose (15) takes the handle in %r10 like every other Nt call here.
#
# It matters more than it looks: fs.y's write_file is open, write, CLOSE, and
# without this body the close falls through to the ELF one -- a raw Linux
# syscall 3, which on NT is an unimplemented ntdll function. The file is written
# correctly and the process then dies in wine's abort handler, which reads as
# "the write failed" when it did not.
#
# The fd is passed through as it stands: fs.y only closes what y_os_openat
# returned, and that is already a handle. (y_os_handle would agree -- it passes
# anything >= 3 through untouched -- but depending on that here would be a
# second thing to keep true.)
#=== replace: y_os_close ===
y_os_close:
    mov 8(%rsp), %r10
    mov $15, %eax
    syscall
    test %eax, %eax
    jne yocl_fail
    xor %eax, %eax
    ret
yocl_fail:
    mov $-1, %rax
    ret
# y_os_mkdir(path, len, mode) -> 0, or -1.
#
# THREE ARGUMENTS, FRAMELESS in the ELF body: mode (arg3) at 8(%rsp) -> 16(%rbp),
# len (arg2) at 16 -> 24, path (arg1) at 24 -> 32. The ELF body ignores len (the
# path is NUL-terminated there) and this one ignores mode, which NT cannot
# express.
#
# NtCreateFile with FILE_CREATE (2) and FILE_DIRECTORY_FILE (1): an existing
# directory must FAIL, because that is what mkdir(2) does and what fs.make_dir
# reports, and FILE_CREATE is the one disposition wine honours as a create (see
# y_os_openat for the measurement). The handle it returns is closed at once --
# the directory exists as soon as the call returns.
#
# FILE_SYNCHRONOUS_IO_NONALERT (32) is here for the same reason as in openat:
# an asynchronous handle is not what the rest of the layer expects.
#
# Layout as in y_os_openat: the path at -2200 (y_w_path writes upward from
# there), the UNICODE_STRING at -2320, the handle at -2300, the
# OBJECT_ATTRIBUTES at -2380 and the IO_STATUS_BLOCK at -2400 -- all below the
# buffer's start, where its growth cannot reach.
#=== replace: y_os_mkdir ===
y_os_mkdir:
    push %rbp
    mov %rsp, %rbp
    sub $3000, %rsp
    lea -2200(%rbp), %rdi
    mov 32(%rbp), %rsi
    mov 24(%rbp), %rcx
    call y_w_path
    cmp $0, %rax
    jl yomk_fail
    mov %rax, %r8
    add %r8, %r8
    mov %r8, %rax
    movb %al, -2320(%rbp)
    shr $8, %rax
    movb %al, -2319(%rbp)
    add $2, %r8
    mov %r8, %rax
    movb %al, -2318(%rbp)
    shr $8, %rax
    movb %al, -2317(%rbp)
    lea -2200(%rbp), %rax
    mov %rax, -2312(%rbp)
    mov $48, %rax
    mov %rax, -2380(%rbp)
    mov $0, %rax
    mov %rax, -2372(%rbp)
    lea -2320(%rbp), %rax
    mov %rax, -2364(%rbp)
    mov $64, %rax
    mov %rax, -2356(%rbp)
    mov $0, %rax
    mov %rax, -2348(%rbp)
    mov $0, %rax
    mov %rax, -2340(%rbp)
    mov $1048705, %rdx
    mov $0, 40(%rsp)
    mov $128, 48(%rsp)
    mov $7, 56(%rsp)
    mov $2, 64(%rsp)
    mov $33, 72(%rsp)
    mov $0, 80(%rsp)
    mov $0, 88(%rsp)
    lea -2300(%rbp), %r10
    lea -2380(%rbp), %r8
    lea -2400(%rbp), %r9
    mov $85, %eax
    syscall
    test %eax, %eax
    jne yomk_fail
    mov -2300(%rbp), %r10
    mov $15, %eax
    syscall
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
yomk_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_unlink(path, len, isdir) -> 0, or -1.
#
# Arg3 is a BOOLEAN here (fs.remove_dir passes 1), and it decides the open's
# CreateOptions: FILE_DIRECTORY_FILE (1) or FILE_NON_DIRECTORY_FILE (64). Same
# frameless offsets as y_os_mkdir: isdir at 16(%rbp), len at 24, path at 32.
#
# Deleting is two calls, not one: NtSetInformationFile (39) with
# FileDispositionInformation (13), whose information is a SINGLE BYTE -- BOOLEAN
# DeleteFile -- after opening the file with DELETE access (65536). Opening with
# FILE_OPEN (1) and no create disposition is deliberate: unlinking something
# that is not there must fail.
#
# FILE_SYNCHRONOUS_IO_NONALERT (32) is set for FILES here (96 = 32|64) as well as
# directories (33 = 32|1): with an asynchronous handle NtSetInformationFile
# answers STATUS_PENDING, the delete happens anyway, and a status check that
# treats non-zero as failure reports "could not delete" for a file that is gone.
# That is the second bug this block had, and the same fixture caught it.
#
# THE STATUS GOES IN A FRAME SLOT, NOT A REGISTER: `syscall` clobbers %rcx AND
# %r11 architecturally, so saving the status in %r11 and restoring it after the
# close hands the caller whatever the close left there -- which read as "-1, but
# the file is gone". -2216 is below the path buffer's start, out of its way.
#
# STATUS_PENDING (259, 0x103) IS SUCCESS for this one call, and it is the only
# place in this file that is true: FileDispositionInformation is documented to
# answer it, the delete does happen, and a status check that reads "non-zero
# means failure" reports "could not delete" for a file that is gone. That was
# the third bug this block had, and the same fixture caught it -- only line 19,
# remove_file, differing while line 20, exists, said false.
#
# A directory has to be empty, which is also what rmdir(2) requires -- and the
# set-information STATUS IS THE RESULT. The first version of this block threw it
# away and returned success unconditionally, which deleted a NON-EMPTY directory
# and reported true where rmdir(2) fails; pe-gate.sh's round-trip fixture caught
# it, because its expected output is the Linux one and `false` came back as
# `true`. The status is saved, the handle is closed, and the status is what the
# caller sees.
#
# The open reuses openat's frame shape; the disposition byte is at -2208, which
# is below the path buffer's start.
#=== replace: y_os_unlink ===
y_os_unlink:
    push %rbp
    mov %rsp, %rbp
    sub $3000, %rsp
    lea -2200(%rbp), %rdi
    mov 32(%rbp), %rsi
    mov 24(%rbp), %rcx
    call y_w_path
    cmp $0, %rax
    jl youn_fail
    mov %rax, %r8
    add %r8, %r8
    mov %r8, %rax
    movb %al, -2320(%rbp)
    shr $8, %rax
    movb %al, -2319(%rbp)
    add $2, %r8
    mov %r8, %rax
    movb %al, -2318(%rbp)
    shr $8, %rax
    movb %al, -2317(%rbp)
    lea -2200(%rbp), %rax
    mov %rax, -2312(%rbp)
    mov $48, %rax
    mov %rax, -2380(%rbp)
    mov $0, %rax
    mov %rax, -2372(%rbp)
    lea -2320(%rbp), %rax
    mov %rax, -2364(%rbp)
    mov $64, %rax
    mov %rax, -2356(%rbp)
    mov $0, %rax
    mov %rax, -2348(%rbp)
    mov $0, %rax
    mov %rax, -2340(%rbp)
    mov $1114112, %rdx
    mov $0, 40(%rsp)
    mov $128, 48(%rsp)
    mov $7, 56(%rsp)
    mov $1, 64(%rsp)
    mov $96, 72(%rsp)
    mov 16(%rbp), %rax
    cmp $0, %rax
    je youn_opts
    mov $33, 72(%rsp)
youn_opts:
    mov $0, 80(%rsp)
    mov $0, 88(%rsp)
    lea -2300(%rbp), %r10
    lea -2380(%rbp), %r8
    lea -2400(%rbp), %r9
    mov $85, %eax
    syscall
    test %eax, %eax
    jne youn_fail
    movb $1, -2208(%rbp)
    mov -2300(%rbp), %r10
    lea -2400(%rbp), %rdx
    lea -2208(%rbp), %r8
    mov $1, %r9
    mov $13, 40(%rsp)
    mov $39, %eax
    syscall
    mov %rax, -2216(%rbp)
    mov -2300(%rbp), %r10
    mov $15, %eax
    syscall
    mov -2216(%rbp), %rax
    test %eax, %eax
    je youn_ok
    cmp $259, %eax
    jne youn_fail
youn_ok:
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
youn_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_set_mode(path, len, mode) -> 0. NT has no mode bits: permissions are an
# ACL, a completely different mechanism from the POSIX mode word, so there is
# nothing here to set and the honest answer is success. It is written down
# rather than left to the ELF body -- which is fchmodat with a Linux syscall
# number -- because a caller that gets 0 back is being told "done", and a caller
# that gets a Linux errno out of a Windows syscall is not being told anything.
# chmod on NT is unimplemented, not failing.
#=== replace: y_os_set_mode ===
y_os_set_mode:
    xor %eax, %eax
    ret
# y_os_lseek(fd, off, whence) -> the new offset, or -1.
#
# Windows has no lseek. There is a file POSITION, which NtQueryInformationFile
# (17) reads and NtSetInformationFile (39) writes, both as an 8-byte
# LARGE_INTEGER under FilePositionInformation (class 14) -- and there is a file
# SIZE, which FileStandardInformation (class 5) carries at offset 8 of its 24
# bytes. So the three whences are:
#   0 SEEK_SET  the offset itself
#   1 SEEK_CUR  the queried position + off
#   2 SEEK_END  the queried size + off
# and then one set-information call, whose information is just the 8-byte
# target position. The answer is that position, read back out of the frame
# rather than out of a register: the set call clobbers %rcx and %r11, and the
# value has to survive it.
#
# THREE ARGUMENTS, FRAMELESS in the ELF body: whence (arg3) at 8(%rsp) ->
# 16(%rbp), off (arg2) at 16 -> 24, fd (arg1) at 24 -> 32. The fd is a handle
# (fs.y only seeks what y_os_openat returned) and goes through as it stands.
#
# `add` takes no memory operand in this assembler, so the offset is loaded into a
# register first -- "arith reg form in 'add'" is what the direct form reports.
#
# An offset that lands before the start of the file is refused by the kernel,
# which is also what lseek(2) does with a negative result.
#
# Frame: the IO_STATUS_BLOCK at -32 (16 bytes), the position at -8, and the
# 24-byte file standard information at -64. 80 keeps rsp 0 mod 16.
#=== replace: y_os_lseek ===
y_os_lseek:
    push %rbp
    mov %rsp, %rbp
    sub $80, %rsp
    mov 32(%rbp), %r10
    mov 16(%rbp), %rax
    cmp $0, %rax
    jne yols_cur
    mov 24(%rbp), %rax
    mov %rax, -8(%rbp)
    jmp yols_set
yols_cur:
    cmp $1, %rax
    jne yols_end
    lea -32(%rbp), %rdx
    lea -8(%rbp), %r8
    mov $8, %r9
    mov $14, 40(%rsp)
    mov $17, %eax
    syscall
    test %eax, %eax
    jne yols_fail
    mov -8(%rbp), %rax
    mov 24(%rbp), %r11
    add %r11, %rax
    mov %rax, -8(%rbp)
    jmp yols_set
yols_end:
    lea -32(%rbp), %rdx
    lea -64(%rbp), %r8
    mov $24, %r9
    mov $5, 40(%rsp)
    mov $17, %eax
    syscall
    test %eax, %eax
    jne yols_fail
    mov -56(%rbp), %rax
    mov 24(%rbp), %r11
    add %r11, %rax
    mov %rax, -8(%rbp)
yols_set:
    mov 32(%rbp), %r10
    lea -32(%rbp), %rdx
    lea -8(%rbp), %r8
    mov $8, %r9
    mov $14, 40(%rsp)
    mov $39, %eax
    syscall
    test %eax, %eax
    jne yols_fail
    mov -8(%rbp), %rax
    mov %rbp, %rsp
    pop %rbp
    ret
yols_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_rename(from, len, to, len2) -> 0, or -1.
#
# FOUR ARGUMENTS, FRAMELESS in the ELF body: len2 (arg4) at 8(%rsp) -> 16(%rbp),
# to (arg3) at 16 -> 24, len (arg2) at 24 -> 32, from (arg1) at 32 -> 40.
#
# Renaming is not a path-to-path call. It is open the SOURCE with DELETE access
# (65536) and then NtSetInformationFile (39) with FileRenameInformation
# (class 10), whose information is a FILE_RENAME_INFORMATION:
#
#   +0   BOOLEAN ReplaceIfExists   -- 1, which is what rename(2) does
#   +8   HANDLE  RootDirectory     -- 0, because the name is absolute
#   +16  ULONG   FileNameLength    -- BYTES, and only the name
#   +20  WCHAR   FileName[]        -- the full absolute TARGET path
#
# FileName is INLINE, so the target is built straight into the struct: y_w_path
# is pointed at struct+20 and writes upward from there. FileNameLength is
# written a BYTE at a time, because an 8-byte store at +16 would run into the
# name that starts at +20. The information length is 20 + 2*units.
#
# TWO UNIT COUNTS LIVE IN FRAME SLOTS, not registers. The second y_w_path call
# clobbers %r8, so the source's count has to be saved before it; and the target's
# count is needed after the open, which is another chance to lose it. The first
# version kept the source's in %r8 and built the UNICODE_STRING with the
# TARGET's length, so the open was handed the wrong name entirely.
#
# AND THE FRAME MUST BE DEEPER THAN THE STACK ARGUMENTS ARE FAR DOWN. NtCreateFile
# puts six arguments at 40(%rsp) and up: with a 4800-byte frame that is
# rbp-4760, which was this block's IO_STATUS_BLOCK, so the call overwrote the
# block it was about to be handed and answered STATUS_INVALID_PARAMETER
# (0xC000000D) -- which reads exactly like a bad path. 5200 puts the argument
# area at rbp-5160, clear of every object here.
#
# Layout: the SOURCE path at -2200 (y_w_path writes upward to -200 at most), the
# rename struct at -4600 with its name from -4580 (upward to -2580, so the two
# paths cannot meet), the handle at -4640, the UNICODE_STRING at -4680, the
# OBJECT_ATTRIBUTES at -4740, the IO_STATUS_BLOCK at -4760, and three scratch
# words at -4776, -4784 and -4792.
#=== replace: y_os_rename ===
y_os_rename:
    push %rbp
    mov %rsp, %rbp
    sub $5200, %rsp
    lea -2200(%rbp), %rdi
    mov 40(%rbp), %rsi
    mov 32(%rbp), %rcx
    call y_w_path
    cmp $0, %rax
    jl yorn_fail
    mov %rax, -4792(%rbp)
    lea -4580(%rbp), %rdi
    mov 24(%rbp), %rsi
    mov 16(%rbp), %rcx
    call y_w_path
    cmp $0, %rax
    jl yorn_fail
    mov %rax, -4784(%rbp)
    movb $1, -4600(%rbp)
    mov $0, %rax
    mov %rax, -4592(%rbp)
    add %rax, %rax
    mov -4784(%rbp), %rax
    add %rax, %rax
    movb %al, -4584(%rbp)
    shr $8, %rax
    movb %al, -4583(%rbp)
    shr $8, %rax
    movb %al, -4582(%rbp)
    shr $8, %rax
    movb %al, -4581(%rbp)
    mov -4792(%rbp), %r8
    mov %r8, %rax
    add %rax, %rax
    movb %al, -4680(%rbp)
    shr $8, %rax
    movb %al, -4679(%rbp)
    add $2, %r8
    mov %r8, %rax
    movb %al, -4678(%rbp)
    shr $8, %rax
    movb %al, -4677(%rbp)
    lea -2200(%rbp), %rax
    mov %rax, -4672(%rbp)
    mov $48, %rax
    mov %rax, -4740(%rbp)
    mov $0, %rax
    mov %rax, -4732(%rbp)
    lea -4680(%rbp), %rax
    mov %rax, -4724(%rbp)
    mov $64, %rax
    mov %rax, -4716(%rbp)
    mov $0, %rax
    mov %rax, -4708(%rbp)
    mov $0, %rax
    mov %rax, -4700(%rbp)
    mov $1114112, %rdx
    mov $0, 40(%rsp)
    mov $128, 48(%rsp)
    mov $7, 56(%rsp)
    mov $1, 64(%rsp)
    mov $32, 72(%rsp)
    mov $0, 80(%rsp)
    mov $0, 88(%rsp)
    lea -4640(%rbp), %r10
    lea -4740(%rbp), %r8
    lea -4760(%rbp), %r9
    mov $85, %eax
    syscall
    test %eax, %eax
    jne yorn_openfail
    mov -4640(%rbp), %r10
    lea -4760(%rbp), %rdx
    lea -4600(%rbp), %r8
    mov -4784(%rbp), %r9
    add %r9, %r9
    add $20, %r9
    mov $10, 40(%rsp)
    mov $39, %eax
    syscall
    mov %rax, -4776(%rbp)
    mov -4640(%rbp), %r10
    mov $15, %eax
    syscall
    mov -4776(%rbp), %rax
    test %eax, %eax
    je yorn_ok
    cmp $259, %eax
    jne yorn_setfail
yorn_ok:
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
yorn_openfail:
    mov %rax, -4776(%rbp)
    mov -4640(%rbp), %r10
    mov $15, %eax
    syscall
    mov -4776(%rbp), %rax
    shl $32, %rax
    shr $32, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
yorn_setfail:
    shl $32, %rax
    shr $32, %rax
    mov %r11, %r11
    mov %rbp, %rsp
    pop %rbp
    ret
yorn_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_getcwd(buf, len) -> the number of bytes written INCLUDING the NUL, or -1.
# fs.cwd does `from_bytes(buf[0:n-1])`, so the count has to include the
# terminator.
#
# TWO ARGUMENTS, FRAMELESS in the ELF body: len (arg2) at 8(%rsp) -> 16(%rbp),
# buf (arg1) at 16 -> 24.
#
# There is no getcwd(2) equivalent to call: the current directory is a field of
# the PEB. ProcessParameters at PEB+32, CURDIR.DosPath at ProcessParameters+56,
# a UNICODE_STRING whose Length is in BYTES at +56 and whose Buffer is at +64 --
# the same read y_w_path does to build absolute paths. What comes back looks
# like `Z:\tmp\ts\w42\`, so this narrows UTF-16 to bytes (ASCII only, as
# everywhere in this file), turns the separator around to `/` so that the string
# fs.cwd returns is the shape the rest of fs.y expects -- y_w_path turns it back
# -- and drops the TRAILING separator, which is what getcwd(2) returns. A path
# that is nothing but a root keeps it.
#
# The caller's buffer is not trusted to be big enough: a path that does not fit
# is -1, not a truncation.
#=== replace: y_os_getcwd ===
y_os_getcwd:
    push %rbp
    mov %rsp, %rbp
    sub $32, %rsp
    mov 24(%rbp), %rdi
    mov 16(%rbp), %rcx
    cmp $0, %rcx
    je yogc_fail
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov 64(%rax), %rsi
    mov 56(%rax), %r11
    and $65535, %r11
    shr $1, %r11
    xor %r9d, %r9d
yogc_loop:
    cmp %r11, %r9
    jge yogc_done
    mov %r9, %rax
    add %rax, %rax
    movzbq (%rsi,%rax,1), %rdx
    cmp $92, %rdx
    jne yogc_keep
    mov $47, %rdx
yogc_keep:
    cmp %rcx, %r9
    jge yogc_fail
    movb %dl, (%rdi,%r9,1)
    add $1, %r9
    jmp yogc_loop
yogc_done:
    cmp $1, %r9
    jle yogc_term
    mov %r9, %rax
    sub $1, %rax
    movzbq (%rdi,%rax,1), %rdx
    cmp $47, %rdx
    jne yogc_term
    sub $1, %r9
yogc_term:
    cmp %rcx, %r9
    jge yogc_fail
    movb $0, (%rdi,%r9,1)
    add $1, %r9
    mov %r9, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
yogc_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_chdir(path, len) -> 0, or -1.
#
# TWO ARGUMENTS, FRAMELESS: len (arg2) at 8(%rsp) -> 16(%rbp), path (arg1) at
# 16 -> 24.
#
# The current directory is a PEB FIELD, so changing it is not a syscall but a
# write: ProcessParameters at PEB+32, CURDIR.DosPath at +56, a UNICODE_STRING
# whose Length is in BYTES at +56, MaximumLength at +58 and Buffer at +64. The
# text it holds is a DOS path (`Z:\tmp\...`), NOT the `\??\` object-manager form
# y_w_path produces, so the prefix is skipped rather than stripped by a second
# builder -- its length is fixed at four units, the first eight bytes.
#
# THE BUFFER MUST OUTLIVE THE CALL, which rules out the frame: it is allocated
# with NtAllocateVirtualMemory (24) at 2*units+4 bytes, and the DOS path written
# into it as UTF-16 -- TWO bytes per unit, low byte then a zero high byte. The
# first version wrote one byte per unit, which is the shape of every other
# string in this file and the wrong shape for a PEB field: the result looked like
# a path with NULs through it. and its address is what
# the PEB ends up pointing at. chdir therefore LEAKS the previous directory's
# buffer, because nothing else knows when the process is done with it. That is
# the honest price of having no allocator here, and it is bounded by the number
# of chdirs a program makes.
#
# The target is checked with NtQueryFullAttributesFile (196) and must have
# FILE_ATTRIBUTE_DIRECTORY (16) set, because a chdir to something that is not
# there has to FAIL -- chdir(2) says so, fs.chdir returns a bool, and a PEB
# field will happily accept any string at all.
#
# The LENGTH is carried from the copy to the PEB write in %r11: the PEB read
# uses %rax and %rdx, and the first version took the length out of %rdx after
# that read, so Length became a stray character from the copy loop and the
# directory came out as the wrong path -- with chdir still reporting success.
#
# The trailing separator is added only if the path does not already end in one.
# y_w_path leaves a `\` behind when it pops a `..`, so appending unconditionally
# produced `...\w49\\`; fs.cwd drops ONE trailing separator, as getcwd(2) does,
# and therefore reported `Z:/tmp/ts/w49/`. Every relative path after that was
# resolved against a directory whose name ends in a slash, and removing a file
# in it failed while every other operation on it succeeded.
#
# Frame: the path at -2200 (y_w_path writes upward), the UNICODE_STRING at
# -2320, the FILE_NETWORK_OPEN_INFORMATION at -2280 (its 56 bytes end at -2225,
# below the buffer's start), the OBJECT_ATTRIBUTES at -2380, the allocated base
# at -2300, the size at -2316 and two saved words at -2332 and -2340. 3000 puts
# the stack-argument area at rbp-2960, clear of all of it.
#=== replace: y_os_chdir ===
y_os_chdir:
    push %rbp
    mov %rsp, %rbp
    sub $3000, %rsp
    lea -2200(%rbp), %rdi
    mov 24(%rbp), %rsi
    mov 16(%rbp), %rcx
    call y_w_path
    cmp $4, %rax
    jle yocd_fail
    mov %rax, -2400(%rbp)
    sub $4, %rax
    mov %rax, -2408(%rbp)
    mov -2400(%rbp), %r8
    add %r8, %r8
    mov %r8, %rax
    movb %al, -2320(%rbp)
    shr $8, %rax
    movb %al, -2319(%rbp)
    add $2, %r8
    mov %r8, %rax
    movb %al, -2318(%rbp)
    shr $8, %rax
    movb %al, -2317(%rbp)
    lea -2200(%rbp), %rax
    mov %rax, -2312(%rbp)
    mov $48, %rax
    mov %rax, -2380(%rbp)
    mov $0, %rax
    mov %rax, -2372(%rbp)
    lea -2320(%rbp), %rax
    mov %rax, -2364(%rbp)
    mov $64, %rax
    mov %rax, -2356(%rbp)
    mov $0, %rax
    mov %rax, -2348(%rbp)
    mov $0, %rax
    mov %rax, -2340(%rbp)
    lea -2380(%rbp), %r10
    lea -2280(%rbp), %rdx
    mov $196, %eax
    syscall
    test %eax, %eax
    jne yocd_fail
    movzbq -2232(%rbp), %rax
    and $16, %rax
    cmp $0, %rax
    je yocd_fail
    mov $0, %rax
    mov %rax, -2300(%rbp)
    mov -2408(%rbp), %rax
    add %rax, %rax
    add $4, %rax
    mov %rax, -2316(%rbp)
    mov $-1, %r10
    lea -2300(%rbp), %rdx
    xor %r8d, %r8d
    lea -2316(%rbp), %r9
    mov $12288, 40(%rsp)
    mov $4, 48(%rsp)
    mov $24, %eax
    syscall
    test %eax, %eax
    jne yocd_fail
    mov -2300(%rbp), %rdi
    mov -2408(%rbp), %rcx
    xor %r9d, %r9d
yocd_copy:
    cmp %rcx, %r9
    jge yocd_tail
    mov %r9, %rax
    add $4, %rax
    add %rax, %rax
    movzbq -2200(%rbp,%rax,1), %rdx
    mov %r9, %rax
    add %rax, %rax
    movb %dl, (%rdi,%rax,1)
    movb $0, 1(%rdi,%rax,1)
    add $1, %r9
    jmp yocd_copy
yocd_tail:
    mov %r9, %rax
    add %rax, %rax
    cmp $0, %rax
    je yocd_sep
    movzbq -2(%rdi,%rax,1), %rdx
    cmp $92, %rdx
    je yocd_after
yocd_sep:
    movb $92, (%rdi,%rax,1)
    movb $0, 1(%rdi,%rax,1)
    add $2, %rax
yocd_after:
    movb $0, (%rdi,%rax,1)
    movb $0, 1(%rdi,%rax,1)
    mov %rax, %r11
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov %r11, %rdx
    movb %dl, 56(%rax)
    shr $8, %rdx
    movb %dl, 57(%rax)
    add $2, %r11
    mov %r11, %rdx
    movb %dl, 58(%rax)
    shr $8, %rdx
    movb %dl, 59(%rax)
    mov -2300(%rbp), %rdx
    mov %rdx, 64(%rax)
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
yocd_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_list(fd, buf, len, restart) -> the number of BYTES written to buf, or 0
# when the directory is finished (or -1). The bytes are NUL-terminated names,
# "." and ".." left out -- ONE format on both kernels, because fs.list_dir
# parses it and must not branch on the target -- and fs.list_dir stops at
# anything <= 0, so an error ends a listing rather than hanging it.
#
# FOUR ARGUMENTS, FRAMELESS in the ELF body: restart (arg4) at 8(%rsp) ->
# 16(%rbp), len (arg3) at 16 -> 24, buf (arg2) at 24 -> 32, fd (arg1) at 32 -> 40.
# The fd is a DIRECTORY HANDLE from y_os_openat, which opens with
# FILE_DIRECTORY_FILE when fs.y asks for O_DIRECTORY.
#
# NtQueryDirectoryFile (53) takes eleven arguments: four in registers and SEVEN
# on the stack, at 40(%rsp) and up. That is why the frame is 128 bytes and the
# IO_STATUS_BLOCK sits at -32: the argument area is rbp-88 to rbp-33 and the two
# must not overlap, which is the rule round 44 paid for.
#
# FileInformationClass is FileBothDirectoryInformation (3), and THE LAYOUT WAS
# MEASURED, not assumed. FileNamesInformation (12) looked like the obvious
# choice -- it carries nothing but the name -- and wine 11.17 does not answer it
# with FILE_NAMES_INFORMATION; class 3 does answer with
# FILE_BOTH_DIR_INFORMATION, and a dump of the raw buffer (a temporary body that
# made the call and returned without touching it) shows:
#
#   +0   ULONG NextEntryOffset   -- 96 for the first record, 0 on the last
#   +56  ULONG FileAttributes    -- 16, FILE_ATTRIBUTE_DIRECTORY, for "."
#   +60  ULONG FileNameLength    -- 2, i.e. ONE UTF-16 unit for "."
#   +94  WCHAR FileName[]        -- 46 00, which is "."
#
# THE DUMP HAD TO COME FIRST, because this body rewrites the buffer IN PLACE and
# therefore destroys the kernel's own records as it goes: every earlier dump was
# of the walk's output, not of the input, which is why two rounds of offset
# guessing produced nothing. In-place is safe for the same reason the ELF half
# says getdents64 is: a 94-byte header plus a name is always longer than the
# name alone, so the write cursor never catches the read cursor.
#
# Names are narrowed to one byte each (ASCII) and NUL-terminated. The ELF half
# uses an 8-byte store, which is why fs.y passes 32760 rather than 32768; this
# half does not need that slack, but it must not write past len either, so a
# name that does not fit ends the listing.
#
# Status: STATUS_SUCCESS (0) means records follow, STATUS_BUFFER_OVERFLOW
# (0x80000005) means as many as fitted, and STATUS_NO_MORE_FILES (0x80000006)
# means the directory is done and the answer is 0. Anything else is -1.
#=== replace: y_os_list ===
y_os_list:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp
    mov 40(%rbp), %r10
    xor %edx, %edx
    xor %r8d, %r8d
    xor %r9d, %r9d
    lea -32(%rbp), %rax
    mov %rax, 40(%rsp)
    mov 32(%rbp), %rax
    mov %rax, 48(%rsp)
    mov 24(%rbp), %rax
    mov %rax, 56(%rsp)
    mov $3, 64(%rsp)
    mov $0, 72(%rsp)
    mov $0, 80(%rsp)
    mov 16(%rbp), %rax
    mov %rax, 88(%rsp)
    mov $53, %eax
    syscall
    cmp $0, %eax
    je yol_records
    cmp $-2147483643, %eax
    je yol_records
    cmp $-2147483642, %eax
    je yol_none
    jmp yol_fail
yol_none:
    xor %eax, %eax
    mov %rbp, %rsp
    pop %rbp
    ret
yol_records:
    mov 32(%rbp), %rsi
    mov 24(%rbp), %rcx
    mov $0, %r8
    mov $0, %r9
yol_rec:
    mov %rsi, %r11
    add %r8, %r11
    mov 60(%r11), %r10
    shr $1, %r10
    cmp $1, %r10
    jne yol_chk2
    movzbq 94(%r11), %rax
    cmp $46, %rax
    je yol_next
yol_chk2:
    cmp $2, %r10
    jne yol_emit
    movzbq 94(%r11), %rax
    cmp $46, %rax
    jne yol_emit
    movzbq 96(%r11), %rax
    cmp $46, %rax
    je yol_next
yol_emit:
    xor %rdi, %rdi
yol_name:
    cmp %r10, %rdi
    jge yol_term
    cmp %rcx, %r9
    jge yol_done
    mov %rdi, %rax
    add %rax, %rax
    add $94, %rax
    movzbq (%r11,%rax,1), %rdx
    movb %dl, (%rsi,%r9,1)
    add $1, %r9
    add $1, %rdi
    jmp yol_name
yol_term:
    cmp %rcx, %r9
    jge yol_done
    movb $0, (%rsi,%r9,1)
    add $1, %r9
yol_next:
    mov 0(%r11), %rax
    cmp $0, %rax
    je yol_done
    add %rax, %r8
    cmp %rcx, %r8
    jl yol_rec
yol_done:
    mov %r9, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
yol_fail:
    mov $-1, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
