# wgui.s -- what a window needs of the kernel side, on Windows: the way into user32 and
# gdi32 (std/gui.y does the rest in Y), and the window procedure.
#
# A window procedure is a callback Windows makes into our code, with its own frame on the
# stack and the collector scanning that stack, so it never runs Y: yw_gui_wndproc copies
# (hwnd, message, wparam, lparam) of the messages the program cares about into a ring that
# gui.y owns (yw_gui_ring) and hands the rest to DefWindowProcA (yw_gui_defproc). The ring
# is 64 bytes of header (the write count, a quadword at 0) and 256 entries of 32 bytes. A
# message that must not reach the default procedure is answered here: WM_CLOSE (the
# program decides), WM_ERASEBKGND (the program paints every pixel) and a menu key
# (SC_KEYMENU: Alt or F10 would freeze the loop in the system menu).
#
# Every DLL call from Y is y_os_gui_call: Win64 convention, 32 bytes of shadow space, the
# stack 16-byte aligned, the arguments in a block of quadwords (at least four of them, so
# the register loads read inside it). Like y_w_cb it publishes "in a system call" to the
# collector while a thread exists, because a modal loop (a window being dragged) can keep
# a DispatchMessage inside the call for as long as the user likes.

# y_os_gui_sym(dll, name) -> the address of the function, or 0: LoadLibraryA and
# GetProcAddress on two NUL-terminated byte strings. Not cached (gui.y keeps its own).
#=== replace: y_os_gui_sym ===
y_os_gui_sym:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    sub $40, %rsp
    and $-16, %rsp
    mov 24(%rbp), %rcx
    mov y_iat_LoadLibraryA(%rip), %rax
    call *%rax
    test %rax, %rax
    jz yguis_out
    mov %rax, %rcx
    mov 16(%rbp), %rdx
    mov y_iat_GetProcAddress(%rip), %rax
    call *%rax
yguis_out:
    mov -8(%rbp), %rbx
    mov %rbp, %rsp
    pop %rbp
    ret

# y_os_gui_call(fn, args, n) -> rax of the call: fn(args[0], .., args[n-1]).
#=== replace: y_os_gui_call ===
y_os_gui_call:
    push %rbp
    mov %rsp, %rbp
    push %rbx
    push %r12
    push %r13
    push %r14
    mov 32(%rbp), %r14
    mov 24(%rbp), %r13
    mov 16(%rbp), %r12
    mov %r12, %rax
    add $5, %rax
    and $-2, %rax
    shl $3, %rax
    sub %rax, %rsp
    and $-16, %rsp
    mov %r12, %rcx
    sub $4, %rcx
    cmp $0, %rcx
    jle yguic_regs
    lea 32(%r13), %rsi
    lea 32(%rsp), %rdi
yguic_copy:
    mov (%rsi), %rax
    mov %rax, (%rdi)
    add $8, %rsi
    add $8, %rdi
    sub $1, %rcx
    jnz yguic_copy
yguic_regs:
    lea y_heap(%rip), %r11
    mov 24(%r11), %r11
    test %r11, %r11
    jnz yguic_threaded
    mov (%r13), %rcx
    mov 8(%r13), %rdx
    mov 16(%r13), %r8
    mov 24(%r13), %r9
    call *%r14
    jmp yguic_out
yguic_threaded:
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jz yguic_go
    mov y_gc_safe_fn(%rip), %rax
    call *%rax
    jmp yguic_threaded
yguic_go:
    mov %gs:5752, %rax
    mov %rsp, 88(%rax)
    mov $4, %rcx
    mov %rcx, 96(%rax)
    mov (%r13), %rcx
    mov 8(%r13), %rdx
    mov 16(%r13), %r8
    mov 24(%r13), %r9
    call *%r14
    mov %rax, %rbx
    mov %gs:5752, %rcx
    xor %eax, %eax
    xchg %rax, 96(%rcx)
    mov y_gc_stw(%rip), %rax
    test %rax, %rax
    jz yguic_back
    mov y_gc_safe_fn(%rip), %rax
    call *%rax
yguic_back:
    mov %rbx, %rax
yguic_out:
    lea -32(%rbp), %rsp
    pop %r14
    pop %r13
    pop %r12
    pop %rbx
    pop %rbp
    ret

# y_os_gui_wndproc(ring, defproc) -> the address of the window procedure, with the ring
# and DefWindowProcA it uses set.
#=== replace: y_os_gui_wndproc ===
y_os_gui_wndproc:
    push %rbp
    mov %rsp, %rbp
    mov 24(%rbp), %rax
    mov %rax, yw_gui_ring(%rip)
    mov 16(%rbp), %rax
    mov %rax, yw_gui_defproc(%rip)
    lea yw_gui_wndproc(%rip), %rax
    pop %rbp
    ret

# LRESULT CALLBACK yw_gui_wndproc(hwnd %rcx, message %rdx, wparam %r8, lparam %r9). Only
# volatile registers are used, so the tail call to DefWindowProcA sees the arguments as
# they came.
#=== add: yw_gui_wndproc ===
yw_gui_wndproc:
    mov yw_gui_ring(%rip), %rax
    test %rax, %rax
    jz yguiw_def
    cmp $274, %rdx
    jne yguiw_not_sys
    mov %r8, %r10
    and $65520, %r10
    cmp $61696, %r10
    je yguiw_zero
    jmp yguiw_def
yguiw_not_sys:
    cmp $256, %rdx
    jb yguiw_low
    cmp $526, %rdx
    jbe yguiw_rec
    jmp yguiw_def
yguiw_low:
    cmp $2, %rdx
    je yguiw_rec
    cmp $5, %rdx
    je yguiw_rec
    cmp $6, %rdx
    je yguiw_rec
    cmp $7, %rdx
    je yguiw_rec
    cmp $8, %rdx
    je yguiw_rec
    cmp $15, %rdx
    je yguiw_rec
    cmp $16, %rdx
    je yguiw_rec
    cmp $20, %rdx
    je yguiw_one
    jmp yguiw_def
yguiw_rec:
    mov (%rax), %r10
    mov %r10, %r11
    and $255, %r11
    shl $5, %r11
    add %rax, %r11
    add $64, %r11
    mov %rcx, (%r11)
    mov %rdx, 8(%r11)
    mov %r8, 16(%r11)
    mov %r9, 24(%r11)
    add $1, %r10
    mov %r10, (%rax)
    cmp $16, %rdx
    je yguiw_zero
    cmp $20, %rdx
    je yguiw_one
yguiw_def:
    mov yw_gui_defproc(%rip), %rax
    jmp *%rax
yguiw_zero:
    xor %eax, %eax
    ret
yguiw_one:
    mov $1, %eax
    ret
