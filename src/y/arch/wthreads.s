# wthreads.s -- the thread runtime for the Windows target: threads.s with
# the Linux kernel calls replaced by what NT offers (arch set "wthreads", linked
# in place of "threads" when the target is Windows).
#
#   TLS     the thread's block address lives in TEB.TlsSlots[63] (%gs:5752, the
#           slot the Linux runtime keeps in %fs:24 -- the Windows prelude is
#           assembled with %fs:24 rewritten to it, arch_x64.y arch_windows_lines).
#           Not NT_TIB.SubSystemTib (%gs:24): wine's GetModuleFileNameW fails
#           while it is non-zero. The main thread's TEB is reached through its
#           own Self pointer (%gs:48).
#   spawn   kernel32!CreateThread (resolved on first use, y_w_api) on a stack of
#           8 MiB reserved; the thread routine receives the block in %rcx. The
#           handle is closed at once: join waits on the block's tid word, as on
#           Linux, and the routine clears it as its last act.
#   stacks  the collector derives a thread's stack top as word 4 + 8392704; the
#           routine stores StackBase (%gs:8) - 8392704 there before it runs anything.
#   waits   there is no futex: a join, a lock and a semaphore wait poll and
#           yield (y_w_pause), each pass inside y_gc_block_begin/end so a
#           collector cycle never waits on a sleeper -- the same shape as the
#           Linux 100 us futex timeouts. An unlock has nothing to wake.
#   fork    see y_fork in wsys.s's companion (spawns a copy of the process).
#
# Everything the collector reads is laid out exactly as threads.s lays it out.

# The first spawn moves the main thread's heap state (cur, end, used)
# into a block of its own, points %fs at it and empties the global
# block: from then on y_alloc_slow sends every thread to its own block.
# A thread's block is [cur, end, used, self, ...]: %gs:5752 is its address.
y_threads_on:
# The first spawn inside a region would hand the region's bump block to the
# main thread (regions are one-thread only: arch/prelude.s y_region_enter).
    mov y_region+0(%rip), %rdx
    test %rdx, %rdx
    jnz y_region_trap
    lea y_heap(%rip), %rcx
    mov 24(%rcx), %rdx
    test %rdx, %rdx
    jne y_threads_on_done
    mov $128, %rdi
    call y_alloc
    lea y_heap(%rip), %rcx
# y_heap+32 is set while the block is the rest of a recycled free run (y_alloc_nt),
# with live blocks after it. Then the tail gets a free header and the thread an
# empty block at 0, outside every chunk, so the sweep's clamp at `cur` never hides
# what follows. A fresh chunk's tail is handed over as it is.
    mov 32(%rcx), %rdx
    test %rdx, %rdx
    jz ythr_copy
    mov (%rcx), %rdx
    mov 8(%rcx), %rsi
    cmp %rsi, %rdx
    jae ythr_nc
    sub %rdx, %rsi
    mov %rsi, (%rdx)
ythr_nc:
    xor %edx, %edx
    mov %rdx, 0(%rax)
    mov %rdx, 8(%rax)
    jmp ythr_copied
ythr_copy:
    mov (%rcx), %rdx
    mov %rdx, 0(%rax)
    mov 8(%rcx), %rdx
    mov %rdx, 8(%rax)
ythr_copied:
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
    mov %gs:48, %rcx
    mov %rax, 5752(%rcx)
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
    mov $128, %rdi
    call y_alloc
    mov %rax, %r12
    mov %r12, 24(%r12)
# y_alloc does not zero a payload, and a recycled tcb is full of whatever the
# previous block held. Every field the collector reads must be defined BEFORE
# the tcb is linked into y_gc_threads: the state word (word 12) or the walk
# below would read a stale 1 ("parked") or 3 ("blocked") and sweep while this
# thread runs -- --gc=stress with four mutex threads hit exactly that -- and
# the bump ends (words 0/8) would start the child's allocator at a random
# address.
    xor %eax, %eax
    mov %rax, 0(%r12)
    mov %rax, 8(%r12)
    mov %rax, 88(%r12)
    mov %rax, 96(%r12)
    mov %rax, 104(%r12)
    mov %rax, 112(%r12)
    mov %rax, 120(%r12)
# Register before clone: the child starts out a registered, running thread
# (state 0), so a cycle either waits for it or scans it -- never skips it.
# The registry is a singly linked list that spawns push on and exiting threads
# take themselves off, and both are read-modify-write of the head or a link:
# two spawns at once, or a spawn beside an exit, lost an update and dropped a
# live thread from the list -- its stack never scanned, its control block and
# start closure freed under it. y_heap+64 is the spin lock for those updates.
    lea y_heap(%rip), %rdi
    add $64, %rdi
    call y_gc_lock
    mov y_gc_threads(%rip), %rdx
    mov %rdx, 80(%r12)
    mov %r12, y_gc_threads(%rip)
    mov %rbx, 64(%r12)
    lea y_heap(%rip), %rdi
    add $64, %rdi
    call y_gc_unlock
# The spare is the unused tail of a chunk some joined thread left behind, kept
# in the tcb (words 14/15), never in the tail itself: the old chain wrote the
# tail's END into its first word (y_join_done), and pass1 -- which stops a chunk
# at a ZERO header -- then read that pointer as a block header whose size runs
# past the chunk (--gc=stress on t160_threads).
    mov %gs:5752, %rcx
    mov 112(%rcx), %rax
    test %rax, %rax
    je y_spawn_stack
    mov 120(%rcx), %rdx
    mov %rcx, %r9
    xor %ecx, %ecx
    mov %rcx, 112(%r9)
    mov %rcx, 120(%r9)
    mov %rax, 0(%r12)
    mov %rdx, 8(%r12)
y_spawn_stack:
# the tcb names the process that started the thread (word 9); the thread is
# alive (tid word 8 = 1) until its routine clears it
    mov %gs:64, %rax
    mov %rax, 72(%r12)
    mov $1, %rax
    mov %rax, 48(%r12)
    xor %eax, %eax
    mov %rax, 32(%r12)
# CreateThread(0, 8392704, y_thread_start, tcb, STACK_SIZE_PARAM_IS_A_RESERVATION, 0)
    lea ywt_name_create(%rip), %r8
    lea yw_apis(%rip), %rcx
    call y_w_api_k32
    test %rax, %rax
    jz y_alloc_fail
    mov %rsp, %r13
    and $-16, %rsp
    sub $48, %rsp
    mov $65536, %rcx
    mov %rcx, 32(%rsp)
    xor %ecx, %ecx
    mov %rcx, 40(%rsp)
    mov $8392704, %rdx
    lea y_thread_start(%rip), %r8
    mov %r12, %r9
    call *%rax
    mov %r13, %rsp
    test %rax, %rax
    jz y_alloc_fail
    mov %rax, %r10
    mov $15, %eax
    syscall
    mov $16, %rdi
    call y_alloc
    lea y_join_code(%rip), %rcx
    mov %rcx, 0(%rax)
    mov %r12, 8(%rax)
    pop %r12
    pop %rbx
    pop %rbp
    ret
ywt_name_create: .string "CreateThread"
# the thread routine (a Win64 callee: rcx is the block, the callee-saved
# registers are kept): it publishes its block and stack top, calls the closure,
# keeps the value, leaves the registry and clears tid as its last act.
y_thread_start:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %rdi
    push %rsi
    push %r12
    push %r13
    push %r14
    push %r15
    sub $8, %rsp
    mov %rcx, %r12
    mov %gs:48, %rax
    mov %r12, 5752(%rax)
    mov %gs:8, %rax
    sub $8392704, %rax
    mov %rax, 32(%r12)
    xor %ebp, %ebp
    mov 64(%r12), %rax
    push %rax
    mov 0(%rax), %rax
    call *%rax
    add $8, %rsp
    mov %rax, 56(%r12)
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
    lea y_heap(%rip), %rdi
    add $64, %rdi
    call y_gc_lock
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
    lea y_heap(%rip), %rdi
    add $64, %rdi
    call y_gc_unlock
    xor %eax, %eax
    mov %rax, y_gc_stw(%rip)
    xor %eax, %eax
    mov %rax, 48(%r12)
    add $8, %rsp
    pop %r15
    pop %r14
    pop %r13
    pop %r12
    pop %rsi
    pop %rdi
    pop %rbx
    pop %rbp
    xor %eax, %eax
    ret
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
    mov 72(%rbx), %rdx
    test %rdx, %rdx
    je y_join_wait
    mov %gs:64, %rax
    cmp %rax, %rdx
    je y_join_wait
    mov $1, %rax
    push %rax
    lea ystr_thread_foreign(%rip), %rax
    push %rax
    mov $ystr_thread_foreign_end-ystr_thread_foreign, %rax
    push %rax
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
y_join_wait:
    mov 48(%rbx), %rdx
    test %rdx, %rdx
    je y_join_done
    call y_gc_block_begin
    call y_w_pause
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
# Record the unused tail in the JOINING thread's tcb (words 14/15), writing
# nothing into the chunk: the collector still finds the zero header its walk
# stops at.
    mov %gs:5752, %rcx
    mov %rdi, 112(%rcx)
    mov %rax, 120(%rcx)
y_join_value:
    mov 56(%rbx), %rax
    pop %rbx
    ret
# a mutex (%rax): word 0 is 0 when free, 1 when held, 2 when held and a thread
# may be waiting for it; word 8 is the owning process's id, 0 exactly when the
# mutex is free. A waiter marks the word 2 and polls (y_w_pause): no wake is
# needed, so an unlock is the exchange alone.
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
    mov %gs:64, %rax
    cmp %rax, %rdx
    je y_mutex_lock_free
    mov $1, %rax
    push %rax
    lea ystr_mutex_foreign(%rip), %rax
    push %rax
    mov $ystr_mutex_foreign_end-ystr_mutex_foreign, %rax
    push %rax
    call y_os_write
    add $24, %rsp
    mov $1, %rax
    push %rax
    call y_os_exit
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
    call y_w_pause
    call y_gc_block_end
    jmp y_mutex_wait
y_mutex_got:
    mov %gs:64, %rax
    mov %rax, 8(%rbx)
    pop %rbx
    ret
y_mutex_unlock:
    xor %ecx, %ecx
    xchg %rcx, 0(%rax)
    mov $0, %rdx
    mov %rdx, 8(%rax)
    ret
# 1 in %rax when the mutex (%rax) was free and is now held. Taking it with xchg
# 1 may erase a 2 (a waiter's mark), which then goes back -- and if the mutex
# was released meanwhile, that takes it.
y_mutex_trylock:
    mov %rax, %r8
    mov 8(%r8), %rdx
    test %rdx, %rdx
    je y_mutex_try_swap
    mov %gs:64, %rax
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
    mov %gs:64, %rax
    mov %rax, 8(%r8)
    mov $1, %rax
    ret
# a semaphore (%rax): its count at 0, guarded by the mutex at 8; a wait polls
# the count while it is 0
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
    call y_w_pause
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
    pop %rbx
    ret
# fork: %rax the block's closure; see y_w_fork (wsys.s)
y_fork:
    jmp y_w_fork
# state (0 running, 1 parked, 2 gone).
y_gc_safepoint:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    push %r15
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jz ygsp_done
ygsp_park:
    mov %gs:5752, %rbx
    mov %rsp, 88(%rbx)
    mov $1, %rax
    mov %rax, 96(%rbx)
ygsp_spin:
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jnz ygsp_spin
# Leaving: state := running, with a full fence (xchg), and then look at the flag
# again. A collector that began a new cycle just now saw this thread's old state
# (parked) and will not wait for it; with the fence either it sees "running" and
# waits, or this thread sees its flag and parks again. Without them the thread
# could run on through a cycle that had counted it stopped.
    mov $0, %rax
    xchg %rax, 96(%rbx)
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jnz ygsp_park
ygsp_done:
    pop %r15
    pop %r14
    pop %r13
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

