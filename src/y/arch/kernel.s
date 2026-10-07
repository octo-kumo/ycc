# kernel.s -- the kernel half of the arch prelude (`ycc --kernel`).
#
# The blocks of prelude.s that reach a kernel -- mmap through y_alloc_map,
# write/read/exit through y_os_*, and the five trap stubs -- are WRONG in a
# freestanding payload: they are raw Linux syscalls.  This file replaces them
# whole, exactly the way wsys.s replaces them for Windows (arch_x64.y's
# arch_replaced_lines), and adds the pieces a kernel needs and a hosted
# program never does: the 16550 serial port, the 8259 PIC, the IDT, and a
# halt loop to end in.
#
# Every routine here is 64-bit code reached from Y through `ndef` (std/kernel.y)
# or from another block of this file.  Nothing is linked into a normal
# program: the blocks carry `add:`/`replace:` markers and the tree shaker
# drops what a kept body does not call, so hello.y is byte-identical with and
# without this file's existence.
#
# The calling convention is prelude.s's, because Y calls these: arguments are
# pushed left to right by the caller, so the LAST parameter is the lowest, at
# 8(%rsp) for a one-argument frameless routine.  The `_raw` variants take
# their argument in a register instead, so one asm block can call another
# without touching the stack; a Y-facing wrapper for them is two lines.

#=== add: y_kernel_halt ===
# There is nothing to return to and nothing to schedule: stop the CPU until
# the next interrupt, forever.  The emitter's exit, exit(N), a triple fault
# and a panic all land here.
y_kernel_halt:
    cli
    hlt
    jmp y_kernel_halt

#=== add: y_kernel_idle ===
# Wait for interrupts with them ENABLED: `hlt` wakes on the next one.  A
# kernel whose work is done by handlers idles here rather than halting,
# because y_kernel_halt's `cli` would never let another one in.
y_kernel_idle:
    sti
y_ki_loop:
    hlt
    jmp y_ki_loop

#=== add: y_kernel_sti ===
# Let interrupts in (and back out).  A kernel's top level does this once the
# IDT and the PIC are ready; nothing here does it for it.
y_kernel_sti:
    sti
    ret

#=== add: y_kernel_cli ===
y_kernel_cli:
    cli
    ret

#=== add: y_serial_write_raw ===
# %rsi = bytes, %rdx = count.  The one place bytes leave the machine, so the
# console is one label away when the payload wants one.
# The count lives in %rcx, not %rdx: the port number has to be in %dx (only
# DX can be an in/out register operand), so y_serial_putb_raw clobbers %rdx
# on every byte.  Keeping the loop counter there made the first write stop
# after the 1021 bytes it took %rdx to come back down to zero -- the message
# arrived followed by a kilobyte of zeros, and the machine got no further.
y_serial_write_raw:
    mov %rdx, %rcx
    cmp $0, %rcx
    je y_swr_done
y_swr_loop:
    movzbq (%rsi), %rdi
    call y_serial_putb_raw
    add $1, %rsi
    sub $1, %rcx
    cmp $0, %rcx
    jne y_swr_loop
y_swr_done:
    ret

#=== add: y_serial_putb_raw ===
# %dil = the byte.  Wait for the transmitter to empty (LSR bit 5), then
# write the data register.  Polled: the transmit interrupt is never enabled.
y_serial_putb_raw:
    mov $1021, %edx
y_spb_wait:
    inb %dx, %al
    movzbq %al, %rax
    and $32, %rax
    cmp $0, %rax
    je y_spb_wait
    mov $1016, %edx
    mov %rdi, %rax
    outb %al, %dx
    ret

#=== add: y_serial_putb ===
# y_serial_putb(c: long) -- the Y-facing form, argument on the stack.
y_serial_putb:
    mov 8(%rsp), %rdi
    jmp y_serial_putb_raw

#=== add: y_serial_read_raw ===
# The data register, read without polling: the receive interrupt has already
# said there is a byte.  Result in %rax.
y_serial_read_raw:
    mov $1016, %edx
    inb %dx, %al
    movzbq %al, %rax
    ret

#=== add: y_serial_getb ===
# y_serial_getb() -> long: block until a byte arrives, then answer it.
y_serial_getb:
    mov $1021, %edx
y_sgb_wait:
    inb %dx, %al
    movzbq %al, %rax
    and $1, %rax
    cmp $0, %rax
    je y_sgb_wait
    jmp y_serial_read_raw

#=== add: y_serial_init ===
# COM1 at 38400 8N1, FIFO on, OUT2 set (without OUT2 the UART's interrupt
# never reaches the PIC).  The receiver interrupt itself stays OFF until
# y_serial_irq_on, so a kernel that never enables it never takes IRQ4.
y_serial_init:
    mov $1017, %edx
    mov $0, %eax
    outb %al, %dx
    mov $1019, %edx
    mov $128, %eax
    outb %al, %dx
    mov $1016, %edx
    mov $3, %eax
    outb %al, %dx
    mov $1017, %edx
    mov $0, %eax
    outb %al, %dx
    mov $1019, %edx
    mov $3, %eax
    outb %al, %dx
    mov $1018, %edx
    mov $199, %eax
    outb %al, %dx
    mov $1020, %edx
    mov $11, %eax
    outb %al, %dx
    ret

#=== add: y_serial_irq_on ===
# IER bit 0: "received data available" raises IRQ4.
y_serial_irq_on:
    mov $1017, %edx
    mov $1, %eax
    outb %al, %dx
    ret

#=== add: y_pic_remap ===
# The 8259s come out of reset with vectors 0x08..0x0F, on top of the CPU's
# own exceptions.  Move them to 0x20..0x2F: master IRQ0-7, slave IRQ8-15.
# Master mask 0xEF leaves IRQ4 (the UART) open and nothing else; the slave is
# masked entirely.
y_pic_remap:
    mov $32, %edx
    mov $17, %eax
    outb %al, %dx
    mov $160, %edx
    mov $17, %eax
    outb %al, %dx
    mov $33, %edx
    mov $32, %eax
    outb %al, %dx
    mov $161, %edx
    mov $40, %eax
    outb %al, %dx
    mov $33, %edx
    mov $4, %eax
    outb %al, %dx
    mov $161, %edx
    mov $2, %eax
    outb %al, %dx
    mov $33, %edx
    mov $1, %eax
    outb %al, %dx
    mov $161, %edx
    mov $1, %eax
    outb %al, %dx
    mov $33, %edx
    mov $239, %eax
    outb %al, %dx
    mov $161, %edx
    mov $255, %eax
    outb %al, %dx
    ret

#=== add: y_pic_eoi ===
# y_pic_eoi(irq: long) -- irq is the LINE (0..15).  A slave line needs the
# slave acknowledged first, then the master.
y_pic_eoi:
    mov 8(%rsp), %rdi
    cmp $8, %rdi
    jl y_pe_master
    mov $160, %edx
    mov $32, %eax
    outb %al, %dx
y_pe_master:
    mov $32, %edx
    mov $32, %eax
    outb %al, %dx
    ret





#=== add: y_mb_info_get ===
# The Multiboot info structure's physical address, as the loader left it in
# %ebx and the 64-bit entry stored it (arch_x64.y's kernel head).  0 when
# there is none, which is what the memory-map readers check for.
y_mb_info_get:
    mov y_mb_info(%rip), %rax
    ret

#=== add: y_kernel_end_get ===
# The address one past everything the image occupies: the first byte of RAM
# a physical page allocator may hand out.
y_kernel_end_get:
    lea y_kernel_end(%rip), %rax
    ret

#=== add: y_cr3_get ===
# The three control-register instructions are raw bytes: the in-tree encoder
# has no control-register operand (its register file is the GPRs and XMM),
# and one 3-byte `.ascii` is cheaper than a new operand kind in both copies
# of the compiler.  0F 20 /r is `mov %crN, %r64`, 0F 22 /r the other way.
y_cr3_get:
    .ascii "\017\040\330"
    ret

#=== add: y_cr3_set ===
# y_cr3_set(dir) -> void: the address-space switch, and the whole of it.
y_cr3_set:
    mov 8(%rsp), %rax
    .ascii "\017\042\330"
    ret

#=== add: y_invlpg ===
# y_invlpg(vaddr): drop one page from the TLB.  0F 01 /7 takes a memory
# operand and nothing else, so the address comes off the stack into %rax.
y_invlpg:
    mov 8(%rsp), %rax
    .ascii "\017\001\070"
    ret

#=== add: y_cr2_get ===
# CR2 holds the faulting address of the last #PF: what a page-fault report
# needs and what no GPR carries.
y_cr2_get:
    .ascii "\017\040\320"
    ret

#=== replace: y_alloc_map ===
# The page source under y_alloc.  A hosted build asks mmap; a kernel has no
# mmap, so this bumps a region of RAM that std/kernel.y's y_heap_init chose
# (as DIRECT-MAP addresses: the kernel's own identity map is one 2 MB page, so
# RAM above it is only reachable through the direct map).
#
# The region is chosen lazily, on the FIRST allocation rather than by a boot
# step, because a kernel program's globals can allocate before its top level
# runs.  y_heap_init is in std/kernel.y and is kept by the tree shaker as the
# helper a kept prelude block calls; a kernel program that does not link that
# module gets "undefined label 'y_heap_init'" from the assembler, which is the
# right complaint.
#
# Called with %rsi = the size to hand over; answers its base in %rax, and
# every size y_alloc_more asks for is page-aligned, so the bases are too.
# ── the collector, switched off ─────────────────────────────────────────
# A kernel image must not have the collector: the allocator here is the bump
# allocator, the collector's chunk path ends in y_gc_unmap (a munmap SYSCALL),
# and its stack base comes from a hosted _start a kernel does not have.
#
# These are `replace:` blocks rather than plain labels, and that is the whole
# point: label resolution is LAST-WINS, master's collector lives later in
# arch/prelude.s than y_alloc_map does, and a plain label here therefore loses
# to it (measured: a kernel -S listing showed y_gc_maybe with the PRELUDE's
# body, and a kernel then faulted reading address 0 before its first byte of
# output, reproducible with a program that never allocates).  Replacing the
# block drops the prelude's copy, the same way `replace: y_alloc_map` drops
# the hosted mmap version a few lines down.
#
# They are internal asm-to-asm calls, so arguments arrive in %rdi/%rsi and not
# on the stack: y_gc_chunk_add(base, size) -> base, y_gc_maybe() -> 0 (nothing
# collected), y_gc_alloc_free(...) -> 0 (no free run), y_gc_unmap(addr, len) ->
# nothing to unmap, since the bump never frees.
#=== replace: y_gc_maybe ===
y_gc_maybe:
    xor %eax, %eax
    ret

#=== replace: y_gc_alloc_free ===
y_gc_alloc_free:
    xor %eax, %eax
    ret

#=== replace: y_gc_chunk_add ===
y_gc_chunk_add:
    mov %rdi, %rax
    ret

#=== replace: y_gc_unmap ===
y_gc_unmap:
    ret

y_alloc_map:
    mov y_heap_limit(%rip), %rdx
    test %rdx, %rdx
    jne y_am_ram
    push %rsi
    call y_heap_init
    pop %rsi
    mov y_heap_limit(%rip), %rdx
    test %rdx, %rdx
    je y_alloc_fail
y_am_ram:
    mov y_heap_next(%rip), %rax
    test %rax, %rax
    jne y_am_have
    mov y_heap_bias(%rip), %rax
    test %rax, %rax
    je y_alloc_fail
y_am_have:
    mov %rax, %r8
    add %rsi, %r8
    cmp %rdx, %r8
    jg y_alloc_fail
    mov %r8, y_heap_next(%rip)
    ret

#=== add: y_heap_region_set ===
# y_heap_region_set(start, limit) -> void: hand the Y heap the PHYSICAL RAM
# region it will use for the rest of the kernel's life.  The direct-map base is
# added HERE rather than by the caller because this can run before the compiler
# module's globals are initialized -- the first allocation may be another
# module's global initializer -- and a `const` read that early reads zero.
#
#   y_heap_start  physical, the boundary the page allocator stops at
#   y_heap_bias   the direct-map address of that boundary
#   y_heap_limit  ditto for the top: what the bump is compared against
y_heap_region_set:
    mov $18446612682070032384, %r10
    mov 8(%rsp), %rax
    add %r10, %rax
    mov %rax, y_heap_limit(%rip)
    mov 16(%rsp), %rax
    mov %rax, y_heap_start(%rip)
    mov %rax, %rdx
    add %r10, %rdx
    mov %rdx, y_heap_bias(%rip)
    mov %rdx, y_heap_next(%rip)
    ret

#=== add: y_heap_start_get ===
y_heap_start_get:
    mov y_heap_start(%rip), %rax
    ret

#=== add: y_heap_bias_get ===
y_heap_bias_get:
    mov y_heap_bias(%rip), %rax
    ret

#=== add: y_heap_limit_get ===
y_heap_limit_get:
    mov y_heap_limit(%rip), %rax
    ret

#=== add: y_syscall_entry ===
# The SYSCALL entry, addressed by LSTAR.  The instruction has already masked
# the flags FMASK names, put the return rip in %rcx and the flags in %r11, and
# left %rsp on the USER stack -- which is the one thing it does not change, so
# the first move here is to take a kernel one.
#
# What is built is the whole state a task needs to be left and resumed:
#
#   [SS][RSP][RFLAGS][CS][RIP]      an IRETQ frame, RIP lowest
#   [rax][rdi][rsi][rdx][r10][r8][r9]
#                                   the user's caller-saved registers, which
#                                   are also the dispatcher's arguments
#
# The frame goes on FIRST, and in that order, because IRETQ pops RIP first and
# has to find it at the lowest address; the argument slots go below it, so the
# pop that restores the user's registers is also what uncovers the frame.  The
# dispatcher's answer is written into the saved rax slot -- 48(%rsp) after the
# call, the seventh word up; 56 is RIP, and writing the answer there is a
# return to address 6 -- so the last pop IS the return value.  IRETQ restores only
# RIP/CS/RFLAGS/RSP/SS, which is why the registers are popped by hand.
#
# The layout at the switch point -- and this is the WHOLE contract between the
# two entry paths, because a task suspended in one is resumed in the other:
#
#   [r9][r8][r10][rdx][rsi][rdi][rax][r11][rcx][RIP][CS][RFLAGS][RSP][SS]
#
# The first seven are the dispatcher's arguments.  r11 and rcx sit above them
# so that an INTERRUPT stub, which has to save those two by hand, can produce
# the same shape; the syscall path needs the slots only for that reason, since
# its IRETQ restores both from the frame.
#
# The syscall number is pushed above the frame first and read back into place
# seven words later (56(%rsp) from the RIP, with rcx and r11 in between):
# %rax is the frame's scratch, and the number belongs just ABOVE %rdi, where
# the seventh pop finds it.
#
# The frame pointer is published BEFORE the dispatcher runs, not after: a
# handler that has to copy the caller's frame (fork) or complete a suspended
# syscall later (wait4) reaches it through y_cur_task_rsp.
#
# A task switch is a stack switch at the marked point: every task that is
# switched out is suspended there with %rsp saved into one fixed word, and
# resuming one loads its %rsp and pops ITS registers and frame.  Nothing else
# is saved, which is why the kernel needs no context-switch assembly -- and why
# the switch happens on the way OUT (the plan's non-preemptible kernel: no
# locks anywhere, the timer only sets a flag).
y_syscall_entry:
    mov %rsp, y_user_rsp(%rip)
    mov y_cur_kstack(%rip), %rsp
    push %rax
    mov $27, %rax
    push %rax
    mov y_user_rsp(%rip), %rax
    push %rax
    push %r11
    mov $35, %rax
    push %rax
    push %rcx
    push %rcx
    push %r11
    mov 56(%rsp), %rax
    push %rax
    push %rdi
    push %rsi
    push %rdx
    push %r10
    push %r8
    push %r9
    mov %rsp, y_cur_task_rsp(%rip)
    call y_sys_dispatch
    mov %rax, 48(%rsp)
    call y_sched_pick
    test %rax, %rax
    jz y_se_same
    mov %rax, %rsp
y_se_same:
    pop %r9
    pop %r8
    pop %r10
    pop %rdx
    pop %rsi
    pop %rdi
    pop %rax
    pop %r11
    pop %rcx
    iretq

#=== add: y_syscall_entry_addr ===
# Where the syscall entry is, for LSTAR.
y_syscall_entry_addr:
    lea y_syscall_entry(%rip), %rax
    ret

#=== add: y_cur_kstack_set ===
# y_cur_kstack_set(top): the running task's kernel stack -- where SYSCALL lands
# and where the TSS's RSP0 points, so it must be updated on every switch.
y_cur_kstack_set:
    mov 8(%rsp), %rax
    mov %rax, y_cur_kstack(%rip)
    ret

#=== add: y_cur_task_rsp_get ===
# The %rsp of the frame the running task was suspended at.  The entry stub
# writes it just before calling the scheduler, which is what makes a task
# switch a stack switch and nothing more.
y_cur_task_rsp_get:
    mov y_cur_task_rsp(%rip), %rax
    ret

#=== add: y_enter_frame ===
# y_enter_frame(rsp): resume a suspended frame.  The syscall entry's tail, nine
# register slots and an IRETQ, and the way a task is started for the first time
# -- a switch *inside* the scheduler needs no such thing, because every
# suspended task is suspended at exactly this shape.  It has to be the SAME
# tail as the stubs': popping seven here and nine there is an IRETQ with the
# wrong frame.
y_enter_frame:
    mov 8(%rsp), %rsp
    pop %r9
    pop %r8
    pop %r10
    pop %rdx
    pop %rsi
    pop %rdi
    pop %rax
    pop %r11
    pop %rcx
    iretq

#=== add: y_enter_user ===
# y_enter_user(rip, rsp, rflags): leave for ring 3.  The iretq frame is
# [SS][RSP][RFLAGS][CS][RIP] and the CPU pops it in that order, so it is built
# in reverse; the two selectors are the user ones with RPL 3, which is what
# STAR's upper half also encodes for SYSRET (0x1B data, 0x23 code).
y_enter_user:
    mov 8(%rsp), %rax
    mov 16(%rsp), %rdx
    mov 24(%rsp), %rcx
    mov $27, %r8
    push %r8
    push %rdx
    push %rax
    mov $35, %r9
    push %r9
    push %rcx
    iretq

#=== add: y_lgdt ===
# y_lgdt(addr): load a GDT whose 10-byte descriptor the caller built in memory
# (std/kernel.y builds it with two aligned 64-bit writes).  `lgdt m16&64` has
# no mnemonic in the in-tree encoder, so it is three raw bytes: 0F 01 /2.
y_lgdt:
    mov 8(%rsp), %rax
    .ascii "\017\001\020"
    ret

#=== add: y_ltr ===
# y_ltr(sel): load the task register with a TSS selector.  0F 00 /3, and the
# only instruction here that the encoder cannot spell.  The selector is loaded
# as a full GPR -- `ltr %ax` reads only the low 16 bits, and `mov r16, m16` is
# a size the encoder wants spelled, which a GPR load is not.
y_ltr:
    mov 8(%rsp), %rax
    .ascii "\017\000\330"
    ret

#=== add: y_tr_get ===
# The task register, as a selector: 0x28 once y_ltr has run.  0F 00 /1.
y_tr_get:
    .ascii "\017\000\310"
    and $65535, %rax
    ret

#=== add: y_kernel_stack_top_get ===
# The boot kernel stack's top: what the TSS's RSP0 points at, so a ring-3
# interrupt lands on kernel memory.  M2 gives each task one of its own.
y_kernel_stack_top_get:
    lea y_kernel_stack_top(%rip), %rax
    ret

#=== add: y_msr_read ===
# y_msr_read(reg) -> value.  EFER, STAR, LSTAR and FMASK are the ones the
# syscall path needs; rdmsr splits the answer across edx:eax.
y_msr_read:
    mov 8(%rsp), %rcx
    .ascii "\017\062"
    shl $32, %rdx
    or %rdx, %rax
    ret

#=== add: y_msr_write ===
# y_msr_write(reg, value).  wrmsr reads edx:eax.
y_msr_write:
    mov 8(%rsp), %rdx
    mov %rdx, %rax
    shr $32, %rdx
    mov 16(%rsp), %rcx
    .ascii "\017\060"
    ret

#=== add: y_kexit ===
# kexit(code): leave qemu through the isa-debug-exit device, port 0x501.  The
# DEVICE applies the encoding -- it exits with (value << 1) | 1 -- so the code
# goes out as it came in, which is why a `kexit(7)` is a status of 15 at the
# runner.  A freestanding payload has nobody to return a status to, so this is
# the test harness's verdict path.  Interrupts are off because this is the
# machine's last instruction.
y_kexit:
    cli
    mov 8(%rsp), %rax
    mov $1281, %edx
    outb %al, %dx
    jmp y_kernel_halt

#=== replace: y_os_exit ===
# exit(N): a kernel has no one to return the status to.
y_os_exit:
    jmp y_kernel_halt

#=== replace: y_os_write ===
# y_os_write(fd, buf, len) -> len.  Stdout and stderr both mean COM1; there
# is nowhere else for them to go.  This is what makes `print`/`puts` work in
# a kernel without a line of std changing.
y_os_write:
    mov 8(%rsp), %rdx
    mov 16(%rsp), %rsi
    push %rdx
    call y_serial_write_raw
    pop %rax
    ret

#=== replace: y_os_read ===
# y_os_read(fd, buf, len) -> 1, one byte at a time from COM1.  Blocking, so
# the polling path and the IRQ path agree on the byte order.
y_os_read:
    mov 16(%rsp), %rsi
    mov 8(%rsp), %rdx
    cmp $0, %rdx
    jle y_or_none
    call y_serial_getb
    mov %al, (%rsi)
    mov $1, %rax
    ret
y_or_none:
    mov $0, %rax
    ret

#=== replace: y_div_zero ===
y_div_zero:
    lea ystr_divzero(%rip), %rsi
    mov $ystr_divzero_end-ystr_divzero, %rdx
    call y_serial_write_raw
    jmp y_kernel_halt

#=== replace: y_oob ===
y_oob:
    lea ystr_oob(%rip), %rsi
    mov $ystr_oob_end-ystr_oob, %rdx
    call y_serial_write_raw
    jmp y_kernel_halt

#=== replace: y_cast_trap ===
y_cast_trap:
    lea ystr_cast(%rip), %rsi
    mov $ystr_cast_end-ystr_cast, %rdx
    call y_serial_write_raw
    jmp y_kernel_halt

#=== replace: y_alloc_fail ===
y_alloc_fail:
    lea ystr_oom(%rip), %rsi
    mov $ystr_oom_end-ystr_oom, %rdx
    call y_serial_write_raw
    jmp y_kernel_halt

#=== replace: y_opt_unwrap ===
y_opt_unwrap:
    lea ystr_opt(%rip), %rsi
    mov $ystr_opt_end-ystr_opt, %rdx
    call y_serial_write_raw
    jmp y_kernel_halt
