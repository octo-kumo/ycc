# The first spawn moves the main thread's heap state (cur, end, used)
# into a block of its own, points %fs at it and empties the global
# block: from then on y_alloc_slow sends every thread to its own block.
# A thread's block is [cur, end, used, self, ...]: %fs:24 is its address.
y_threads_on:
    lea y_heap(%rip), %rcx
    mov 24(%rcx), %rdx
    test %rdx, %rdx
    jne y_threads_on_done
    mov $112, %rdi
    call y_alloc
    lea y_heap(%rip), %rcx
    mov (%rcx), %rdx
    mov %rdx, 0(%rax)
    mov 8(%rcx), %rdx
    mov %rdx, 8(%rax)
    mov 16(%rcx), %rdx
    mov %rdx, 16(%rax)
    mov %rax, 24(%rax)
# The main thread is a registered thread too (tcb words 10-13 are next, rsp,
# state and the gc mark; word 4 stays 0: it has no stack mapping of its own, so
# the collector reads y_gc_stack_top for it).
    mov %rax, y_gc_threads(%rip)
# From here on the allocator's slow path parks. This is the only thing that
# puts code there: a program that never spawns keeps y_alloc_more lean.
    lea y_gc_safepoint(%rip), %rdx
    mov %rdx, y_gc_safe_fn(%rip)
    lea y_gc_alloc_free_locked(%rip), %rdx
    mov %rdx, y_gc_free_fn(%rip)
    lea y_gc_chunk_add_locked(%rip), %rdx
    mov %rdx, y_gc_chunk_fn(%rip)
    xor %edx, %edx
    mov %rdx, (%rcx)
    mov %rdx, 8(%rcx)
    mov $1, %rdx
    mov %rdx, 24(%rcx)
    mov %rax, %rsi
    mov $158, %rax
    mov $4098, %rdi
    syscall
y_threads_on_done:
    ret
# spawn: %rax the block's closure -> %rax its handle, a closure
# [y_join_code, tcb]. The thread control block is its heap block
# [cur, end, used, self, stack, spare] then [tid, value, closure];
# the thread runs on an 8 MiB stack of its own (the mapping at
# `stack`, a guard page below it), with %fs at the block. Its
# heap starts in the spawning thread's first spare chunk tail, if
# it has one: `spare` lists the tails its joins took back, each
# tail's first two words [end, next].
y_spawn:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    mov %rax, %rbx
    call y_threads_on
# Park here if a cycle owns the world: registration must not race with the
# walk that decides every thread is stopped. The closure is already in %rbx,
# which this prologue pushed, so a parked thread's roots are complete.
    call y_gc_safepoint
    mov $112, %rdi
    call y_alloc
    mov %rax, %r12
    mov %r12, 24(%r12)
# Register before clone: the child starts out a registered, running thread.
    mov y_gc_threads(%rip), %rdx
    mov %rdx, 80(%r12)
    mov %r12, y_gc_threads(%rip)
    mov %rbx, 64(%r12)
    mov %fs:24, %rcx
    mov 40(%rcx), %rax
    test %rax, %rax
    je y_spawn_stack
    mov 8(%rax), %rdx
    mov %rdx, 40(%rcx)
    mov 0(%rax), %rdx
    xor %ecx, %ecx
    mov %rcx, 0(%rax)
    mov %rcx, 8(%rax)
    mov %rax, 0(%r12)
    mov %rdx, 8(%r12)
y_spawn_stack:
    mov $9, %rax
    xor %edi, %edi
    mov $8392704, %rsi
    mov $3, %rdx
    mov $131106, %r10
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    test %rax, %rax
    js y_alloc_fail
    mov %rax, 32(%r12)
    mov %rax, %rdi
    mov $4096, %rsi
    xor %edx, %edx
    mov $10, %rax
    syscall
    mov 32(%r12), %rsi
    add $8392688, %rsi
    mov %r12, 0(%rsi)
# the tcb names the pid that started the thread, so a forked child's
# join can tell the thread is not its own (y_join_code)
# the tcb names the pid that started the thread, so a forked child's
# join can tell the thread is not its own (y_join_code)
    mov $39, %rax
    syscall
    mov %rax, 72(%r12)
    mov $56, %rax
    mov $4001536, %rdi
    lea 48(%r12), %rdx
    lea 48(%r12), %r10
    mov %r12, %r8
    syscall
    test %rax, %rax
    je y_thread_start
    js y_alloc_fail
    mov $16, %rdi
    call y_alloc
    lea y_join_code(%rip), %rcx
    mov %rcx, 0(%rax)
    mov %r12, 8(%rax)
    pop %r12
    pop %rbx
    pop %rbp
    ret
# the new thread: its stack's top holds the tcb; it calls the
# closure, keeps the value, unmaps its stack (nothing after the
# munmap touches it) and ends (exit, not exit_group: the kernel
# then clears tid, in the tcb, and wakes a join)
y_thread_start:
    mov %rsp, %rax
    mov 0(%rax), %r12
    xor %ebp, %ebp
    mov 64(%r12), %rax
    push %rax
    mov 0(%rax), %rax
    call *%rax
    mov %rax, 56(%r12)
# Deregister before the stack goes: the collector walks the tcb list and must
# not scan a mapping that is already unmapped. Taking the stop-the-world flag
# is what makes that safe -- a cycle holds it while it runs, and one that
# starts while this thread holds it gives up (y_gc_stw_begin).
    mov $1, %rax
yts_unlink_try:
    xchg %rax, y_gc_stw(%rip)
    test %rax, %rax
    jz yts_unlink_own
    mov $1, %rax
    jmp yts_unlink_try
yts_unlink_own:
    mov $2, %rax
    mov %rax, 96(%r12)
    lea y_gc_threads(%rip), %rcx
yts_unlink_loop:
    mov (%rcx), %rdx
    test %rdx, %rdx
    jz yts_unlink_done
    cmp %r12, %rdx
    je yts_unlink_hit
    lea 80(%rdx), %rcx
    jmp yts_unlink_loop
yts_unlink_hit:
    mov 80(%rdx), %rax
    mov %rax, (%rcx)
yts_unlink_done:
    xor %eax, %eax
    mov %rax, y_gc_stw(%rip)
    mov 32(%r12), %rdi
    mov $8392704, %rsi
    mov $11, %rax
    syscall
    mov $60, %rax
    xor %edi, %edi
    syscall
# join: the handle called as a closure -> the thread's value, once
# its tid is 0. The first join takes the unused tail of the
# thread's chunk (a page or more; xchg takes it once) onto the
# joining thread's spare list, for its next spawn.
y_join_code:
    mov %rsp, %rax
    mov 8(%rax), %rax
    mov 8(%rax), %rcx
    push %rbx
    mov %rcx, %rbx
# The tcb's word 9 -- one past the eight the thread code uses -- is the
# pid that started the thread (y_spawn sets
# it, and it is 0 only for a tcb no spawn has written yet). A forked
# child's copy names its parent, and that thread cannot end as far as
# this address space is concerned -- it would wait on the child's own
# copy of a tid nobody will ever clear, and the parent waits in
# wait_pid, so both stop with no diagnostic. The pid lives in %rdx
# because syscall leaves %rcx as the return address.
    mov 72(%rbx), %rdx
    test %rdx, %rdx
    je y_join_wait
    mov $39, %rax
    syscall
    cmp %rax, %rdx
    je y_join_wait
    mov $1, %rax
    mov $1, %rdi
    lea ystr_thread_foreign(%rip), %rsi
    mov $ystr_thread_foreign_end-ystr_thread_foreign, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
y_join_wait:
    mov 48(%rbx), %rdx
    test %rdx, %rdx
    je y_join_done
    call y_gc_block_begin
    mov $202, %rax
    lea 48(%rbx), %rdi
    xor %esi, %esi
    xor %r10d, %r10d
    syscall
    call y_gc_block_end
    jmp y_join_wait
y_join_done:
    xor %eax, %eax
    xchg %rax, 8(%rbx)
    mov 0(%rbx), %rdi
    mov %rax, %rsi
    sub %rdi, %rsi
    cmp $4096, %rsi
    jl y_join_value
    mov %fs:24, %rcx
    mov %rax, 0(%rdi)
    mov 40(%rcx), %rdx
    mov %rdx, 8(%rdi)
    mov %rdi, 40(%rcx)
y_join_value:
    mov 56(%rbx), %rax
    pop %rbx
    ret
# a mutex (%rax): word 0 is 0 when free, 1 when held, 2 when held
# and a thread may be waiting for it (Drepper, "Futexes Are Tricky",
# with xchg alone): a waiter marks it 2 before it sleeps, and only an
# unlock that finds 2 makes a syscall (the wake). Word 8 is the pid
# holding it, and is 0 exactly when the mutex is free.
#
# That word is what keeps a fork from hanging. A child inherits the
# lock word but nobody in the child will ever release it, so waiting
# on it waits on a futex nobody wakes -- and the parent waits in
# wait_pid as well, so the program stops with no diagnostic at all.
# Taking a mutex another process holds is undefined (POSIX says as
# much of fork in a threaded program), so now it traps; a mutex the
# child itself holds carries the child's own pid and locks as usual.
#
# Every comparison below keeps the pid in %rdx or %r8: syscall leaves
# %rcx as the return address and %r11 as the flags, so a value read
# before getpid and compared after it has to live somewhere else.
# the two trap messages this prelude can print, in the prelude so
# that a program without threads does not carry them in .rodata
ystr_mutex_foreign: .ascii "runtime error: this mutex is held by another process (a fork) and a lock held across a fork is undefined\n"
ystr_mutex_foreign_end:
ystr_thread_foreign: .ascii "runtime error: this thread belongs to another process (a fork) and cannot end in the child\n"
ystr_thread_foreign_end:
y_mutex_lock:
    push %rbx
    mov %rax, %rbx
    mov 8(%rbx), %rdx
    test %rdx, %rdx
    je y_mutex_lock_free
    mov $39, %rax
    syscall
    cmp %rax, %rdx
    je y_mutex_lock_free
    mov $1, %rax
    mov $1, %rdi
    lea ystr_mutex_foreign(%rip), %rsi
    mov $ystr_mutex_foreign_end-ystr_mutex_foreign, %rdx
    syscall
    mov $231, %rax
    mov $1, %rdi
    syscall
y_mutex_lock_free:
    mov $1, %rcx
    xchg %rcx, 0(%rbx)
    test %rcx, %rcx
    je y_mutex_got
y_mutex_wait:
    mov $2, %rcx
    xchg %rcx, 0(%rbx)
    test %rcx, %rcx
    je y_mutex_got
    call y_gc_block_begin
    mov $202, %rax
    mov %rbx, %rdi
    mov $128, %rsi
    mov $2, %rdx
    xor %r10d, %r10d
    syscall
    call y_gc_block_end
    jmp y_mutex_wait
y_mutex_got:
    mov $39, %rax
    syscall
    mov %rax, 8(%rbx)
    pop %rbx
    ret
y_mutex_unlock:
    xor %ecx, %ecx
    xchg %rcx, 0(%rax)
# %rcx is the word just taken (0, 1 or 2) and decides the wake below;
# the owner goes to 0, which is what "free" means here
    mov $0, %rdx
    mov %rdx, 8(%rax)
    cmp $2, %rcx
    jne y_mutex_free
    mov %rax, %rdi
    mov $202, %rax
    mov $129, %rsi
    mov $1, %rdx
    syscall
y_mutex_free:
    ret
# 1 in %rax when the mutex (%rax) was free and is now held. Taking
# it with xchg 1 may erase a 2 (a waiter's mark), which then goes
# back -- and if the mutex was released meanwhile, that takes it.
# The mutex is kept in %r8 through the whole helper, because the owner
# check calls getpid and syscall leaves %rax as the pid -- it would
# have taken the mutex pointer with it (a try_lock of a held mutex
# then swapped 1 into the pid's address, and the program faulted).
y_mutex_trylock:
    mov %rax, %r8
    mov 8(%r8), %rdx
    test %rdx, %rdx
    je y_mutex_try_swap
    mov $39, %rax
    syscall
    cmp %rax, %rdx
    je y_mutex_try_swap
    xor %eax, %eax
    ret
y_mutex_try_swap:
    mov $1, %rcx
    xchg %rcx, 0(%r8)
    test %rcx, %rcx
    je y_mutex_took
    cmp $2, %rcx
    jne y_mutex_busy
    xchg %rcx, 0(%r8)
    test %rcx, %rcx
    je y_mutex_took
y_mutex_busy:
    xor %eax, %eax
    ret
y_mutex_took:
    mov $39, %rax
    syscall
    mov %rax, 8(%r8)
    mov $1, %rax
    ret
# a semaphore (%rax): its count at 0, guarded by the mutex at 8; a
# wait sleeps on the count while it is 0
y_sem_wait:
    push %rbx
    mov %rax, %rbx
y_sem_again:
    lea 8(%rbx), %rax
    call y_mutex_lock
    mov 0(%rbx), %rcx
    test %rcx, %rcx
    je y_sem_sleep
    sub $1, %rcx
    mov %rcx, 0(%rbx)
    lea 8(%rbx), %rax
    call y_mutex_unlock
    pop %rbx
    ret
y_sem_sleep:
    lea 8(%rbx), %rax
    call y_mutex_unlock
    call y_gc_block_begin
    mov $202, %rax
    mov %rbx, %rdi
    mov $128, %rsi
    xor %edx, %edx
    xor %r10d, %r10d
    syscall
    call y_gc_block_end
    jmp y_sem_again
y_sem_post:
    push %rbx
    mov %rax, %rbx
    lea 8(%rbx), %rax
    call y_mutex_lock
    mov 0(%rbx), %rcx
    add $1, %rcx
    mov %rcx, 0(%rbx)
    lea 8(%rbx), %rax
    call y_mutex_unlock
    mov $202, %rax
    mov %rbx, %rdi
    mov $129, %rsi
    mov $1, %rdx
    syscall
    pop %rbx
    ret
# fork: %rax the block's closure; the child runs it and ends (0),
# the parent gets the pid (or -errno)
y_fork:
    push %rbx
    mov %rax, %rbx
    mov $57, %rax
    syscall
    test %rax, %rax
    je y_fork_child
    pop %rbx
    ret
y_fork_child:
    push %rbx
# The child has one thread: the registry must name only it, or a cycle here
# would wait for the parent's threads, which do not exist in this process.
    mov y_gc_threads(%rip), %rax
    test %rax, %rax
    jz y_fork_child_go
    mov %fs:24, %rax
    xor %ecx, %ecx
    mov %rcx, 80(%rax)
    mov %rcx, 88(%rax)
    mov %rcx, 96(%rax)
    mov %rax, y_gc_threads(%rip)
    mov %rcx, y_gc_parked(%rip)
    mov %rcx, y_gc_stw(%rip)
y_fork_child_go:
    mov 0(%rbx), %rax
    call *%rax
    mov $231, %rax
    xor %edi, %edi
    syscall

# y_gc_safepoint: park while a cycle owns the world. Called through
# y_gc_safe_fn from the allocator's slow path (every register is already pushed
# there, so publishing %rsp publishes the roots), and from spawn before a
# thread is registered. Word 11 of the tcb is the published %rsp, word 12 the
# state (0 running, 1 parked, 2 gone).
y_gc_safepoint:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jz ygsp_done
    mov %fs:24, %rbx
    mov %rsp, 88(%rbx)
    mov $1, %rax
    mov %rax, 96(%rbx)
ygsp_spin:
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jnz ygsp_spin
    mov $0, %rax
    mov %rax, 96(%rbx)
ygsp_done:
    pop %r12
    pop %rbx
    pop %rbp
    ret

# y_gc_alloc_free_locked(p) / y_gc_chunk_add_locked(base, size, dedicated): the
# shared-memory halves of the slow path, with y_gc_lk held. Ordering is always
# y_gc_lk then y_gc_meta_alloc's own lock (never the reverse).
y_gc_alloc_free_locked:
    push %rbp
    mov %rsp, %rbp
    push %rdi
    lea y_gc_lk(%rip), %rdi
    call y_gc_lock
    pop %rdi
    call y_gc_alloc_free
    push %rax
    lea y_gc_lk(%rip), %rdi
    call y_gc_unlock
    pop %rax
    pop %rbp
    ret

y_gc_chunk_add_locked:
    push %rbp
    mov %rsp, %rbp
    push %rdi
    push %rsi
    push %rdx
    lea y_gc_lk(%rip), %rdi
    call y_gc_lock
    pop %rdx
    pop %rsi
    pop %rdi
    call y_gc_chunk_add
    push %rax
    lea y_gc_lk(%rip), %rdi
    call y_gc_unlock
    pop %rax
    pop %rbp
    ret

