// arch_x64.c — Linux x86_64 code emitters for the native backend (ycc).
// 1:1 port of src/y/arch_x64.y (see PORTING.md): same defs in the same
// order, same control flow, character-identical asm text.
#include "arch_x64.h"

/* imported */
/* none — arch_x64.y calls no other module's defs. The only builtins used
   are tostring(x) of a long -> ys_long(x) and join(a, sep) -> ys_join(a,
   sep); both come from yv.h. */

Yv *arch_id(void) {
    return ys("x86_64-linux");
}

long arch_word(void) {
    return 8;
}

// syscall number table. NOTE: one arm per syscall (ladder style, see the
// master note in asm.y's is_digit_ch — not a language restriction).
long arch_sysno(Yv *name) {
    if (ys_eq_lit(name, "read")) { return 0; }
    else if (ys_eq_lit(name, "write")) { return 1; }
    else if (ys_eq_lit(name, "close")) { return 3; }
    else if (ys_eq_lit(name, "openat")) { return 257; }
    else if (ys_eq_lit(name, "exit")) { return 60; }
    else { return -1; }
}

Yv *arch_fn_label(long uid, Yv *name) {
    return ys_cat(ys_cat(ys_cat(ys("yfn_"), ys_long(uid)), ys("_")), name);
}

Yv *arch_global_label(long uid, Yv *name) {
    return ys_cat(ys_cat(ys_cat(ys("yg_"), ys_long(uid)), ys("_")), name);
}

Yv *arch_loc_label(long fuid, long n) {
    return ys_cat(ys_cat(ys_cat(ys("yL_"), ys_long(fuid)), ys("_")), ys_long(n));
}

Yv *arch_str_label(long i) {
    return ys_cat(ys("ystr_"), ys_long(i));
}

Yv *arch_header(void) {
    return ys(".text\n.globl _start\n");
}

Yv *arch_rodata(void) {
    return ys(".section .rodata\n");
}

Yv *arch_text(void) {
    return ys(".text\n");
}

/* One zeroed 8-byte cell per global (see emit_program in native.y). */
Yv *arch_bss(void) {
    return ys(".section .bss\n");
}

Yv *arch_global_cell(Yv *label) {
    return ys_cat(label, ys(":\n.zero 8\n"));
}

// The allocator's state, four .bss words: the bump pointer, the end of
// the current chunk, the bytes handed out so far (heap_used) and whether
// a thread was ever spawned. The first spawn moves the first three into
// the main thread's own block and empties these, so that the bump fails
// on them in every thread and y_alloc_slow sends it to its own block
// (arch_prelude_threads): a program without threads pays nothing for
// them. A program that never allocates shakes the cells out with
// y_alloc.
//   y_alloc(n) hands out (n + 15) & -8 bytes: the 8 spare bytes let the
//   word-at-a-time string loops over-read past a NUL safely. The fast
//   path is a bump; when the chunk is full, a request under 256 KB opens
//   a fresh 4 MB anonymous mapping (the old chunk's tail is abandoned)
//   and a larger one gets a mapping of its own. mmap memory is zeroed,
//   like the brk memory this replaced -- and unlike brk it has no 8 MB
//   cap under valgrind.
Yv *arch_heap_cells(void) {
    return ys("y_heap:\n.zero 32\n");
}

long arch_frame(long slots) {
    // slots * 8, rounded up to a multiple of 16 (call alignment)
    long bytes = slots * 8;
    if (bytes % 16 == 0) { return bytes; } else { return bytes + (16 - bytes % 16); }
}

Yv *arch_exit(void) {
    return ys("    mov $231, %rax\n    xor %edi, %edi\n    syscall\n");
}

// The prelude as its lines: labels alone at column 0, everything else
// indented (native.c prelude_blocks relies on it).
Yv *arch_prelude_lines(void) {
    // Runtime PRIMITIVES — everything with a specific behaviour lives in
    // std/rt.y as ordinary Y code (tree shaking drops what a program does
    // not use, here and there: native.y's shake_prelude prunes these lines
    // block by block, prune_bodies does the same for rt.y's functions).
    // What stays here is what only raw machine state can do: the bump
    // allocator (y_alloc, over 4 MB mmap chunks, its state in the y_heap
    // .bss cells), the trap stubs, the byte-moving
    // string/array cores
    // (eq/cmp/cat/join/slice, arr push/prepend/slice/cat/eq), long and
    // float formatting, str<->[byte] conversion and argv materialization.
    Yv *lines = yav(0);
    // Frameless: the two arguments are read off the stack (%rsp still holds
    // the return address, so arg1 is at 8(%rsp)) and only the caller-saved
    // registers are touched. ycc compares two strings 71 million times
    // compiling itself and each comparison is a handful of bytes, so the old
    // push %rbp/%rbx/%r13 ... pop sequence -- ten instructions, a third of
    // the call -- was pure overhead.
    lines = ya_push(lines, ys("y_str_eq:"));
    lines = ya_push(lines, ys("    mov 8(%rsp), %rax"));
    lines = ya_push(lines, ys("    mov 16(%rsp), %rcx"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    jz yse_bn"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jz yse_no"));
    lines = ya_push(lines, ys("    mov (%rax), %r8"));
    lines = ya_push(lines, ys("    mov (%rcx), %r9"));
    lines = ya_push(lines, ys("    cmp %r9, %r8"));
    lines = ya_push(lines, ys("    jnz yse_no"));
    lines = ya_push(lines, ys("    add $8, %rax"));
    lines = ya_push(lines, ys("    add $8, %rcx"));
    lines = ya_push(lines, ys("    xor %r10d, %r10d"));
    lines = ya_push(lines, ys("yse_loop:"));
    lines = ya_push(lines, ys("    mov %r8, %rdx"));
    lines = ya_push(lines, ys("    sub %r10, %rdx"));
    lines = ya_push(lines, ys("    sub $8, %rdx"));
    lines = ya_push(lines, ys("    jb yse_tail"));
    lines = ya_push(lines, ys("    mov (%rax,%r10,1), %rdx"));
    lines = ya_push(lines, ys("    mov (%rcx,%r10,1), %r11"));
    lines = ya_push(lines, ys("    cmp %r11, %rdx"));
    lines = ya_push(lines, ys("    jnz yse_no"));
    lines = ya_push(lines, ys("    add $8, %r10"));
    lines = ya_push(lines, ys("    jmp yse_loop"));
    lines = ya_push(lines, ys("yse_tail:"));
    lines = ya_push(lines, ys("    mov %r8, %r10"));
    lines = ya_push(lines, ys("    sub $8, %r10"));
    lines = ya_push(lines, ys("    mov (%rax,%r10,1), %rdx"));
    lines = ya_push(lines, ys("    mov (%rcx,%r10,1), %r11"));
    lines = ya_push(lines, ys("    cmp %r11, %rdx"));
    lines = ya_push(lines, ys("    jnz yse_no"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("yse_no:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("    ret"));
    // arg1 was none: equal only if arg2 is too
    lines = ya_push(lines, ys("yse_bn:"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jz yse_yes"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("yse_yes:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    ret"));
    // y_str_cmp(a, b) -> -1 / 0 / 1, lexicographic unsigned-byte
    // order. Only the SIGN is meaningful to callers (types.y typeof_cmp,
    // native.y gen_str_cmp), and yv.c's ys_cmp agrees (memcmp on the
    // common prefix, then length), so the three spellings of string order
    // all rank identically.
    lines = ya_push(lines, ys("y_str_cmp:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r13"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    mov (%r13), %rdx"));
    lines = ya_push(lines, ys("    add $8, %rbx"));
    lines = ya_push(lines, ys("    add $8, %r13"));
    lines = ya_push(lines, ys("    xor %r8d, %r8d"));
    lines = ya_push(lines, ys("ysc_loop:"));
    lines = ya_push(lines, ys("    cmp %rcx, %r8"));
    lines = ya_push(lines, ys("    jge ysc_aend"));
    lines = ya_push(lines, ys("    cmp %rdx, %r8"));
    lines = ya_push(lines, ys("    jge ysc_pos"));
    lines = ya_push(lines, ys("    movzbq (%rbx,%r8,1), %rax"));
    lines = ya_push(lines, ys("    movzbq (%r13,%r8,1), %r14"));
    lines = ya_push(lines, ys("    cmp %r14, %rax"));
    lines = ya_push(lines, ys("    jl ysc_neg"));
    lines = ya_push(lines, ys("    jg ysc_pos"));
    lines = ya_push(lines, ys("    inc %r8"));
    lines = ya_push(lines, ys("    jmp ysc_loop"));
    lines = ya_push(lines, ys("ysc_aend:"));
    lines = ya_push(lines, ys("    cmp %rdx, %r8"));
    lines = ya_push(lines, ys("    jge ysc_zero"));
    lines = ya_push(lines, ys("ysc_neg:"));
    lines = ya_push(lines, ys("    mov $-1, %rax"));
    lines = ya_push(lines, ys("    jmp ysc_done"));
    lines = ya_push(lines, ys("ysc_pos:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    jmp ysc_done"));
    lines = ya_push(lines, ys("ysc_zero:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("ysc_done:"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_str_cat:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r13"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    mov (%r13), %rdx"));
    lines = ya_push(lines, ys("    add %rdx, %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    mov %rcx, %r12"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    mov %rbx, %rsi"));
    lines = ya_push(lines, ys("    add $8, %rsi"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    add $8, %rdi"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("    mov %r13, %rsi"));
    lines = ya_push(lines, ys("    add $8, %rsi"));
    lines = ya_push(lines, ys("    mov (%rbx), %rdx"));
    lines = ya_push(lines, ys("    mov %rdi, %rdi"));
    lines = ya_push(lines, ys("    add %rdx, %rdi"));
    lines = ya_push(lines, ys("    mov (%r13), %rcx"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jz ysc_skip2"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("ysc_skip2:"));
    lines = ya_push(lines, ys("    mov %r12, (%r14)"));
    lines = ya_push(lines, ys("    mov %r12, %rbx"));
    lines = ya_push(lines, ys("    movb $0, 8(%r14,%rbx,1)"));
    lines = ya_push(lines, ys("    mov %r14, %rax"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* y_str_app(s, x, own) -> s ++ x for `s += x` statements (see
     * gen_sappend in native.c). own == 1: s came from here and nobody
     * else has seen it, so x goes into its spare room when it fits.
     * Its buffers are [cap][len][bytes]: the value points at len, cap
     * counts the bytes after it. Room runs out: a buffer twice the
     * size; s not owned: an exact copy (+8 for the word copy loop). */
    lines = ya_push(lines, ys("y_str_app:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %r13"));
    lines = ya_push(lines, ys("    mov (%rbx), %r12"));
    lines = ya_push(lines, ys("    mov (%r13), %rdx"));
    lines = ya_push(lines, ys("    add %rdx, %r12"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rax"));
    lines = ya_push(lines, ys("    cmp $1, %rax"));
    lines = ya_push(lines, ys("    jne ysa_new"));
    lines = ya_push(lines, ys("    mov %r12, %rcx"));
    lines = ya_push(lines, ys("    add $8, %rcx"));
    lines = ya_push(lines, ys("    mov -8(%rbx), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %rcx"));
    lines = ya_push(lines, ys("    jg ysa_grow"));
    lines = ya_push(lines, ys("    mov %rbx, %r14"));
    lines = ya_push(lines, ys("    jmp ysa_tail"));
    lines = ya_push(lines, ys("ysa_grow:"));
    lines = ya_push(lines, ys("    mov %r12, %rdi"));
    lines = ya_push(lines, ys("    add %rdi, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    jmp ysa_alloc"));
    lines = ya_push(lines, ys("ysa_new:"));
    lines = ya_push(lines, ys("    mov %r12, %rdi"));
    lines = ya_push(lines, ys("    add $8, %rdi"));
    lines = ya_push(lines, ys("ysa_alloc:"));
    lines = ya_push(lines, ys("    push %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %rdi"));
    lines = ya_push(lines, ys("    mov %rdi, (%rax)"));
    lines = ya_push(lines, ys("    lea 8(%rax), %r14"));
    lines = ya_push(lines, ys("    lea 8(%rbx), %rsi"));
    lines = ya_push(lines, ys("    lea 8(%r14), %rdi"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("ysa_tail:"));
    lines = ya_push(lines, ys("    lea 8(%r13), %rsi"));
    lines = ya_push(lines, ys("    mov (%rbx), %rdx"));
    lines = ya_push(lines, ys("    lea 8(%r14), %rdi"));
    lines = ya_push(lines, ys("    add %rdx, %rdi"));
    lines = ya_push(lines, ys("    mov (%r13), %rcx"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jz ysa_skip"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("ysa_skip:"));
    lines = ya_push(lines, ys("    mov %r12, (%r14)"));
    lines = ya_push(lines, ys("    mov %r12, %rbx"));
    lines = ya_push(lines, ys("    movb $0, 8(%r14,%rbx,1)"));
    lines = ya_push(lines, ys("    mov %r14, %rax"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("ysc_copy:"));
    lines = ya_push(lines, ys("    mov %rcx, %rax"));
    lines = ya_push(lines, ys("    add $7, %rax"));
    lines = ya_push(lines, ys("    shr $3, %rax"));
    lines = ya_push(lines, ys("    xor %r8d, %r8d"));
    lines = ya_push(lines, ys("yscc_loop:"));
    lines = ya_push(lines, ys("    cmp %rax, %r8"));
    lines = ya_push(lines, ys("    jge yscc_done"));
    lines = ya_push(lines, ys("    mov (%rsi,%r8,8), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, (%rdi,%r8,8)"));
    lines = ya_push(lines, ys("    inc %r8"));
    lines = ya_push(lines, ys("    jmp yscc_loop"));
    lines = ya_push(lines, ys("yscc_done:"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_str_join:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r13"));
    lines = ya_push(lines, ys("    mov (%rbx), %r12"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rbx"));
    lines = ya_push(lines, ys("    mov (%r13), %r15"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("    xor %r8d, %r8d"));
    lines = ya_push(lines, ys("ysj_sum:"));
    lines = ya_push(lines, ys("    cmp %r12, %r8"));
    lines = ya_push(lines, ys("    jge ysj_sumd"));
    lines = ya_push(lines, ys("    mov (%rbx,%r8,8), %rax"));
    lines = ya_push(lines, ys("    mov (%rax), %rax"));
    lines = ya_push(lines, ys("    add %rax, %rcx"));
    lines = ya_push(lines, ys("    add %r15, %rcx"));
    lines = ya_push(lines, ys("    inc %r8"));
    lines = ya_push(lines, ys("    jmp ysj_sum"));
    lines = ya_push(lines, ys("ysj_sumd:"));
    lines = ya_push(lines, ys("    test %r12, %r12"));
    lines = ya_push(lines, ys("    jz ysj_alloc"));
    lines = ya_push(lines, ys("    sub %r15, %rcx"));
    lines = ya_push(lines, ys("ysj_alloc:"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, (%rax)"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    lea 8(%rax), %rdi"));
    lines = ya_push(lines, ys("    xor %r9d, %r9d"));
    lines = ya_push(lines, ys("ysj_loop:"));
    lines = ya_push(lines, ys("    cmp %r12, %r9"));
    lines = ya_push(lines, ys("    jge ysj_done"));
    lines = ya_push(lines, ys("    test %r9, %r9"));
    lines = ya_push(lines, ys("    jz ysj_elem"));
    lines = ya_push(lines, ys("    lea 8(%r13), %rsi"));
    lines = ya_push(lines, ys("    mov %r15, %rcx"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("    add %r15, %rdi"));
    lines = ya_push(lines, ys("ysj_elem:"));
    lines = ya_push(lines, ys("    mov (%rbx,%r9,8), %rsi"));
    lines = ya_push(lines, ys("    mov (%rsi), %rcx"));
    lines = ya_push(lines, ys("    add $8, %rsi"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("    add %rcx, %rdi"));
    lines = ya_push(lines, ys("    inc %r9"));
    lines = ya_push(lines, ys("    jmp ysj_loop"));
    lines = ya_push(lines, ys("ysj_done:"));
    lines = ya_push(lines, ys("    mov (%r14), %rcx"));
    lines = ya_push(lines, ys("    movb $0, 8(%r14,%rcx,1)"));
    lines = ya_push(lines, ys("    mov %r14, %rax"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_div_zero:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    lea ystr_divzero(%rip), %rsi"));
    lines = ya_push(lines, ys("    mov $ystr_divzero_end-ystr_divzero, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov $231, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("y_oob:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    lea ystr_oob(%rip), %rsi"));
    lines = ya_push(lines, ys("    mov $ystr_oob_end-ystr_oob, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov $231, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("y_cast_trap:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    lea ystr_cast(%rip), %rsi"));
    lines = ya_push(lines, ys("    mov $ystr_cast_end-ystr_cast, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov $231, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("y_alloc:"));
    lines = ya_push(lines, ys("    lea 15(%rdi), %rax"));
    lines = ya_push(lines, ys("    and $-8, %rax"));
    lines = ya_push(lines, ys("    lea y_heap(%rip), %rcx"));
    lines = ya_push(lines, ys("y_alloc_go:"));
    lines = ya_push(lines, ys("    mov (%rcx), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, %rdi"));
    lines = ya_push(lines, ys("    add %rax, %rdi"));
    lines = ya_push(lines, ys("    mov 8(%rcx), %r11"));
    lines = ya_push(lines, ys("    cmp %r11, %rdi"));
    lines = ya_push(lines, ys("    jg y_alloc_slow"));
    lines = ya_push(lines, ys("    mov %rdi, (%rcx)"));
    lines = ya_push(lines, ys("    mov 16(%rcx), %rdi"));
    lines = ya_push(lines, ys("    add %rax, %rdi"));
    lines = ya_push(lines, ys("    mov %rdi, 16(%rcx)"));
    lines = ya_push(lines, ys("    mov %rdx, %rax"));
    lines = ya_push(lines, ys("    ret"));
    /* Once a thread was spawned (y_heap's flag) the global block is empty, */
    /* so every thread's bump on it fails and lands here, then retries in */
    /* the thread's own block (%fs:24 points to it; arch_prelude_threads). */
    lines = ya_push(lines, ys("y_alloc_slow:"));
    lines = ya_push(lines, ys("    lea y_heap(%rip), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %rcx"));
    lines = ya_push(lines, ys("    jne y_alloc_more"));
    lines = ya_push(lines, ys("    mov 24(%rdx), %rdx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    je y_alloc_more"));
    lines = ya_push(lines, ys("    mov %fs:24, %rcx"));
    lines = ya_push(lines, ys("    jmp y_alloc_go"));
    lines = ya_push(lines, ys("y_alloc_more:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %rsi"));
    lines = ya_push(lines, ys("    push %r8"));
    lines = ya_push(lines, ys("    push %r9"));
    lines = ya_push(lines, ys("    push %r10"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    mov %rax, %rbx"));
    lines = ya_push(lines, ys("    mov %rcx, %r12"));
    lines = ya_push(lines, ys("    mov $262144, %rsi"));
    lines = ya_push(lines, ys("    cmp %rsi, %rbx"));
    lines = ya_push(lines, ys("    jge y_alloc_big"));
    lines = ya_push(lines, ys("    mov $4194304, %rsi"));
    lines = ya_push(lines, ys("    call y_alloc_map"));
    lines = ya_push(lines, ys("    mov %rax, %rdx"));
    lines = ya_push(lines, ys("    add %rbx, %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 0(%r12)"));
    lines = ya_push(lines, ys("    mov $4194304, %rdx"));
    lines = ya_push(lines, ys("    add %rax, %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%r12)"));
    lines = ya_push(lines, ys("    jmp y_alloc_out"));
    lines = ya_push(lines, ys("y_alloc_big:"));
    lines = ya_push(lines, ys("    mov %rbx, %rsi"));
    lines = ya_push(lines, ys("    add $4095, %rsi"));
    lines = ya_push(lines, ys("    and $-4096, %rsi"));
    lines = ya_push(lines, ys("    call y_alloc_map"));
    lines = ya_push(lines, ys("y_alloc_out:"));
    lines = ya_push(lines, ys("    mov 16(%r12), %rdx"));
    lines = ya_push(lines, ys("    add %rbx, %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 16(%r12)"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %r10"));
    lines = ya_push(lines, ys("    pop %r9"));
    lines = ya_push(lines, ys("    pop %r8"));
    lines = ya_push(lines, ys("    pop %rsi"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_alloc_map:"));
    lines = ya_push(lines, ys("    mov $9, %rax"));
    lines = ya_push(lines, ys("    xor %edi, %edi"));
    lines = ya_push(lines, ys("    mov $3, %rdx"));
    lines = ya_push(lines, ys("    mov $34, %r10"));
    lines = ya_push(lines, ys("    mov $-1, %r8"));
    lines = ya_push(lines, ys("    xor %r9d, %r9d"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    js y_alloc_fail"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_heap_used:"));
    lines = ya_push(lines, ys("    lea y_heap(%rip), %rcx"));
    lines = ya_push(lines, ys("    mov 24(%rcx), %rdx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    je y_heap_used_go"));
    lines = ya_push(lines, ys("    mov %fs:24, %rcx"));
    lines = ya_push(lines, ys("y_heap_used_go:"));
    lines = ya_push(lines, ys("    mov 16(%rcx), %rax"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_alloc_fail:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    lea ystr_oom(%rip), %rsi"));
    lines = ya_push(lines, ys("    mov $ystr_oom_end-ystr_oom, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov $231, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("y_opt_unwrap:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    lea ystr_opt(%rip), %rsi"));
    lines = ya_push(lines, ys("    mov $ystr_opt_end-ystr_opt, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov $231, %rax"));
    lines = ya_push(lines, ys("    mov $1, %rdi"));
    lines = ya_push(lines, ys("    syscall"));
    // y_arr_slice(arr, lo, hi, esz) -> new array. esz is the element
    // width in bytes (1 for packed [byte], 8 for everything else), so
    // one implementation serves both layouts.
    lines = ya_push(lines, ys("y_arr_slice:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 40(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %r13"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r9"));
    lines = ya_push(lines, ys("    mov (%rbx), %r15"));
    lines = ya_push(lines, ys("    test %r12, %r12"));
    lines = ya_push(lines, ys("    jns yas_lo1"));
    lines = ya_push(lines, ys("    xor %r12d, %r12d"));
    lines = ya_push(lines, ys("yas_lo1:"));
    lines = ya_push(lines, ys("    cmp %r15, %r12"));
    lines = ya_push(lines, ys("    jle yas_lo2"));
    lines = ya_push(lines, ys("    mov %r15, %r12"));
    lines = ya_push(lines, ys("yas_lo2:"));
    lines = ya_push(lines, ys("    test %r13, %r13"));
    lines = ya_push(lines, ys("    jns yas_hi1"));
    lines = ya_push(lines, ys("    xor %r13d, %r13d"));
    lines = ya_push(lines, ys("yas_hi1:"));
    lines = ya_push(lines, ys("    cmp %r15, %r13"));
    lines = ya_push(lines, ys("    jle yas_hi2"));
    lines = ya_push(lines, ys("    mov %r15, %r13"));
    lines = ya_push(lines, ys("yas_hi2:"));
    lines = ya_push(lines, ys("    mov %r13, %r14"));
    lines = ya_push(lines, ys("    sub %r12, %r14"));
    lines = ya_push(lines, ys("    test %r14, %r14"));
    lines = ya_push(lines, ys("    jns yas_n"));
    lines = ya_push(lines, ys("    xor %r14d, %r14d"));
    lines = ya_push(lines, ys("yas_n:"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    cmp $8, %rdi"));
    lines = ya_push(lines, ys("    jge yas_sz"));
    lines = ya_push(lines, ys("    mov $8, %rdi"));
    lines = ya_push(lines, ys("yas_sz:"));
    lines = ya_push(lines, ys("    push %r9"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r9"));
    lines = ya_push(lines, ys("    mov %rax, %r15"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov $24, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    mov %r14, (%rax)"));
    lines = ya_push(lines, ys("    mov %r14, 8(%rax)"));
    lines = ya_push(lines, ys("    mov %r15, 16(%rax)"));
    lines = ya_push(lines, ys("    mov %rax, %r13"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rsi"));
    lines = ya_push(lines, ys("    mov %r12, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    add %rax, %rsi"));
    lines = ya_push(lines, ys("    mov %r15, %rdi"));
    lines = ya_push(lines, ys("    mov %r14, %rcx"));
    lines = ya_push(lines, ys("    imul %r9, %rcx"));
    lines = ya_push(lines, ys("    call y_mem_copy"));
    lines = ya_push(lines, ys("    mov %r13, %rax"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_arr_eq(a, b, esz) -> bool. Structural: same length, same
    // elements. esz selects the element width.
    lines = ya_push(lines, ys("y_arr_eq:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r9"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    mov (%r12), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %rcx"));
    lines = ya_push(lines, ys("    jnz yae_ne"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%r12), %r12"));
    lines = ya_push(lines, ys("    xor %edx, %edx"));
    lines = ya_push(lines, ys("yae_loop:"));
    lines = ya_push(lines, ys("    cmp %rcx, %rdx"));
    lines = ya_push(lines, ys("    jge yae_eq"));
    lines = ya_push(lines, ys("    mov %rdx, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    mov %rax, %rsi"));
    lines = ya_push(lines, ys("    add %rbx, %rax"));
    lines = ya_push(lines, ys("    add %r12, %rsi"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je yae_c1"));
    lines = ya_push(lines, ys("    mov (%rax), %rax"));
    lines = ya_push(lines, ys("    mov (%rsi), %rsi"));
    lines = ya_push(lines, ys("    jmp yae_cn"));
    lines = ya_push(lines, ys("yae_c1:"));
    lines = ya_push(lines, ys("    movzbq (%rax), %rax"));
    lines = ya_push(lines, ys("    movzbq (%rsi), %rsi"));
    lines = ya_push(lines, ys("yae_cn:"));
    lines = ya_push(lines, ys("    cmp %rsi, %rax"));
    lines = ya_push(lines, ys("    jnz yae_ne"));
    lines = ya_push(lines, ys("    inc %rdx"));
    lines = ya_push(lines, ys("    jmp yae_loop"));
    lines = ya_push(lines, ys("yae_eq:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    jmp yae_done"));
    lines = ya_push(lines, ys("yae_ne:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("yae_done:"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_arr_eq_str:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov (%rbx), %r13"));
    lines = ya_push(lines, ys("    mov (%r12), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %r13"));
    lines = ya_push(lines, ys("    jnz yaes_ne"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%r12), %r12"));
    lines = ya_push(lines, ys("    xor %r14d, %r14d"));
    lines = ya_push(lines, ys("yaes_loop:"));
    lines = ya_push(lines, ys("    cmp %r13, %r14"));
    lines = ya_push(lines, ys("    jge yaes_eq"));
    lines = ya_push(lines, ys("    mov (%rbx,%r14,8), %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov (%r12,%r14,8), %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    call y_str_eq"));
    lines = ya_push(lines, ys("    add $16, %rsp"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    jz yaes_ne"));
    lines = ya_push(lines, ys("    inc %r14"));
    lines = ya_push(lines, ys("    jmp yaes_loop"));
    lines = ya_push(lines, ys("yaes_eq:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    jmp yaes_done"));
    lines = ya_push(lines, ys("yaes_ne:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("yaes_done:"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // long -> decimal string: digits from one idiv each into a stack
    // buffer, filled from the end; the remainder takes the dividend's
    // sign, so negating it per digit is exact for LONG_MIN too. One
    // allocation of exactly the used length.
    lines = ya_push(lines, ys("y_long_tostr:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    sub $32, %rsp"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rax"));
    lines = ya_push(lines, ys("    lea -16(%rbp), %rsi"));
    lines = ya_push(lines, ys("    mov $10, %rcx"));
    lines = ya_push(lines, ys("ylts_loop:"));
    lines = ya_push(lines, ys("    cqo"));
    lines = ya_push(lines, ys("    idiv %rcx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    jns ylts_pos"));
    lines = ya_push(lines, ys("    neg %rdx"));
    lines = ya_push(lines, ys("ylts_pos:"));
    lines = ya_push(lines, ys("    add $48, %rdx"));
    lines = ya_push(lines, ys("    dec %rsi"));
    lines = ya_push(lines, ys("    movb %dl, (%rsi)"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    jnz ylts_loop"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rax"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    jns ylts_mk"));
    lines = ya_push(lines, ys("    dec %rsi"));
    lines = ya_push(lines, ys("    movb $45, (%rsi)"));
    lines = ya_push(lines, ys("ylts_mk:"));
    lines = ya_push(lines, ys("    lea -16(%rbp), %rbx"));
    lines = ya_push(lines, ys("    sub %rsi, %rbx"));
    lines = ya_push(lines, ys("    mov %rsi, %r12"));
    lines = ya_push(lines, ys("    mov %rbx, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov %rbx, (%rax)"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("ylts_cp:"));
    lines = ya_push(lines, ys("    cmp %rbx, %rcx"));
    lines = ya_push(lines, ys("    jge ylts_done"));
    lines = ya_push(lines, ys("    movzbq (%r12,%rcx,1), %rdx"));
    lines = ya_push(lines, ys("    movb %dl, 8(%rax,%rcx,1)"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    jmp ylts_cp"));
    lines = ya_push(lines, ys("ylts_done:"));
    lines = ya_push(lines, ys("    movb $0, 8(%rax,%rbx,1)"));
    lines = ya_push(lines, ys("    add $32, %rsp"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_float_tostr:"));
    /* print(f) / tostring(f): the float's IEEE-754 bits, as y_fmt_f takes
     * them, formatted at the 6 places this has always printed. It USED to be
     * double arithmetic -- int part by cvttsd2si, fraction times 1e6, +0.5,
     * truncate -- which is round-half-up and loses the digits below the 53 the
     * product carries, so print(x) and f"{x:.6f}" disagreed on a tie and
     * neither always matched C: 3123845.1640625 printed 3123845.164063 here
     * and 3123845.164062 there, and 0.0000025 (whose exact value is a hair
     * above the midpoint) printed 0.000002 against C's 0.000003. std/str.y's
     * y_fmt_f writes the exact binary value out in decimal and rounds half to
     * even, so one call gives print and the f-string the same text, C's
     * answer, and -0.0 its sign (the sign is the top bit of the bits, which
     * `x < 0` never sees). It also formats a magnitude at or past 2^63
     * exactly, where this used to give up with "<float magnitude >2^63>".
     *
     * Args: (bits: long, code: long, width: long, prec: long), pushed right to
     * left; code 102 is 'f' with no fill, alignment, alternate form, grouping
     * or sign override, width -1 none, 6 places. */
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    /* the float arrives as the first stack argument, not in %xmm0 (the old
     * body read it from 16(%rbp) for the same reason) */
    lines = ya_push(lines, ys("    mov 16(%rbp), %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov $102, %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov $-1, %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov $6, %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    call y_fmt_f"));
    lines = ya_push(lines, ys("    add $32, %rsp"));
    lines = ya_push(lines, ys("yft_ret:"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_fmod(x, y) -> x % y: the IEEE remainder truncated toward zero, the
    // one C's fmod returns -- the result keeps the sign of the dividend and
    // is under |y| in magnitude. x87 had fprem for it in one instruction
    // and SSE2 has nothing, so this is long division on the significands.
    //
    // Registers, not the stack: only gen_float_bin's `%` calls this, and it
    // has both operands in SSE registers already. %xmm0 = x and %xmm1 = y
    // on entry, the remainder in %xmm0 on return.
    //
    // Each side comes apart into a significand and an exponent: a normal
    // double is (mantissa | 2^52) * 2^(field - 1075), and a subnormal has
    // no implicit leading bit, so its significand is the raw mantissa at
    // the fixed exponent -1074. Measured in the unit 2^-1074 that they
    // share, x is mx * 2^(ex - ey + 1074) and y is my * 2^-1074, so
    //
    //     x % y == ((mx * 2^e) % my) * 2^ey,   e = ex - ey >= 0,
    //
    // because |x| >= |y| is all that is left of the early exits. mx and my
    // are both under 2^53, so mx % my is one `div`, and the e passes after
    // it double a remainder already known to be under my: no overflow, and
    // no rounding either, since scaling by a power of two and subtracting
    // an integer are both exact. Every bit pattern compared below has its
    // sign cleared, so the signed jumps are the unsigned ones; this
    // assembler has jb/jl/jg/jge/jle and no jae.
    lines = ya_push(lines, ys("y_fmod:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    movq %xmm0, %rbx"));
    lines = ya_push(lines, ys("    movq %xmm1, %r12"));
    lines = ya_push(lines, ys("    mov $9223372036854775807, %rax"));
    lines = ya_push(lines, ys("    mov %rbx, %r13"));
    lines = ya_push(lines, ys("    and %rax, %r13"));
    lines = ya_push(lines, ys("    and %rax, %r12"));
    // x infinite or NaN, y zero, or y NaN: all NaN. A NaN sorts above
    // infinity as a bit pattern, which is the whole test, and the order is
    // what makes an infinite y answer with x itself: y is known finite by
    // the time |x| < |y| runs, and the only y that reaches here as
    // infinity is the one every finite x is under.
    lines = ya_push(lines, ys("    mov $9218868437227405312, %rax"));
    lines = ya_push(lines, ys("    cmp %rax, %r13"));
    lines = ya_push(lines, ys("    jge yfm_nan"));
    lines = ya_push(lines, ys("    test %r12, %r12"));
    lines = ya_push(lines, ys("    jz yfm_nan"));
    lines = ya_push(lines, ys("    cmp %rax, %r12"));
    lines = ya_push(lines, ys("    jle yfm_y_le_inf"));
    lines = ya_push(lines, ys("    jmp yfm_nan"));
    lines = ya_push(lines, ys("yfm_y_le_inf:"));
    lines = ya_push(lines, ys("    cmp %r12, %r13"));
    lines = ya_push(lines, ys("    jl yfm_ret_x"));
    // e = field(x) - field(y), plus one for each side that is subnormal:
    // its significand is half as big, so it sits a power of two lower
    lines = ya_push(lines, ys("    mov %r13, %rsi"));
    lines = ya_push(lines, ys("    shr $52, %rsi"));
    lines = ya_push(lines, ys("    mov %r12, %rcx"));
    lines = ya_push(lines, ys("    shr $52, %rcx"));
    lines = ya_push(lines, ys("    sub %rcx, %rsi"));
    // A subnormal's significand carries no implicit bit, so its exponent is
    // one lower than its field says -- +1 for x above, and the same -1 for
    // y here, since e is the difference of the two.
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jnz yfm_ynorm"));
    lines = ya_push(lines, ys("    dec %rsi"));
    lines = ya_push(lines, ys("yfm_ynorm:"));
    lines = ya_push(lines, ys("    mov %r13, %rdx"));
    lines = ya_push(lines, ys("    shr $52, %rdx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    jnz yfm_got_e"));
    lines = ya_push(lines, ys("    inc %rsi"));
    lines = ya_push(lines, ys("yfm_got_e:"));
    lines = ya_push(lines, ys("    mov %rsi, %r14"));
    // ey: a subnormal sits at -1074, everything else at field - 1075
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jnz yfm_ey_norm"));
    lines = ya_push(lines, ys("    mov $-1074, %r15"));
    lines = ya_push(lines, ys("    jmp yfm_have_ey"));
    lines = ya_push(lines, ys("yfm_ey_norm:"));
    lines = ya_push(lines, ys("    mov %rcx, %r15"));
    lines = ya_push(lines, ys("    add $-1075, %r15"));
    lines = ya_push(lines, ys("yfm_have_ey:"));
    // mx and my, with the implicit leading bit where there is one
    lines = ya_push(lines, ys("    mov $4503599627370495, %rax"));
    lines = ya_push(lines, ys("    mov %r13, %rdx"));
    lines = ya_push(lines, ys("    and %rax, %rdx"));
    lines = ya_push(lines, ys("    mov %r12, %rdi"));
    lines = ya_push(lines, ys("    and %rax, %rdi"));
    lines = ya_push(lines, ys("    mov $4503599627370496, %rax"));
    lines = ya_push(lines, ys("    mov %r13, %rsi"));
    lines = ya_push(lines, ys("    shr $52, %rsi"));
    lines = ya_push(lines, ys("    test %rsi, %rsi"));
    lines = ya_push(lines, ys("    jz yfm_mx_done"));
    lines = ya_push(lines, ys("    add %rax, %rdx"));
    lines = ya_push(lines, ys("yfm_mx_done:"));
    lines = ya_push(lines, ys("    mov %r12, %rsi"));
    lines = ya_push(lines, ys("    shr $52, %rsi"));
    lines = ya_push(lines, ys("    test %rsi, %rsi"));
    lines = ya_push(lines, ys("    jz yfm_my_done"));
    lines = ya_push(lines, ys("    add %rax, %rdi"));
    lines = ya_push(lines, ys("yfm_my_done:"));
    // mx % my -- both fit in 53 bits, so the 128-bit divide never widens
    lines = ya_push(lines, ys("    mov %rdi, %rcx"));
    lines = ya_push(lines, ys("    mov %rdx, %rax"));
    lines = ya_push(lines, ys("    xor %edx, %edx"));
    lines = ya_push(lines, ys("    div %rcx"));
    lines = ya_push(lines, ys("    mov %rdx, %r12"));
    lines = ya_push(lines, ys("    mov %rdi, %r13"));
    lines = ya_push(lines, ys("    mov $1, %rcx"));
    lines = ya_push(lines, ys("yfm_loop:"));
    lines = ya_push(lines, ys("    cmp %r14, %rcx"));
    lines = ya_push(lines, ys("    jg yfm_put"));
    lines = ya_push(lines, ys("    add %r12, %r12"));
    lines = ya_push(lines, ys("    cmp %r13, %r12"));
    lines = ya_push(lines, ys("    jl yfm_next"));
    lines = ya_push(lines, ys("    sub %r13, %r12"));
    lines = ya_push(lines, ys("yfm_next:"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    jmp yfm_loop"));
    // The remainder is r * 2^ey, and r is under 2^53, so its bit length
    // and y's exponent place it exactly.
    lines = ya_push(lines, ys("yfm_put:"));
    lines = ya_push(lines, ys("    test %r12, %r12"));
    lines = ya_push(lines, ys("    jz yfm_zero"));
    lines = ya_push(lines, ys("    mov %r12, %rax"));
    lines = ya_push(lines, ys("    xor %rcx, %rcx"));
    // shifts needed to empty r, so the loop leaves k = the exponent
    lines = ya_push(lines, ys("yfm_len:"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    jz yfm_len_done"));
    lines = ya_push(lines, ys("    shr $1, %rax"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    jmp yfm_len"));
    lines = ya_push(lines, ys("yfm_len_done:"));
    lines = ya_push(lines, ys("    dec %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, %rsi"));
    lines = ya_push(lines, ys("    mov %rsi, %rdx"));
    lines = ya_push(lines, ys("    add %r15, %rdx"));
    lines = ya_push(lines, ys("    add $1023, %rdx"));
    lines = ya_push(lines, ys("    cmp $1, %rdx"));
    lines = ya_push(lines, ys("    jl yfm_sub"));
    lines = ya_push(lines, ys("    mov $52, %rcx"));
    lines = ya_push(lines, ys("    sub %rsi, %rcx"));
    lines = ya_push(lines, ys("    mov %r12, %rax"));
    lines = ya_push(lines, ys("    shl %cl, %rax"));
    // a normal's leading bit is implicit, and bit 52 of the pattern is the
    // exponent's -- so it comes off before the field goes in
    lines = ya_push(lines, ys("    mov $4503599627370496, %rsi"));
    lines = ya_push(lines, ys("    sub %rsi, %rax"));
    lines = ya_push(lines, ys("    shl $52, %rdx"));
    lines = ya_push(lines, ys("    or %rdx, %rax"));
    lines = ya_push(lines, ys("    jmp yfm_sign"));
    lines = ya_push(lines, ys("yfm_zero:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("    jmp yfm_sign"));
    // Under the smallest normal, so the value is m * 2^-1074. The bits
    // that shift out are zero -- or this remainder would not be a double.
    lines = ya_push(lines, ys("yfm_sub:"));
    lines = ya_push(lines, ys("    mov %r15, %rdx"));
    lines = ya_push(lines, ys("    add $1074, %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, %rcx"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jle yfm_sub_shr"));
    lines = ya_push(lines, ys("    mov %r12, %rax"));
    lines = ya_push(lines, ys("    shl %cl, %rax"));
    lines = ya_push(lines, ys("    jmp yfm_sign"));
    lines = ya_push(lines, ys("yfm_sub_shr:"));
    lines = ya_push(lines, ys("    neg %rcx"));
    lines = ya_push(lines, ys("    mov %r12, %rax"));
    lines = ya_push(lines, ys("    shr %cl, %rax"));
    lines = ya_push(lines, ys("    jmp yfm_sign"));
    lines = ya_push(lines, ys("yfm_sign:"));
    // The remainder carries x's sign and nothing else. A shift by 63 keeps
    // bit 0, not bit 63, so the sign comes down and goes back up.
    lines = ya_push(lines, ys("    mov %rbx, %rcx"));
    lines = ya_push(lines, ys("    shr $63, %rcx"));
    lines = ya_push(lines, ys("    shl $63, %rcx"));
    lines = ya_push(lines, ys("    or %rcx, %rax"));
    lines = ya_push(lines, ys("    movq %rax, %xmm0"));
    lines = ya_push(lines, ys("    jmp yfm_done"));
    lines = ya_push(lines, ys("yfm_nan:"));
    lines = ya_push(lines, ys("    mov $9220233022162178560, %rax"));
    lines = ya_push(lines, ys("    movq %rax, %xmm0"));
    lines = ya_push(lines, ys("    jmp yfm_done"));
    lines = ya_push(lines, ys("yfm_ret_x:"));
    lines = ya_push(lines, ys("    mov %rbx, %rax"));
    lines = ya_push(lines, ys("    movq %rax, %xmm0"));
    lines = ya_push(lines, ys("yfm_done:"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_str_slice:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rax"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r14"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    cmp $0, %rax"));
    lines = ya_push(lines, ys("    jge ysb_look"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("ysb_look:"));
    lines = ya_push(lines, ys("    cmp %rcx, %r14"));
    lines = ya_push(lines, ys("    jle ysb_hiok"));
    lines = ya_push(lines, ys("    mov %rcx, %r14"));
    lines = ya_push(lines, ys("ysb_hiok:"));
    lines = ya_push(lines, ys("    sub %rax, %r14"));
    lines = ya_push(lines, ys("    jle ysb_empty"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    mov %rax, %r12"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov %rax, %r13"));
    lines = ya_push(lines, ys("    mov %r13, %rdi"));
    lines = ya_push(lines, ys("    add $8, %rdi"));
    lines = ya_push(lines, ys("    mov %rbx, %rsi"));
    lines = ya_push(lines, ys("    add $8, %rsi"));
    lines = ya_push(lines, ys("    add %r12, %rsi"));
    lines = ya_push(lines, ys("    mov %r14, %rcx"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jz ysb_nocopy"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("ysb_nocopy:"));
    lines = ya_push(lines, ys("    mov %r14, (%r13)"));
    lines = ya_push(lines, ys("    movb $0, 8(%r13,%r14,1)"));
    lines = ya_push(lines, ys("    mov %r13, %rax"));
    lines = ya_push(lines, ys("    jmp ysb_done"));
    lines = ya_push(lines, ys("ysb_empty:"));
    lines = ya_push(lines, ys("    mov $16, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov $0, (%rax)"));
    lines = ya_push(lines, ys("    movb $0, 8(%rax)"));
    lines = ya_push(lines, ys("ysb_done:"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* y_str_index(hay, needle) -> the first i at which needle occurs in */
    /* hay, or -1 (an empty needle never matches): a scan for the needle's */
    /* first byte, the rest compared where it is found. Assembly, as the */
    /* scan cost ~40 instructions a byte in Y (the assembler searches each */
    /* of its lines). */
    lines = ya_push(lines, ys("y_str_index:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rsi"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rdi"));
    lines = ya_push(lines, ys("    mov $-1, %rax"));
    lines = ya_push(lines, ys("    mov (%rdi), %r9"));
    lines = ya_push(lines, ys("    test %r9, %r9"));
    lines = ya_push(lines, ys("    jz ysi_done"));
    lines = ya_push(lines, ys("    mov (%rsi), %r10"));
    lines = ya_push(lines, ys("    sub %r9, %r10"));
    lines = ya_push(lines, ys("    js ysi_done"));
    lines = ya_push(lines, ys("    movzbq 8(%rdi), %r11"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("ysi_scan:"));
    lines = ya_push(lines, ys("    cmp %r10, %rcx"));
    lines = ya_push(lines, ys("    jg ysi_done"));
    lines = ya_push(lines, ys("    movzbq 8(%rsi,%rcx,1), %rdx"));
    lines = ya_push(lines, ys("    cmp %r11, %rdx"));
    lines = ya_push(lines, ys("    je ysi_first"));
    lines = ya_push(lines, ys("ysi_next:"));
    lines = ya_push(lines, ys("    add $1, %rcx"));
    lines = ya_push(lines, ys("    jmp ysi_scan"));
    lines = ya_push(lines, ys("ysi_first:"));
    lines = ya_push(lines, ys("    mov %rsi, %rbx"));
    lines = ya_push(lines, ys("    add %rcx, %rbx"));
    lines = ya_push(lines, ys("    mov $1, %r8"));
    lines = ya_push(lines, ys("ysi_rest:"));
    lines = ya_push(lines, ys("    cmp %r9, %r8"));
    lines = ya_push(lines, ys("    jge ysi_hit"));
    lines = ya_push(lines, ys("    movzbq 8(%rbx,%r8,1), %rdx"));
    lines = ya_push(lines, ys("    movzbq 8(%rdi,%r8,1), %r12"));
    lines = ya_push(lines, ys("    cmp %r12, %rdx"));
    lines = ya_push(lines, ys("    jne ysi_next"));
    lines = ya_push(lines, ys("    add $1, %r8"));
    lines = ya_push(lines, ys("    jmp ysi_rest"));
    lines = ya_push(lines, ys("ysi_hit:"));
    lines = ya_push(lines, ys("    mov %rcx, %rax"));
    lines = ya_push(lines, ys("ysi_done:"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* y_str_trim(s) -> s without the spaces, tabs, newlines and carriage */
    /* returns at its ends; s itself when there are none. */
    lines = ya_push(lines, ys("y_str_trim:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rsi"));
    lines = ya_push(lines, ys("    mov (%rsi), %r9"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("yst_lead:"));
    lines = ya_push(lines, ys("    cmp %r9, %rcx"));
    lines = ya_push(lines, ys("    jge yst_cut"));
    lines = ya_push(lines, ys("    movzbq 8(%rsi,%rcx,1), %rdx"));
    lines = ya_push(lines, ys("    cmp $32, %rdx"));
    lines = ya_push(lines, ys("    je yst_lead1"));
    lines = ya_push(lines, ys("    cmp $9, %rdx"));
    lines = ya_push(lines, ys("    je yst_lead1"));
    lines = ya_push(lines, ys("    cmp $10, %rdx"));
    lines = ya_push(lines, ys("    je yst_lead1"));
    lines = ya_push(lines, ys("    cmp $13, %rdx"));
    lines = ya_push(lines, ys("    jne yst_trail"));
    lines = ya_push(lines, ys("yst_lead1:"));
    lines = ya_push(lines, ys("    add $1, %rcx"));
    lines = ya_push(lines, ys("    jmp yst_lead"));
    lines = ya_push(lines, ys("yst_trail:"));
    lines = ya_push(lines, ys("    cmp %rcx, %r9"));
    lines = ya_push(lines, ys("    jle yst_cut"));
    lines = ya_push(lines, ys("    movzbq 7(%rsi,%r9,1), %rdx"));
    lines = ya_push(lines, ys("    cmp $32, %rdx"));
    lines = ya_push(lines, ys("    je yst_trail1"));
    lines = ya_push(lines, ys("    cmp $9, %rdx"));
    lines = ya_push(lines, ys("    je yst_trail1"));
    lines = ya_push(lines, ys("    cmp $10, %rdx"));
    lines = ya_push(lines, ys("    je yst_trail1"));
    lines = ya_push(lines, ys("    cmp $13, %rdx"));
    lines = ya_push(lines, ys("    jne yst_cut"));
    lines = ya_push(lines, ys("yst_trail1:"));
    lines = ya_push(lines, ys("    sub $1, %r9"));
    lines = ya_push(lines, ys("    jmp yst_trail"));
    lines = ya_push(lines, ys("yst_cut:"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    jnz yst_slice"));
    lines = ya_push(lines, ys("    mov (%rsi), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %r9"));
    lines = ya_push(lines, ys("    jne yst_slice"));
    lines = ya_push(lines, ys("    mov %rsi, %rax"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("yst_slice:"));
    lines = ya_push(lines, ys("    push %rsi"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    push %r9"));
    lines = ya_push(lines, ys("    call y_str_slice"));
    lines = ya_push(lines, ys("    add $24, %rsp"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* y_str_split(s, sep) -> [str]: s cut at every non-overlapping match */
    /* of sep; a trailing empty piece is dropped ("a," -> ["a"]), an empty */
    /* sep gives no pieces. Assembly for the scan, as y_str_index. */
    lines = ya_push(lines, ys("y_str_split:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov $8, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov $24, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 16(%rax)"));
    lines = ya_push(lines, ys("    mov %rax, %r15"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov (%r12), %r13"));
    lines = ya_push(lines, ys("    test %r13, %r13"));
    lines = ya_push(lines, ys("    jz yss_done"));
    lines = ya_push(lines, ys("    xor %r14d, %r14d"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("yss_scan:"));
    lines = ya_push(lines, ys("    mov (%rbx), %rax"));
    lines = ya_push(lines, ys("    sub %r13, %rax"));
    lines = ya_push(lines, ys("    cmp %rax, %rcx"));
    lines = ya_push(lines, ys("    jg yss_tail"));
    lines = ya_push(lines, ys("    movzbq 8(%rbx,%rcx,1), %rax"));
    lines = ya_push(lines, ys("    movzbq 8(%r12), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %rax"));
    lines = ya_push(lines, ys("    jne yss_next"));
    lines = ya_push(lines, ys("    mov $1, %r8"));
    lines = ya_push(lines, ys("yss_rest:"));
    lines = ya_push(lines, ys("    cmp %r13, %r8"));
    lines = ya_push(lines, ys("    jge yss_hit"));
    lines = ya_push(lines, ys("    mov %rcx, %r9"));
    lines = ya_push(lines, ys("    add %r8, %r9"));
    lines = ya_push(lines, ys("    movzbq 8(%rbx,%r9,1), %rax"));
    lines = ya_push(lines, ys("    movzbq 8(%r12,%r8,1), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %rax"));
    lines = ya_push(lines, ys("    jne yss_next"));
    lines = ya_push(lines, ys("    add $1, %r8"));
    lines = ya_push(lines, ys("    jmp yss_rest"));
    lines = ya_push(lines, ys("yss_hit:"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    call y_str_slice"));
    lines = ya_push(lines, ys("    add $24, %rsp"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov $8, %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    call y_arr_push"));
    lines = ya_push(lines, ys("    add $24, %rsp"));
    lines = ya_push(lines, ys("    pop %rcx"));
    lines = ya_push(lines, ys("    add %r13, %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, %r14"));
    lines = ya_push(lines, ys("    jmp yss_scan"));
    lines = ya_push(lines, ys("yss_next:"));
    lines = ya_push(lines, ys("    add $1, %rcx"));
    lines = ya_push(lines, ys("    jmp yss_scan"));
    lines = ya_push(lines, ys("yss_tail:"));
    lines = ya_push(lines, ys("    mov (%rbx), %rax"));
    lines = ya_push(lines, ys("    cmp %rax, %r14"));
    lines = ya_push(lines, ys("    jge yss_done"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    call y_str_slice"));
    lines = ya_push(lines, ys("    add $24, %rsp"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov $8, %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    call y_arr_push"));
    lines = ya_push(lines, ys("    add $24, %rsp"));
    lines = ya_push(lines, ys("yss_done:"));
    lines = ya_push(lines, ys("    mov %r15, %rax"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_arr_cat(l, r, esz) -> NEW array = l ++ r (the copy form of
    // `+`; the operands are untouched). esz is the element width.
    lines = ya_push(lines, ys("y_arr_cat:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r9"));
    lines = ya_push(lines, ys("    mov (%rbx), %r13"));
    lines = ya_push(lines, ys("    mov (%r12), %rdx"));
    lines = ya_push(lines, ys("    add %rdx, %r13"));
    lines = ya_push(lines, ys("    mov %r13, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    cmp $8, %rdi"));
    lines = ya_push(lines, ys("    jge ycat_sz"));
    lines = ya_push(lines, ys("    mov $8, %rdi"));
    lines = ya_push(lines, ys("ycat_sz:"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov $24, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    mov %r13, (%rax)"));
    lines = ya_push(lines, ys("    mov %r13, 8(%rax)"));
    lines = ya_push(lines, ys("    mov %r14, 16(%rax)"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    xor %r15d, %r15d"));
    lines = ya_push(lines, ys("ycat_l:"));
    lines = ya_push(lines, ys("    mov (%rbx), %rdi"));
    lines = ya_push(lines, ys("    cmp %rdi, %r15"));
    lines = ya_push(lines, ys("    jge ycat_r"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rsi"));
    lines = ya_push(lines, ys("    mov %r15, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    add %rsi, %rax"));
    lines = ya_push(lines, ys("    mov %r15, %rsi"));
    lines = ya_push(lines, ys("    imul %r9, %rsi"));
    lines = ya_push(lines, ys("    add %r14, %rsi"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je ycat_l1"));
    lines = ya_push(lines, ys("    mov (%rax), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, (%rsi)"));
    lines = ya_push(lines, ys("    jmp ycat_ln"));
    lines = ya_push(lines, ys("ycat_l1:"));
    lines = ya_push(lines, ys("    movzbq (%rax), %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%rsi)"));
    lines = ya_push(lines, ys("ycat_ln:"));
    lines = ya_push(lines, ys("    inc %r15"));
    lines = ya_push(lines, ys("    jmp ycat_l"));
    lines = ya_push(lines, ys("ycat_r:"));
    lines = ya_push(lines, ys("    xor %r15d, %r15d"));
    lines = ya_push(lines, ys("ycat_rl:"));
    lines = ya_push(lines, ys("    mov (%r12), %rdi"));
    lines = ya_push(lines, ys("    cmp %rdi, %r15"));
    lines = ya_push(lines, ys("    jge ycat_done"));
    lines = ya_push(lines, ys("    mov 16(%r12), %rsi"));
    lines = ya_push(lines, ys("    mov %r15, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    add %rsi, %rax"));
    lines = ya_push(lines, ys("    mov %r15, %rsi"));
    lines = ya_push(lines, ys("    mov (%rbx), %rdx"));
    lines = ya_push(lines, ys("    add %rdx, %rsi"));
    lines = ya_push(lines, ys("    imul %r9, %rsi"));
    lines = ya_push(lines, ys("    add %r14, %rsi"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je ycat_r1"));
    lines = ya_push(lines, ys("    mov (%rax), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, (%rsi)"));
    lines = ya_push(lines, ys("    jmp ycat_rn"));
    lines = ya_push(lines, ys("ycat_r1:"));
    lines = ya_push(lines, ys("    movzbq (%rax), %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%rsi)"));
    lines = ya_push(lines, ys("ycat_rn:"));
    lines = ya_push(lines, ys("    inc %r15"));
    lines = ya_push(lines, ys("    jmp ycat_rl"));
    lines = ya_push(lines, ys("ycat_done:"));
    lines = ya_push(lines, ys("    pop %rax"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_arr_prepend(arr, val, esz) -> arr with val inserted at the
    // front, IN PLACE (the header never moves — every alias sees it).
    // The header's fourth word, front, counts the free element slots
    // before data in its block: a prepend with front > 0 steps data
    // back one slot. Otherwise the elements move to a new block with
    // max(len, 8) slots of room in front and the same room behind, so
    // n prepends cost O(n) moves in all, like n pushes.
    lines = ya_push(lines, ys("y_arr_prepend:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r9"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    mov 24(%rbx), %rdx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    jz yapd_grow"));
    lines = ya_push(lines, ys("    dec %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 24(%rbx)"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %r13"));
    lines = ya_push(lines, ys("    sub %r9, %r13"));
    lines = ya_push(lines, ys("    mov %r13, 16(%rbx)"));
    lines = ya_push(lines, ys("    mov 8(%rbx), %rdx"));
    lines = ya_push(lines, ys("    inc %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%rbx)"));
    lines = ya_push(lines, ys("    jmp yapd_put"));
    lines = ya_push(lines, ys("yapd_grow:"));
    lines = ya_push(lines, ys("    mov %rcx, %r14"));
    lines = ya_push(lines, ys("    cmp $8, %r14"));
    lines = ya_push(lines, ys("    jge yapd_room"));
    lines = ya_push(lines, ys("    mov $8, %r14"));
    lines = ya_push(lines, ys("yapd_room:"));
    lines = ya_push(lines, ys("    mov 8(%rbx), %rdi"));
    lines = ya_push(lines, ys("    add %r14, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    push %r9"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r9"));
    lines = ya_push(lines, ys("    pop %rcx"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %r15"));
    lines = ya_push(lines, ys("    mov %r14, %r13"));
    lines = ya_push(lines, ys("    dec %r13"));
    lines = ya_push(lines, ys("    mov %r13, 24(%rbx)"));
    lines = ya_push(lines, ys("    imul %r9, %r13"));
    lines = ya_push(lines, ys("    add %rax, %r13"));
    lines = ya_push(lines, ys("    mov %r13, 16(%rbx)"));
    lines = ya_push(lines, ys("    mov 8(%rbx), %rdx"));
    lines = ya_push(lines, ys("    inc %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%rbx)"));
    lines = ya_push(lines, ys("    xor %esi, %esi"));
    lines = ya_push(lines, ys("yapd_cp:"));
    lines = ya_push(lines, ys("    cmp %rcx, %rsi"));
    lines = ya_push(lines, ys("    jge yapd_put"));
    lines = ya_push(lines, ys("    mov %rsi, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    add %r15, %rax"));
    lines = ya_push(lines, ys("    mov %rsi, %rdi"));
    lines = ya_push(lines, ys("    inc %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    add %r13, %rdi"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je yapd_cp1"));
    lines = ya_push(lines, ys("    mov (%rax), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, (%rdi)"));
    lines = ya_push(lines, ys("    jmp yapd_cpn"));
    lines = ya_push(lines, ys("yapd_cp1:"));
    lines = ya_push(lines, ys("    movzbq (%rax), %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%rdi)"));
    lines = ya_push(lines, ys("yapd_cpn:"));
    lines = ya_push(lines, ys("    inc %rsi"));
    lines = ya_push(lines, ys("    jmp yapd_cp"));
    lines = ya_push(lines, ys("yapd_put:"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %r13"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je yapd_p1"));
    lines = ya_push(lines, ys("    mov %r12, (%r13)"));
    lines = ya_push(lines, ys("    jmp yapd_pn"));
    lines = ya_push(lines, ys("yapd_p1:"));
    lines = ya_push(lines, ys("    mov %r12, %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%r13)"));
    lines = ya_push(lines, ys("yapd_pn:"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, (%rbx)"));
    lines = ya_push(lines, ys("    mov %rbx, %rax"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_arr_push(arr, val, esz) -> arr. esz is the element width; one
    // implementation covers packed [byte] and word-per-element arrays
    // alike. The header is {len, cap, data, front} and NEVER moves
    // (elements live in a separate block), so growth is invisible to
    // aliases, `arr += v` is truly in place, and the returned header is
    // the one the caller passed in. Capacity doubles when reached (8
    // first), matching yv.c's ya_push; a grown block has no room in
    // front, so front becomes 0 (y_arr_prepend).
    lines = ya_push(lines, ys("y_arr_push:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %r12"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r9"));
    lines = ya_push(lines, ys("    mov (%rbx), %rcx"));
    lines = ya_push(lines, ys("    mov 8(%rbx), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %rcx"));
    lines = ya_push(lines, ys("    jz yap_grow"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %r13"));
    lines = ya_push(lines, ys("    mov %rcx, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    add %r13, %rax"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je yap_st1"));
    lines = ya_push(lines, ys("    mov %r12, (%rax)"));
    lines = ya_push(lines, ys("    jmp yap_stn"));
    lines = ya_push(lines, ys("yap_st1:"));
    lines = ya_push(lines, ys("    mov %r12, %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%rax)"));
    lines = ya_push(lines, ys("yap_stn:"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, (%rbx)"));
    lines = ya_push(lines, ys("    mov %rbx, %rax"));
    lines = ya_push(lines, ys("    jmp yap_done"));
    lines = ya_push(lines, ys("yap_grow:"));
    lines = ya_push(lines, ys("    mov %rdx, %r13"));
    lines = ya_push(lines, ys("    shl $1, %r13"));
    lines = ya_push(lines, ys("    cmp $8, %r13"));
    lines = ya_push(lines, ys("    jge yap_cap"));
    lines = ya_push(lines, ys("    mov $8, %r13"));
    lines = ya_push(lines, ys("yap_cap:"));
    lines = ya_push(lines, ys("    mov %r13, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    push %r9"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r9"));
    lines = ya_push(lines, ys("    pop %rcx"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %r15"));
    lines = ya_push(lines, ys("    mov %r13, 8(%rbx)"));
    lines = ya_push(lines, ys("    mov %r14, 16(%rbx)"));
    lines = ya_push(lines, ys("    xor %esi, %esi"));
    lines = ya_push(lines, ys("    mov %rsi, 24(%rbx)"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    mov %r15, %rsi"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rcx"));
    lines = ya_push(lines, ys("    call y_mem_copy"));
    lines = ya_push(lines, ys("    pop %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, %rax"));
    lines = ya_push(lines, ys("    imul %r9, %rax"));
    lines = ya_push(lines, ys("    add %r14, %rax"));
    lines = ya_push(lines, ys("    cmp $1, %r9"));
    lines = ya_push(lines, ys("    je yap_last1"));
    lines = ya_push(lines, ys("    mov %r12, (%rax)"));
    lines = ya_push(lines, ys("    jmp yap_lastn"));
    lines = ya_push(lines, ys("yap_last1:"));
    lines = ya_push(lines, ys("    mov %r12, %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%rax)"));
    lines = ya_push(lines, ys("yap_lastn:"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, (%rbx)"));
    lines = ya_push(lines, ys("    mov %rbx, %rax"));
    lines = ya_push(lines, ys("yap_done:"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* y_arr_extend(arr, other, esz) -> arr: other's elements appended */
    /* (`arr += other` when the element types are one: native.y */
    /* gen_opassign_arr). The block grows once, to the capacity pushing them */
    /* one by one would reach (doubling from 8), and the elements move in */
    /* bulk. other's length and block are read first, so `a += a` doubles a. */
    lines = ya_push(lines, ys("y_arr_extend:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 32(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rax"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r9"));
    lines = ya_push(lines, ys("    mov (%rax), %r12"));
    lines = ya_push(lines, ys("    mov 16(%rax), %r13"));
    lines = ya_push(lines, ys("    mov (%rbx), %r14"));
    lines = ya_push(lines, ys("    mov %r14, %r15"));
    lines = ya_push(lines, ys("    add %r12, %r15"));
    lines = ya_push(lines, ys("    mov 8(%rbx), %rdx"));
    lines = ya_push(lines, ys("    cmp %rdx, %r15"));
    lines = ya_push(lines, ys("    jle yax_copy"));
    lines = ya_push(lines, ys("yax_cap:"));
    lines = ya_push(lines, ys("    shl $1, %rdx"));
    lines = ya_push(lines, ys("    cmp $8, %rdx"));
    lines = ya_push(lines, ys("    jge yax_cap1"));
    lines = ya_push(lines, ys("    mov $8, %rdx"));
    lines = ya_push(lines, ys("yax_cap1:"));
    lines = ya_push(lines, ys("    cmp %r15, %rdx"));
    lines = ya_push(lines, ys("    jl yax_cap"));
    lines = ya_push(lines, ys("    mov %rdx, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    push %r9"));
    lines = ya_push(lines, ys("    push %rdx"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %rdx"));
    lines = ya_push(lines, ys("    pop %r9"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%rbx)"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rsi"));
    lines = ya_push(lines, ys("    mov %rax, 16(%rbx)"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("    mov %rcx, 24(%rbx)"));
    lines = ya_push(lines, ys("    mov %rax, %rdi"));
    lines = ya_push(lines, ys("    mov %r14, %rcx"));
    lines = ya_push(lines, ys("    imul %r9, %rcx"));
    lines = ya_push(lines, ys("    call y_mem_copy"));
    lines = ya_push(lines, ys("yax_copy:"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    imul %r9, %rdi"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rax"));
    lines = ya_push(lines, ys("    add %rax, %rdi"));
    lines = ya_push(lines, ys("    mov %r13, %rsi"));
    lines = ya_push(lines, ys("    mov %r12, %rcx"));
    lines = ya_push(lines, ys("    imul %r9, %rcx"));
    lines = ya_push(lines, ys("    call y_mem_copy"));
    lines = ya_push(lines, ys("    mov %r15, (%rbx)"));
    lines = ya_push(lines, ys("    mov %rbx, %rax"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* y_mem_copy: %rcx bytes from %rsi to %rdi (apart), eight at a time, */
    /* then the rest one by one: nothing read or written past either end. */
    /* Clobbers %rax, %rdx and %r8. */
    lines = ya_push(lines, ys("y_mem_copy:"));
    lines = ya_push(lines, ys("    xor %r8d, %r8d"));
    lines = ya_push(lines, ys("    mov %rcx, %rax"));
    lines = ya_push(lines, ys("    and $-8, %rax"));
    lines = ya_push(lines, ys("ymc_words:"));
    lines = ya_push(lines, ys("    cmp %rax, %r8"));
    lines = ya_push(lines, ys("    jge ymc_bytes"));
    lines = ya_push(lines, ys("    mov (%rsi,%r8,1), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, (%rdi,%r8,1)"));
    lines = ya_push(lines, ys("    add $8, %r8"));
    lines = ya_push(lines, ys("    jmp ymc_words"));
    lines = ya_push(lines, ys("ymc_bytes:"));
    lines = ya_push(lines, ys("    cmp %rcx, %r8"));
    lines = ya_push(lines, ys("    jge ymc_done"));
    lines = ya_push(lines, ys("    movzbq (%rsi,%r8,1), %rdx"));
    lines = ya_push(lines, ys("    movb %dl, (%rdi,%r8,1)"));
    lines = ya_push(lines, ys("    add $1, %r8"));
    lines = ya_push(lines, ys("    jmp ymc_bytes"));
    lines = ya_push(lines, ys("ymc_done:"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_argv_init:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov 24(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %r13"));
    lines = ya_push(lines, ys("    mov %r13, %rax"));
    lines = ya_push(lines, ys("    shl $3, %rax"));
    lines = ya_push(lines, ys("    cmp $8, %rax"));
    lines = ya_push(lines, ys("    jge yai_sz"));
    lines = ya_push(lines, ys("    mov $8, %rax"));
    lines = ya_push(lines, ys("yai_sz:"));
    lines = ya_push(lines, ys("    mov %rax, %rdi"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov $24, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    mov %rax, %r15"));
    lines = ya_push(lines, ys("    mov %r13, (%r15)"));
    lines = ya_push(lines, ys("    mov %r13, 8(%r15)"));
    lines = ya_push(lines, ys("    mov %r14, 16(%r15)"));
    lines = ya_push(lines, ys("    xor %r14d, %r14d"));
    lines = ya_push(lines, ys("yai_loop:"));
    lines = ya_push(lines, ys("    cmp %r13, %r14"));
    lines = ya_push(lines, ys("    jge yai_done"));
    lines = ya_push(lines, ys("    mov (%rbx,%r14,8), %rcx"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %r15"));
    lines = ya_push(lines, ys("    mov %rcx, %rdi"));
    lines = ya_push(lines, ys("    call y_cstr_to_str"));
    lines = ya_push(lines, ys("    mov %rax, %rcx"));
    lines = ya_push(lines, ys("    pop %r15"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    add $8, %rsp"));
    lines = ya_push(lines, ys("    mov 16(%r15), %rax"));
    lines = ya_push(lines, ys("    mov %rcx, (%rax,%r14,8)"));
    lines = ya_push(lines, ys("    inc %r14"));
    lines = ya_push(lines, ys("    jmp yai_loop"));
    lines = ya_push(lines, ys("yai_done:"));
    lines = ya_push(lines, ys("    mov %r15, %rax"));
    lines = ya_push(lines, ys("    add $8, %rsp"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_argv:"));
    lines = ya_push(lines, ys("    mov %r15, %rax"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_cstr_to_str:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov %rdi, %rbx"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("ycs_len:"));
    lines = ya_push(lines, ys("    movzbq (%rbx,%rcx,1), %rax"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    jz ycs_mk"));
    lines = ya_push(lines, ys("    inc %rcx"));
    lines = ya_push(lines, ys("    jmp ycs_len"));
    lines = ya_push(lines, ys("ycs_mk:"));
    lines = ya_push(lines, ys("    mov %rcx, %r13"));
    lines = ya_push(lines, ys("    mov %rcx, %r14"));
    lines = ya_push(lines, ys("    mov %rcx, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    mov %rax, %rdi"));
    lines = ya_push(lines, ys("    mov %r13, (%rdi)"));
    lines = ya_push(lines, ys("    mov %r14, %rcx"));
    lines = ya_push(lines, ys("    mov %rbx, %rsi"));
    lines = ya_push(lines, ys("    mov %rdi, %rax"));
    lines = ya_push(lines, ys("    add $8, %rax"));
    lines = ya_push(lines, ys("    mov %rax, %rdi"));
    lines = ya_push(lines, ys("    push %rdi"));
    lines = ya_push(lines, ys("    push %rsi"));
    lines = ya_push(lines, ys("    push %rcx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    call ysc_copy"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rcx"));
    lines = ya_push(lines, ys("    pop %rsi"));
    lines = ya_push(lines, ys("    pop %rdi"));
    lines = ya_push(lines, ys("    movb $0, 8(%rdi,%r13,1)"));
    lines = ya_push(lines, ys("    mov %rdi, %rax"));
    lines = ya_push(lines, ys("    sub $8, %rax"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_str_to_bytes(s) -> [byte]: copy the string's bytes into a
    // packed array header {len, cap, data...}. One byte per element.
    lines = ya_push(lines, ys("y_str_to_bytes:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov (%rbx), %r13"));
    lines = ya_push(lines, ys("    mov %r13, %rdi"));
    lines = ya_push(lines, ys("    cmp $8, %rdi"));
    lines = ya_push(lines, ys("    jge ystb_sz"));
    lines = ya_push(lines, ys("    mov $8, %rdi"));
    lines = ya_push(lines, ys("ystb_sz:"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov $24, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    mov %r13, (%rax)"));
    lines = ya_push(lines, ys("    mov %r13, 8(%rax)"));
    lines = ya_push(lines, ys("    mov %r14, 16(%rax)"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov %rbx, %rsi"));
    lines = ya_push(lines, ys("    add $8, %rsi"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    mov %r13, %rcx"));
    lines = ya_push(lines, ys("    call y_mem_copy"));
    lines = ya_push(lines, ys("    pop %rax"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    // y_bytes_to_str(b) -> str: the inverse. The result is a string
    // header {len, data..., NUL}.
    lines = ya_push(lines, ys("y_bytes_to_str:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r13"));
    lines = ya_push(lines, ys("    push %r14"));
    lines = ya_push(lines, ys("    mov 16(%rbp), %rbx"));
    lines = ya_push(lines, ys("    mov (%rbx), %r13"));
    lines = ya_push(lines, ys("    mov 16(%rbx), %rbx"));
    lines = ya_push(lines, ys("    mov %r13, %rdi"));
    lines = ya_push(lines, ys("    add $16, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov %rax, %r14"));
    lines = ya_push(lines, ys("    mov %r13, (%r14)"));
    lines = ya_push(lines, ys("    mov %rbx, %rsi"));
    lines = ya_push(lines, ys("    mov %r14, %rdi"));
    lines = ya_push(lines, ys("    add $8, %rdi"));
    lines = ya_push(lines, ys("    mov %r13, %rcx"));
    lines = ya_push(lines, ys("    call y_mem_copy"));
    lines = ya_push(lines, ys("    mov %r14, %rsi"));
    lines = ya_push(lines, ys("    add $8, %rsi"));
    lines = ya_push(lines, ys("    add %r13, %rsi"));
    lines = ya_push(lines, ys("    movb $0, (%rsi)"));
    lines = ya_push(lines, ys("    mov %r14, %rax"));
    lines = ya_push(lines, ys("    pop %r14"));
    lines = ya_push(lines, ys("    pop %r13"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    return lines;
}

// The thread runtime (CHOICES_MADE.md 33), linked only when a program's
// code calls into it (native.y uses_threads): every compile looks at
// each line of the prelude it is given.
Yv *arch_prelude_threads_lines(void) {
    Yv *lines = yav(0);
    /* The first spawn moves the main thread's heap state (cur, end, used) */
    /* into a block of its own, points %fs at it and empties the global */
    /* block: from then on y_alloc_slow sends every thread to its own block. */
    /* A thread's block is [cur, end, used, self, ...]: %fs:24 is its address. */
    lines = ya_push(lines, ys("y_threads_on:"));
    lines = ya_push(lines, ys("    lea y_heap(%rip), %rcx"));
    lines = ya_push(lines, ys("    mov 24(%rcx), %rdx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    jne y_threads_on_done"));
    lines = ya_push(lines, ys("    mov $48, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    lea y_heap(%rip), %rcx"));
    lines = ya_push(lines, ys("    mov (%rcx), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 0(%rax)"));
    lines = ya_push(lines, ys("    mov 8(%rcx), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%rax)"));
    lines = ya_push(lines, ys("    mov 16(%rcx), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 16(%rax)"));
    lines = ya_push(lines, ys("    mov %rax, 24(%rax)"));
    lines = ya_push(lines, ys("    xor %edx, %edx"));
    lines = ya_push(lines, ys("    mov %rdx, (%rcx)"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%rcx)"));
    lines = ya_push(lines, ys("    mov $1, %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 24(%rcx)"));
    lines = ya_push(lines, ys("    mov %rax, %rsi"));
    lines = ya_push(lines, ys("    mov $158, %rax"));
    lines = ya_push(lines, ys("    mov $4098, %rdi"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("y_threads_on_done:"));
    lines = ya_push(lines, ys("    ret"));
    /* spawn: %rax the block's closure -> %rax its handle, a closure */
    /* [y_join_code, tcb]. The thread control block is its heap block */
    /* [cur, end, used, self, stack, spare] then [tid, value, closure]; */
    /* the thread runs on an 8 MiB stack of its own (the mapping at */
    /* `stack`, a guard page below it), with %fs at the block. Its */
    /* heap starts in the spawning thread's first spare chunk tail, if */
    /* it has one: `spare` lists the tails its joins took back, each */
    /* tail's first two words [end, next]. */
    lines = ya_push(lines, ys("y_spawn:"));
    lines = ya_push(lines, ys("    push %rbp"));
    lines = ya_push(lines, ys("    mov %rsp, %rbp"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    push %r12"));
    lines = ya_push(lines, ys("    mov %rax, %rbx"));
    lines = ya_push(lines, ys("    call y_threads_on"));
    lines = ya_push(lines, ys("    mov $72, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    mov %rax, %r12"));
    lines = ya_push(lines, ys("    mov %r12, 24(%r12)"));
    lines = ya_push(lines, ys("    mov %rbx, 64(%r12)"));
    lines = ya_push(lines, ys("    mov %fs:24, %rcx"));
    lines = ya_push(lines, ys("    mov 40(%rcx), %rax"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    je y_spawn_stack"));
    lines = ya_push(lines, ys("    mov 8(%rax), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 40(%rcx)"));
    lines = ya_push(lines, ys("    mov 0(%rax), %rdx"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("    mov %rcx, 0(%rax)"));
    lines = ya_push(lines, ys("    mov %rcx, 8(%rax)"));
    lines = ya_push(lines, ys("    mov %rax, 0(%r12)"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%r12)"));
    lines = ya_push(lines, ys("y_spawn_stack:"));
    lines = ya_push(lines, ys("    mov $9, %rax"));
    lines = ya_push(lines, ys("    xor %edi, %edi"));
    lines = ya_push(lines, ys("    mov $8392704, %rsi"));
    lines = ya_push(lines, ys("    mov $3, %rdx"));
    lines = ya_push(lines, ys("    mov $131106, %r10"));
    lines = ya_push(lines, ys("    mov $-1, %r8"));
    lines = ya_push(lines, ys("    xor %r9d, %r9d"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    js y_alloc_fail"));
    lines = ya_push(lines, ys("    mov %rax, 32(%r12)"));
    lines = ya_push(lines, ys("    mov %rax, %rdi"));
    lines = ya_push(lines, ys("    mov $4096, %rsi"));
    lines = ya_push(lines, ys("    xor %edx, %edx"));
    lines = ya_push(lines, ys("    mov $10, %rax"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov 32(%r12), %rsi"));
    lines = ya_push(lines, ys("    add $8392688, %rsi"));
    lines = ya_push(lines, ys("    mov %r12, 0(%rsi)"));
    lines = ya_push(lines, ys("    mov $56, %rax"));
    lines = ya_push(lines, ys("    mov $4001536, %rdi"));
    lines = ya_push(lines, ys("    lea 48(%r12), %rdx"));
    lines = ya_push(lines, ys("    lea 48(%r12), %r10"));
    lines = ya_push(lines, ys("    mov %r12, %r8"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    je y_thread_start"));
    lines = ya_push(lines, ys("    js y_alloc_fail"));
    lines = ya_push(lines, ys("    mov $16, %rdi"));
    lines = ya_push(lines, ys("    call y_alloc"));
    lines = ya_push(lines, ys("    lea y_join_code(%rip), %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, 0(%rax)"));
    lines = ya_push(lines, ys("    mov %r12, 8(%rax)"));
    lines = ya_push(lines, ys("    pop %r12"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    pop %rbp"));
    lines = ya_push(lines, ys("    ret"));
    /* the new thread: its stack's top holds the tcb; it calls the */
    /* closure, keeps the value, unmaps its stack (nothing after the */
    /* munmap touches it) and ends (exit, not exit_group: the kernel */
    /* then clears tid, in the tcb, and wakes a join) */
    lines = ya_push(lines, ys("y_thread_start:"));
    lines = ya_push(lines, ys("    mov %rsp, %rax"));
    lines = ya_push(lines, ys("    mov 0(%rax), %r12"));
    lines = ya_push(lines, ys("    xor %ebp, %ebp"));
    lines = ya_push(lines, ys("    mov 64(%r12), %rax"));
    lines = ya_push(lines, ys("    push %rax"));
    lines = ya_push(lines, ys("    mov 0(%rax), %rax"));
    lines = ya_push(lines, ys("    call *%rax"));
    lines = ya_push(lines, ys("    mov %rax, 56(%r12)"));
    lines = ya_push(lines, ys("    mov 32(%r12), %rdi"));
    lines = ya_push(lines, ys("    mov $8392704, %rsi"));
    lines = ya_push(lines, ys("    mov $11, %rax"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    mov $60, %rax"));
    lines = ya_push(lines, ys("    xor %edi, %edi"));
    lines = ya_push(lines, ys("    syscall"));
    /* join: the handle called as a closure -> the thread's value, once */
    /* its tid is 0. The first join takes the unused tail of the */
    /* thread's chunk (a page or more; xchg takes it once) onto the */
    /* joining thread's spare list, for its next spawn. */
    lines = ya_push(lines, ys("y_join_code:"));
    lines = ya_push(lines, ys("    mov %rsp, %rax"));
    lines = ya_push(lines, ys("    mov 8(%rax), %rax"));
    lines = ya_push(lines, ys("    mov 8(%rax), %rcx"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    mov %rcx, %rbx"));
    lines = ya_push(lines, ys("y_join_wait:"));
    lines = ya_push(lines, ys("    mov 48(%rbx), %rdx"));
    lines = ya_push(lines, ys("    test %rdx, %rdx"));
    lines = ya_push(lines, ys("    je y_join_done"));
    lines = ya_push(lines, ys("    mov $202, %rax"));
    lines = ya_push(lines, ys("    lea 48(%rbx), %rdi"));
    lines = ya_push(lines, ys("    xor %esi, %esi"));
    lines = ya_push(lines, ys("    xor %r10d, %r10d"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    jmp y_join_wait"));
    lines = ya_push(lines, ys("y_join_done:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("    xchg %rax, 8(%rbx)"));
    lines = ya_push(lines, ys("    mov 0(%rbx), %rdi"));
    lines = ya_push(lines, ys("    mov %rax, %rsi"));
    lines = ya_push(lines, ys("    sub %rdi, %rsi"));
    lines = ya_push(lines, ys("    cmp $4096, %rsi"));
    lines = ya_push(lines, ys("    jl y_join_value"));
    lines = ya_push(lines, ys("    mov %fs:24, %rcx"));
    lines = ya_push(lines, ys("    mov %rax, 0(%rdi)"));
    lines = ya_push(lines, ys("    mov 40(%rcx), %rdx"));
    lines = ya_push(lines, ys("    mov %rdx, 8(%rdi)"));
    lines = ya_push(lines, ys("    mov %rdi, 40(%rcx)"));
    lines = ya_push(lines, ys("y_join_value:"));
    lines = ya_push(lines, ys("    mov 56(%rbx), %rax"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    ret"));
    /* a mutex (%rax): its word 0 is 0 when free, 1 when held, 2 when */
    /* held and a thread may be waiting for it (Drepper, "Futexes Are */
    /* Tricky", with xchg alone): a waiter marks it 2 before it sleeps, */
    /* and only an unlock that finds 2 makes a syscall (the wake) */
    lines = ya_push(lines, ys("y_mutex_lock:"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    mov %rax, %rbx"));
    lines = ya_push(lines, ys("    mov $1, %rcx"));
    lines = ya_push(lines, ys("    xchg %rcx, 0(%rbx)"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    je y_mutex_got"));
    lines = ya_push(lines, ys("y_mutex_wait:"));
    lines = ya_push(lines, ys("    mov $2, %rcx"));
    lines = ya_push(lines, ys("    xchg %rcx, 0(%rbx)"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    je y_mutex_got"));
    lines = ya_push(lines, ys("    mov $202, %rax"));
    lines = ya_push(lines, ys("    mov %rbx, %rdi"));
    lines = ya_push(lines, ys("    mov $128, %rsi"));
    lines = ya_push(lines, ys("    mov $2, %rdx"));
    lines = ya_push(lines, ys("    xor %r10d, %r10d"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    jmp y_mutex_wait"));
    lines = ya_push(lines, ys("y_mutex_got:"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_mutex_unlock:"));
    lines = ya_push(lines, ys("    xor %ecx, %ecx"));
    lines = ya_push(lines, ys("    xchg %rcx, 0(%rax)"));
    lines = ya_push(lines, ys("    cmp $2, %rcx"));
    lines = ya_push(lines, ys("    jne y_mutex_free"));
    lines = ya_push(lines, ys("    mov %rax, %rdi"));
    lines = ya_push(lines, ys("    mov $202, %rax"));
    lines = ya_push(lines, ys("    mov $129, %rsi"));
    lines = ya_push(lines, ys("    mov $1, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("y_mutex_free:"));
    lines = ya_push(lines, ys("    ret"));
    /* 1 in %rax when the mutex (%rax) was free and is now held. Taking */
    /* it with xchg 1 may erase a 2 (a waiter's mark), which then goes */
    /* back -- and if the mutex was released meanwhile, that takes it. */
    lines = ya_push(lines, ys("y_mutex_trylock:"));
    lines = ya_push(lines, ys("    mov $1, %rcx"));
    lines = ya_push(lines, ys("    xchg %rcx, 0(%rax)"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    je y_mutex_took"));
    lines = ya_push(lines, ys("    cmp $2, %rcx"));
    lines = ya_push(lines, ys("    jne y_mutex_busy"));
    lines = ya_push(lines, ys("    xchg %rcx, 0(%rax)"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    je y_mutex_took"));
    lines = ya_push(lines, ys("y_mutex_busy:"));
    lines = ya_push(lines, ys("    xor %eax, %eax"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_mutex_took:"));
    lines = ya_push(lines, ys("    mov $1, %rax"));
    lines = ya_push(lines, ys("    ret"));
    /* a semaphore (%rax): its count at 0, guarded by the mutex at 8; a */
    /* wait sleeps on the count while it is 0 */
    lines = ya_push(lines, ys("y_sem_wait:"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    mov %rax, %rbx"));
    lines = ya_push(lines, ys("y_sem_again:"));
    lines = ya_push(lines, ys("    lea 8(%rbx), %rax"));
    lines = ya_push(lines, ys("    call y_mutex_lock"));
    lines = ya_push(lines, ys("    mov 0(%rbx), %rcx"));
    lines = ya_push(lines, ys("    test %rcx, %rcx"));
    lines = ya_push(lines, ys("    je y_sem_sleep"));
    lines = ya_push(lines, ys("    sub $1, %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, 0(%rbx)"));
    lines = ya_push(lines, ys("    lea 8(%rbx), %rax"));
    lines = ya_push(lines, ys("    call y_mutex_unlock"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_sem_sleep:"));
    lines = ya_push(lines, ys("    lea 8(%rbx), %rax"));
    lines = ya_push(lines, ys("    call y_mutex_unlock"));
    lines = ya_push(lines, ys("    mov $202, %rax"));
    lines = ya_push(lines, ys("    mov %rbx, %rdi"));
    lines = ya_push(lines, ys("    mov $128, %rsi"));
    lines = ya_push(lines, ys("    xor %edx, %edx"));
    lines = ya_push(lines, ys("    xor %r10d, %r10d"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    jmp y_sem_again"));
    lines = ya_push(lines, ys("y_sem_post:"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    mov %rax, %rbx"));
    lines = ya_push(lines, ys("    lea 8(%rbx), %rax"));
    lines = ya_push(lines, ys("    call y_mutex_lock"));
    lines = ya_push(lines, ys("    mov 0(%rbx), %rcx"));
    lines = ya_push(lines, ys("    add $1, %rcx"));
    lines = ya_push(lines, ys("    mov %rcx, 0(%rbx)"));
    lines = ya_push(lines, ys("    lea 8(%rbx), %rax"));
    lines = ya_push(lines, ys("    call y_mutex_unlock"));
    lines = ya_push(lines, ys("    mov $202, %rax"));
    lines = ya_push(lines, ys("    mov %rbx, %rdi"));
    lines = ya_push(lines, ys("    mov $129, %rsi"));
    lines = ya_push(lines, ys("    mov $1, %rdx"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    ret"));
    /* fork: %rax the block's closure; the child runs it and ends (0), */
    /* the parent gets the pid (or -errno) */
    lines = ya_push(lines, ys("y_fork:"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    mov %rax, %rbx"));
    lines = ya_push(lines, ys("    mov $57, %rax"));
    lines = ya_push(lines, ys("    syscall"));
    lines = ya_push(lines, ys("    test %rax, %rax"));
    lines = ya_push(lines, ys("    je y_fork_child"));
    lines = ya_push(lines, ys("    pop %rbx"));
    lines = ya_push(lines, ys("    ret"));
    lines = ya_push(lines, ys("y_fork_child:"));
    lines = ya_push(lines, ys("    push %rbx"));
    lines = ya_push(lines, ys("    mov 0(%rbx), %rax"));
    lines = ya_push(lines, ys("    call *%rax"));
    lines = ya_push(lines, ys("    mov $231, %rax"));
    lines = ya_push(lines, ys("    xor %edi, %edi"));
    lines = ya_push(lines, ys("    syscall"));
    return lines;
}

Yv *arch_consts(void) {
    // rodata literals emitted once at the end of the file (string headers,
    // error messages)
    Yv *lines = yav(0);
    lines = ya_push(lines, ys("ystr_minus_h:"));
    lines = ya_push(lines, ys(".quad 1"));
    lines = ya_push(lines, ys(".string \"-\""));
    lines = ya_push(lines, ys("ystr_dot_h:"));
    lines = ya_push(lines, ys(".quad 1"));
    lines = ya_push(lines, ys(".string \".\""));
    lines = ya_push(lines, ys("ystr_divzero: .ascii \"runtime error: division by zero\\n\""));
    lines = ya_push(lines, ys("ystr_divzero_end:"));
    lines = ya_push(lines, ys("ystr_oob: .ascii \"runtime error: index out of bounds\\n\""));
    lines = ya_push(lines, ys("ystr_oob_end:"));
    lines = ya_push(lines, ys("ystr_cast: .ascii \"runtime error: a union value cast to a member it does not hold\\n\""));
    lines = ya_push(lines, ys("ystr_cast_end:"));
    lines = ya_push(lines, ys("ystr_oom: .ascii \"runtime error: out of memory\\n\""));
    lines = ya_push(lines, ys("ystr_oom_end:"));
    lines = ya_push(lines, ys("ystr_opt: .ascii \"runtime error: unwrap of none\\n\""));
    lines = ya_push(lines, ys("ystr_opt_end:"));
    return ys_cat(ys_join(lines, ys("\n")), ys("\n"));
}
