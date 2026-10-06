# Frameless: the two arguments are read off the stack (%rsp still
# holds the return address, so arg1 is at 8(%rsp)) and only the
# caller-saved registers are touched. ycc compares two strings
# 71 million times compiling itself and each comparison is a
# handful of bytes, so the old push %rbp/%rbx/%r13 ... pop
# sequence -- ten instructions, a third of the call -- was pure
# overhead.
y_str_eq:
    mov 8(%rsp), %rax
    mov 16(%rsp), %rcx
    test %rax, %rax
    jz yse_bn
    test %rcx, %rcx
    jz yse_no
    mov (%rax), %r8
    mov (%rcx), %r9
    cmp %r9, %r8
    jnz yse_no
    add $8, %rax
    add $8, %rcx
    xor %r10d, %r10d
yse_loop:
    mov %r8, %rdx
    sub %r10, %rdx
    sub $8, %rdx
    jb yse_tail
    mov (%rax,%r10,1), %rdx
    mov (%rcx,%r10,1), %r11
    cmp %r11, %rdx
    jnz yse_no
    add $8, %r10
    jmp yse_loop
yse_tail:
    mov %r8, %r10
    sub $8, %r10
    mov (%rax,%r10,1), %rdx
    mov (%rcx,%r10,1), %r11
    cmp %r11, %rdx
    jnz yse_no
    mov $1, %rax
    ret
yse_no:
    xor %eax, %eax
    ret
# arg1 was none: equal only if arg2 is too
yse_bn:
    test %rcx, %rcx
    jz yse_yes
    xor %eax, %eax
    ret
yse_yes:
    mov $1, %rax
    ret
# y_str_cmp(a, b) -> -1 / 0 / 1, lexicographic unsigned-byte
# order. Only the SIGN is meaningful to callers (types.y
# typeof_cmp, native.y gen_str_cmp), and yv.c's ys_cmp agrees
# (memcmp on the common prefix, then length), so the three
# spellings of string order all rank identically.
y_str_cmp:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r13
    mov (%rbx), %rcx
    mov (%r13), %rdx
    add $8, %rbx
    add $8, %r13
    xor %r8d, %r8d
ysc_loop:
    cmp %rcx, %r8
    jge ysc_aend
    cmp %rdx, %r8
    jge ysc_pos
    movzbq (%rbx,%r8,1), %rax
    movzbq (%r13,%r8,1), %r14
    cmp %r14, %rax
    jl ysc_neg
    jg ysc_pos
    inc %r8
    jmp ysc_loop
ysc_aend:
    cmp %rdx, %r8
    jge ysc_zero
ysc_neg:
    mov $-1, %rax
    jmp ysc_done
ysc_pos:
    mov $1, %rax
    jmp ysc_done
ysc_zero:
    xor %eax, %eax
ysc_done:
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
y_str_cat:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    push %r12
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r13
    mov (%rbx), %rcx
    mov (%r13), %rdx
    add %rdx, %rcx
    mov %rcx, %rdi
    add $16, %rdi
    mov %rcx, %r12
    call y_alloc
    mov %rax, %r14
    mov %rbx, %rsi
    add $8, %rsi
    mov %r14, %rdi
    add $8, %rdi
    mov (%rbx), %rcx
    call ysc_copy
    mov %r13, %rsi
    add $8, %rsi
    mov (%rbx), %rdx
    mov %rdi, %rdi
    add %rdx, %rdi
    mov (%r13), %rcx
    test %rcx, %rcx
    jz ysc_skip2
    call ysc_copy
ysc_skip2:
    mov %r12, (%r14)
    mov %r12, %rbx
    movb $0, 8(%r14,%rbx,1)
    mov %r14, %rax
    pop %r12
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
# y_str_app(s, x, own) -> s ++ x for `s += x` statements (see
# gen_sappend in native.y). own == 1: s came from here and nobody
# else has seen it, so x goes into its spare room when it fits.
# Its buffers are [cap][len][bytes]: the value points at len, cap
# counts the bytes after it. Room runs out: a buffer twice the
# size; s not owned: an exact copy (+8 for the word copy loop).
y_str_app:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    push %r12
    mov 32(%rbp), %rbx
    mov 24(%rbp), %r13
    mov (%rbx), %r12
    mov (%r13), %rdx
    add %rdx, %r12
    mov 16(%rbp), %rax
    cmp $1, %rax
    jne ysa_new
    mov %r12, %rcx
    add $8, %rcx
    mov -8(%rbx), %rdx
    cmp %rdx, %rcx
    jg ysa_grow
    mov %rbx, %r14
    jmp ysa_tail
ysa_grow:
    mov %r12, %rdi
    add %rdi, %rdi
    add $16, %rdi
    jmp ysa_alloc
ysa_new:
    mov %r12, %rdi
    add $8, %rdi
ysa_alloc:
    push %rdi
    add $16, %rdi
    call y_alloc
    pop %rdi
    mov %rdi, (%rax)
    lea 8(%rax), %r14
    lea 8(%rbx), %rsi
    lea 8(%r14), %rdi
    mov (%rbx), %rcx
    call ysc_copy
ysa_tail:
    lea 8(%r13), %rsi
    mov (%rbx), %rdx
    lea 8(%r14), %rdi
    add %rdx, %rdi
    mov (%r13), %rcx
    test %rcx, %rcx
    jz ysa_skip
    call ysc_copy
ysa_skip:
    mov %r12, (%r14)
    mov %r12, %rbx
    movb $0, 8(%r14,%rbx,1)
    mov %r14, %rax
    pop %r12
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
ysc_copy:
    mov %rcx, %rax
    add $7, %rax
    shr $3, %rax
    xor %r8d, %r8d
yscc_loop:
    cmp %rax, %r8
    jge yscc_done
    mov (%rsi,%r8,8), %rdx
    mov %rdx, (%rdi,%r8,8)
    inc %r8
    jmp yscc_loop
yscc_done:
    ret
y_str_join:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r13
    mov (%rbx), %r12
    mov 16(%rbx), %rbx
    mov (%r13), %r15
    xor %ecx, %ecx
    xor %r8d, %r8d
ysj_sum:
    cmp %r12, %r8
    jge ysj_sumd
    mov (%rbx,%r8,8), %rax
    mov (%rax), %rax
    add %rax, %rcx
    add %r15, %rcx
    inc %r8
    jmp ysj_sum
ysj_sumd:
    test %r12, %r12
    jz ysj_alloc
    sub %r15, %rcx
ysj_alloc:
    push %rcx
    mov %rcx, %rdi
    add $16, %rdi
    call y_alloc
    pop %rcx
    mov %rcx, (%rax)
    mov %rax, %r14
    lea 8(%rax), %rdi
    xor %r9d, %r9d
ysj_loop:
    cmp %r12, %r9
    jge ysj_done
    test %r9, %r9
    jz ysj_elem
    lea 8(%r13), %rsi
    mov %r15, %rcx
    call ysc_copy
    add %r15, %rdi
ysj_elem:
    mov (%rbx,%r9,8), %rsi
    mov (%rsi), %rcx
    add $8, %rsi
    call ysc_copy
    add %rcx, %rdi
    inc %r9
    jmp ysj_loop
ysj_done:
    mov (%r14), %rcx
    movb $0, 8(%r14,%rcx,1)
    mov %r14, %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
y_div_zero:
    mov $1, %rax
    mov $1, %rdi
    lea ystr_divzero(%rip), %rsi
    mov $ystr_divzero_end-ystr_divzero, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
y_oob:
    mov $1, %rax
    mov $1, %rdi
    lea ystr_oob(%rip), %rsi
    mov $ystr_oob_end-ystr_oob, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
y_cast_trap:
    mov $1, %rax
    mov $1, %rdi
    lea ystr_cast(%rip), %rsi
    mov $ystr_cast_end-ystr_cast, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
y_alloc:
    lea 15(%rdi), %rax
    and $-8, %rax
    lea y_heap(%rip), %rcx
y_alloc_go:
    mov (%rcx), %rdx
    mov %rdx, %rdi
    add %rax, %rdi
    mov 8(%rcx), %r11
    cmp %r11, %rdi
    jg y_alloc_slow
    mov %rdi, (%rcx)
    mov 16(%rcx), %rdi
    add %rax, %rdi
    mov %rdi, 16(%rcx)
    mov %rdx, %rax
    ret
# Once a thread was spawned (y_heap's flag) the global block is empty,
# so every thread's bump on it fails and lands here, then retries in
# the thread's own block (%fs:24 points to it; arch_prelude_threads).
y_alloc_slow:
    lea y_heap(%rip), %rdx
    cmp %rdx, %rcx
    jne y_alloc_more
    mov 24(%rdx), %rdx
    test %rdx, %rdx
    je y_alloc_more
    mov %fs:24, %rcx
    jmp y_alloc_go
y_alloc_more:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rsi
    push %r8
    push %r9
    push %r10
    push %r12
    mov %rax, %rbx
    mov %rcx, %r12
    mov $262144, %rsi
    cmp %rsi, %rbx
    jge y_alloc_big
    mov $4194304, %rsi
    call y_alloc_map
    mov %rax, %rdx
    add %rbx, %rdx
    mov %rdx, 0(%r12)
    mov $4194304, %rdx
    add %rax, %rdx
    mov %rdx, 8(%r12)
    jmp y_alloc_out
y_alloc_big:
    mov %rbx, %rsi
    add $4095, %rsi
    and $-4096, %rsi
    call y_alloc_map
y_alloc_out:
    mov 16(%r12), %rdx
    add %rbx, %rdx
    mov %rdx, 16(%r12)
    pop %r12
    pop %r10
    pop %r9
    pop %r8
    pop %rsi
    pop %rbx
    pop %rbp
    ret
y_alloc_map:
    mov $9, %rax
    xor %edi, %edi
    mov $3, %rdx
    mov $34, %r10
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    test %rax, %rax
    js y_alloc_fail
    ret
# y_os_exit(status) -- exit_group(status), and it does NOT return. Called from
# the emitter's `exit(N)` rather than inlined, because rt.y's own error paths
# call exit(1): rt.y is compiled into the std pack, and the pack is written by
# ONE compiler with ONE res_target, so any target test the emitter makes while
# compiling rt.y is baked into every program built from that pack. Naming a
# label instead puts the choice where it belongs -- the arch module -- and makes
# rt.y's compiled body identical for both targets. Status in %rdi, the calling
# convention every function here uses.
y_os_exit:
    push %rbp
    mov %rsp, %rbp
    mov 16(%rbp), %rdi
    mov $231, %rax
    syscall
    mov %rbp, %rsp
    pop %rbp
    ret
# y_os_write(fd, buf, len) -> bytes written, or -1. The named-syscall-layer
# entry point rt.y's y_put_hstr reaches (os_write in the checker): write(2)
# here, NtWriteFile on Windows (src/y/arch/wsys.s). One label, one calling
# convention, so shared std code does not have to know which target it is
# compiled for -- which is the whole point, since the four embedded std units
# are shared by both and serialized into one pack.
#
# It reads its three arguments off the stack -- 24(%rsp) for the descriptor,
# 16 for the bytes, 8 for the count -- rather than out of %rdi/%rsi/%rdx.
# Arguments are pushed left to right by gen_push_args, so the LAST one pushed
# is the first parameter and sits lowest, just above the return address the
# `call` pushed; that is the same rbp+16+8*(n-1-k) layout every Y function
# uses, and the reason a `call` cannot leave them in registers.
y_os_write:
    mov 24(%rsp), %rdi
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov $1, %eax
    syscall
    test %rax, %rax
    js yosw_fail
    ret
yosw_fail:
    mov $-1, %rax
    ret
# The named syscall layer: the blocks std code reaches the kernel through, by
# name, so that rt.y/prelude.y/exec.y compile to the same bytes on every
# target and the std pack stays target-independent (types.y os_call_names has
# the argument for why that is not a simplification).
#
# Every one of these is frameless and reads its arguments off the stack, the
# way y_os_write above does: pushed left to right, so the LAST parameter sits
# lowest, just above the return address the `call` pushed. `ret` and nothing
# else -- the block's result is in %rax, and a negative return is the kernel's
# own errno-negative convention, which is what the caller's `>= 0` checks want.
#
# Each name here needs a Windows body in wsys.s, and types.y's os_call_names is
# the list of the names both halves must define: adding a name to one and not
# the other is a link error on the target that is missing it, and native.y
# check_os_call_names turns that into a compile error here instead.
#
# These three read and fill a struct timespec { i64 sec; i64 nsec; }, which is
# the Linux layout and is also what rt.y allocates. The Windows halves CONVERT
# -- a FILETIME is two 32-bit fields and a QPC tick is not a nanosecond -- so
# nothing above the arch module has to know either.
#
# y_os_read(fd, buf, len) -> bytes read, or a negative errno. read(2).
# y_os_lseek(fd, off, whence) -> the new offset, or a negative errno. lseek(2).
# prelude.y's readline uses it to push back what it read too much of: whence 1
# (SEEK_CUR) with a negative offset. The Windows half is not a transliteration
# of this one -- Windows has no lseek at all -- and says so.
y_os_lseek:
    mov 24(%rsp), %rdi
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov $8, %eax
    syscall
    ret
# y_os_clock_gettime(clock, ts) -> 0, or a negative errno. clock is 0 for
# CLOCK_REALTIME (microseconds since the epoch) and 1 for CLOCK_MONOTONIC.
# clock_gettime(2) is ONE syscall number for every clock, hence one entry in
# arch_x64.y's table rather than two.
y_os_clock_gettime:
    mov 16(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov $228, %eax
    syscall
    ret
# y_os_nanosleep(ts) -> 0, or a negative errno (a negative EINTR means the sleep
# was cut short, which rt.y's sleep ignores). nanosleep(2). The second argument
# stays 0: `rem` is the remaining time and nothing here wants it.
y_os_nanosleep:
    mov 8(%rsp), %rdi
    xor %esi, %esi
    mov $35, %eax
    syscall
    ret
y_os_read:
    mov 24(%rsp), %rdi
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    xor %eax, %eax
    syscall
    ret
# y_os_wait4(pid, status) -> the pid that changed state, or a negative errno.
# wait4(2) with options 0, so the wait is not WNOHANG and not __WCLONE. The
# status word is written as a plain 32-bit int, which is what rt.y's
# `status[0] & 65535` reads.
y_os_wait4:
    mov 16(%rsp), %rdi
    mov 8(%rsp), %rsi
    xor %edx, %edx
    xor %r10d, %r10d
    mov $61, %eax
    syscall
    ret
# y_os_fork() -> 0 in the child, the child's pid in the parent, or a negative
# errno. fork(2). Only one argument register is live here, so the ABI delta
# this block would otherwise carry is nothing at all.
y_os_fork:
    mov $57, %eax
    syscall
    ret
# y_os_execve(path, argv, envp) -> does not return on success; a negative errno
# on failure. execve(2). `path` and `argv` are NUL-terminated C strings and
# `envp` is an array of them, all made by exec.y.
y_os_execve:
    mov 24(%rsp), %rdi
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    mov $59, %eax
    syscall
    ret
# y_os_pipe(buf) -> 0, or a negative errno. pipe(2) writes the two 32-bit
# descriptors as ONE 8-byte int[2], so the caller passes an 8-byte buffer and
# splits it: fds[0] arrives as 0x00000004_00000003 for descriptors 3 and 4
# (low half first on this little-endian machine), and exec.y's popen does the
# masking. Widening them here would need a 32-bit `mov reg, mem`, which the
# in-tree assembler does not encode (enc64.y's mov r,mem is 64-bit only), and
# the one caller that cares is on the one target that has pipe(2) at all.
y_os_pipe:
    mov 8(%rsp), %rdi
    mov $22, %eax
    syscall
    ret
# y_os_dup2(old, new) -> new, or a negative errno. dup2(2). popen uses it in
# the child to put the two pipe ends on fds 0 and 1 before execve.
y_os_dup2:
    mov 16(%rsp), %rdi
    mov 8(%rsp), %rsi
    mov $33, %eax
    syscall
    ret
y_heap_used:
    lea y_heap(%rip), %rcx
    mov 24(%rcx), %rdx
    test %rdx, %rdx
    je y_heap_used_go
    mov %fs:24, %rcx
y_heap_used_go:
    mov 16(%rcx), %rax
    ret
y_alloc_fail:
    mov $1, %rax
    mov $1, %rdi
    lea ystr_oom(%rip), %rsi
    mov $ystr_oom_end-ystr_oom, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
y_opt_unwrap:
    mov $1, %rax
    mov $1, %rdi
    lea ystr_opt(%rip), %rsi
    mov $ystr_opt_end-ystr_opt, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
# y_arr_slice(arr, lo, hi, esz) -> new array. esz is the element
# width in bytes (1 for packed [byte], 8 for everything else), so
# one implementation serves both layouts.
y_arr_slice:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov 40(%rbp), %rbx
    mov 32(%rbp), %r12
    mov 24(%rbp), %r13
    mov 16(%rbp), %r9
    mov (%rbx), %r15
    test %r12, %r12
    jns yas_lo1
    xor %r12d, %r12d
yas_lo1:
    cmp %r15, %r12
    jle yas_lo2
    mov %r15, %r12
yas_lo2:
    test %r13, %r13
    jns yas_hi1
    xor %r13d, %r13d
yas_hi1:
    cmp %r15, %r13
    jle yas_hi2
    mov %r15, %r13
yas_hi2:
    mov %r13, %r14
    sub %r12, %r14
    test %r14, %r14
    jns yas_n
    xor %r14d, %r14d
yas_n:
    mov %r14, %rdi
    imul %r9, %rdi
    cmp $8, %rdi
    jge yas_sz
    mov $8, %rdi
yas_sz:
    push %r9
    call y_alloc
    pop %r9
    mov %rax, %r15
    push %r15
    mov $24, %rdi
    call y_alloc
    pop %r15
    mov %r14, (%rax)
    mov %r14, 8(%rax)
    mov %r15, 16(%rax)
    mov %rax, %r13
    mov 16(%rbx), %rsi
    mov %r12, %rax
    imul %r9, %rax
    add %rax, %rsi
    mov %r15, %rdi
    mov %r14, %rcx
    imul %r9, %rcx
    call y_mem_copy
    mov %r13, %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_arr_eq(a, b, esz) -> bool. Structural: same length, same
# elements. esz selects the element width.
y_arr_eq:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    mov 32(%rbp), %rbx
    mov 24(%rbp), %r12
    mov 16(%rbp), %r9
    mov (%rbx), %rcx
    mov (%r12), %rdx
    cmp %rdx, %rcx
    jnz yae_ne
    mov 16(%rbx), %rbx
    mov 16(%r12), %r12
    xor %edx, %edx
yae_loop:
    cmp %rcx, %rdx
    jge yae_eq
    mov %rdx, %rax
    imul %r9, %rax
    mov %rax, %rsi
    add %rbx, %rax
    add %r12, %rsi
    cmp $1, %r9
    je yae_c1
    mov (%rax), %rax
    mov (%rsi), %rsi
    jmp yae_cn
yae_c1:
    movzbq (%rax), %rax
    movzbq (%rsi), %rsi
yae_cn:
    cmp %rsi, %rax
    jnz yae_ne
    inc %rdx
    jmp yae_loop
yae_eq:
    mov $1, %rax
    jmp yae_done
yae_ne:
    xor %eax, %eax
yae_done:
    pop %r12
    pop %rbx
    pop %rbp
    ret
y_arr_eq_str:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r12
    mov (%rbx), %r13
    mov (%r12), %rdx
    cmp %rdx, %r13
    jnz yaes_ne
    mov 16(%rbx), %rbx
    mov 16(%r12), %r12
    xor %r14d, %r14d
yaes_loop:
    cmp %r13, %r14
    jge yaes_eq
    mov (%rbx,%r14,8), %rax
    push %rax
    mov (%r12,%r14,8), %rax
    push %rax
    call y_str_eq
    add $16, %rsp
    test %rax, %rax
    jz yaes_ne
    inc %r14
    jmp yaes_loop
yaes_eq:
    mov $1, %rax
    jmp yaes_done
yaes_ne:
    xor %eax, %eax
yaes_done:
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# long -> decimal string: digits from one idiv each into a stack
# buffer, filled from the end; the remainder takes the dividend's
# sign, so negating it per digit is exact for LONG_MIN too. One
# allocation of exactly the used length.
y_long_tostr:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    sub $32, %rsp
    mov 16(%rbp), %rax
    lea -16(%rbp), %rsi
    mov $10, %rcx
ylts_loop:
    cqo
    idiv %rcx
    test %rdx, %rdx
    jns ylts_pos
    neg %rdx
ylts_pos:
    add $48, %rdx
    dec %rsi
    movb %dl, (%rsi)
    test %rax, %rax
    jnz ylts_loop
    mov 16(%rbp), %rax
    test %rax, %rax
    jns ylts_mk
    dec %rsi
    movb $45, (%rsi)
ylts_mk:
    lea -16(%rbp), %rbx
    sub %rsi, %rbx
    mov %rsi, %r12
    mov %rbx, %rdi
    add $16, %rdi
    call y_alloc
    mov %rbx, (%rax)
    xor %ecx, %ecx
ylts_cp:
    cmp %rbx, %rcx
    jge ylts_done
    movzbq (%r12,%rcx,1), %rdx
    movb %dl, 8(%rax,%rcx,1)
    inc %rcx
    jmp ylts_cp
ylts_done:
    movb $0, 8(%rax,%rbx,1)
    add $32, %rsp
    pop %r12
    pop %rbx
    pop %rbp
    ret
# print(f) / tostring(f): the float's IEEE-754 bits, as y_fmt_f takes
# them, formatted at the 6 places this has always printed. It USED to
# be the double arithmetic below -- int part by cvttsd2si, fraction
# times 1e6, +0.5, truncate -- which is round-half-up and loses the
# digits below the 53 the product carries, so print(x) and
# f"{x:.6f}" disagreed on a tie and neither always matched C:
# 3123845.1640625 printed 3123845.164063 here and 3123845.164062
# there, and 0.0000025 (whose exact value is a hair above the
# midpoint) printed 0.000002 against C's 0.000003. std/str.y's
# y_fmt_f writes the exact binary value out in decimal and rounds
# half to even, so one call gives print and the f-string the same
# text, C's answer, and -0.0 its sign (the sign is the top bit of the
# bits, which `x < 0` never sees). It also formats a magnitude at or
# past 2^63 exactly, where this used to give up with
# "<float magnitude >2^63>".
#
# Args: (bits: long, code: long, width: long, prec: long), pushed
# right to left; code 102 is 'f' with no fill, alignment, alternate
# form, grouping or sign override, width -1 none, 6 places.
y_float_tostr:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
# the float arrives as the first stack argument, not in %xmm0 (the
# old body read it from 16(%rbp) for the same reason)
    mov 16(%rbp), %rax
    push %rax
    mov $102, %rax
    push %rax
    mov $-1, %rax
    push %rax
    mov $6, %rax
    push %rax
    call y_fmt_f
    add $32, %rsp
yft_ret:
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_fmod(x, y) -> x % y: the IEEE remainder truncated toward zero, the
# one C's fmod returns -- the result keeps the sign of the dividend and
# is under |y| in magnitude. x87 had fprem for it in one instruction
# and SSE2 has nothing, so this is long division on the significands.
#
# Registers, not the stack: only gen_float_bin's `%` calls this, and it
# has both operands in SSE registers already. %xmm0 = x and %xmm1 = y
# on entry, the remainder in %xmm0 on return.
#
# Each side comes apart into a significand and an exponent: a normal
# double is (mantissa | 2^52) * 2^(field - 1075), and a subnormal has
# no implicit leading bit, so its significand is the raw mantissa at
# the fixed exponent -1074. Measured in the unit 2^-1074 that they
# share, x is mx * 2^(ex - ey + 1074) and y is my * 2^-1074, so
#
#     x % y == ((mx * 2^e) % my) * 2^ey,   e = ex - ey >= 0,
#
# because |x| >= |y| is all that is left of the early exits. mx and my
# are both under 2^53, so mx % my is one `div`, and the e passes after
# it double a remainder already known to be under my: no overflow, and
# no rounding either, since scaling by a power of two and subtracting
# an integer are both exact. Every bit pattern compared below has its
# sign cleared, so the signed jumps are the unsigned ones; this
# assembler has jb/jl/jg/jge/jle and no jae.
y_fmod:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    movq %xmm0, %rbx
    movq %xmm1, %r12
    mov $9223372036854775807, %rax
    mov %rbx, %r13
    and %rax, %r13
    and %rax, %r12
# x infinite or NaN, y zero, or y NaN: all NaN. A NaN sorts above
# infinity as a bit pattern, which is the whole test, and the order is
# what makes an infinite y answer with x itself: y is known finite by
# the time |x| < |y| runs, and the only y that reaches here as
# infinity is the one every finite x is under.
    mov $9218868437227405312, %rax
    cmp %rax, %r13
    jge yfm_nan
    test %r12, %r12
    jz yfm_nan
    cmp %rax, %r12
    jle yfm_y_le_inf
    jmp yfm_nan
yfm_y_le_inf:
    cmp %r12, %r13
    jl yfm_ret_x
# e = field(x) - field(y), plus one for each side that is subnormal:
# its significand is half as big, so it sits a power of two lower
    mov %r13, %rsi
    shr $52, %rsi
    mov %r12, %rcx
    shr $52, %rcx
    sub %rcx, %rsi
# A subnormal's significand carries no implicit bit, so its exponent is
# one lower than its field says -- +1 for x above, and the same -1 for
# y here, since e is the difference of the two.
    test %rcx, %rcx
    jnz yfm_ynorm
    dec %rsi
yfm_ynorm:
    mov %r13, %rdx
    shr $52, %rdx
    test %rdx, %rdx
    jnz yfm_got_e
    inc %rsi
yfm_got_e:
    mov %rsi, %r14
# ey: a subnormal sits at -1074, everything else at field - 1075
    test %rcx, %rcx
    jnz yfm_ey_norm
    mov $-1074, %r15
    jmp yfm_have_ey
yfm_ey_norm:
    mov %rcx, %r15
    add $-1075, %r15
yfm_have_ey:
# mx and my, with the implicit leading bit where there is one
    mov $4503599627370495, %rax
    mov %r13, %rdx
    and %rax, %rdx
    mov %r12, %rdi
    and %rax, %rdi
    mov $4503599627370496, %rax
    mov %r13, %rsi
    shr $52, %rsi
    test %rsi, %rsi
    jz yfm_mx_done
    add %rax, %rdx
yfm_mx_done:
    mov %r12, %rsi
    shr $52, %rsi
    test %rsi, %rsi
    jz yfm_my_done
    add %rax, %rdi
yfm_my_done:
# mx % my -- both fit in 53 bits, so the 128-bit divide never widens
    mov %rdi, %rcx
    mov %rdx, %rax
    xor %edx, %edx
    div %rcx
    mov %rdx, %r12
    mov %rdi, %r13
    mov $1, %rcx
yfm_loop:
    cmp %r14, %rcx
    jg yfm_put
    add %r12, %r12
    cmp %r13, %r12
    jl yfm_next
    sub %r13, %r12
yfm_next:
    inc %rcx
    jmp yfm_loop
# The remainder is r * 2^ey, and r is under 2^53, so its bit length
# and y's exponent place it exactly.
yfm_put:
    test %r12, %r12
    jz yfm_zero
    mov %r12, %rax
    xor %rcx, %rcx
# shifts needed to empty r, so the loop leaves k = the exponent
yfm_len:
    test %rax, %rax
    jz yfm_len_done
    shr $1, %rax
    inc %rcx
    jmp yfm_len
yfm_len_done:
    dec %rcx
    mov %rcx, %rsi
    mov %rsi, %rdx
    add %r15, %rdx
    add $1023, %rdx
    cmp $1, %rdx
    jl yfm_sub
    mov $52, %rcx
    sub %rsi, %rcx
    mov %r12, %rax
    shl %cl, %rax
# a normal's leading bit is implicit, and bit 52 of the pattern is the
# exponent's -- so it comes off before the field goes in
    mov $4503599627370496, %rsi
    sub %rsi, %rax
    shl $52, %rdx
    or %rdx, %rax
    jmp yfm_sign
yfm_zero:
    xor %eax, %eax
    jmp yfm_sign
# Under the smallest normal, so the value is m * 2^-1074. The bits
# that shift out are zero -- or this remainder would not be a double.
yfm_sub:
    mov %r15, %rdx
    add $1074, %rdx
    mov %rdx, %rcx
    test %rcx, %rcx
    jle yfm_sub_shr
    mov %r12, %rax
    shl %cl, %rax
    jmp yfm_sign
yfm_sub_shr:
    neg %rcx
    mov %r12, %rax
    shr %cl, %rax
    jmp yfm_sign
yfm_sign:
# The remainder carries x's sign and nothing else. A shift by 63 keeps
# bit 0, not bit 63, so the sign comes down and goes back up.
    mov %rbx, %rcx
    shr $63, %rcx
    shl $63, %rcx
    or %rcx, %rax
    movq %rax, %xmm0
    jmp yfm_done
yfm_nan:
    mov $9220233022162178560, %rax
    movq %rax, %xmm0
    jmp yfm_done
yfm_ret_x:
    mov %rbx, %rax
    movq %rax, %xmm0
yfm_done:
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_str_slice(s, lo, hi) -> NEW str = s[lo:hi], half-open and
# clamped like an array slice: lo < 0 counts from 0, hi > len stops
# at len, hi <= lo is "".
y_str_slice:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    mov 32(%rbp), %rbx
    mov 24(%rbp), %rax
    mov 16(%rbp), %r14
    mov (%rbx), %rcx
    cmp $0, %rax
    jge ysb_look
    xor %eax, %eax
ysb_look:
    cmp %rcx, %r14
    jle ysb_hiok
    mov %rcx, %r14
ysb_hiok:
    sub %rax, %r14
    jle ysb_empty
    mov %r14, %rdi
    add $16, %rdi
    mov %rax, %r12
    call y_alloc
    mov %rax, %r13
    mov %r13, %rdi
    add $8, %rdi
    mov %rbx, %rsi
    add $8, %rsi
    add %r12, %rsi
    mov %r14, %rcx
    test %rcx, %rcx
    jz ysb_nocopy
    push %r13
    push %r14
    call ysc_copy
    pop %r14
    pop %r13
ysb_nocopy:
    mov %r14, (%r13)
    movb $0, 8(%r13,%r14,1)
    mov %r13, %rax
    jmp ysb_done
ysb_empty:
    mov $16, %rdi
    call y_alloc
    mov $0, (%rax)
    movb $0, 8(%rax)
ysb_done:
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_str_index(hay, needle) -> the first i at which needle occurs in
# hay, or -1 (an empty needle never matches): a scan for the needle's
# first byte, the rest compared where it is found. Assembly, as the
# scan cost ~40 instructions a byte in Y (the assembler searches each
# of its lines).
y_str_index:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    mov 24(%rbp), %rsi
    mov 16(%rbp), %rdi
    mov $-1, %rax
    mov (%rdi), %r9
    test %r9, %r9
    jz ysi_done
    mov (%rsi), %r10
    sub %r9, %r10
    js ysi_done
    movzbq 8(%rdi), %r11
    xor %ecx, %ecx
ysi_scan:
    cmp %r10, %rcx
    jg ysi_done
    movzbq 8(%rsi,%rcx,1), %rdx
    cmp %r11, %rdx
    je ysi_first
ysi_next:
    add $1, %rcx
    jmp ysi_scan
ysi_first:
    mov %rsi, %rbx
    add %rcx, %rbx
    mov $1, %r8
ysi_rest:
    cmp %r9, %r8
    jge ysi_hit
    movzbq 8(%rbx,%r8,1), %rdx
    movzbq 8(%rdi,%r8,1), %r12
    cmp %r12, %rdx
    jne ysi_next
    add $1, %r8
    jmp ysi_rest
ysi_hit:
    mov %rcx, %rax
ysi_done:
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_str_trim(s) -> s without the spaces, tabs, newlines and carriage
# returns at its ends; s itself when there are none.
y_str_trim:
    push %rbp
    mov %rsp, %rbp
    mov 16(%rbp), %rsi
    mov (%rsi), %r9
    xor %ecx, %ecx
yst_lead:
    cmp %r9, %rcx
    jge yst_cut
    movzbq 8(%rsi,%rcx,1), %rdx
    cmp $32, %rdx
    je yst_lead1
    cmp $9, %rdx
    je yst_lead1
    cmp $10, %rdx
    je yst_lead1
    cmp $13, %rdx
    jne yst_trail
yst_lead1:
    add $1, %rcx
    jmp yst_lead
yst_trail:
    cmp %rcx, %r9
    jle yst_cut
    movzbq 7(%rsi,%r9,1), %rdx
    cmp $32, %rdx
    je yst_trail1
    cmp $9, %rdx
    je yst_trail1
    cmp $10, %rdx
    je yst_trail1
    cmp $13, %rdx
    jne yst_cut
yst_trail1:
    sub $1, %r9
    jmp yst_trail
yst_cut:
    test %rcx, %rcx
    jnz yst_slice
    mov (%rsi), %rdx
    cmp %rdx, %r9
    jne yst_slice
    mov %rsi, %rax
    pop %rbp
    ret
yst_slice:
    push %rsi
    push %rcx
    push %r9
    call y_str_slice
    add $24, %rsp
    pop %rbp
    ret
# y_str_split(s, sep) -> [str]: s cut at every non-overlapping match
# of sep; a trailing empty piece is dropped ("a," -> ["a"]), an empty
# sep gives no pieces. Assembly for the scan, as y_str_index.
y_str_split:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov $8, %rdi
    call y_alloc
    push %rax
    mov $24, %rdi
    call y_alloc
    pop %rdx
    mov %rdx, 16(%rax)
    mov %rax, %r15
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r12
    mov (%r12), %r13
    test %r13, %r13
    jz yss_done
    xor %r14d, %r14d
    xor %ecx, %ecx
yss_scan:
    mov (%rbx), %rax
    sub %r13, %rax
    cmp %rax, %rcx
    jg yss_tail
    movzbq 8(%rbx,%rcx,1), %rax
    movzbq 8(%r12), %rdx
    cmp %rdx, %rax
    jne yss_next
    mov $1, %r8
yss_rest:
    cmp %r13, %r8
    jge yss_hit
    mov %rcx, %r9
    add %r8, %r9
    movzbq 8(%rbx,%r9,1), %rax
    movzbq 8(%r12,%r8,1), %rdx
    cmp %rdx, %rax
    jne yss_next
    add $1, %r8
    jmp yss_rest
yss_hit:
    push %rcx
    push %rbx
    push %r14
    push %rcx
    call y_str_slice
    add $24, %rsp
    push %r15
    push %rax
    mov $8, %rax
    push %rax
    call y_arr_push
    add $24, %rsp
    pop %rcx
    add %r13, %rcx
    mov %rcx, %r14
    jmp yss_scan
yss_next:
    add $1, %rcx
    jmp yss_scan
yss_tail:
    mov (%rbx), %rax
    cmp %rax, %r14
    jge yss_done
    push %rbx
    push %r14
    push %rax
    call y_str_slice
    add $24, %rsp
    push %r15
    push %rax
    mov $8, %rax
    push %rax
    call y_arr_push
    add $24, %rsp
yss_done:
    mov %r15, %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_arr_cat(l, r, esz) -> NEW array = l ++ r (the copy form of
# `+`; the operands are untouched). esz is the element width.
y_arr_cat:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov 32(%rbp), %rbx
    mov 24(%rbp), %r12
    mov 16(%rbp), %r9
    mov (%rbx), %r13
    mov (%r12), %rdx
    add %rdx, %r13
    mov %r13, %rdi
    imul %r9, %rdi
    cmp $8, %rdi
    jge ycat_sz
    mov $8, %rdi
ycat_sz:
    push %r13
    call y_alloc
    pop %r13
    mov %rax, %r14
    push %r14
    mov $24, %rdi
    call y_alloc
    pop %r14
    mov %r13, (%rax)
    mov %r13, 8(%rax)
    mov %r14, 16(%rax)
    push %rax
    xor %r15d, %r15d
ycat_l:
    mov (%rbx), %rdi
    cmp %rdi, %r15
    jge ycat_r
    mov 16(%rbx), %rsi
    mov %r15, %rax
    imul %r9, %rax
    add %rsi, %rax
    mov %r15, %rsi
    imul %r9, %rsi
    add %r14, %rsi
    cmp $1, %r9
    je ycat_l1
    mov (%rax), %rdx
    mov %rdx, (%rsi)
    jmp ycat_ln
ycat_l1:
    movzbq (%rax), %rdx
    movb %dl, (%rsi)
ycat_ln:
    inc %r15
    jmp ycat_l
ycat_r:
    xor %r15d, %r15d
ycat_rl:
    mov (%r12), %rdi
    cmp %rdi, %r15
    jge ycat_done
    mov 16(%r12), %rsi
    mov %r15, %rax
    imul %r9, %rax
    add %rsi, %rax
    mov %r15, %rsi
    mov (%rbx), %rdx
    add %rdx, %rsi
    imul %r9, %rsi
    add %r14, %rsi
    cmp $1, %r9
    je ycat_r1
    mov (%rax), %rdx
    mov %rdx, (%rsi)
    jmp ycat_rn
ycat_r1:
    movzbq (%rax), %rdx
    movb %dl, (%rsi)
ycat_rn:
    inc %r15
    jmp ycat_rl
ycat_done:
    pop %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_arr_prepend(arr, val, esz) -> arr with val inserted at the
# front, IN PLACE (the header never moves — every alias sees it).
# The header's fourth word, front, counts the free element slots
# before data in its block: a prepend with front > 0 steps data
# back one slot. Otherwise the elements move to a new block with
# max(len, 8) slots of room in front and the same room behind, so
# n prepends cost O(n) moves in all, like n pushes.
y_arr_prepend:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov 32(%rbp), %rbx
    mov 24(%rbp), %r12
    mov 16(%rbp), %r9
    mov (%rbx), %rcx
    mov 24(%rbx), %rdx
    test %rdx, %rdx
    jz yapd_grow
    dec %rdx
    mov %rdx, 24(%rbx)
    mov 16(%rbx), %r13
    sub %r9, %r13
    mov %r13, 16(%rbx)
    mov 8(%rbx), %rdx
    inc %rdx
    mov %rdx, 8(%rbx)
    jmp yapd_put
yapd_grow:
    mov %rcx, %r14
    cmp $8, %r14
    jge yapd_room
    mov $8, %r14
yapd_room:
    mov 8(%rbx), %rdi
    add %r14, %rdi
    imul %r9, %rdi
    push %rcx
    push %r9
    call y_alloc
    pop %r9
    pop %rcx
    mov 16(%rbx), %r15
    mov %r14, %r13
    dec %r13
    mov %r13, 24(%rbx)
    imul %r9, %r13
    add %rax, %r13
    mov %r13, 16(%rbx)
    mov 8(%rbx), %rdx
    inc %rdx
    mov %rdx, 8(%rbx)
    xor %esi, %esi
yapd_cp:
    cmp %rcx, %rsi
    jge yapd_put
    mov %rsi, %rax
    imul %r9, %rax
    add %r15, %rax
    mov %rsi, %rdi
    inc %rdi
    imul %r9, %rdi
    add %r13, %rdi
    cmp $1, %r9
    je yapd_cp1
    mov (%rax), %rdx
    mov %rdx, (%rdi)
    jmp yapd_cpn
yapd_cp1:
    movzbq (%rax), %rdx
    movb %dl, (%rdi)
yapd_cpn:
    inc %rsi
    jmp yapd_cp
yapd_put:
    mov 16(%rbx), %r13
    cmp $1, %r9
    je yapd_p1
    mov %r12, (%r13)
    jmp yapd_pn
yapd_p1:
    mov %r12, %rdx
    movb %dl, (%r13)
yapd_pn:
    inc %rcx
    mov %rcx, (%rbx)
    mov %rbx, %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_arr_push(arr, val, esz) -> arr. esz is the element width; one
# implementation covers packed [byte] and word-per-element arrays
# alike. The header is {len, cap, data, front} and NEVER moves
# (elements live in a separate block), so growth is invisible to
# aliases, `arr += v` is truly in place, and the returned header is
# the one the caller passed in. Capacity doubles when reached (8
# first), matching yv.c's ya_push; a grown block has no room in
# front, so front becomes 0 (y_arr_prepend).
y_arr_push:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov 32(%rbp), %rbx
    mov 24(%rbp), %r12
    mov 16(%rbp), %r9
    mov (%rbx), %rcx
    mov 8(%rbx), %rdx
    cmp %rdx, %rcx
    jz yap_grow
    mov 16(%rbx), %r13
    mov %rcx, %rax
    imul %r9, %rax
    add %r13, %rax
    cmp $1, %r9
    je yap_st1
    mov %r12, (%rax)
    jmp yap_stn
yap_st1:
    mov %r12, %rdx
    movb %dl, (%rax)
yap_stn:
    inc %rcx
    mov %rcx, (%rbx)
    mov %rbx, %rax
    jmp yap_done
yap_grow:
    mov %rdx, %r13
    shl $1, %r13
    cmp $8, %r13
    jge yap_cap
    mov $8, %r13
yap_cap:
    mov %r13, %rdi
    imul %r9, %rdi
    push %rcx
    push %r9
    call y_alloc
    pop %r9
    pop %rcx
    mov %rax, %r14
    mov 16(%rbx), %r15
    mov %r13, 8(%rbx)
    mov %r14, 16(%rbx)
    xor %esi, %esi
    mov %rsi, 24(%rbx)
    push %rcx
    mov %r15, %rsi
    mov %r14, %rdi
    imul %r9, %rcx
    call y_mem_copy
    pop %rcx
    mov %rcx, %rax
    imul %r9, %rax
    add %r14, %rax
    cmp $1, %r9
    je yap_last1
    mov %r12, (%rax)
    jmp yap_lastn
yap_last1:
    mov %r12, %rdx
    movb %dl, (%rax)
yap_lastn:
    inc %rcx
    mov %rcx, (%rbx)
    mov %rbx, %rax
yap_done:
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_arr_extend(arr, other, esz) -> arr: other's elements appended
# (`arr += other` when the element types are one: native.y
# gen_opassign_arr). The block grows once, to the capacity pushing them
# one by one would reach (doubling from 8), and the elements move in
# bulk. other's length and block are read first, so `a += a` doubles a.
y_arr_extend:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov 32(%rbp), %rbx
    mov 24(%rbp), %rax
    mov 16(%rbp), %r9
    mov (%rax), %r12
    mov 16(%rax), %r13
    mov (%rbx), %r14
    mov %r14, %r15
    add %r12, %r15
    mov 8(%rbx), %rdx
    cmp %rdx, %r15
    jle yax_copy
yax_cap:
    shl $1, %rdx
    cmp $8, %rdx
    jge yax_cap1
    mov $8, %rdx
yax_cap1:
    cmp %r15, %rdx
    jl yax_cap
    mov %rdx, %rdi
    imul %r9, %rdi
    push %r9
    push %rdx
    call y_alloc
    pop %rdx
    pop %r9
    mov %rdx, 8(%rbx)
    mov 16(%rbx), %rsi
    mov %rax, 16(%rbx)
    xor %ecx, %ecx
    mov %rcx, 24(%rbx)
    mov %rax, %rdi
    mov %r14, %rcx
    imul %r9, %rcx
    call y_mem_copy
yax_copy:
    mov %r14, %rdi
    imul %r9, %rdi
    mov 16(%rbx), %rax
    add %rax, %rdi
    mov %r13, %rsi
    mov %r12, %rcx
    imul %r9, %rcx
    call y_mem_copy
    mov %r15, (%rbx)
    mov %rbx, %rax
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret
# y_mem_copy: %rcx bytes from %rsi to %rdi (apart), eight at a time,
# then the rest one by one: nothing read or written past either end.
# Clobbers %rax, %rdx and %r8.
y_mem_copy:
    xor %r8d, %r8d
    mov %rcx, %rax
    and $-8, %rax
ymc_words:
    cmp %rax, %r8
    jge ymc_bytes
    mov (%rsi,%r8,1), %rdx
    mov %rdx, (%rdi,%r8,1)
    add $8, %r8
    jmp ymc_words
ymc_bytes:
    cmp %rcx, %r8
    jge ymc_done
    movzbq (%rsi,%r8,1), %rdx
    movb %dl, (%rdi,%r8,1)
    add $1, %r8
    jmp ymc_bytes
ymc_done:
    ret
y_argv_init:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    push %r15
    mov 24(%rbp), %rbx
    mov 16(%rbp), %r13
    mov %r13, %rax
    shl $3, %rax
    cmp $8, %rax
    jge yai_sz
    mov $8, %rax
yai_sz:
    mov %rax, %rdi
    push %rbx
    push %r13
    call y_alloc
    pop %r13
    pop %rbx
    mov %rax, %r14
    push %r14
    mov $24, %rdi
    call y_alloc
    pop %r14
    mov %rax, %r15
    mov %r13, (%r15)
    mov %r13, 8(%r15)
    mov %r14, 16(%r15)
    xor %r14d, %r14d
yai_loop:
    cmp %r13, %r14
    jge yai_done
    mov (%rbx,%r14,8), %rcx
    push %rcx
    push %rbx
    push %r13
    push %r14
    push %r15
    mov %rcx, %rdi
    call y_cstr_to_str
    mov %rax, %rcx
    pop %r15
    pop %r14
    pop %r13
    pop %rbx
    add $8, %rsp
    mov 16(%r15), %rax
    mov %rcx, (%rax,%r14,8)
    inc %r14
    jmp yai_loop
yai_done:
    mov %r15, %rax
    add $8, %rsp
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
y_argv:
    mov %r15, %rax
    ret
y_cstr_to_str:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    mov %rdi, %rbx
    xor %ecx, %ecx
ycs_len:
    movzbq (%rbx,%rcx,1), %rax
    test %rax, %rax
    jz ycs_mk
    inc %rcx
    jmp ycs_len
ycs_mk:
    mov %rcx, %r13
    mov %rcx, %r14
    mov %rcx, %rdi
    add $16, %rdi
    push %rbx
    push %r13
    push %r14
    call y_alloc
    pop %r14
    pop %r13
    pop %rbx
    mov %rax, %rdi
    mov %r13, (%rdi)
    mov %r14, %rcx
    mov %rbx, %rsi
    mov %rdi, %rax
    add $8, %rax
    mov %rax, %rdi
    push %rdi
    push %rsi
    push %rcx
    push %r13
    push %r14
    push %rbx
    call ysc_copy
    pop %rbx
    pop %r14
    pop %r13
    pop %rcx
    pop %rsi
    pop %rdi
    movb $0, 8(%rdi,%r13,1)
    mov %rdi, %rax
    sub $8, %rax
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
# y_str_to_bytes(s) -> [byte]: copy the string's bytes into a
# packed array header {len, cap, data...}. One byte per element.
y_str_to_bytes:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    mov 16(%rbp), %rbx
    mov (%rbx), %r13
    mov %r13, %rdi
    cmp $8, %rdi
    jge ystb_sz
    mov $8, %rdi
ystb_sz:
    call y_alloc
    mov %rax, %r14
    push %r14
    mov $24, %rdi
    call y_alloc
    pop %r14
    mov %r13, (%rax)
    mov %r13, 8(%rax)
    mov %r14, 16(%rax)
    push %rax
    mov %rbx, %rsi
    add $8, %rsi
    mov %r14, %rdi
    mov %r13, %rcx
    call y_mem_copy
    pop %rax
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
# y_bytes_to_str(b) -> str: the inverse. The result is a string
# header {len, data..., NUL}.
y_bytes_to_str:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r13
    push %r14
    mov 16(%rbp), %rbx
    mov (%rbx), %r13
    mov 16(%rbx), %rbx
    mov %r13, %rdi
    add $16, %rdi
    call y_alloc
    mov %rax, %r14
    mov %r13, (%r14)
    mov %rbx, %rsi
    mov %r14, %rdi
    add $8, %rdi
    mov %r13, %rcx
    call y_mem_copy
    mov %r14, %rsi
    add $8, %rsi
    add %r13, %rsi
    movb $0, (%rsi)
    mov %r14, %rax
    pop %r14
    pop %r13
    pop %rbx
    pop %rbp
    ret
# y_os_openat(dirfd, path, plen, flags, mode) -> the fd, or -1.
# The shared std code names ONE entry point for both kernels (ideas/WINDOWS.md):
# here it is openat(2) with dirfd AT_FDCWD (-100) and the Linux O_* flags fs.y
# already computes. plen is passed and IGNORED -- openat(2) takes a NUL-
# terminated path, so the byte is already there. The Windows half needs the
# length to widen the path into UTF-16, so the shared signature carries it and
# only one target has a use for it.
# Arguments arrive cdecl-style, pushed right to left, so argN is the closest to
# the return address and arg1 is the furthest: for five arguments that is 8, 16,
# 24, 32 and 40 (%rsp) for args five down to one. y_os_read's three arguments at
# 24, 16 and 8 are the same rule seen from the other end. openat(2) wants four
# of the five in rdi, rsi, rdx and r10, so arg3 (plen) is stepped over.
y_os_openat:
    mov 8(%rsp), %r10
    mov 16(%rsp), %rdx
    mov 32(%rsp), %rsi
    mov 40(%rsp), %rdi
    mov $257, %eax
    syscall
    ret
# y_os_stat(dirfd, path, len, out, flags) -> 0, or -1. `out` is the caller's
# struct-stat-sized buffer and this half lets newfstatat(2) fill it whole;
# fs.y reads st_mode at long 3 and st_size at long 6, and the Windows half
# synthesizes exactly those two fields, which is the contract (see wsys.s).
# Frameless, five arguments: flags at 8(%rsp), out at 16, path at 32.
y_os_stat:
    mov 8(%rsp), %r10
    mov 16(%rsp), %rdx
    mov 32(%rsp), %rsi
    mov 40(%rsp), %rdi
    mov $262, %eax
    syscall
    test %rax, %rax
    jns yostat_ret
    mov $-1, %rax
yostat_ret:
    ret
# y_os_close(fd) -> 0, or -1. One contract on both kernels: zero for success,
# negative for failure, which is what fs.close_file's `== 0` asks for and what
# close(2) already returns. NtClose answers an NTSTATUS instead, so the Windows
# half folds "not a success" into -1 rather than handing a 0xC00000xx back as
# if it were a descriptor.
y_os_close:
    mov 8(%rsp), %rdi
    mov $3, %eax
    syscall
    test %rax, %rax
    jns yosc_ret
    mov $-1, %rax
yosc_ret:
    ret
