/* boot.s — de-risk experiment for `ycc --kernel`.
 *
 * A Multiboot-1 ELF32 image that QEMU loads with `-kernel`:
 *   32-bit entry -> build page tables -> long mode -> 64-bit payload
 *   -> COM1 serial out, IDT + PIC remap, IRQ4 (serial RX) -> echo.
 *
 * This is the blueprint for the byte blob the compiler will splice in and
 * for the 64-bit kernel prelude assembly.
 */

.set MB_MAGIC,    0x1BADB002
.set MB_FLAGS,    0
.set MB_CHECKSUM, -(MB_MAGIC + MB_FLAGS)

.set COM1,        0x3F8
.set PIC1,        0x20
.set PIC2,        0xA0

/* ── the Multiboot header: first thing in the image, 4-byte aligned ───── */
.section .multiboot, "a", @progbits
.align 4
.long MB_MAGIC
.long MB_FLAGS
.long MB_CHECKSUM

/* ── 32-bit entry: page tables, PAE, LME, paging, far jump ───────────── */
.section .text
.code32
.global _start
_start:
    cli
    cld
    movl $stack_top, %esp
    movl %eax, mb_magic
    movl %ebx, mb_info

    /* zero the four page-table pages */
    movl $pt_pml4, %edi
    xorl %eax, %eax
    movl $(4 * 4096 / 4), %ecx
    rep stosl

    /* PML4[0] -> PDPT, PDPT[0] -> PD */
    movl $(pt_pdpt + 0x3), %eax
    movl %eax, pt_pml4
    movl $(pt_pd + 0x3), %eax
    movl %eax, pt_pdpt

    /* PD: 512 entries, 2 MB each, present+writable+PS -> first 1 GB */
    movl $pt_pd, %edi
    movl $0x83, %eax
    movl $512, %ecx
1:  movl %eax, (%edi)
    addl $0x200000, %eax
    addl $8, %edi
    loop 1b

    /* CR4.PAE, CR3 = PML4 */
    mov %cr4, %eax
    orl $0x20, %eax
    mov %eax, %cr4
    movl $pt_pml4, %eax
    mov %eax, %cr3

    /* EFER.LME */
    movl $0xC0000080, %ecx
    rdmsr
    orl $0x100, %eax
    wrmsr

    /* CR0 = PG | WP | PE */
    mov %cr0, %eax
    orl $0x80010001, %eax
    mov %eax, %cr0

    /* flat 64-bit segments for DS/ES/SS, then the mode switch */
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    lgdt gdtr
    ljmp $0x08, $entry64

/* ── 64-bit payload ───────────────────────────────────────────────────── */
.code64
entry64:
    movl $stack_top, %esp
    xorq %rbp, %rbp
    call kmain
1:  cli
    hlt
    jmp 1b

/* serial_init: 38400 8N1, FIFO on, OUT2 set (IRQs reach the PIC) */
serial_init:
    movw $(COM1 + 1), %dx
    movb $0x00, %al
    outb %al, %dx
    movw $(COM1 + 3), %dx
    movb $0x80, %al
    outb %al, %dx
    movw $(COM1 + 0), %dx
    movb $0x03, %al
    outb %al, %dx
    movw $(COM1 + 1), %dx
    movb $0x00, %al
    outb %al, %dx
    movw $(COM1 + 3), %dx
    movb $0x03, %al
    outb %al, %dx
    movw $(COM1 + 2), %dx
    movb $0xC7, %al
    outb %al, %dx
    movw $(COM1 + 4), %dx
    movb $0x0B, %al
    outb %al, %dx
    ret

/* serial_putc(%dil) */
serial_putc:
    movw $(COM1 + 5), %dx
1:  inb %dx, %al
    testb $0x20, %al
    jz 1b
    movw $COM1, %dx
    movb %dil, %al
    outb %al, %dx
    ret

/* serial_puts(%rdi), NUL-terminated */
serial_puts:
    push %rbx
    mov %rdi, %rbx
1:  movzbq (%rbx), %rdi
    testb %dil, %dil
    jz 2f
    call serial_putc
    inc %rbx
    jmp 1b
2:  pop %rbx
    ret

/* serial_hex(%rdi): two hex digits */
serial_hex:
    push %rbx
    mov %rdi, %rbx
    mov %rbx, %rdi
    shr $4, %rdi
    and $15, %rdi
    call hex_digit
    mov %rbx, %rdi
    and $15, %rdi
    call hex_digit
    pop %rbx
    ret

hex_digit:
    cmp $10, %rdi
    jb 1f
    add $('a' - 10 - '0'), %rdi
1:  add $'0', %rdi
    call serial_putc
    ret

/* irq stubs: one per vector, each pushes its number and joins the common path */
.macro IRQSTUB n
y_irq_\n:
    pushq $\n
    jmp irq_common
.endm

IRQSTUB 0
IRQSTUB 1
IRQSTUB 2
IRQSTUB 3
IRQSTUB 4
IRQSTUB 5
IRQSTUB 6
IRQSTUB 7
IRQSTUB 8
IRQSTUB 9
IRQSTUB 10
IRQSTUB 11
IRQSTUB 12
IRQSTUB 13
IRQSTUB 14
IRQSTUB 15
IRQSTUB 32
IRQSTUB 33
IRQSTUB 34
IRQSTUB 35
IRQSTUB 36
IRQSTUB 37
IRQSTUB 38
IRQSTUB 39
IRQSTUB 40
IRQSTUB 41
IRQSTUB 42
IRQSTUB 43
IRQSTUB 44
IRQSTUB 45
IRQSTUB 46
IRQSTUB 47

/* the common 64-bit trap path: save the caller-saved register set, pass the
   vector to C-like Y code, restore, iretq. */
irq_common:
    push %rax
    push %rcx
    push %rdx
    push %rsi
    push %rdi
    push %r8
    push %r9
    push %r10
    push %r11
    mov 72(%rsp), %rdi          /* 9 saved regs, then the vector */
    call irq_dispatch
    pop %r11
    pop %r10
    pop %r9
    pop %r8
    pop %rdi
    pop %rsi
    pop %rdx
    pop %rcx
    pop %rax
    add $8, %rsp                /* drop the vector */
    iretq

/* the Y-side dispatcher: just print the vector and the serial byte */
irq_dispatch:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    mov %rdi, %rbx
    lea msg_irq(%rip), %rdi
    call serial_puts
    mov %rbx, %rdi
    call serial_hex
    lea msg_nl(%rip), %rdi
    call serial_puts
    cmp $0x24, %rbx
    jne 1f
    /* serial data register: read and echo */
    movw $COM1, %dx
    inb %dx, %al
    movzbl %al, %edi
    call serial_putc
1:  /* EOI */
    cmp $0x28, %rbx
    jb 2f
    movw $(PIC2), %dx
    movb $0x20, %al
    outb %al, %dx
2:  movw $(PIC1), %dx
    movb $0x20, %al
    outb %al, %dx
    pop %rbx
    pop %rbp
    ret

/* fill 256 IDT entries; only the IRQ vectors have real stubs, the rest point
   at vector 0's stub so a stray exception is loud instead of silent. */
idt_init:
    lea idt(%rip), %rdi
    xor %ecx, %ecx
1:  lea irq_unknown(%rip), %rax
    cmp $0x24, %ecx
    jne 2f
    lea y_irq_36(%rip), %rax
    jmp 3f
2:  cmp $0x20, %ecx
    jb 3f
    cmp $0x30, %ecx
    jae 3f
    /* the table lists vectors 0..15 then 32..47, so vector-16 indexes it */
    mov %rcx, %rdx
    sub $0x10, %rdx
    lea irq_stub_tab(%rip), %rax
    movl (%rax,%rdx,4), %eax
3:  mov %ax, 0(%rdi)
    movw $0x08, 2(%rdi)
    movb $0x00, 4(%rdi)
    movb $0x8E, 5(%rdi)
    shr $16, %rax
    mov %ax, 6(%rdi)
    shr $16, %rax
    mov %eax, 8(%rdi)
    movl $0x00000000, 12(%rdi)
    add $16, %rdi
    inc %ecx
    cmp $256, %ecx
    jne 1b
    lidt idtr(%rip)
    ret

irq_unknown:
    pushq $0
    jmp irq_common

/* PIC remap: master 0x20..0x27, slave 0x28..0x2F; only IRQ4 unmasked. */
pic_remap:
    movw $(PIC1), %dx
    movb $0x11, %al
    outb %al, %dx
    movw $(PIC2), %dx
    movb $0x11, %al
    outb %al, %dx
    movw $(PIC1 + 1), %dx
    movb $0x20, %al
    outb %al, %dx
    movw $(PIC2 + 1), %dx
    movb $0x28, %al
    outb %al, %dx
    movw $(PIC1 + 1), %dx
    movb $0x04, %al
    outb %al, %dx
    movw $(PIC2 + 1), %dx
    movb $0x02, %al
    outb %al, %dx
    movw $(PIC1 + 1), %dx
    movb $0x01, %al
    outb %al, %dx
    movw $(PIC2 + 1), %dx
    movb $0x01, %al
    outb %al, %dx
    movw $(PIC1 + 1), %dx
    movb $0xEF, %al          /* IRQ4 only */
    outb %al, %dx
    movw $(PIC2 + 1), %dx
    movb $0xFF, %al
    outb %al, %dx
    ret

kmain:
    push %rbp
    mov %rsp, %rbp
    call serial_init
    lea msg_hello(%rip), %rdi
    call serial_puts
    lea idtr(%rip), %rax
    movw $4095, (%rax)
    lea idt(%rip), %rdx
    movl %edx, %edx
    mov %rdx, 2(%rax)
    call idt_init
    call pic_remap
    /* enable the receiver and its interrupt */
    movw $(COM1 + 1), %dx
    movb $0x01, %al
    outb %al, %dx
    sti
1:  hlt
    jmp 1b

/* ── data ─────────────────────────────────────────────────────────────── */
.section .rodata
.align 8
gdt:
    .quad 0x0000000000000000
    .quad 0x00AF9A000000FFFF   /* 64-bit code, ring 0 */
    .quad 0x00AF92000000FFFF   /* data */
gdt_end:
gdtr:
    .word gdt_end - gdt - 1
    .long gdt

.align 4
/* 32-bit entries: the payload lives below 4 GB, so zero-extending loads
   recover the full 64-bit handler address. */
irq_stub_tab:
    .long y_irq_0,  y_irq_1,  y_irq_2,  y_irq_3
    .long y_irq_4,  y_irq_5,  y_irq_6,  y_irq_7
    .long y_irq_8,  y_irq_9,  y_irq_10, y_irq_11
    .long y_irq_12, y_irq_13, y_irq_14, y_irq_15
    .long y_irq_32, y_irq_33, y_irq_34, y_irq_35
    .long y_irq_36, y_irq_37, y_irq_38, y_irq_39
    .long y_irq_40, y_irq_41, y_irq_42, y_irq_43
    .long y_irq_44, y_irq_45, y_irq_46, y_irq_47

msg_hello:  .asciz "ycc --kernel: long mode up, serial alive\n"
msg_irq:    .asciz "irq "
msg_nl:     .asciz "\n"

/* ── bss: stack, page tables, IDT ─────────────────────────────────────── */
.section .bss
.align 16
mb_magic:   .zero 4
mb_info:    .zero 4
.align 4096
pt_pml4:    .zero 4096
pt_pdpt:    .zero 4096
pt_pd:      .zero 4096
pt_pad:     .zero 4096
.align 16
idt:        .zero 4096
.align 16
idtr:       .zero 16
stack_bottom: .zero 16384
stack_top:
