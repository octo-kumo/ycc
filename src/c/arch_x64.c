// arch_x64.c — Linux x86_64 code emitters for the native backend (ycc).
// 1:1 port of src/y/arch_x64.y (see PORTING.md): same defs in the same
// order, same control flow, character-identical asm text.
#include "ylong.h"
#include "arch_x64.h"
#include "target.h"

Y_EMBED(PRELUDE_ASM, "src/y/arch/prelude.s")
Y_EMBED(THREADS_ASM, "src/y/arch/threads.s")
/* The Windows half of the arch prelude: the blocks of prelude.s that reach
   the kernel, replaced whole (see arch_windows_lines). It is DATA here, not a
   second arch module — a path import is flattened into its importer, so a
   second arch_x64.y could not coexist (arch_frame would be defined twice and
   the second would win). */
Y_EMBED(W_SYS_ASM, "src/y/arch/wsys.s")
/* The float primitives std/math.y's kernels reach for (`native def`s with no
   body -- see NATIVE.md, "Backend"), one embedded copy like the rest. */
Y_EMBED(MATH_ASM, "src/y/arch/math.s")
/* The Windows syscall self-test: the probe w_self_test_lines returns, run
   from _start before anything else on that target. Its own file so GNU as
   reads it (make asm-check) like the other arch assembly. */
Y_EMBED(WSELFTEST_ASM, "src/y/arch/wselftest.s")
/* The kernel half of the prelude (`ycc --kernel`): the blocks of prelude.s
   that touch the kernel, replaced whole -- mmap, serial, exit, the traps --
   plus the pieces a freestanding payload needs and a hosted program does not
   (port I/O, the PIC, the IDT, the halt loop). Same `#=== replace:` /
   `#=== add:` mechanism as wsys.s; see arch_replaced_lines. */
Y_EMBED(KERNEL_ASM, "src/y/arch/kernel.s")

/* The ELF32 Multiboot writer's layout constants (base, header size, where
   .bss starts). The trampoline below bakes the same numbers into its 32-bit
   immediates, so both sides read them from kelf.c rather than spelling them. */
#include "kelf.h"

/* imported */
/* target.c's res_target / target_is_windows (target.y), the one other module
   this one calls. The rest of the builtins used are tostring(x) of a long ->
   ys_long(x) and join(a, sep) -> ys_join(a, sep); both come from yv.h. */

/* The Windows half of the prelude (arch_x64.y's "── the Windows half ──"
   section). Every one of these is a `def` the Y module does not export, so
   each is static here; arch_windows_lines is forward-declared because
   arch_prelude_lines above calls it, exactly as the Y module's own order has
   it. */
static ylong l_sysno(Yv *name);
static ylong w_sysno(Yv *name);
static Yv *arch_windows_lines(void);
static Yv *arch_kernel_lines(void);
static Yv *arch_replaced_lines(Yv *sub, Yv *what);
static Yv *arch_win_blocks(Yv *lines);
static ylong arch_win_check(Yv *lines, Yv *blocks, Yv *what);
static int arch_win_labeled(Yv *lines, Yv *nm);
static Yv *arch_win_marker(Yv *l);
static Yv *arch_win_tail(Yv *mode, Yv *name);
static Yv *arch_win_head(Yv *nm);
static int arch_is_label_line(Yv *l);
static Yv *arch_win_sub(Yv *lines, Yv *blocks);
static Yv *arch_win_split(Yv *out);
static ylong arch_win_find(Yv *blocks, Yv *nm);
static Yv *arch_win_push(Yv *out, Yv *l);
static Yv *kernel_head_text(void);
static Yv *mb_header_bytes(void);
static Yv *ktramp(Yv *pre, ylong pt, ylong gdtr, ylong entry);
static Yv *ktramp_pre(ylong pt, ylong gdtr);
static Yv *kb1(Yv *b, ylong v);
static Yv *kb2(Yv *b, ylong a, ylong c);
static Yv *kb3(Yv *b, ylong a, ylong c, ylong d);
static Yv *kb_imm32(Yv *b, ylong reg, ylong v);
static Yv *kbput32(Yv *b, ylong v);
static Yv *kbput16(Yv *b, ylong v);
static Yv *kascii(Yv *b);
static Yv *k_oct3(ylong v);

/* the twin of arch_x64.y's arch_asm_lines: the embedded text as prelude
   lines, one per line, indentation kept. Dropped: a whole-line '#' comment
   (the in-tree assembler treats a comment as a backend bug and must never see
   one — every comment line in the arch .s files starts at column 0
   for exactly that reason) and the empty tail a trailing newline leaves behind. The two
   costs are accounted for in the Y comment: split() materialising the lines
   (+374K instructions once per process, the price of one copy of the asm), and
   no trim per line, which cost ~630 instructions a line (+37% on hello.y). Byte
   35 is '#'. */
static Yv *arch_asm_lines(Yv *text) {
    Yv *out = yav(0);
    Yv *all = ys_split(text, ys("\n"));
    ylong i = 0;
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
    if (target_is_windows()) { return ys("x86_64-windows"); }
    else if (target_is_kernel()) { return ys("x86_64-kernel"); }
    else { return ys("x86_64-linux"); }
}

ylong arch_word(void) {
    return 8;
}

// syscall number table. NOTE: one arm per syscall (ladder style, see the
// master note in asm.c's is_digit_ch — not a language restriction).
// The Windows half is w_sysno: the numbers there are the NT syscall index
// range, which is dense and live, so a Linux number left behind does not
// fail loudly — it calls a different, real Nt function. That is why they are
// one table here, read off the stubs in a real ntdll rather than written from
// memory. w_self_test would probe one call per class at program start, and
// does not yet -- see its own comment below.
ylong arch_sysno(Yv *name) {
    if (target_is_windows()) { return w_sysno(name); }
    else if (target_is_kernel()) { return -1; }
    else { return l_sysno(name); }
}

static ylong l_sysno(Yv *name) {
    if (ys_eq_lit(name, "read")) { return 0; }
    else if (ys_eq_lit(name, "write")) { return 1; }
    else if (ys_eq_lit(name, "close")) { return 3; }
    else if (ys_eq_lit(name, "openat")) { return 257; }
    else if (ys_eq_lit(name, "exit")) { return 60; }
    else { return -1; }
}

// The NT syscall index of each Windows call, pinned to Windows 10 1607 / 11
// x64. Measured, not remembered: each number was read out of the `mov $N,%eax`
// of the corresponding stub in a real ntdll.dll's .text (a leftover Linux
// number silently calls a real, different Nt function, which is exactly why
// this is one table a review can read at once).
static ylong w_sysno(Yv *name) {
    if (ys_eq_lit(name, "write")) { return 8; }              /* NtWriteFile */
    else if (ys_eq_lit(name, "read")) { return 6; }          /* NtReadFile */
    else if (ys_eq_lit(name, "close")) { return 15; }        /* NtClose */
    else if (ys_eq_lit(name, "exit")) { return 44; }         /* NtTerminateProcess */
    else if (ys_eq_lit(name, "alloc")) { return 24; }        /* NtAllocateVirtualMemory */
    else if (ys_eq_lit(name, "free")) { return 30; }         /* NtFreeVirtualMemory */
    else if (ys_eq_lit(name, "protect")) { return 80; }      /* NtProtectVirtualMemory */
    else if (ys_eq_lit(name, "perf_counter")) { return 49; } /* NtQueryPerformanceCounter */
    else if (ys_eq_lit(name, "delay")) { return 52; }        /* NtDelayExecution */
    else if (ys_eq_lit(name, "system_time")) { return 90; }  /* NtQuerySystemTime */
    /* 196 is NOT what the public Windows 10 table suggests (it lists 62, whose
       neighbour NtQueryAttributesFile really is 61); 62 answers
       STATUS_INVALID_HANDLE. Read out of the installed ntdll's own stub by
       test/sh/w_sysno.py, which is the only authority for what a probe under
       this wine will do. */
    else if (ys_eq_lit(name, "attrs")) { return 196; }  /* NtQueryFullAttributesFile */
    else { return -1; }
}

/* The Windows syscall self-test is NOT implemented. The design is in
   ideas/WINDOWS.md (Risks): one Nt call per class -- memory, file, time,
   thread -- with its NTSTATUS checked once at program start, so a number that
   drifted on a different Windows build fails loudly instead of calling some
   other real Nt function. It is a real gap rather than a postponed detail:
   w_sysno's numbers are pinned to one ntdll sample and nothing verifies them
   at runtime. This stub returns no lines, and says so, because a comment that
   promises a probe nobody runs is worse than no comment.

   Not `static`, and not in arch_x64.h either: a Y `def` is callable from
   anywhere in its module and nothing warns when nothing calls it, whereas an
   unused static is a -Wunused-function warning. Leaving the definition with
   external linkage keeps the twin honest; leaving it out of the header keeps
   the header matching the Y export list exactly. */
Yv *w_self_test_lines(void) {
    if (target_is_windows()) { return arch_asm_lines(WSELFTEST_ASM()); } else { return yav(0); }
}

Yv *arch_fn_label(ylong uid, Yv *name) {
    return ys_cat(ys_cat(ys_cat(ys("yfn_"), ys_long(uid)), ys("_")), name);
}

Yv *arch_global_label(ylong uid, Yv *name) {
    return ys_cat(ys_cat(ys_cat(ys("yg_"), ys_long(uid)), ys("_")), name);
}

Yv *arch_loc_label(ylong fuid, ylong n) {
    return ys_cat(ys_cat(ys_cat(ys("yL_"), ys_long(fuid)), ys("_")), ys_long(n));
}

Yv *arch_str_label(ylong i) {
    return ys_cat(ys("ystr_"), ys_long(i));
}

Yv *arch_header(void) {
    if (target_is_kernel()) { return kernel_head_text(); }
    else { return ys(".text\n.globl _start\n"); }
}

Yv *arch_rodata(void) {
    return ys(".section .rodata\n");
}

Yv *arch_text(void) {
    return ys(".text\n");
}

/* One zeroed 8-byte cell per global (see emit_program in native.y). */
/* The .bss block the Windows imports need: one 8-byte cell per imported
   function, then one zeroed terminator per DLL, in w_imports()' order. It is
   emitted as the FIRST thing in .bss, which is what makes each cell's offset a
   constant (0, 8, 16, ...) rather than something the writer has to ask the
   assembler's label map for -- and a wrong offset there is an image whose
   FirstThunk points outside .bss, so the loader writes the resolved addresses
   over whatever does live there. */
Yv *w_iat_bss_lines(void) {
    Yv *out = yav(0);
    Yv *imps = w_imports();
    ylong i = 0;
    while (i < yv_len(imps)) {
        Yv *funcs = yr_get(ya_get(imps, i), "funcs");
        ylong f = 0;
        while (f < yv_len(funcs)) {
            out = ya_push(out, ys_cat(ys_cat(w_iat_label(ya_get(funcs, f)),
                                             ys(":\n.zero 8\n")), ys("")));
            f = f + 1;
        }
        out = ya_push(out, ys_cat(w_iat_term_label(yr_get(ya_get(imps, i), "dll")),
                                  ys(":\n.zero 8\n")));
        i = i + 1;
    }
    return out;
}

/* The .bss offset of function `f` of DLL index `d`: the block above is first in
   the section, so this is arithmetic on the spec rather than a lookup. */
ylong w_iat_offset(ylong d, ylong f) {
    Yv *imps = w_imports();
    ylong at = 0;
    ylong i = 0;
    while (i < d) {
        at = at + 8 * (yv_len(yr_get(ya_get(imps, i), "funcs")) + 1);
        i = i + 1;
    }
    return at + 8 * f;
}

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
/* ── the Windows imports ──────────────────────────────────────────────
   Windows has no syscall for randomness (BCryptGenRandom is a DLL export), for
   sockets (Winsock) or for the console API, so those arrive as PE imports. The
   list lives here, in the arch module, because two things need it and they are
   on opposite sides of the build: the linker (native.c) reserves one .bss cell
   per imported function so the code can reach the resolved pointer, and the PE
   writer (pe.c) emits the descriptor, ILT and name table that fills those
   cells. One list, or the two would drift. */
Yv *w_imports(void) {
    /* yavs, not yav: the count in yav() is a number that has to be kept in step
       with the list by hand, and it silently DROPS anything appended past it --
       which is exactly what happened here when advapi32 was added below and the
       2 was not. yavs(..., NULL) is terminated by the sentinel. */
    return yavs(
        yr(2, "dll", ys("KERNEL32.dll"),
              "funcs", yav(1, ys("GetCurrentProcessId"))),
        /* RtlGenRandom: the classic Windows RNG, and the one this layer uses.
           bcrypt's provider/handle/close dance is what wine cannot do (rounds
           34-49), while this is a single call: BOOLEAN SystemFunction036(PVOID,
           ULONG), exported by name from advapi32. */
        yr(2, "dll", ys("advapi32.dll"),
              "funcs", yav(1, ys("SystemFunction036"))),
        NULL);
}

/* The .bss cell the loader writes an imported function's address into. The
   code calls through it -- `mov y_iat_X(%rip), %rax; call *%rax` -- which is
   why it has to be a cell with a label rather than a slot inside .idata: only
   .text, .bss and the unwind sections have addresses the assembler knows. */
Yv *w_iat_label(Yv *fn) { return ys_cat(ys("y_iat_"), fn); }

/* The terminator slot of a DLL's IAT: the image format wants the array to end
   in a zero entry, and the loader writes it along with the resolved addresses
   (it walks the ILT, which carries the names, and fills one IAT slot per entry
   plus that zero). One per DLL, named after it so two DLLs cannot share. */
Yv *w_iat_term_label(Yv *dll) { return ys_cat(ys("y_iatz_"), dll); }

Yv *arch_heap_cells(void) {
    /* y_heap_base holds the main heap's bytes handed out before the program's
       own top-level code runs -- the argv copies y_argv_init makes, which are
       the one part of that baseline that changes with how the caller spelled
       the command (SUGGESTIONS.md 24: heap_used() moved one byte per
       character of argv[0]). y_heap_used subtracts it, on the main heap only:
       a spawned thread gets a heap of its own, and the argv copies are not in
       it.

       The y_gc_* cells are the collector's state (arch/prelude.s): the stack
       top _start records, the heap's low/high bounds, the chunk list and its
       hash table, the metadata bump, the free-list heads and mark stack, the
       live-byte and trigger counters, and the running/off guards. They are
       words, so a program that never allocates shakes them out with y_alloc
       and every other program carries a few hundred zeroed .bss bytes. */
    return ys("y_heap:\n.zero 32\ny_heap_base:\n.zero 8\n"
              "y_gc_stack_top:\n.zero 8\ny_gc_lo:\n.zero 8\ny_gc_hi:\n.zero 8\n"
              "y_gc_all:\n.zero 8\ny_gc_tab:\n.zero 8\ny_gc_tabn:\n.zero 8\n"
              "y_gc_meta_cur:\n.zero 8\ny_gc_meta_end:\n.zero 8\n"
              "y_gc_free:\n.zero 8\ny_gc_ms_cur:\n.zero 8\ny_gc_ms_end:\n.zero 8\n"
              "y_gc_ms_seg:\n.zero 8\n"
              "y_gc_live:\n.zero 8\ny_gc_last:\n.zero 8\n"
              "y_gc_run:\n.zero 8\ny_gc_off:\n.zero 8\n");
}

ylong arch_frame(ylong slots) {
    // slots * 8, rounded up to a multiple of 16 (call alignment)
    ylong bytes = slots * 8;
    if (bytes % 16 == 0) { return bytes; } else { return bytes + (16 - bytes % 16); }
}

Yv *arch_exit(void) {
    if (target_is_windows()) {
        return ys("    mov $44, %rax\n    mov $-1, %r10\n    xor %edi, %edi\n    mov %edi, %r9\n    syscall\n");
    }
    else if (target_is_kernel()) { return ys("    jmp y_kernel_halt\n"); }
    else { return ys("    mov $231, %rax\n    xor %edi, %edi\n    syscall\n"); }
}

/* The kernel's own .bss: the IDT and its descriptor, the kernel stack, the
   fixed heap arena `y_alloc_map` hands out of, and the multiboot info
   pointer. None of it exists on a hosted target, so native.c emits this only
   for --kernel. */
Yv *arch_kernel_bss(void) {
    /* The 16 MB arena that used to live here is gone: it put the image's end
       18 MB up, which is where user space wants to be (a Linux executable is
       linked at 0x400000), and the kernel is mapped by ONE 2 MB page. The Y
       heap now lives in RAM above the image, chosen by std/kernel.y's
       y_heap_init the first time anything allocates. */
    return ys(".align 16\n"
              "y_mb_info:\n.zero 8\n"
              ".align 16\n"
              "y_kernel_idt:\n.zero 4096\n"
              "y_kernel_idtr:\n.zero 16\n"
              ".align 16\n"
              "y_kernel_stack_bottom:\n.zero 32768\n"
              "y_kernel_stack_top:\n"
              ".align 16\n"
              /* The syscall path's two words: where the user stack was when
                 SYSCALL arrived, and the kernel stack it switched to (M2
                 gives each task one). */
              "y_user_rsp:\n.zero 8\n"
              /* The running task: its kernel stack top, and the %rsp of its
                 suspended frame (the frame IS the state). */
              "y_irq_scratch:\n.zero 8\n"
              "y_cur_kstack:\n.zero 8\n"
              "y_cur_task_rsp:\n.zero 8\n"
              /* The Y heap's region: a physical address and direct-map
                 addresses, set once by y_heap_region_set. */
              "y_heap_start:\n.zero 8\n"
              "y_heap_bias:\n.zero 8\n"
              "y_heap_next:\n.zero 8\n"
              "y_heap_limit:\n.zero 8\n"
              /* Where the kernel's own memory ends: a physical page
                 allocator starts at the next page after this. */
              "y_kernel_end:\n");
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
    if (target_is_windows()) { return arch_windows_lines(); }
    else if (target_is_kernel()) { return arch_kernel_lines(); }
    else { return arch_asm_lines(PRELUDE_ASM()); }
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
    lines = ya_push(lines, ys("ystr_wselftest: .ascii \"runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)\\n\""));
    lines = ya_push(lines, ys("ystr_wselftest_end:"));
    return ys_cat(ys_join(lines, ys("\n")), ys("\n"));
}

// ── the Windows half of the prelude ─────────────────────────────────────
// Everything in prelude.s that reaches the kernel carries a SysV `syscall`
// inline, so those blocks are wrong on Windows and everything else in the
// prelude is not. Rather than a second copy of 1682 lines of assembly, the
// target-specific blocks are replaced WHOLE: arch_windows_lines walks the
// prelude's lines and, at each block wsys.s claims, emits that block's lines
// instead and skips the Linux one.
//
// wsys.s delimits its blocks with a `#=== ... ===` marker line, because
// splitting on every column-0 label would tear a block in half at a label
// only the Windows block has (y_alloc_map_fail) and drop the rest of it. The
// marker says which it is:
//   `#=== replace: NAME ===`  this block replaces prelude.s's block NAME
//   `#=== add: NAME ===`      a new block, emitted after the last replaced
//                              one; the tree shaker prunes it unless a kept
//                              block calls it, so y_os_write costs a program
//                              that never writes nothing
// A `replace:` name the prelude does not define is a hard error (see
// arch_win_find): it means the Windows half was written against a block that
// moved, and the substitution would silently do nothing. `make asm-check`
// gives GNU as a second opinion on wsys.s as well.
static Yv *arch_windows_lines(void) {
    return arch_replaced_lines(W_SYS_ASM(), ys("src/y/arch/wsys.s"));
}

// The kernel's replacement blocks (`ycc --kernel`): the same substitution,
// against src/y/arch/kernel.s.
static Yv *arch_kernel_lines(void) {
    return arch_replaced_lines(KERNEL_ASM(), ys("src/y/arch/kernel.s"));
}

static Yv *arch_replaced_lines(Yv *sub, Yv *what) {
    Yv *blocks = arch_win_blocks(ys_split(sub, ys("\n")));
    /* NOTE: index loop, not foreach (PORTING.md rule 9). */
    ylong i = 0;
    while (i < yv_len(blocks)) {
        Yv *e = ya_get(blocks, i);
        if (yv_len(e) > 1 && ys_eq_lit(ya_get(e, 1), "2")) {
            puts_(ys_cat(ys_cat(ys_cat(ys_cat(ys("error: "), what),
                                      ys(": bad block marker ('")),
                              ya_get(e, 0)),
                      ys("'): want '#=== replace: NAME ===' or '#=== add: NAME ==='\n")));
            exit_(1);
        };
        i = i + 1;
    }
    Yv *lines = arch_asm_lines(PRELUDE_ASM());
    arch_win_check(lines, blocks, what);
    return arch_win_sub(lines, blocks);
}

// Every `replace:` name must be a block the prelude really has. This is the
// check that keeps the substitution honest: a marker naming a block that
// moved (or one whose marker line lost its leading "#", which drops the
// marker and silently substitutes nothing) would otherwise leave the SysV
// code in a Windows binary -- the failure mode with no symptom until the
// program calls the wrong syscall. It cost one whole debugging session to
// earn, which is why it is a hard error rather than a comment.
static ylong arch_win_check(Yv *lines, Yv *blocks, Yv *what) {
    ylong i = 0;
    while (i < yv_len(blocks)) {
        if (ys_eq_lit(ya_get(ya_get(blocks, i), 1), "0")) {
            if (arch_win_labeled(lines, ya_get(ya_get(blocks, i), 0))) { /* found */ }
            else {
                puts_(ys_cat(ys_cat(ys_cat(ys("error: "), what),
                                    ys(" replaces '")),
                             ys_cat(ya_get(ya_get(blocks, i), 0),
                                    ys("', which src/y/arch/prelude.s does not define\n"))));
                exit_(1);
            }
        }
        i = i + 1;
    }
    return 0;
}

static int arch_win_labeled(Yv *lines, Yv *nm) {
    ylong i = 0;
    int found = 0;
    while (i < yv_len(lines)) {
        Yv *l = ya_get(lines, i);
        if (arch_is_label_line(l)
            && ys_eq(ys_trim(ys_slice(l, 0, yv_len(l) - 1)), nm)) { found = 1; }
        i = i + 1;
    }
    return found;
}

// wsys.s's blocks as [name, mode, line, line, ...] records, in the order the
// file gives them: mode 0 replaces the same-named prelude block, 1 is new.
static Yv *arch_win_blocks(Yv *lines) {
    Yv *out = yav(0);
    Yv *cur = yav(0);
    ylong i = 0;
    while (i < yv_len(lines)) {
        Yv *l = ya_get(lines, i);
        Yv *mk = arch_win_marker(l);
        if (yv_len(mk) != 0) {
            if (yv_len(cur) > 0) { out = ya_push(out, cur); }
            cur = arch_win_head(mk);
            i = i + 1;
        } else {
            // Comments are documentation here (GNU as reads them too) and
            // must not reach the assembler, which calls one a backend bug.
            if (yv_len(l) > 0 && ys_byte_at(l, 0) != 35) {
                cur = ya_push(cur, l);
            }
            i = i + 1;
        }
    }
    if (yv_len(cur) > 0) { out = ya_push(out, cur); }
    return out;
}

// "#=== replace: NAME ===" -> "replace: NAME", or "" when the line is not a
// marker. A line that starts with "#===" but does not parse comes back as "?"
// and arch_replaced_lines makes it a hard error: a silently ignored marker is
// the one failure this substitution cannot be allowed to have, because the
// symptom -- a Linux block sitting in a Windows binary -- appears far away.
//
// The length gate is load-bearing and was a live trap: a blank line in a
// replacement file sliced past its own end here (wsys.s has none, kernel.s
// has one between every block), and the bounds check turned a whole compile
// into "runtime error: index out of bounds".
static Yv *arch_win_marker(Yv *l) {
    if (yv_len(l) < 4) {
        return ys("");
    } else if (!ys_eq(ys_slice(l, 0, 4), ys("#==="))) {
        return ys("");
    }
    Yv *body = ys_slice_from(l, 4);
    ylong colon = ys_index_of(body, ys(":"));
    if (colon < 0) { return ys("?"); }
    else {
        return arch_win_tail(ys_trim(ys_slice(body, 0, colon)),
                             ys_trim(ys_slice_from(body, colon + 1)));
    }
}

// "replace: y_alloc_map ===" -> "replace: y_alloc_map". The closing "==="
// goes by SUFFIX: index_of would find the marker line's OWN leading "===".
static Yv *arch_win_tail(Yv *mode, Yv *name) {
    ylong k = yv_len(name) - 3;
    if (k >= 0 && ys_eq(ys_slice_from(name, k), ys("==="))) {
        return ys_cat(ys_cat(mode, ys(": ")), ys_trim(ys_slice(name, 0, k)));
    } else { return ys("?"); }
}

// The [name, mode] head of a block: 0 replaces the same-named prelude block,
// 1 is new, 2 is a malformed marker.
static Yv *arch_win_head(Yv *nm) {
    if (yv_len(nm) >= 9 && ys_eq(ys_slice(nm, 0, 9), ys("replace: "))) {
        return yav(2, ys_slice_from(nm, 9), ys("0"));
    } else if (yv_len(nm) >= 5 && ys_eq(ys_slice(nm, 0, 5), ys("add: "))) {
        return yav(2, ys_slice_from(nm, 5), ys("1"));
    } else {
        return yav(2, ys("?"), ys("2"));
    }
}

static int arch_is_label_line(Yv *l) {
    if (yv_len(l) == 0) { return 0; }
    else if (ys_byte_at(l, 0) == 32 || ys_byte_at(l, 0) == 9) { return 0; }
    else if (!ys_eq(ys_slice_from(l, yv_len(l) - 1), ys(":"))) { return 0; }
    else { return ys_index_of(l, ys(" ")) < 0; }
}

// `lines` walked; at a label a replacing block claims, that block's lines and
// not the prelude's. The new blocks go after the last replaced one.
/* Replace the block that starts at the column-0 label `name` (through the line
   before the next label) with `repl`. */
static Yv *arch_block_sub(Yv *lines, Yv *name, Yv *repl) {
    Yv *out = yav(0);
    ylong i = 0;
    while (i < yv_len(lines)) {
        Yv *l = ya_get(lines, i);
        if (arch_is_label_line(l)
            && ys_eq(ys_trim(ys_slice(l, 0, yv_len(l) - 1)), name)) {
            ylong r = 0;
            while (r < yv_len(repl)) {
                out = ya_push(out, ya_get(repl, r));
                r = r + 1;
            }
            i = i + 1;
            while (i < yv_len(lines) && !arch_is_label_line(ya_get(lines, i))) {
                i = i + 1;
            }
        } else {
            out = ya_push(out, l);
            i = i + 1;
        }
    }
    return out;
}

/* The GC-free runtime: a program whose heap cannot grow does not link the
   collector at all (--gc, or the auto analysis). The allocator itself is
   UNCHANGED -- only the collector's three entry points become stubs -- so the
   chunk layout and heap_used() accounting are bit-identical, and every other
   collector block (the registry, metadata arena, marker, sweeper, free lists)
   becomes unreachable and is shaken out.
     y_gc_maybe      never runs a cycle
     y_gc_alloc_free never recycles a block (0 = none)
     y_gc_chunk_add  returns the base the allocator wants, registers nothing */
Yv *arch_nogc_lines(Yv *lines) {
    Yv *out = arch_block_sub(lines, ys("y_gc_maybe"),
                             yavs(ys("y_gc_maybe:"), ys("    ret"), NULL));
    out = arch_block_sub(out, ys("y_gc_alloc_free"),
                         yavs(ys("y_gc_alloc_free:"), ys("    xor %eax, %eax"),
                              ys("    ret"), NULL));
    return arch_block_sub(out, ys("y_gc_chunk_add"),
                          yavs(ys("y_gc_chunk_add:"), ys("    mov %rdi, %rax"),
                               ys("    ret"), NULL));
}

static Yv *arch_win_sub(Yv *lines, Yv *blocks) {
    Yv *out = yav(0);
    ylong i = 0;
    while (i < yv_len(lines)) {
        Yv *l = ya_get(lines, i);
        ylong b = -1;
        if (arch_is_label_line(l)) {
            b = arch_win_find(blocks, ys_trim(ys_slice(l, 0, yv_len(l) - 1)));
        }
        if (b >= 0) {
            Yv *blk = ya_get(blocks, b);
            out = arch_win_push(out, ys_join(ya_slice(blk, 2, yv_len(blk)), ys("\n")));
            i = i + 1;
            while (i < yv_len(lines) && !arch_is_label_line(ya_get(lines, i))) { i = i + 1; }
        } else {
            out = arch_win_push(out, l);
            i = i + 1;
        }
    }
    i = 0;
    while (i < yv_len(blocks)) {
        Yv *blk = ya_get(blocks, i);
        if (ys_eq_lit(ya_get(blk, 1), "1")) {
            out = arch_win_push(out, ys_join(ya_slice(blk, 2, yv_len(blk)), ys("\n")));
        }
        i = i + 1;
    }
    // one line per list element: arch_prelude_lines' contract with
    // native.c's prelude_blocks and shake_prelude.
    return arch_win_split(out);
}

static Yv *arch_win_split(Yv *out) {
    Yv *res = yav(0);
    ylong i = 0;
    while (i < yv_len(out)) {
        Yv *parts = ys_split(ya_get(out, i), ys("\n"));
        ylong j = 0;
        while (j < yv_len(parts)) {
            if (yv_len(ya_get(parts, j)) > 0) { res = ya_push(res, ya_get(parts, j)); }
            j = j + 1;
        }
        i = i + 1;
    }
    return res;
}

// The block that replaces `nm`, or -1 when wsys.s does not define one (mode
// "0", name `nm`).
static ylong arch_win_find(Yv *blocks, Yv *nm) {
    ylong at = -1;
    ylong i = 0;
    while (i < yv_len(blocks)) {
        Yv *blk = ya_get(blocks, i);
        if (ys_eq_lit(ya_get(blk, 1), "0") && ys_eq(ya_get(blk, 0), nm)) { at = i; }
        i = i + 1;
    }
    return at;
}

static Yv *arch_win_push(Yv *out, Yv *l) {
    if (yv_len(l) > 0) { out = ya_push(out, l); }
    return out;
}

// ── the generated interrupt plumbing ─────────────────────────────────────
// One stub per `irq N def f()` the program declared (target.h's
// res_irq_stubs), plus the routine that installs them: fill all 256 IDT
// entries with a stop-the-machine default, overwrite the declared vectors,
// load the IDT. Generated rather than kept in arch/kernel.s because it names
// the program's own handler labels; it is a text part, so the tree shaker
// never sees it -- which is also why it carries its own copy of the
// entry-packing helper instead of calling one the shaker could drop.
//
// The stub is the x86-64 interrupt entry:
//   - save the CALLER-saved registers. The handler is an ordinary Y function
//     and is free to clobber rax/rcx/rdx/rsi/rdi/r8-r11; rbx, rbp and r12-r15
//     are callee-saved and it preserves them itself. %rbp is saved too because
//     the stub holds the pre-alignment stack in it.
//   - align %rsp to 16 and call the handler, so the handler's own calls see
//     the alignment the SysV convention wants (the interrupted stack has no
//     alignment guarantee).
//   - acknowledge the 8259 line (slave first, for IRQ8-15).
//   - iretq.
// A handler that clobbers an XMM register would need the SSE state saved as
// well; nothing does that yet, and the Y backend only touches XMM in float
// code.
/* The vectors whose entry pushes an error code (Intel SDM, "Exception and
 * Interrupt Vectors"): 8, 10-14, 17, 21, 29, 30.  The rest get a zero so the
 * handler always reads a second argument. */
static int trap_has_error_code(ylong v) {
    return v == 8 || (v >= 10 && v <= 14) || v == 17 || v == 21 || v == 29 || v == 30;
}

Yv *kernel_irq_text(int has_trap) {
    Yv *out = ys(".text\n");
    out = ys_cat(out, ys("y_kernel_irq_default:\n"));
    out = ys_cat(out, ys("    jmp y_kernel_halt\n"));
    /* The CPU's own exceptions (vectors 0..31): each stub saves the
     * caller-saved set, pushes its vector and the CPU's error code and calls
     * the Y handler y_kernel_trap(vec, err).  A fault is not resumed from, so
     * there is no `iretq` here.  The vector goes on with a register push
     * rather than `push $N` (the encoder has no immediate push) and AFTER the
     * saves, so the interrupted %rax is already safe.  The CPU's error code
     * ends up just above the ten saved registers, at 80(%rbp). */
    /* NOTE: index loop, not foreach (PORTING.md rule 9). */
    ylong v = 0;
    while (v < 32) {
        out = ys_cat(out, ys_cat(ys_cat(ys("y_trap_stub_"), ys_long(v)), ys(":\n")));
        out = ys_cat(out, ys("    push %rbp\n"));
        out = ys_cat(out, ys("    push %rax\n"));
        out = ys_cat(out, ys("    push %rcx\n"));
        out = ys_cat(out, ys("    push %rdx\n"));
        out = ys_cat(out, ys("    push %rsi\n"));
        out = ys_cat(out, ys("    push %rdi\n"));
        out = ys_cat(out, ys("    push %r8\n"));
        out = ys_cat(out, ys("    push %r9\n"));
        out = ys_cat(out, ys("    push %r10\n"));
        out = ys_cat(out, ys("    push %r11\n"));
        out = ys_cat(out, ys("    mov %rsp, %rbp\n"));
        out = ys_cat(out, ys("    and $-16, %rsp\n"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov $"), ys_long(v)), ys(", %eax\n")));
        out = ys_cat(out, ys("    push %rax\n"));
        if (trap_has_error_code(v)) {
            out = ys_cat(out, ys("    mov 80(%rbp), %rax\n"));
        } else {
            out = ys_cat(out, ys("    mov $0, %eax\n"));
        };
        out = ys_cat(out, ys("    push %rax\n"));
        out = ys_cat(out, ys("    call y_kernel_trap\n"));
        out = ys_cat(out, ys("    jmp y_kernel_halt\n"));
        v++;
    };
    if (!has_trap) {
        /* No unit defines one: the stubs must still resolve.  std/kernel.y's
         * is the diagnostic version; this is what a bare kernel gets. */
        out = ys_cat(out, ys("y_kernel_trap:\n"));
        out = ys_cat(out, ys("    jmp y_kernel_halt\n"));
    };
    /* NOTE: index loop, not foreach (PORTING.md rule 9). */
    ylong i = 0;
    while (i < yv_len(res_irq_stubs)) {
        Yv *e = ya_get(res_irq_stubs, i);
        out = ys_cat(out, ys_cat(ys_cat(ys("y_irq_stub_"),
                                        ys_long(yv_l(yr_get(e, "line")))),
                                 ys(":\n")));
        /* An interrupt stub is the syscall entry's shape: nine saved
         * registers -- rax, rdi, rsi, rdx, r10, r8, r9 and then rcx, r11 --
         * above the frame the CPU pushed, which is what makes a task switch
         * possible from here (a suspended task's %rsp always points at the
         * lowest of those nine, from either path).  The switch itself only
         * happens for a USER frame: a ring-0 one has no RSP/SS words. */
        out = ys_cat(out, ys("    push %r15\n"));
        out = ys_cat(out, ys("    push %r14\n"));
        out = ys_cat(out, ys("    push %r13\n"));
        out = ys_cat(out, ys("    push %r12\n"));
        out = ys_cat(out, ys("    push %rbp\n"));
        out = ys_cat(out, ys("    push %rbx\n"));
        out = ys_cat(out, ys("    push %rcx\n"));
        out = ys_cat(out, ys("    push %r11\n"));
        out = ys_cat(out, ys("    push %rax\n"));
        out = ys_cat(out, ys("    push %rdi\n"));
        out = ys_cat(out, ys("    push %rsi\n"));
        out = ys_cat(out, ys("    push %rdx\n"));
        out = ys_cat(out, ys("    push %r10\n"));
        out = ys_cat(out, ys("    push %r8\n"));
        out = ys_cat(out, ys("    push %r9\n"));
        /* The stack is aligned for the handler's call, and the value to
         * restore parks in a GLOBAL rather than %rbp: the interrupt may have
         * arrived in the middle of the kernel's own frame-pointer code. */
        out = ys_cat(out, ys("    mov %rsp, y_irq_scratch(%rip)\n"));
        out = ys_cat(out, ys("    and $-16, %rsp\n"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    call "), yr_get(e, "label")), ys("\n")));
        out = ys_cat(out, ys("    mov y_irq_scratch(%rip), %rsp\n"));
        if (yv_l(yr_get(e, "line")) >= 8) {
            out = ys_cat(out, ys("    mov $160, %edx\n"));
            out = ys_cat(out, ys("    mov $32, %eax\n"));
            out = ys_cat(out, ys("    outb %al, %dx\n"));
        };
        out = ys_cat(out, ys("    mov $32, %edx\n"));
        out = ys_cat(out, ys("    mov $32, %eax\n"));
        out = ys_cat(out, ys("    outb %al, %dx\n"));
        /* The switch point: CS is nine words above the frame's RIP. */
        out = ys_cat(out, ys("    mov 128(%rsp), %rax\n"));
        out = ys_cat(out, ys("    and $3, %rax\n"));
        out = ys_cat(out, ys_cat(ys("    jz y_irq_same_"), ys_long(yv_l(yr_get(e, "line")))));
        out = ys_cat(out, ys("\n"));
        out = ys_cat(out, ys("    mov %rsp, y_cur_task_rsp(%rip)\n"));
        /* The scheduler is Y code and may use SSE, which faults on a
         * misaligned stack: align the call and keep the canonical %rsp in the
         * scratch word for the "stay" case. */
        out = ys_cat(out, ys("    mov %rsp, y_irq_scratch(%rip)\n"));
        out = ys_cat(out, ys("    and $-16, %rsp\n"));
        out = ys_cat(out, ys("    call y_sched_pick\n"));
        out = ys_cat(out, ys("    test %rax, %rax\n"));
        out = ys_cat(out, ys_cat(ys("    jz y_irq_stay_"), ys_long(yv_l(yr_get(e, "line")))));
        out = ys_cat(out, ys("\n"));
        out = ys_cat(out, ys("    mov %rax, %rsp\n"));
        out = ys_cat(out, ys_cat(ys("    jmp y_irq_same_"), ys_long(yv_l(yr_get(e, "line")))));
        out = ys_cat(out, ys("\n"));
        out = ys_cat(out, ys_cat(ys("y_irq_stay_"), ys_long(yv_l(yr_get(e, "line")))));
        out = ys_cat(out, ys(":\n"));
        out = ys_cat(out, ys("    mov y_irq_scratch(%rip), %rsp\n"));
        out = ys_cat(out, ys_cat(ys("y_irq_same_"), ys_long(yv_l(yr_get(e, "line")))));
        out = ys_cat(out, ys(":\n"));
        out = ys_cat(out, ys("    pop %r9\n"));
        out = ys_cat(out, ys("    pop %r8\n"));
        out = ys_cat(out, ys("    pop %r10\n"));
        out = ys_cat(out, ys("    pop %rdx\n"));
        out = ys_cat(out, ys("    pop %rsi\n"));
        out = ys_cat(out, ys("    pop %rdi\n"));
        out = ys_cat(out, ys("    pop %rax\n"));
        out = ys_cat(out, ys("    pop %r11\n"));
        out = ys_cat(out, ys("    pop %rcx\n"));
        out = ys_cat(out, ys("    pop %rbx\n"));
        out = ys_cat(out, ys("    pop %rbp\n"));
        out = ys_cat(out, ys("    pop %r12\n"));
        out = ys_cat(out, ys("    pop %r13\n"));
        out = ys_cat(out, ys("    pop %r14\n"));
        out = ys_cat(out, ys("    pop %r15\n"));
        out = ys_cat(out, ys("    iretq\n"));
        i = i + 1;
    };
    /* %rax = a handler's address -> %rax = the first 8 bytes of its IDT entry:
       offset[0:16] | selector 8 << 16 | type 0x8E << 40 | offset[16:32] << 48.
       The payload lives below 4 GB, so the entry's high half is always zero
       (the `mov $0, +8` below). */
    out = ys_cat(out, ys("y_kernel_idt_pack:\n"));
    out = ys_cat(out, ys("    mov %rax, %rdx\n"));
    out = ys_cat(out, ys("    shr $16, %rdx\n"));
    out = ys_cat(out, ys("    shl $48, %rdx\n"));
    out = ys_cat(out, ys("    and $65535, %rax\n"));
    out = ys_cat(out, ys("    mov $156130651668480, %rcx\n"));
    out = ys_cat(out, ys("    or %rcx, %rax\n"));
    out = ys_cat(out, ys("    or %rdx, %rax\n"));
    out = ys_cat(out, ys("    ret\n"));
    out = ys_cat(out, ys("y_kernel_irq_init:\n"));
    out = ys_cat(out, ys("    push %rbp\n"));
    out = ys_cat(out, ys("    mov %rsp, %rbp\n"));
    out = ys_cat(out, ys("    lea y_kernel_irq_default(%rip), %rax\n"));
    out = ys_cat(out, ys("    call y_kernel_idt_pack\n"));
    out = ys_cat(out, ys("    lea y_kernel_idt(%rip), %rdi\n"));
    out = ys_cat(out, ys("    mov $256, %esi\n"));
    out = ys_cat(out, ys("y_kii_loop:\n"));
    out = ys_cat(out, ys("    mov %rax, (%rdi)\n"));
    out = ys_cat(out, ys("    mov $0, 8(%rdi)\n"));
    out = ys_cat(out, ys("    add $16, %rdi\n"));
    out = ys_cat(out, ys("    sub $1, %esi\n"));
    out = ys_cat(out, ys("    cmp $0, %esi\n"));
    out = ys_cat(out, ys("    jne y_kii_loop\n"));
    ylong tv = 0;
    while (tv < 32) {
        out = ys_cat(out, ys_cat(ys_cat(ys("    lea y_trap_stub_"), ys_long(tv)),
                                 ys("(%rip), %rax\n")));
        out = ys_cat(out, ys("    call y_kernel_idt_pack\n"));
        out = ys_cat(out, ys("    lea y_kernel_idt(%rip), %rdi\n"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(tv * 16)),
                                 ys("(%rdi)\n")));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov $0, "), ys_long(tv * 16 + 8)),
                                 ys("(%rdi)\n")));
        tv++;
    };
    i = 0;
    while (i < yv_len(res_irq_stubs)) {
        Yv *e = ya_get(res_irq_stubs, i);
        ylong v = 32 + yv_l(yr_get(e, "line"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    lea y_irq_stub_"),
                                        ys_long(yv_l(yr_get(e, "line")))),
                                 ys("(%rip), %rax\n")));
        out = ys_cat(out, ys("    call y_kernel_idt_pack\n"));
        out = ys_cat(out, ys("    lea y_kernel_idt(%rip), %rdi\n"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov %rax, "), ys_long(v * 16)),
                                 ys("(%rdi)\n")));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov $0, "), ys_long(v * 16 + 8)),
                                 ys("(%rdi)\n")));
        i = i + 1;
    };
    /* Unmask the declared lines. The compiler knows which they are and the
       program does not have to: y_pic_remap leaves every line masked, so a
       handler installed without this would never fire and nothing would say
       why. One byte per 8259, computed here: a slave line also opens the
       master's cascade (IRQ2), or the slave's request never reaches the CPU. */
    ylong mm = 255;
    ylong sm = 255;
    ylong ii = 0;
    while (ii < yv_len(res_irq_stubs)) {
        ylong ln = yv_l(yr_get(ya_get(res_irq_stubs, ii), "line"));
        if (ln < 8) {
            mm = mm & ~(1 << ln);
        } else {
            sm = sm & ~(1 << (ln - 8));
            mm = mm & ~4;
        };
        ii++;
    };
    if (yv_len(res_irq_stubs) > 0) {
        out = ys_cat(out, ys("    mov $33, %edx\n"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov $"), ys_long(mm)), ys(", %eax\n")));
        out = ys_cat(out, ys("    outb %al, %dx\n"));
        out = ys_cat(out, ys("    mov $161, %edx\n"));
        out = ys_cat(out, ys_cat(ys_cat(ys("    mov $"), ys_long(sm)), ys(", %eax\n")));
        out = ys_cat(out, ys("    outb %al, %dx\n"));
    };
    out = ys_cat(out, ys("    lea y_kernel_idtr(%rip), %rdi\n"));
    out = ys_cat(out, ys("    lea y_kernel_idt(%rip), %rax\n"));
    out = ys_cat(out, ys("    shl $16, %rax\n"));
    out = ys_cat(out, ys("    or $4095, %rax\n"));
    out = ys_cat(out, ys("    mov %rax, (%rdi)\n"));
    out = ys_cat(out, ys("    mov $0, 8(%rdi)\n"));
    out = ys_cat(out, ys("    lidt y_kernel_idtr(%rip)\n"));
    out = ys_cat(out, ys("    pop %rbp\n"));
    out = ys_cat(out, ys("    ret\n"));
    return out;
}

// ── the kernel head: a Multiboot header and a 32-bit trampoline ──────────
// `ycc --kernel` emits an ELF32 Multiboot-1 payload (kelf.c) whose entry is
// 32-bit code, because that is the mode every Multiboot loader starts an
// image in. The 32-bit half does exactly four things and then disappears:
//
//   1. build the page tables that identity-map the first 1 GB with 2 MB pages
//      (the file carries them; the code only points CR3 at them),
//   2. turn on PAE, LME and paging,
//   3. load a flat 64-bit GDT and far-jump to the 64-bit entry, which is the
//      only way to change CS.L and so the only way into long mode,
//   4. hand %ebx (the Multiboot info pointer) to the 64-bit side.
//
// It cannot be written in the in-tree assembly: enc64.c is x86-64-only, and in
// 32-bit protected mode a `mov %cr4, %eax` has no REX prefix, a `mov $addr,
// %eax` is an absolute moffs, and rip-relative addressing does not exist at
// all. So the trampoline is a byte blob, transcribed from
// experiments/kernel/boot.s -- the same payload booted under
// `qemu-system-x86_64 -kernel` with GNU as assembling the blob -- with the
// addresses patched to where this image actually puts the tables.
//
// The 64-bit entry (`y_kernel_entry64`) IS ordinary assembly text: it sets the
// stack, calls the program's top level (renamed y_kernel_main; the program's
// `_start` name belongs to the trampoline here) and falls into the halt loop
// kernel.s defines.
static Yv *kernel_head_text(void) {
    ylong base = kelf_base();
    ylong code_off = kelf_code_off();
    ylong head = kelf_head_len();
    /* The trampoline's length does not depend on the addresses in it (each one
       is a 32-bit immediate), so a first pass with zeros measures it. */
    Yv *pre = ktramp_pre(0, 0);
    ylong tlen = yv_len(pre) + 7;
    /* The page tables must be aligned in PHYSICAL memory, so pad between the
       trampoline and them until (base + code_off + head + tlen + pad) is a
       page. Everything after that is placed by construction: three 4 KB
       tables, then the 24-byte GDT and its 6-byte descriptor. */
    ylong start = base + code_off + head + tlen;
    ylong pad = 0;
    if (start % 4096 != 0) { pad = 4096 - start % 4096; };
    ylong pt = start + pad;
    ylong pdpt_low = pt + 4096;
    ylong pd_low = pt + 8192;
    ylong pdpt_dm = pt + 12288;
    ylong pd_dm = pt + 16384;
    ylong gdt = pt + 20480;
    ylong gdtr = gdt + 24;
    ylong entry = gdtr + 6;
    Yv *tramp = ktramp(pre, pt, gdtr, entry);
    Yv *text = ys(".text\n.globl _start\n");
    text = ys_cat(text, ys_cat(ys_cat(ys(".ascii \""), kascii(mb_header_bytes())), ys("\"\n")));
    text = ys_cat(text, ys("_start:\n"));
    text = ys_cat(text, ys_cat(ys_cat(ys(".ascii \""), kascii(tramp)), ys("\"\n")));
    /* pad to the page the tables start on */
    if (pad > 0) { text = ys_cat(text, ys_cat(ys_cat(ys(".zero "), ys_long(pad)), ys("\n"))); };
    /* One PML4 entry for the kernel's own 2 MB and one for the direct map.
     * Nothing else is mapped: PML4[0]'s low half belongs to user space, and
     * 0x400000 -- where a Linux executable is linked -- has to be free, which
     * is why the kernel's identity map is one 2 MB page and not a gigabyte. */
    text = ys_cat(text, ys_cat(ys_cat(ys("y_kernel_pml4:\n.quad "), ys_long(pdpt_low + 3)), ys("\n.zero 2176\n.quad ")));
    text = ys_cat(text, ys_cat(ys_cat(ys_long(pdpt_dm + 3), ys("\n.zero 1904\n")), ys("")));
    text = ys_cat(text, ys_cat(ys_cat(ys("y_kernel_pdpt_low:\n.quad "), ys_long(pd_low + 3)), ys("\n.zero 4088\n")));
    text = ys_cat(text, ys("y_kernel_pd_low:\n.quad 131\n.zero 4088\n"));
    text = ys_cat(text, ys_cat(ys_cat(ys("y_kernel_pdpt_dir:\n.quad "), ys_long(pd_dm + 3)), ys("\n.zero 4088\n")));
    text = ys_cat(text, ys("y_kernel_pd_dir:\n"));
    ylong i = 0;
    while (i < 512) {
        text = ys_cat(text, ys_cat(ys_cat(ys(".quad "), ys_long(i * 2097152 + 131)), ys("\n")));
        i = i + 1;
    };
    /* null, 64-bit code (L=1), data */
    text = ys_cat(text, ys("y_kernel_gdt:\n.quad 0\n.quad 49427445715107839\n.quad 49418649622085631\n"));
    /* the 6-byte GDTR the 32-bit lgdt reads: limit 23, base gdt */
    Yv *gd = kbput32(kbput16(yav(0), 23), gdt);
    text = ys_cat(text, ys_cat(ys_cat(ys("y_kernel_gdtr:\n.ascii \""), kascii(gd)), ys("\"\n")));
    text = ys_cat(text, ys("y_kernel_entry64:\n"));
    text = ys_cat(text, ys("    lea y_kernel_stack_top(%rip), %rsp\n"));
    /* A hosted program's _start records where the stack began, because the
     * collector scans the stack for roots; a kernel image has no _start, so
     * the kernel's own entry does it -- before anything can allocate. */
    text = ys_cat(text, ys("    mov %rsp, y_gc_stack_top(%rip)\n"));
    text = ys_cat(text, ys("    xor %rbp, %rbp\n"));
    /* The Multiboot loader left the info structure's physical address in
     * %ebx; nothing in the 32-bit half touches it, and the upper half of a
     * GPR is not defined across the mode switch, so the 32 bits are
     * zero-extended before the store. */
    text = ys_cat(text, ys("    mov %rbx, %rax\n"));
    text = ys_cat(text, ys("    shl $32, %rax\n"));
    text = ys_cat(text, ys("    shr $32, %rax\n"));
    text = ys_cat(text, ys("    mov %rax, y_mb_info(%rip)\n"));
    text = ys_cat(text, ys("    call y_kernel_main\n"));
    text = ys_cat(text, ys("    jmp y_kernel_halt\n"));
    return text;
}

// The 12-byte Multiboot-1 header: magic, flags 0 (no address fields, the ELF
// program headers say where everything goes), and the checksum that makes the
// three sum to zero.
static Yv *mb_header_bytes(void) {
    Yv *b = yav(0);
    b = kbput32(b, 464367618);      /* 0x1BADB002 */
    b = kbput32(b, 0);
    b = kbput32(b, 3830599678);     /* 0xE4524FFE -- -(magic + flags) */
    return b;
}

// The 32-bit half of the trampoline, everything up to and including the far
// jump. `pre` is built twice: once with zeros (to measure it) and once with
// the real page-table and GDT addresses.
static Yv *ktramp(Yv *pre, ylong pt, ylong gdtr, ylong entry) {
    (void)pre;
    Yv *b = ktramp_pre(pt, gdtr);
    /* ljmp $0x08, $entry: the mode switch. A far jump is the only instruction
       that reloads CS with L=1, and it has to name the target absolutely --
       hence the patched constant. */
    b = kb1(b, 234);
    b = kbput32(b, entry);
    b = kb1(b, 8);
    b = kb1(b, 0);
    return b;
}

static Yv *ktramp_pre(ylong pt, ylong gdtr) {
    Yv *b = yav(0);
    /* No table entries are stored here any more: they are emitted as data
     * below, and the only thing the 32-bit code does with the tables is
     * point CR3 at them. */
    b = kb1(b, 250);                        /* cli */
    b = kb1(b, 252);                        /* cld */
    b = kb3(b, 15, 32, 224);                /* mov %cr4, %eax */
    /* or $0x620, %eax: PAE (5) plus OSFXSR (9) and OSXMMEXCPT (10). The last
       two are not optional: without OSFXSR every SSE instruction is #UD, and
       the Y backend uses XMM for every float operation -- so
       `print(1.0 * 2.0)` stopped the machine at its first `movq %rax,%xmm0`
       while `print(7.0)` (a literal, passed in a GPR) worked. A hosted program
       never notices because Linux sets these before entering user space. */
    b = kb1(b, 13);
    b = kbput32(b, 1568);
    b = kb3(b, 15, 34, 224);                /* mov %eax, %cr4 */
    b = kb_imm32(b, 0, pt);                 /* mov $pml4, %eax */
    b = kb3(b, 15, 34, 216);                /* mov %eax, %cr3 */
    b = kb_imm32(b, 1, 3221225600);         /* mov $0xC0000080, %ecx */
    b = kb2(b, 15, 50);                     /* rdmsr */
    b = kb1(b, 13);                         /* or $0x100, %eax    (LME) */
    b = kbput32(b, 256);
    b = kb2(b, 15, 48);                     /* wrmsr */
    b = kb3(b, 15, 32, 192);                /* mov %cr0, %eax */
    b = kb1(b, 13);                         /* or $0x80010001, %eax (PG|WP|PE) */
    b = kbput32(b, 2147549185);
    b = kb3(b, 15, 34, 192);                /* mov %eax, %cr0 */
    b = kb1(b, 102);                        /* mov $0x10, %ax */
    b = kb1(b, 184);
    b = kb1(b, 16);
    b = kb1(b, 0);
    b = kb2(b, 142, 216);                   /* mov %ax, %ds */
    b = kb2(b, 142, 192);                   /* mov %ax, %es */
    b = kb2(b, 142, 208);                   /* mov %ax, %ss */
    b = kb3(b, 15, 1, 21);                  /* lgdt gdtr */
    b = kbput32(b, gdtr);
    return b;
}

static Yv *kb1(Yv *b, ylong v) {
    b = ya_push(b, yv_long(v % 256));
    return b;
}

static Yv *kb2(Yv *b, ylong a, ylong c) {
    b = kb1(b, a);
    b = kb1(b, c);
    return b;
}

static Yv *kb3(Yv *b, ylong a, ylong c, ylong d) {
    b = kb2(b, a, c);
    b = kb1(b, d);
    return b;
}

/* `mov $imm32, %reg`: B8+r id. */
static Yv *kb_imm32(Yv *b, ylong reg, ylong v) {
    b = kb1(b, 184 + reg);
    b = kbput32(b, v);
    return b;
}

static Yv *kbput32(Yv *b, ylong v) {
    b = ya_push(b, yv_long(v % 256));
    b = ya_push(b, yv_long((v / 256) % 256));
    b = ya_push(b, yv_long((v / 65536) % 256));
    b = ya_push(b, yv_long((v / 16777216) % 256));
    return b;
}

static Yv *kbput16(Yv *b, ylong v) {
    b = ya_push(b, yv_long(v % 256));
    b = ya_push(b, yv_long((v / 256) % 256));
    return b;
}

/* Bytes as the payload of an `.ascii "..."`: every byte an octal escape, so
   the assembler's decode_str (asm.c) reproduces them exactly. `\0` is the one
   byte it cannot spell with a short escape. */
static Yv *kascii(Yv *b) {
    Yv *out = ys("");
    /* NOTE: index loop, not foreach (PORTING.md rule 9). */
    ylong i = 0;
    while (i < yv_len(b)) {
        Yv *e = ya_get(b, i);
        out = ys_cat(out, ys("\\"));
        out = ys_cat(out, k_oct3(yv_l(e)));
        i = i + 1;
    };
    return out;
}

static Yv *k_oct3(ylong v) {
    ylong a = v / 64;
    ylong b = (v / 8) % 8;
    ylong c = v % 8;
    return ys_cat(ys_cat(ys_long(a), ys_long(b)), ys_long(c));
}
