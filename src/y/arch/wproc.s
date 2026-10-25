# wproc.s -- processes on Windows: fork, spawn, wait, pipe.  A block set of the
# Windows arch module (see wsys.s); every block here is an `add:` or a `replace:`.
#
# Win32 calls are resolved on first use (wsys.s y_w_api) and called Win64 style:
# arguments in %rcx %rdx %r8 %r9 then at 32(%rsp), 40(%rsp)...; every function
# here frames itself with %rbp, saves what it uses, and aligns %rsp to 16 before
# a call (its callers are Y code, whose alignment is not promised).  r15 holds
# the argument vector for the whole run (_start), so it is never touched.
#
# THE API CACHE, cell numbers of yw_apis (arch_heap_cells):
#   0 CreateThread   1 CreateProcessW  2 GetModuleFileNameW  3 GetCommandLineW
#   4 VirtualAllocEx 5 WriteProcessMemory  6 ResumeThread  7 TerminateProcess
#   8 WaitForSingleObject  9 GetExitCodeProcess  10 CreatePipe
#  11 SetHandleInformation  12 VirtualQuery
#
# THE PROCESS TABLE yw_procs: 64 pairs {pid, process handle} of the children a
# fork or spawn started and wait4 has not yet reaped.
#
# fork on Windows (y_w_fork).  There is no fork; what Y needs from it is "run this
# closure in a copy of my state, and give me something to wait for". So: start a
# suspended copy of this very executable (CreateProcessW on its own path with its
# own command line, standard handles passed, every inheritable handle inherited);
# put into it the heap -- every committed page of the address range the
# allocator maps from (y_alloc_map hands out hint addresses from yw_hint, which
# is why the copy can be made at the SAME addresses) -- and the .bss from y_heap
# up (the import table, which the loader fills, is below it); set yw_fork_hook
# in the copy and resume it.  The copy's _start runs y_w_self_test, which sees
# the hook and calls y_w_fork_child: that adopts the forking thread's state,
# calls the closure on its own stack and exits.  The parent keeps the process
# handle for wait4.  The copy is made WITHOUT stopping the parent's other
# threads (as POSIX warns for fork in a threaded program).
#
# y_w_fork(closure in %rax) -> the child's process id, or -1 / -12 (no memory
# at the addresses, or an allocation the hints could not place).

#=== add: y_w_fork ===
y_w_fork:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $1600, %rsp
    and $-16, %rsp
    mov %rax, -176(%rbp)
    mov yw_ovf(%rip), %rax
    test %rax, %rax
    jz ywf_ok1
    mov $-12, %rax
    jmp ywf_out
ywf_ok1:
    xor %eax, %eax
    lea -144(%rbp), %rdi
    mov $13, %rcx
ywf_zsi:
    mov %rax, (%rdi)
    add $8, %rdi
    sub $1, %rcx
    jnz ywf_zsi
    mov $104, %rax
    mov %rax, -144(%rbp)
    mov $1099511627776, %rax
    mov %rax, -88(%rbp)
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov 32(%rax), %rcx
    mov %rcx, -64(%rbp)
    mov 40(%rax), %rcx
    mov %rcx, -56(%rbp)
    mov 48(%rax), %rcx
    mov %rcx, -48(%rbp)
    lea yw_apis(%rip), %rcx
    add $16, %rcx
    lea ywn_y_w_fork_GetModuleFileNameW(%rip), %r8
    call y_w_api_k32
    xor %ecx, %ecx
    lea -1424(%rbp), %rdx
    mov $520, %r8
    call *%rax
    lea yw_apis(%rip), %rcx
    add $24, %rcx
    lea ywn_y_w_fork_GetCommandLineW(%rip), %r8
    call y_w_api_k32
    call *%rax
    mov %rax, %r14
    lea yw_apis(%rip), %rcx
    add $8, %rcx
    lea ywn_y_w_fork_CreateProcessW(%rip), %r8
    call y_w_api_k32
    lea -1424(%rbp), %rcx
    mov %r14, %rdx
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov $1, %r10
    mov %r10, 32(%rsp)
    mov $4, %r10
    mov %r10, 40(%rsp)
    xor %r10d, %r10d
    mov %r10, 48(%rsp)
    mov %r10, 56(%rsp)
    lea -144(%rbp), %r10
    mov %r10, 64(%rsp)
    lea -168(%rbp), %r10
    mov %r10, 72(%rsp)
    call *%rax
    test %eax, %eax
    jnz ywf_made
    lea yw_apis(%rip), %rcx
    add $104, %rcx
    lea ywn_y_w_fork_GetLastError(%rip), %r8
    call y_w_api_k32
    call *%rax
    neg %rax
    jmp ywf_out
ywf_made:
    mov -168(%rbp), %r12
    mov -160(%rbp), %r13
    mov -152(%rbp), %r14
    shl $32, %r14
    shr $32, %r14
# the heap: walk the hinted range, copy every committed region at its own address
    mov $35184372088832, %rbx
ywf_walk:
    mov yw_hint(%rip), %rax
    cmp %rax, %rbx
    jge ywf_walked
    lea yw_apis(%rip), %rcx
    add $96, %rcx
    lea ywn_y_w_fork_VirtualQuery(%rip), %r8
    call y_w_api_k32
    mov %rbx, %rcx
    lea -224(%rbp), %rdx
    mov $48, %r8
    call *%rax
    test %rax, %rax
    jz ywf_walked
    mov -192(%rbp), %rax
    and $4096, %rax
    jz ywf_skip
    lea yw_apis(%rip), %rcx
    add $32, %rcx
    lea ywn_y_w_fork_VirtualAllocEx(%rip), %r8
    call y_w_api_k32
    mov %r12, %rcx
    mov -224(%rbp), %rdx
    mov -200(%rbp), %r8
    mov $12288, %r9
    mov $4, %r10
    mov %r10, 32(%rsp)
    call *%rax
    test %rax, %rax
    jz ywf_fail_a
    lea yw_apis(%rip), %rcx
    add $40, %rcx
    lea ywn_y_w_fork_WriteProcessMemory(%rip), %r8
    call y_w_api_k32
    mov %r12, %rcx
    mov -224(%rbp), %rdx
    mov %rdx, %r8
    mov -200(%rbp), %r9
    xor %r10d, %r10d
    mov %r10, 32(%rsp)
    call *%rax
    test %eax, %eax
    jz ywf_fail_b
ywf_skip:
    mov -224(%rbp), %rax
    mov -200(%rbp), %rcx
    add %rcx, %rax
    mov %rax, %rbx
    jmp ywf_walk
ywf_walked:
# the state the copy adopts, then the .bss from y_heap up
    mov -176(%rbp), %rax
    mov %rax, yw_fork_closure(%rip)
    mov %gs:5752, %rax
    mov %rax, yw_fork_tcb(%rip)
    mov %r15, yw_fork_r15(%rip)
    lea y_w_fork_child(%rip), %rax
    mov %rax, yw_fork_hook(%rip)
    lea yw_apis(%rip), %rcx
    add $40, %rcx
    lea ywn_y_w_fork_WriteProcessMemory(%rip), %r8
    call y_w_api_k32
    mov %r12, %rcx
    lea y_heap(%rip), %rdx
    mov %rdx, %r8
    lea y_bss_hi(%rip), %r9
    sub %rdx, %r9
    xor %r10d, %r10d
    mov %r10, 32(%rsp)
    call *%rax
    xor %ecx, %ecx
    mov %rcx, yw_fork_hook(%rip)
    mov %rcx, yw_fork_closure(%rip)
    test %eax, %eax
    jz ywf_fail_c
    lea yw_apis(%rip), %rcx
    add $48, %rcx
    lea ywn_y_w_fork_ResumeThread(%rip), %r8
    call y_w_api_k32
    mov %r13, %rcx
    call *%rax
    mov %r13, %r10
    mov $15, %eax
    syscall
# remember the child for wait4
    lea yw_procs(%rip), %rcx
    mov $64, %rdx
ywf_slot:
    mov (%rcx), %rax
    test %rax, %rax
    jz ywf_put
    add $16, %rcx
    sub $1, %rdx
    jnz ywf_slot
    mov %r12, %r10
    mov $15, %eax
    syscall
    jmp ywf_pid
ywf_put:
    mov %r14, (%rcx)
    mov %r12, 8(%rcx)
ywf_pid:
    mov %r14, %rax
    jmp ywf_out
ywf_fail_a:
    mov $21, %r14
    jmp ywf_fail
ywf_fail_b:
    mov $22, %r14
    jmp ywf_fail
ywf_fail_c:
    mov $23, %r14
ywf_fail:
    lea yw_apis(%rip), %rcx
    add $56, %rcx
    lea ywn_y_w_fork_TerminateProcess(%rip), %r8
    call y_w_api_k32
    mov %r12, %rcx
    mov $1, %rdx
    call *%rax
    mov %r12, %r10
    mov $15, %eax
    syscall
    mov %r13, %r10
    mov $15, %eax
    syscall
    neg %r14
    mov %r14, %rax
ywf_out:
    lea -32(%rbp), %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywn_y_w_fork_GetModuleFileNameW: .string "GetModuleFileNameW"
ywn_y_w_fork_GetCommandLineW: .string "GetCommandLineW"
ywn_y_w_fork_CreateProcessW: .string "CreateProcessW"
ywn_y_w_fork_VirtualQuery: .string "VirtualQuery"
ywn_y_w_fork_VirtualAllocEx: .string "VirtualAllocEx"
ywn_y_w_fork_WriteProcessMemory: .string "WriteProcessMemory"
ywn_y_w_fork_ResumeThread: .string "ResumeThread"
ywn_y_w_fork_TerminateProcess: .string "TerminateProcess"
ywn_y_w_fork_GetLastError: .string "GetLastError"

# y_w_fork_child: the copy's side of fork. y_w_self_test jumps here (through the
# hook the parent set in the copied .bss) on the copy's first run, on the copy's
# own stack, after _start recorded that stack's top for the collector. It takes
# over the forking thread's identity, becomes the only thread, runs the closure
# and ends the process with status 0.
#=== add: y_w_fork_child ===
y_w_fork_child:
# the API cache came across with the .bss: it names functions of DLLs this
# process may not have loaded (ws2_32 in a copy that never used a socket), so it
# starts empty, and Winsock is not started here
    lea yw_apis(%rip), %rdi
    mov $128, %rcx
    xor %eax, %eax
ywfc_zap:
    mov %rax, (%rdi)
    add $8, %rdi
    sub $1, %rcx
    jnz ywfc_zap
    mov %rax, yw_wsa(%rip)
    mov yw_fork_r15(%rip), %r15
    mov yw_fork_closure(%rip), %rbx
    xor %eax, %eax
    mov %rax, yw_fork_hook(%rip)
    mov %rax, yw_fork_closure(%rip)
    lea y_heap(%rip), %rcx
    mov 24(%rcx), %rdx
    test %rdx, %rdx
    jz ywfc_go
    mov yw_fork_tcb(%rip), %rax
    mov %gs:48, %rcx
    mov %rax, 5752(%rcx)
    xor %ecx, %ecx
    mov %rcx, 80(%rax)
    mov %rcx, 88(%rax)
    mov %rcx, 96(%rax)
    mov %rax, y_gc_threads(%rip)
    mov %rcx, y_gc_parked(%rip)
    mov %rcx, y_gc_stw(%rip)
    mov %gs:8, %rcx
    sub $8392704, %rcx
    mov %rcx, 32(%rax)
ywfc_go:
    push %rbx
    mov 0(%rbx), %rax
    call *%rax
    xor %eax, %eax
    push %rax
    call y_os_exit

# y_os_wait4(pid, status) -> the pid, with the exit status in the wait(2)
# shape in *status (code in bits 8-15; a crash, an NT exception status, reads as
# signal 11); -10 (ECHILD) when this process started no such child. The wait
# polls in slices of 10 ms inside y_gc_block_begin/end, so a collector cycle never
# waits on it.
#=== replace: y_os_wait4 ===
y_os_wait4:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    sub $96, %rsp
    and $-16, %rsp
    mov 24(%rbp), %r13
    mov 16(%rbp), %r12
    cmp $0, %r13
    jle yw4_none
    lea yw_procs(%rip), %rbx
    mov $64, %rcx
yw4_find:
    mov (%rbx), %rax
    cmp %r13, %rax
    je yw4_found
    add $16, %rbx
    sub $1, %rcx
    jnz yw4_find
yw4_none:
    mov $-10, %rax
    jmp yw4_out
yw4_found:
    lea yw_apis(%rip), %rcx
    add $64, %rcx
    lea ywn_y_os_wait4_WaitForSingleObject(%rip), %r8
    call y_w_api_k32
    mov %rax, %r13
yw4_wait:
    call y_w_block_begin
    mov 8(%rbx), %rcx
    mov $10, %rdx
    call *%r13
    mov %rax, -48(%rbp)
    call y_w_block_end
    mov -48(%rbp), %rax
    cmp $258, %rax
    je yw4_wait
    lea yw_apis(%rip), %rcx
    add $72, %rcx
    lea ywn_y_os_wait4_GetExitCodeProcess(%rip), %r8
    call y_w_api_k32
    mov 8(%rbx), %rcx
    lea -56(%rbp), %rdx
    mov $0, %r10
    mov %r10, (%rdx)
    call *%rax
    mov -56(%rbp), %rax
    shl $32, %rax
    shr $32, %rax
    mov $3221225472, %rdx
    cmp %rdx, %rax
    jae yw4_crash
    and $255, %rax
    shl $8, %rax
    jmp yw4_store
yw4_crash:
    mov $11, %rax
yw4_store:
    mov %rax, (%r12)
    mov 8(%rbx), %r10
    mov $15, %eax
    syscall
    mov (%rbx), %rax
    xor %ecx, %ecx
    mov %rcx, (%rbx)
    mov %rcx, 8(%rbx)
yw4_out:
    lea -24(%rbp), %rsp
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywn_y_os_wait4_WaitForSingleObject: .string "WaitForSingleObject"
ywn_y_os_wait4_GetExitCodeProcess: .string "GetExitCodeProcess"

# y_w_utf16: the NUL-terminated UTF-8 at %rsi as UTF-16LE at %rdi (room for one
# unit per byte plus the terminator) -> the number of units, without the
# terminator, in %rax.  Clobbers rcx rdx rsi r8 r9.
#=== add: y_w_utf16 ===
y_w_utf16:
    mov %rdi, %r9
    xor %r8d, %r8d
ywu_loop:
    movzbq (%rsi), %rax
    test %rax, %rax
    jz ywu_end
    add $1, %rsi
    cmp $128, %rax
    jl ywu_put
    cmp $224, %rax
    jl ywu_two
    cmp $240, %rax
    jl ywu_three
    and $7, %rax
    shl $18, %rax
    movzbq (%rsi), %rdx
    and $63, %rdx
    shl $12, %rdx
    or %rdx, %rax
    add $1, %rsi
    movzbq (%rsi), %rdx
    and $63, %rdx
    shl $6, %rdx
    or %rdx, %rax
    add $1, %rsi
    movzbq (%rsi), %rdx
    and $63, %rdx
    or %rdx, %rax
    add $1, %rsi
    jmp ywu_put
ywu_three:
    and $15, %rax
    shl $12, %rax
    movzbq (%rsi), %rdx
    and $63, %rdx
    shl $6, %rdx
    or %rdx, %rax
    add $1, %rsi
    movzbq (%rsi), %rdx
    and $63, %rdx
    or %rdx, %rax
    add $1, %rsi
    jmp ywu_put
ywu_two:
    and $31, %rax
    shl $6, %rax
    movzbq (%rsi), %rdx
    and $63, %rdx
    or %rdx, %rax
    add $1, %rsi
ywu_put:
    cmp $65536, %rax
    jl ywu_one
    sub $65536, %rax
    mov %rax, %rdx
    shr $10, %rdx
    add $55296, %rdx
    and $1023, %rax
    add $56320, %rax
    mov %rax, %rcx
    call ywu_emit
    mov %rcx, %rdx
    call ywu_emit
    jmp ywu_loop
ywu_one:
    mov %rax, %rdx
    call ywu_emit
    jmp ywu_loop
ywu_emit:
    movb %dl, (%r9)
    shr $8, %rdx
    movb %dl, 1(%r9)
    add $2, %r9
    add $1, %r8
    ret
ywu_end:
    movb $0, (%r9)
    movb $0, 1(%r9)
    mov %r8, %rax
    ret

# y_os_pipe(buf) -> 0, or -1. CreatePipe with inheritable ends; the two handles
# are stored as the Linux call stores its two descriptors, the read end in the
# low half of the 8 bytes at buf and the write end in the high half.
#=== replace: y_os_pipe ===
y_os_pipe:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $120, %rsp
    and $-16, %rsp
    mov 16(%rbp), %rbx
    mov $24, %rax
    mov %rax, -48(%rbp)
    xor %eax, %eax
    mov %rax, -40(%rbp)
    mov $1, %rax
    mov %rax, -32(%rbp)
    lea yw_apis(%rip), %rcx
    add $80, %rcx
    lea ywn_y_os_pipe_CreatePipe(%rip), %r8
    call y_w_api_k32
    lea -56(%rbp), %rcx
    lea -64(%rbp), %rdx
    lea -48(%rbp), %r8
    xor %r9d, %r9d
    call *%rax
    test %eax, %eax
    jz yop_fail
    mov -56(%rbp), %rax
    mov -64(%rbp), %rdx
    shl $32, %rdx
    shl $32, %rax
    shr $32, %rax
    or %rdx, %rax
    mov %rax, (%rbx)
    xor %eax, %eax
    jmp yop_out
yop_fail:
    mov $-1, %rax
yop_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret
ywn_y_os_pipe_CreatePipe: .string "CreatePipe"

# y_w_inherit(handle in %rcx, flag in %rdx): SetHandleInformation(handle,
# HANDLE_FLAG_INHERIT, flag); a negative handle is no handle and is skipped.
#=== add: y_w_inherit ===
y_w_inherit:
    cmp $0, %rcx
    jl ywi_none
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    mov %rcx, %rbx
    mov %rdx, %r12
    sub $48, %rsp
    and $-16, %rsp
    lea yw_apis(%rip), %rcx
    add $88, %rcx
    lea ywn_y_w_inherit_SetHandleInformation(%rip), %r8
    call y_w_api_k32
    mov %rbx, %rcx
    mov $1, %rdx
    mov %r12, %r8
    call *%rax
    lea -16(%rbp), %rsp
    pop %r12
    pop %rbx
    pop %rbp
ywi_none:
    ret
ywn_y_w_inherit_SetHandleInformation: .string "SetHandleInformation"

# y_os_spawn(cmd, in, out, close_a, close_b) -> the child's id, or -1: run the
# NUL-terminated command through the system shell (here cmd.exe /d /s /c) as a
# new process. `in` and `out` are handles for its standard input and output (-1:
# the parent's own); close_a and close_b are the parent's ends of the pipes
# the child must not inherit (-1: none). Arguments, last pushed lowest: close_b
# 16(%rbp), close_a 24, out 32, in 40, cmd 48.
#=== replace: y_os_spawn ===
y_os_spawn:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    sub $1600, %rsp
    and $-16, %rsp
    mov 48(%rbp), %rsi
    xor %r12d, %r12d
yos_len:
    movzbq (%rsi,%r12,1), %rax
    test %rax, %rax
    jz yos_len_done
    add $1, %r12
    jmp yos_len
yos_len_done:
    lea 24(%r12), %rdi
    add %rdi, %rdi
    call y_alloc
    mov %rax, %r13
    lea ywsp_prefix(%rip), %rsi
    mov %r13, %rdi
    call y_w_utf16
    mov %rax, %r14
    add %r14, %r14
    mov 48(%rbp), %rsi
    lea (%r13,%r14,1), %rdi
    call y_w_utf16
    add %rax, %rax
    add %rax, %r14
    lea (%r13,%r14,1), %rdi
    movb $34, (%rdi)
    movb $0, 1(%rdi)
    movb $0, 2(%rdi)
    movb $0, 3(%rdi)
    xor %eax, %eax
    lea -144(%rbp), %rdi
    mov $13, %rcx
yos_zsi:
    mov %rax, (%rdi)
    add $8, %rdi
    sub $1, %rcx
    jnz yos_zsi
    mov $104, %rax
    mov %rax, -144(%rbp)
    mov $1099511627776, %rax
    mov %rax, -88(%rbp)
    mov %gs:96, %rax
    mov 32(%rax), %rax
    mov 32(%rax), %rcx
    mov 40(%rax), %rdx
    mov 48(%rax), %r8
    mov 40(%rbp), %r9
    cmp $0, %r9
    jl yos_in_own
    mov %r9, %rcx
yos_in_own:
    mov 32(%rbp), %r9
    cmp $0, %r9
    jl yos_out_own
    mov %r9, %rdx
yos_out_own:
    mov %rcx, -64(%rbp)
    mov %rdx, -56(%rbp)
    mov %r8, -48(%rbp)
    mov -64(%rbp), %rcx
    mov $1, %rdx
    call y_w_inherit
    mov -56(%rbp), %rcx
    mov $1, %rdx
    call y_w_inherit
    mov -48(%rbp), %rcx
    mov $1, %rdx
    call y_w_inherit
    mov 40(%rbp), %rcx
    mov $1, %rdx
    call y_w_inherit
    mov 32(%rbp), %rcx
    mov $1, %rdx
    call y_w_inherit
    mov 24(%rbp), %rcx
    xor %edx, %edx
    call y_w_inherit
    mov 16(%rbp), %rcx
    xor %edx, %edx
    call y_w_inherit
    lea yw_apis(%rip), %rcx
    add $8, %rcx
    lea ywn_y_os_spawn_CreateProcessW(%rip), %r8
    call y_w_api_k32
    xor %ecx, %ecx
    mov %r13, %rdx
    xor %r8d, %r8d
    xor %r9d, %r9d
    mov $1, %r10
    mov %r10, 32(%rsp)
    xor %r10d, %r10d
    mov %r10, 40(%rsp)
    mov %r10, 48(%rsp)
    mov %r10, 56(%rsp)
    lea -144(%rbp), %r10
    mov %r10, 64(%rsp)
    lea -168(%rbp), %r10
    mov %r10, 72(%rsp)
    call *%rax
    test %eax, %eax
    jnz yos_made
    mov $-1, %rax
    jmp yos_out
yos_made:
    mov -160(%rbp), %r10
    mov $15, %eax
    syscall
    mov -168(%rbp), %r12
    mov -152(%rbp), %r14
    shl $32, %r14
    shr $32, %r14
    lea yw_procs(%rip), %rcx
    mov $64, %rdx
yos_slot:
    mov (%rcx), %rax
    test %rax, %rax
    jz yos_put
    add $16, %rcx
    sub $1, %rdx
    jnz yos_slot
    mov %r12, %r10
    mov $15, %eax
    syscall
    jmp yos_pid
yos_put:
    mov %r14, (%rcx)
    mov %r12, 8(%rcx)
yos_pid:
    mov %r14, %rax
yos_out:
    lea -32(%rbp), %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywsp_prefix: .string "cmd.exe /d /s /c \""
ywn_y_os_spawn_CreateProcessW: .string "CreateProcessW"
