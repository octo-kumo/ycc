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
static Yv *arch_win_blocks(Yv *lines);
static ylong arch_win_check(Yv *lines, Yv *blocks);
static int arch_win_labeled(Yv *lines, Yv *nm);
static Yv *arch_win_marker(Yv *l);
static Yv *arch_win_tail(Yv *mode, Yv *name);
static Yv *arch_win_head(Yv *nm);
static int arch_is_label_line(Yv *l);
static Yv *arch_win_sub(Yv *lines, Yv *blocks);
static Yv *arch_win_split(Yv *out);
static ylong arch_win_find(Yv *blocks, Yv *nm);
static Yv *arch_win_push(Yv *out, Yv *l);

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
    return ys(".text\n.globl _start\n");
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
    else { return ys("    mov $231, %rax\n    xor %edi, %edi\n    syscall\n"); }
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
    Yv *blocks = arch_win_blocks(ys_split(W_SYS_ASM(), ys("\n")));
    ylong i = 0;
    while (i < yv_len(blocks)) {
        if (ys_eq_lit(ya_get(ya_get(blocks, i), 1), "2")) {
            puts_(ys_cat(ys_cat(ys("error: arch/wsys.s: bad block marker ('"),
                                  ya_get(ya_get(blocks, i), 0)),
                         ys("'): want '#=== replace: NAME ===' or '#=== add: NAME ==='\n")));
            exit_(1);
        }
        i = i + 1;
    }
    Yv *lines = arch_asm_lines(PRELUDE_ASM());
    arch_win_check(lines, blocks);
    return arch_win_sub(lines, blocks);
}

// Every `replace:` name must be a block the prelude really has. This is the
// check that keeps the substitution honest: a marker naming a block that
// moved (or one whose marker line lost its leading "#", which drops the
// marker and silently substitutes nothing) would otherwise leave the SysV
// code in a Windows binary -- the failure mode with no symptom until the
// program calls the wrong syscall. It cost one whole debugging session to
// earn, which is why it is a hard error rather than a comment.
static ylong arch_win_check(Yv *lines, Yv *blocks) {
    ylong i = 0;
    while (i < yv_len(blocks)) {
        if (ys_eq_lit(ya_get(ya_get(blocks, i), 1), "0")) {
            if (arch_win_labeled(lines, ya_get(ya_get(blocks, i), 0))) { /* found */ }
            else {
                puts_(ys_cat(ys_cat(ys("error: arch/wsys.s replaces '"),
                                      ya_get(ya_get(blocks, i), 0)),
                             ys("', which src/y/arch/prelude.s does not define\n")));
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
            if (yv_len(l) == 0 || ys_byte_at(l, 0) != 35) {
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
// and arch_windows_lines makes it a hard error: a silently ignored marker is
// the one failure this substitution cannot be allowed to have, because the
// symptom -- a Linux block sitting in a Windows binary -- appears far away.
static Yv *arch_win_marker(Yv *l) {
    if (!ys_eq(ys_slice(l, 0, 4), ys("#==="))) {
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
    if (ys_eq(ys_slice(nm, 0, 9), ys("replace: "))) {
        return yav(2, ys_slice_from(nm, 9), ys("0"));
    } else if (ys_eq(ys_slice(nm, 0, 5), ys("add: "))) {
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
