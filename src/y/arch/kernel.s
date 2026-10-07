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
# mmap, so this bumps through y_kheap, a 16 MB .bss reservation (arch_x64.y's
# arch_kernel_bss) whose zero-filled pages cost RAM and no file bytes.
# Called with %rsi = the size to hand over; answers its base in %rax, and
# every size y_alloc_more asks for is page-aligned, so the bases are too.
y_alloc_map:
    mov y_kheap_used(%rip), %rax
    lea y_kheap(%rip), %rdx
    add %rdx, %rax
    mov y_kheap_used(%rip), %r8
    add %rsi, %r8
    mov %r8, y_kheap_used(%rip)
    cmp $16777216, %r8
    jg y_alloc_fail
    ret

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
