// arch_x64.y — Linux x86_64 code emitters for the native backend (ycc).
//
// The machine code itself lives in src/y/arch/*.s, embedded here and
// .incbin'd by the C twin (PORTING.md rules 10 and 11): ONE copy of the
// assembly, not one per compiler. A whole-line '#' comment is documentation —
// for whoever reads the .s, and for `make asm-check` (GNU as) — and
// arch_asm_lines drops it, because the in-tree assembler treats a comment as a
// backend bug and must never see one.
embed PRELUDE_ASM from "./arch/prelude.s";
embed THREADS_ASM from "./arch/threads.s";

// `text` as prelude lines: one per line, indentation kept (the -S output
// shows it). Dropped: a whole-line '#' comment (the in-tree assembler treats a
// comment as a backend bug and must never see one — every comment line in
// .s files under src/y/arch start at column 0 for exactly this reason) and the empty
// tail a trailing newline leaves behind.
// TWO COSTS, both measured, both paid once per compiler process (emit_program
// calls arch_prelude_lines exactly once):
//   - split() materialises the 1542 lines as strings: +374K instructions, half
//     of what this function costs. That is the price of ONE copy of the asm
//     instead of one per compiler, and it is what bought it: arch_x64.y shrank
//     2181 -> 158 lines, src/c/arch_x64.c 2185 -> 162, cycc 2091496 -> 1811992
//     bytes. Removing it needs the shaking to work on offsets into the one
//     string (the backend IR in ideas/OPTIMIZE.md), not a tweak here.
//   - no trim() per line: it allocated a second string for each of the 1542
//     lines at ~630 instructions a line, and measured +37% instructions to
//     compile hello.y before this. Byte 35 is '#'; reading the first byte is
//     the same test for the price of one.
def arch_asm_lines(text: str) -> [str] {
    let out: [str] = [];
    let all = text.split("\n");
    let i = 0;
    while (i < len(all)) {
        let l = all[i];
        if (len(l) > 0 && byte_at(l, 0) != 35) { out += l; };
        i = i + 1;
    };
    out
};

def arch_id() -> str {
    "x86_64-linux"
};

def arch_word() -> long {
    8
};

// syscall number table. NOTE: one arm per syscall (ladder style, see the
// master note in asm.y's is_digit_ch — not a language restriction).
def arch_sysno(name: str) -> long {
    if (name == "read") { 0 }
    else if (name == "write") { 1 }
    else if (name == "close") { 3 }
    else if (name == "openat") { 257 }
    else if (name == "exit") { 60 }
    else { -1 }
};

def arch_fn_label(uid: long, name: str) -> str {
    "yfn_" + uid + "_" + name
};

def arch_global_label(uid: long, name: str) -> str {
    "yg_" + uid + "_" + name
};

def arch_loc_label(fuid: long, n: long) -> str {
    "yL_" + fuid + "_" + n
};

def arch_str_label(i: long) -> str {
    "ystr_" + i
};

def arch_header() -> str {
    ".text\n.globl _start\n"
};

def arch_rodata() -> str {
    ".section .rodata\n"
};

def arch_text() -> str {
    ".text\n"
};

// One zeroed 8-byte cell per global (see emit_program in native.y).
def arch_bss() -> str {
    ".section .bss\n"
};

def arch_global_cell(label: str) -> str {
    label + ":\n.zero 8\n"
};

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
def arch_heap_cells() -> str {
    "y_heap:\n.zero 32\n"
};

def arch_frame(slots: long) -> long {
    // slots * 8, rounded up to a multiple of 16 (call alignment)
    let bytes = slots * 8;
    if (bytes % 16 == 0) { bytes } else { bytes + (16 - bytes % 16) }
};

def arch_exit() -> str {
    "    mov \$231, %rax\n    xor %edi, %edi\n    syscall\n"
};

// The prelude as its lines: labels alone at column 0, everything else
// indented (native.y prelude_blocks relies on it).
def arch_prelude_lines() -> [str] {
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
    arch_asm_lines(PRELUDE_ASM)
};

// The thread runtime (CHOICES_MADE.md 33), linked only when a program's
// code calls into it (native.y uses_threads): every compile looks at
// each line of the prelude it is given.
def arch_prelude_threads_lines() -> [str] {
    arch_asm_lines(THREADS_ASM)
};

def arch_consts() -> str {
    // rodata literals emitted once at the end of the file (string headers,
    // error messages)
    join([
        "ystr_minus_h:",
        ".quad 1",
        ".string \"-\"",
        "ystr_dot_h:",
        ".quad 1",
        ".string \".\"",
        "ystr_divzero: .ascii \"runtime error: division by zero\\n\"",
        "ystr_divzero_end:",
        "ystr_oob: .ascii \"runtime error: index out of bounds\\n\"",
        "ystr_oob_end:",
        "ystr_cast: .ascii \"runtime error: a union value cast to a member it does not hold\\n\"",
        "ystr_cast_end:",
        "ystr_oom: .ascii \"runtime error: out of memory\\n\"",
        "ystr_oom_end:",
        "ystr_opt: .ascii \"runtime error: unwrap of none\\n\"",
        "ystr_opt_end:",
    ], "\n") + "\n"
};

export { arch_id, arch_word, arch_sysno, arch_fn_label, arch_global_label, arch_loc_label, arch_str_label, arch_header, arch_rodata, arch_text, arch_bss, arch_global_cell, arch_heap_cells, arch_prelude_lines, arch_prelude_threads_lines, arch_consts, arch_frame, arch_exit };
