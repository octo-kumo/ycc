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
# y_w_path(dst, rel, len) -> the number of UTF-16 units written, or -1, with
# the three arguments in %rdi, %rsi and %rcx -- %rcx and not %rdx, because every
# caller is a `replace:` block that has just loaded the layer's own argument
# slots and already holds the length there. Getting that wrong assembles, runs
# and fails as an unwrap of none, which is a whole debugging session for one
# register. Builds
# an ABSOLUTE NT path at dst: the `\??\` prefix, then the current directory's
# own DOS path out of the PEB, then `rel` widened byte by byte.
#
# It exists as one helper because every path-taking call needs exactly this, and
# WINDOWS DOES NOT DO IT FOR US. A relative name handed to the kernel answers
# STATUS_OBJECT_PATH_SYNTAX_BAD: resolving one against the process's current
# directory is user-space work (RtlDosPathNameToNtPathName) and there is no
# user space here, just syscalls. Two further details, both learned by watching
# a real call fail:
#
#   * the PEB's CURDIR.DosPath is a UNICODE_STRING at ProcessParameters+56 whose
#     Length (BYTES) is at +56 and whose Buffer is at +64. It usually ends in a
#     backslash already, and a doubled one is not harmless, so the separator is
#     added only if the last unit copied is not one.
#   * `/` must become `\`. `pe-fs.expected` (no separator) worked while
#     `src/y/std/fs.y` answered "no such file", which is a confusing way to
#     learn that NT does not take the Unix separator.
#
# Only ASCII is accepted: a byte >= 128 returns -1 rather than being mangled,
# because a wrong path is worse than a refused one. An empty relative path is
# also -1: `\??\CWD\` alone is the current directory, and that is not what
# fs.exists("") answers on Linux.
#
# Callers get the unit count so they can fill UNICODE_STRING.Length (in BYTES,
# without the terminator, which MaximumLength leaves room for).
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
    je ywp_fail
    xor %r9d, %r9d
ywp_loop:
    cmp %rcx, %r9
    jge ywp_done
    movzbq (%rsi,%r9,1), %rax
    cmp $128, %rax
    jge ywp_fail
    cmp $47, %rax
    jne ywp_keep
    mov $92, %rax
ywp_keep:
    movb %al, (%rdi)
    movb $0, 1(%rdi)
    add $2, %rdi
    add $1, %r8
    add $1, %r9
    cmp $1000, %r8
    jg ywp_fail
    jmp ywp_loop
ywp_done:
    movb $0, (%rdi)
    movb $0, 1(%rdi)
    mov %r8, %rax
    mov %rbp, %rsp
    pop %rbp
    ret
ywp_fail:
    mov $-1, %rax
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
