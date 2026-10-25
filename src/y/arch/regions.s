# regions.s -- `region { .. }` and `heap { .. }`.
# Linked only into a program whose code opens a region (native.y uses_regions:
# y_region_enter or y_region_auto_enter), so no other compile decodes it;
# arch/prelude.s keeps the trap and the two hooks (the slow path's test of the
# open region, the roots' call through the hook). Target-independent: it maps
# and unmaps through y_alloc_map and y_gc_unmap, which each target defines.
#
# All regions share one ARENA, a stack of chunks: regions are blocks, so they
# open and close in LIFO order, and a region is a MARK in the arena. Entering
# saves the bump block and the arena position; the region bumps on from there
# (a nested region from where its parent is, the outermost from the arena's
# saved position); leaving zeroes what the region used (the allocator's memory
# is always zero), gives the chunks it added back to a cache of two (or
# unmaps them) and restores both. The collector never runs inside a region and
# never sees the arena. One thread only: with threads the allocator's block is
# per thread, and an explicit region traps instead (an automatic one does
# nothing).
#
# The state is one cell, y_region:
#   +0  the innermost open region R (0: none -- the allocator is the collector's)
#   +8  the list of `heap { .. }` suspensions H
#   +16 the root walk the first suspension installs (prelude y_gc_roots)
#   +24 the arena's top chunk
#   +32 +40  the arena position {cur, end} while no region is open
#   +48 the chunk cache (two 4 MiB chunks, zeroed), +56 its count
#   +64 the bytes of chunks on the arena stack
#   +72 1 once the arena has been handed to the collector (y_region_spill):
#       automatic regions open nothing from then on
# and the two `heap { .. }` hooks the emitter calls through, y_rg_henter and
# y_rg_hleave, which the first region installs (a program with no region
# carries neither function).
#
# R is 64 bytes in the opening function's frame: +0 the enclosing open region,
# +8 +16 the bump block {cur, end} as it was, +24 the arena's top chunk at the
# mark, +32 the slow path's target (y_region_more; 0: an automatic region that
# did not open), +40 +48 the arena position at the mark, +56 1 for an automatic
# region. A chunk starts with 32 bytes: +0 the chunk below (the next, in the
# cache), +8 its length, +16 how far it was used (set when the region bumps on
# into a new chunk, or leaves it).
#
# y_region_more(%rbx = the rounded size, %r12 = the bump block), reached from
# inside y_alloc_more's frame: the next chunk of the arena, the block at its
# start, the rest the bump block's. An arena of automatic regions only that
# passes 32 MiB is handed to the collector first (y_region_spill).
y_region_more:
    mov y_region+24(%rip), %rax
    test %rax, %rax
    jz yrm_nohi
    mov 0(%r12), %rdx
    mov %rdx, 16(%rax)
yrm_nohi:
    mov y_region+64(%rip), %rax
    cmp $33554432, %rax
    jb yrm_take
    call y_region_spill
    test %rax, %rax
    jnz yam_noreg
yrm_take:
    lea 4127(%rbx), %rsi
    and $-4096, %rsi
    mov $4194304, %rdx
    cmp %rdx, %rsi
    jg yrm_map
    mov %rdx, %rsi
    mov y_region+48(%rip), %rax
    test %rax, %rax
    jz yrm_map
    mov 0(%rax), %rdx
    mov %rdx, y_region+48(%rip)
    mov y_region+56(%rip), %rdx
    dec %rdx
    mov %rdx, y_region+56(%rip)
    jmp yrm_have
yrm_map:
    mov %rsi, %r14
    call y_alloc_map
    mov %r14, %rsi
yrm_have:
    mov y_region+24(%rip), %rdx
    mov %rdx, 0(%rax)
    mov %rsi, 8(%rax)
    mov %rax, y_region+24(%rip)
    mov y_region+64(%rip), %rdx
    add %rsi, %rdx
    mov %rdx, y_region+64(%rip)
    lea (%rax,%rsi), %rdx
    mov %rdx, 8(%r12)
    add $32, %rax
    lea (%rax,%rbx), %rdx
    mov %rdx, 0(%r12)
    jmp y_alloc_out

# y_region_spill (%r12 = the bump block) -> %rax 1 when the arena was handed
# to the collector: every chunk registered as one of its own (its blocks carry
# the allocator's headers and the unused tail is zero, so the collector walks
# it like any chunk), every open region marked as not opened, and the bump
# block back to the collector's. 0, and nothing done, when an explicit region
# is open or a `heap { .. }` has suspended one: those keep their promise.
# Automatic regions then stay off for the rest of the run: a program whose
# turns are that large would otherwise map a fresh arena per turn and hand
# each to the collector, growing by one arena a turn.
y_region_spill:
    mov y_region+8(%rip), %rax
    test %rax, %rax
    jnz yrs_no
    mov y_region+0(%rip), %rax
yrs_chk:
    test %rax, %rax
    jz yrs_go
    mov 56(%rax), %rdx
    test %rdx, %rdx
    jz yrs_no
    mov 0(%rax), %rax
    jmp yrs_chk
yrs_go:
    mov y_region+24(%rip), %r13
yrs_chunk:
    test %r13, %r13
    jz yrs_done
    mov 0(%r13), %r14
    lea 32(%r13), %rdi
    mov 8(%r13), %rsi
    sub $32, %rsi
    xor %edx, %edx
    call y_gc_chunk_add
    mov %r14, %r13
    jmp yrs_chunk
yrs_done:
    mov $1, %eax
    mov %rax, y_region+72(%rip)
    xor %ecx, %ecx
    mov %rcx, y_region+24(%rip)
    mov %rcx, y_region+32(%rip)
    mov %rcx, y_region+40(%rip)
    mov %rcx, y_region+64(%rip)
    mov y_region+0(%rip), %rax
yrs_off:
    mov %rcx, 32(%rax)
    mov 0(%rax), %rdx
    test %rdx, %rdx
    jz yrs_bottom
    mov %rdx, %rax
    jmp yrs_off
yrs_bottom:
    mov 8(%rax), %rdx
    mov %rdx, 0(%r12)
    mov 16(%rax), %rdx
    mov %rdx, 8(%r12)
    mov %rcx, y_region+0(%rip)
    mov $1, %eax
    ret
yrs_no:
    xor %eax, %eax
    ret

# y_region_enter(%rdi = R): open an explicit region (`region { .. }`).
# y_region_auto_enter(%rdi = R): open one the compiler placed around a loop
# body (native.y gen_region); with threads running it opens nothing and its
# leave does nothing.
y_region_enter:
    lea y_heap(%rip), %rcx
    mov 24(%rcx), %rax
    test %rax, %rax
    jnz y_region_trap
    xor %eax, %eax
    mov %rax, 56(%rdi)
    jmp yre_go
y_region_auto_enter:
    lea y_heap(%rip), %rcx
    mov 24(%rcx), %rax
    mov y_region+72(%rip), %rdx
    or %rdx, %rax
    test %rax, %rax
    jz yre_auto
    xor %eax, %eax
    mov %rax, 32(%rdi)
    ret
yre_auto:
    mov $1, %eax
    mov %rax, 56(%rdi)
yre_go:
    mov y_region+0(%rip), %rax
    mov %rax, 0(%rdi)
    mov 0(%rcx), %rdx
    mov %rdx, 8(%rdi)
    mov 8(%rcx), %rdx
    mov %rdx, 16(%rdi)
    test %rax, %rax
    jz yre_outer
    mov 0(%rcx), %rdx
    mov %rdx, 40(%rdi)
    mov 8(%rcx), %rdx
    mov %rdx, 48(%rdi)
    jmp yre_mark
yre_outer:
    mov y_region+32(%rip), %rdx
    mov %rdx, 40(%rdi)
    mov %rdx, 0(%rcx)
    mov y_region+40(%rip), %rdx
    mov %rdx, 48(%rdi)
    mov %rdx, 8(%rcx)
yre_mark:
    mov y_region+24(%rip), %rdx
    mov %rdx, 24(%rdi)
    lea y_region_more(%rip), %rdx
    mov %rdx, 32(%rdi)
    lea y_heapblk_enter(%rip), %rdx
    mov %rdx, y_rg_henter(%rip)
    lea y_heapblk_leave(%rip), %rdx
    mov %rdx, y_rg_hleave(%rip)
    mov %rdi, y_region+0(%rip)
    ret

# y_region_leave(%rdi = R): close it. The chunks above the mark go back to the
# cache (zeroed as far as they were used) or are unmapped; the mark's own chunk
# is zeroed from the mark on. When the mark is the empty arena, the bottom 4 MiB
# chunk stays as the arena's base, so a region per turn of a loop maps nothing
# after the first and never takes the slow path for its first allocation.
y_region_leave:
    mov 32(%rdi), %rax
    test %rax, %rax
    jnz yrl_on
    ret
# The common case never left the chunk it started in: zero from the mark to
# the bump pointer and put everything back, touching no saved register.
yrl_on:
    mov y_region+24(%rip), %rax
    mov 24(%rdi), %rdx
    cmp %rdx, %rax
    jne yrl_go
    mov %rdi, %rsi
    lea y_heap(%rip), %r8
    mov 40(%rsi), %rdi
    mov 0(%r8), %rcx
    sub %rdi, %rcx
    jbe yrl_fset
    shr $3, %rcx
    xor %eax, %eax
# rep stosq (F3 48 AB): %rcx words of %rax at %rdi
    .ascii "\363\110\253"
yrl_fset:
    mov 8(%rsi), %rdx
    mov %rdx, 0(%r8)
    mov 16(%rsi), %rdx
    mov %rdx, 8(%r8)
    mov 40(%rsi), %rdx
    mov %rdx, y_region+32(%rip)
    mov 48(%rsi), %rdx
    mov %rdx, y_region+40(%rip)
    mov 0(%rsi), %rdx
    mov %rdx, y_region+0(%rip)
    ret
yrl_go:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    mov %rdi, %r12
    lea y_heap(%rip), %r13
    call yr_unwind
    mov 8(%r12), %rdx
    mov %rdx, 0(%r13)
    mov 16(%r12), %rdx
    mov %rdx, 8(%r13)
    mov 40(%r12), %rdx
    mov %rdx, y_region+32(%rip)
    mov 48(%r12), %rdx
    mov %rdx, y_region+40(%rip)
    mov 0(%r12), %rdx
    mov %rdx, y_region+0(%rip)
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

# y_region_tick(%rdi = R): the top of a turn of a loop whose region spans the
# loop (native.y gen_rg_loop_enter). The turns before are dead (escape.y), so
# once 64 KiB has piled up since the mark -- or another chunk was taken -- the
# region goes back to its mark and stays open. Otherwise nothing: a turn costs
# a call and a compare, not a region.
y_region_tick:
    mov 32(%rdi), %rax
    test %rax, %rax
    jz yrt_out
    mov y_region+24(%rip), %rax
    mov 24(%rdi), %rdx
    cmp %rdx, %rax
    jne yrt_go
    lea y_heap(%rip), %r8
    mov 0(%r8), %rcx
    mov 40(%rdi), %rdx
    sub %rdx, %rcx
    cmp $65536, %rcx
    jb yrt_out
yrt_go:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    mov %rdi, %r12
    lea y_heap(%rip), %r13
    call yr_unwind
    mov 40(%r12), %rdx
    mov %rdx, 0(%r13)
    mov 48(%r12), %rdx
    mov %rdx, 8(%r13)
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
yrt_out:
    ret

# yr_unwind(%r12 = R, %r13 = the bump block): give back what R used. Every
# chunk above its mark goes to the cache or is unmapped, the mark's chunk is
# zeroed from the mark to as far as it was used. An empty mark keeps the bottom
# 4 MiB chunk and moves the mark to its start. Clobbers %rbx and the scratch
# registers.
yr_unwind:
    mov y_region+24(%rip), %rbx
    test %rbx, %rbx
    jz yru_pop
    mov 0(%r13), %rdx
    mov %rdx, 16(%rbx)
yru_pop:
    mov y_region+24(%rip), %rbx
    mov 24(%r12), %rdx
    cmp %rdx, %rbx
    je yru_mark
    mov 0(%rbx), %rax
    test %rax, %rax
    jnz yru_release
    mov 8(%rbx), %rax
    cmp $4194304, %rax
    jne yru_release
    lea 32(%rbx), %rdi
    mov 16(%rbx), %rdx
    call yr_zero
    mov %rbx, 24(%r12)
    lea 32(%rbx), %rdx
    mov %rdx, 40(%r12)
    lea 4194304(%rbx), %rdx
    mov %rdx, 48(%r12)
    ret
yru_release:
    mov 0(%rbx), %rax
    mov %rax, y_region+24(%rip)
    mov 8(%rbx), %rsi
    mov y_region+64(%rip), %rdx
    sub %rsi, %rdx
    mov %rdx, y_region+64(%rip)
    cmp $4194304, %rsi
    jne yru_unmap
    mov y_region+56(%rip), %rax
    cmp $2, %rax
    jae yru_unmap
    inc %rax
    mov %rax, y_region+56(%rip)
    lea 32(%rbx), %rdi
    mov 16(%rbx), %rdx
    call yr_zero
    mov y_region+48(%rip), %rax
    mov %rax, 0(%rbx)
    mov %rbx, y_region+48(%rip)
    jmp yru_pop
yru_unmap:
    mov %rbx, %rdi
    call y_gc_unmap
    jmp yru_pop
yru_mark:
    test %rbx, %rbx
    jz yru_out
    mov 40(%r12), %rdi
    test %rdi, %rdi
    jz yru_out
    mov 16(%rbx), %rdx
    call yr_zero
yru_out:
    ret

# yr_zero(%rdi = from, %rdx = to): clear the words between (nothing when
# to <= from). Clobbers %rax, %rcx, %rdi.
yr_zero:
    mov %rdx, %rcx
    sub %rdi, %rcx
    jbe yrz_out
    shr $3, %rcx
    xor %eax, %eax
# rep stosq (F3 48 AB)
    .ascii "\363\110\253"
yrz_out:
    ret

# `heap { .. }`: allocate outside every open region, in the collector's heap,
# for what must outlive them (a cache a std unit fills on first use). Reached
# through y_rg_henter / y_rg_hleave, so a std unit's heap block costs a program
# with no region nothing. H is 32 bytes in the frame: +0 the innermost open
# region (0: there was none, and leaving does nothing), +8 +16 the bump block
# (the arena position), +24 the enclosing suspension. The collector's bump
# block is the one the outermost region saved, and it is written back there on
# the way out. y_region+8 lists the suspensions, so a collection inside one
# scans the arena as roots (y_gc_roots): a region value may hold the only
# reference to a value the collector owns.
y_heapblk_enter:
    mov y_region+0(%rip), %rax
    mov %rax, 0(%rdi)
    test %rax, %rax
    jz yhe_done
    lea y_heap(%rip), %rcx
    mov 0(%rcx), %rdx
    mov %rdx, 8(%rdi)
    mov %rdx, y_region+32(%rip)
    mov 8(%rcx), %rdx
    mov %rdx, 16(%rdi)
    mov %rdx, y_region+40(%rip)
    mov y_region+24(%rip), %rdx
    test %rdx, %rdx
    jz yhe_link
    mov 0(%rcx), %rsi
    mov %rsi, 16(%rdx)
yhe_link:
    mov y_region+8(%rip), %rdx
    mov %rdx, 24(%rdi)
    mov %rdi, y_region+8(%rip)
    lea y_region_roots(%rip), %rdx
    mov %rdx, y_region+16(%rip)
yhe_bottom:
    mov 0(%rax), %rdx
    test %rdx, %rdx
    jz yhe_found
    mov %rdx, %rax
    jmp yhe_bottom
yhe_found:
    mov 8(%rax), %rdx
    mov %rdx, 0(%rcx)
    mov 16(%rax), %rdx
    mov %rdx, 8(%rcx)
    xor %edx, %edx
    mov %rdx, y_region+0(%rip)
yhe_done:
    ret
y_heapblk_leave:
    mov 0(%rdi), %rax
    test %rax, %rax
    jz yhl_done
    mov %rax, %rdx
yhl_bottom:
    mov 0(%rdx), %rsi
    test %rsi, %rsi
    jz yhl_found
    mov %rsi, %rdx
    jmp yhl_bottom
yhl_found:
    lea y_heap(%rip), %rcx
    mov 0(%rcx), %rsi
    mov %rsi, 8(%rdx)
    mov 8(%rcx), %rsi
    mov %rsi, 16(%rdx)
    mov 8(%rdi), %rsi
    mov %rsi, 0(%rcx)
    mov 16(%rdi), %rsi
    mov %rsi, 8(%rcx)
    mov %rax, y_region+0(%rip)
    mov 24(%rdi), %rsi
    mov %rsi, y_region+8(%rip)
yhl_done:
    ret

# y_region_roots: scan the arena's chunks as roots while a `heap { .. }`
# suspends a region, each as far as it was used (the suspension recorded the
# top chunk's; a region opened since and closed again left zeroes).
y_region_roots:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    mov y_region+8(%rip), %rax
    test %rax, %rax
    jz yrr_out
    mov y_region+24(%rip), %rbx
yrr_chunk:
    test %rbx, %rbx
    jz yrr_out
    lea 32(%rbx), %rdi
    mov 16(%rbx), %rsi
    cmp %rsi, %rdi
    jae yrr_next
    call y_gc_scan_words
yrr_next:
    mov 0(%rbx), %rbx
    jmp yrr_chunk
yrr_out:
    pop %r12
    pop %rbx
    pop %rbp
    ret
