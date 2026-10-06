# wselftest.s -- the Windows syscall self-test (ideas/WINDOWS.md W3): one Nt
# call per class, once at program start, with its NTSTATUS checked.
#
# WHY IT EXISTS. The numbers in arch_x64.y's w_sysno are pinned to one ntdll
# sample (Windows 10 1607 / 11 x64). A wrong number here does NOT fail with
# "no such syscall": the NT index range is dense and live, so a stale entry
# calls a *different, real* Nt function and the symptom appears much later as
# wrong memory or wrong I/O, with nothing at the call site to say so. This
# block turns that into a named failure in the first instruction of the
# program.
#
# HOW IT IS WIRED. arch_x64.y's w_self_test_lines returns these lines and
# native.y feeds them to the prelude (so the tree shaker sees the references
# and keeps y_os_write/y_os_exit for it); the _start prologue calls
# y_w_self_test before it does anything else, on the Windows target only. On
# Linux the function returns no lines and no call is emitted, so nothing here
# reaches an ELF.
#
# WHAT IS CHECKED. Memory: NtAllocateVirtualMemory, NtProtectVirtualMemory,
# NtFreeVirtualMemory. Time: NtQueryPerformanceCounter, NtQuerySystemTime,
# NtDelayExecution. File: NtWriteFile. Each must return STATUS_SUCCESS
# (NT_SUCCESS(s) == (s >= 0), i.e. the sign bit of the low 32 bits clear).
#
# WHAT IS NOT. There is no thread or process entry in w_sysno to check, and
# NtClose/NtReadFile are exercised by the first fs/read call a real program
# makes (a failed close would leak a handle, not misprint a byte). Only the
# numbers the runtime actually reaches are probed.
#
# A WRONG NUMBER IN THE ARGUMENT REGISTERS WOULD BE SILENT, so the register
# set is the one wsys.s documents and every Nt* call agrees on:
#   arg1 %r10   arg2 %rdx   arg3 %r8   arg4 %r9   arg5+ at 40(%rsp), 48, ...
# Every immediate here is DECIMAL: the in-tree assembler's number reader is
# decimal (asm.y parse_num), and a hex literal is a "bad operand" diagnostic
# that names the instruction rather than the literal.
#
# The frame: 128 bytes below %rbp for the out-parameters and the stack
# arguments (args 5+ are written at 40(%rsp), 48(%rsp), ... -- see wsys.s).
# The 16-byte IO_STATUS_BLOCK of NtWriteFile lives at -72(%rbp)..-57 and the
# zero buffer it writes from at -80(%rbp); they must not overlap, because the
# kernel writes the block.

y_w_self_test:
    push %rbp
    mov %rsp, %rbp
    sub $128, %rsp
# ── memory: NtAllocateVirtualMemory(-1, &base, 0, &size, MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)
    mov $0, -8(%rbp)
    mov $4096, -16(%rbp)
    mov $-1, %r10
    lea -8(%rbp), %rdx
    xor %r8d, %r8d
    lea -16(%rbp), %r9
    mov $12288, 40(%rsp)
    mov $4, 48(%rsp)
    mov $24, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
# ── memory: NtProtectVirtualMemory(-1, &base, &size, PAGE_READONLY, &old)
    mov $0, -24(%rbp)
    mov $-1, %r10
    lea -8(%rbp), %rdx
    lea -16(%rbp), %r8
    mov $2, %r9
    lea -24(%rbp), %rax
    mov %rax, 40(%rsp)
    mov $80, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
# ── memory: NtFreeVirtualMemory(-1, &base, &size, MEM_RELEASE)
    mov $-1, %r10
    lea -8(%rbp), %rdx
    lea -16(%rbp), %r8
    mov $32768, %r9
    mov $30, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
# ── time: NtQueryPerformanceCounter(&counter, &frequency)
    lea -32(%rbp), %r10
    lea -40(%rbp), %rdx
    mov $49, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
# ── time: NtQuerySystemTime(&system_time)
    lea -48(%rbp), %r10
    mov $90, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
# ── time: NtDelayExecution(FALSE, &interval) with a zero interval
    mov $0, -56(%rbp)
    xor %r10d, %r10d
    lea -56(%rbp), %rdx
    mov $52, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
# ── file: NtWriteFile(stdout, 0, 0, 0, &iosb, &zero, 0, 0, 0) -- a
#    ZERO-LENGTH write, so a right number prints nothing and a wrong one is
#    caught here instead of in the first byte a program prints. The 16-byte
#    IO_STATUS_BLOCK is at -72 and the (never-read) zero buffer at -80: they
#    must not overlap, because the kernel writes the block.
    mov $0, -80(%rbp)
    mov $0, -72(%rbp)
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov 40(%rax), %r10
    xor %edx, %edx
    xor %r8d, %r8d
    xor %r9d, %r9d
    lea -72(%rbp), %rax
    mov %rax, 40(%rsp)
    lea -80(%rbp), %rax
    mov %rax, 48(%rsp)
    mov $0, 56(%rsp)
    mov $0, 64(%rsp)
    mov $0, 72(%rsp)
    mov $8, %eax
    syscall
    test %eax, %eax
    js y_w_self_test_fail
    mov %rbp, %rsp
    pop %rbp
    ret
y_w_self_test_fail:
# The message, then exit 1 -- the same shape the trap stubs below use
# (yself... the string lives in arch_x64.y arch_consts, so a program that
# never fails pays nothing for it: the rodata shaker drops it unless this
# block is kept, and this block is kept only when it is called).
# y_os_write takes its arguments ON THE STACK, count pushed last (see wsys.s).
    mov $2, %rax
    push %rax
    lea ystr_wselftest(%rip), %rax
    push %rax
    mov $ystr_wselftest_end-ystr_wselftest, %rax
    push %rax
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
