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
#   arg1 %r10  arg2 %r9  arg3 %r8  arg4 %rdx
#   the result is an NTSTATUS in %rax, and FAILURE IS THE POSITIVE SIGN BIT
#   of its low 32 bits: `test %eax,%eax; js` is the failure test. Carrying a
#   SysV `js`/`>= 0` over would read failure as success, and testing %rax
#   instead of %eax would too -- writing EAX clears the high half, so a
#   failure status arrives as a POSITIVE 64-bit value.
#
# ARGUMENTS FIVE AND UP ARE A COMPATIBILITY SHIM, and this is the one place
# where wine and a real Windows are MEASURED to differ. The Windows kernel
# takes arg5 in %rcx, arg6 in %r11 and arg7 and after at 32(%rsp), 40(%rsp),
# 48(%rsp)... . Wine (11.17, measured here by calling NtAllocateVirtualMemory
# and reading the raw NTSTATUS) additionally takes arg5 from 32(%rsp) and
# arg6 from 40(%rsp), and reports STATUS_INVALID_PARAMETER (0xC000000D) when
# only the registers are set. So every call here sets the registers AND the
# stack slots, which is harmless on Windows (it ignores the slots) and what
# wine needs. Arguments one to four are identical on both, which is why only
# the calls with five or more arguments need the duplication.
#
# The numbers are the Windows 10 1607 / 11 x64 table, pinned in
# arch_x64.y w_sysno (one arm per call, so a future Windows is a small diff).
# They were read off the syscall stubs in a real ntdll's .text, not written
# from memory: a leftover Linux number silently calls a different, real Nt
# function, which is why that table is one list a review can read at once.
#
# y_os_handle: fd (%rdi, 0/1/2) -> the process's standard I/O handle. %gs:0x60
# is the PEB on x64 -- stable, unlike TEB.ThreadLocalStoragePointer across
# versions -- PEB+0x20 is ProcessParameters, and RTL_USER_PROCESS_PARAMETERS
# holds StandardInput/Output/Error at +0x20/+0x28/+0x30. This is the one PEB
# read in the tree, and it exists because a "fd" is not a handle on Windows.
# A syscall per write, which is the cost of having no imports at all.
#=== add: y_os_handle ===
y_os_handle:
    mov %gs:0x60, %rax
    mov 0x20(%rax), %rax
    cmp $1, %rdi
    jl yosh_in
    je yosh_out
    mov 0x30(%rax), %rax
    ret
yosh_in:
    mov 0x20(%rax), %rax
    ret
yosh_out:
    mov 0x28(%rax), %rax
    ret
# y_os_write(fd, buf, len) -> bytes written, or -1.
# NtWriteFile takes NINE arguments: handle, event, ApcRoutine, ApcContext,
# IoStatusBlock, buffer, length, offset, key. The first four go in the NT
# registers and the last five at 32(%rsp) onwards -- the six bytes of room
# reserved below %rsp here, which is our own frame (the shadow space the ABI
# reserves for register arguments sits ABOVE %rsp and is unused here). Offset
# and key are NULL, which is what a console or a pipe wants; the byte count
# comes back in the IO_STATUS_BLOCK's Information field, not in the status.
# The IO_STATUS_BLOCK lives at -16(%rbp), with Information at -8(%rbp).
#=== add: y_os_write ===
y_os_write:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    sub $128, %rsp
    mov %rdx, %r12
    mov %rsi, %rbx
    call y_os_handle
    mov %rax, %r10
    xor %r9d, %r9d
    xor %r8d, %r8d
    xor %edx, %edx
    lea -16(%rbp), %rcx
    mov %rbx, %r11
    mov %r12, 32(%rsp)
    mov $0, 40(%rsp)
    mov $0, 48(%rsp)
    mov $8, %eax
    syscall
    test %eax, %eax
    jns yow_ok
    mov $-1, %rax
    jmp yow_out
yow_ok:
    mov -8(%rbp), %rax
yow_out:
    mov %rbp, %rsp
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_os_exit(status) -- NtTerminateProcess(-1, status). `div` by zero after it:
# the call does not return, and if it somehow does the program must stop
# loudly rather than run on past its own exit. `div` by zero is the trap the
# rest of the prelude already uses for an impossible condition (y_long_tostr);
# the encoder has no ud2.
#=== add: y_os_exit ===
y_os_exit:
    mov $-1, %r10
    mov %rdi, %r9
    mov $44, %eax
    syscall
    xor %eax, %eax
    div %rax
# The trap stubs. Each writes its message to the standard output and ends the
# process with status 1, which is what the SysV version does (write(1, ...)
# then exit_group(1)).
#=== replace: y_div_zero ===
y_div_zero:
    mov $1, %rdi
    lea ystr_divzero(%rip), %rsi
    mov $ystr_divzero_end-ystr_divzero, %rdx
    call y_os_write
    mov $1, %rdi
    call y_os_exit
#=== replace: y_oob ===
y_oob:
    mov $1, %rdi
    lea ystr_oob(%rip), %rsi
    mov $ystr_oob_end-ystr_oob, %rdx
    call y_os_write
    mov $1, %rdi
    call y_os_exit
#=== replace: y_cast_trap ===
y_cast_trap:
    mov $1, %rdi
    lea ystr_cast(%rip), %rsi
    mov $ystr_cast_end-ystr_cast, %rdx
    call y_os_write
    mov $1, %rdi
    call y_os_exit
#=== replace: y_alloc_fail ===
y_alloc_fail:
    mov $1, %rdi
    lea ystr_oom(%rip), %rsi
    mov $ystr_oom_end-ystr_oom, %rdx
    call y_os_write
    mov $1, %rdi
    call y_os_exit
#=== replace: y_opt_unwrap ===
y_opt_unwrap:
    mov $1, %rdi
    lea ystr_opt(%rip), %rsi
    mov $ystr_opt_end-ystr_opt, %rdx
    call y_os_write
    mov $1, %rdi
    call y_os_exit
# y_alloc_map: the allocator's mapping request. The size arrives in %rsi,
# the same register the SysV mmap call it replaces takes it in (y_alloc_more
# sets it). NtAllocateVirtualMemory takes six arguments -- the first four in
# registers, then allocation type and protection (both set in the registers
# AND at 32/40(%rsp), see the file header):
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
    lea -8(%rbp), %r9
    xor %r8d, %r8d
    lea -16(%rbp), %rdx
    mov $12288, %rcx
    mov $4, %r11
    mov $12288, 32(%rsp)
    mov $4, 40(%rsp)
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