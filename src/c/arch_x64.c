// arch_x64.c — Linux x86_64 code emitters for the native backend (ycc).
// 1:1 port of src/y/arch_x64.y (see PORTING.md): same defs in the same
// order, same control flow, character-identical asm text.
#include "arch_x64.h"

Y_EMBED(PRELUDE_ASM, "src/y/arch/prelude.s")
Y_EMBED(THREADS_ASM, "src/y/arch/threads.s")
Y_EMBED(MATH_ASM, "src/y/arch/math.s")

/* imported */
/* none — arch_x64.y calls no other module's defs. The only builtins used
   are tostring(x) of a long -> ys_long(x) and join(a, sep) -> ys_join(a,
   sep); both come from yv.h. */

/* the twin of arch_x64.y's arch_asm_lines: the embedded text as prelude
   lines, one per line, indentation kept. Dropped: a whole-line '#' comment
   (the in-tree assembler treats a comment as a backend bug and must never see
   one — every comment line in the .s files under src/y/arch starts at column 0
   for exactly
   this reason) and the empty tail a trailing newline leaves behind. The two
   costs are accounted for in the Y comment: split() materialising the lines
   (+374K instructions once per process, the price of one copy of the asm), and
   no trim per line, which cost ~630 instructions a line (+37% on hello.y). Byte
   35 is '#'. */
static Yv *arch_asm_lines(Yv *text) {
    Yv *out = yav(0);
    Yv *all = ys_split(text, ys("\n"));
    long i = 0;
    while (i < yv_len(all)) {
        Yv *l = ya_get(all, i);
        if (yv_len(l) > 0 && ys_byte_at(l, 0) != 35) {
            out = ya_push(out, l);
        }
        i = i + 1;
    }
    return out;
}

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
    return arch_asm_lines(PRELUDE_ASM());
}

// The thread runtime (CHOICES_MADE.md 33), linked only when a program's
// code calls into it (native.y uses_threads): every compile looks at
// each line of the prelude it is given.
Yv *arch_prelude_threads_lines(void) {
    return arch_asm_lines(THREADS_ASM());
}


/* The floating-point primitives (src/y/arch/math.s): the four a std module
 * reaches through `native def`, and the only machine code between Y and a
 * numeric library -- Y has no float-to-long conversion and no way to read a
 * float's bits. Always given to the shaking (they are a few lines, unlike the
 * thread runtime, so there is nothing to save by looking first). */
Yv *arch_math_lines(void) {
    return arch_asm_lines(MATH_ASM());
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
    lines = ya_push(lines, ys("ystr_int: .ascii \"runtime error: a float with no integer part a long holds\\n\""));
    lines = ya_push(lines, ys("ystr_int_end:"));
    return ys_cat(ys_join(lines, ys("\n")), ys("\n"));
}
