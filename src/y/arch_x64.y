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
// The Windows half of the arch prelude: the blocks of prelude.s that reach
// the kernel, replaced whole (see arch_windows_lines). It is DATA here, not a
// second arch module -- a path import is flattened into its importer, so a
// second arch_x64.y could not coexist (arch_frame would be defined twice and
// the second would win).
embed W_SYS_ASM from "./arch/wsys.s";

// `text` as prelude lines: one per line, indentation kept (the -S output
// shows it). Dropped: a whole-line '#' comment (the in-tree assembler treats a
// comment as a backend bug and must never see one — every comment line in
// src/y/arch/*.s starts at column 0 for exactly this reason) and the empty
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
    if (target_is_windows()) { "x86_64-windows" } else { "x86_64-linux" }
};

def arch_word() -> long {
    8
};

// syscall number table. NOTE: one arm per syscall (ladder style, see the
// master note in asm.y's is_digit_ch — not a language restriction).
// The Windows half is w_sysno: the numbers there are the NT syscall index
// range, which is dense and live, so a Linux number left behind does not
// fail loudly -- it calls a different, real Nt function. That is why they are
// one table here, read off the stubs in a real ntdll rather than written from
// memory, and why w_self_test probes one call per class at program start.
def arch_sysno(name: str) -> long {
    if (target_is_windows()) { w_sysno(name) }
    else { l_sysno(name) }
};

def l_sysno(name: str) -> long {
    if (name == "read") { 0 }
    else if (name == "write") { 1 }
    else if (name == "close") { 3 }
    else if (name == "openat") { 257 }
    else if (name == "exit") { 60 }
    else { -1 }
};

// The NT syscall index of each Windows call, pinned to Windows 10 1607 / 11
// x64.  Measured, not remembered: each number was read out of the `mov $N,%eax`
// of the corresponding stub in a real ntdll.dll's .text (a leftover Linux
// number silently calls a real, different Nt function, which is exactly why
// this is one table a review can read at once).
def w_sysno(name: str) -> long {
    if (name == "write") { 8 }              // NtWriteFile
    else if (name == "read") { 6 }          // NtReadFile
    else if (name == "close") { 15 }        // NtClose
    else if (name == "exit") { 44 }         // NtTerminateProcess
    else if (name == "alloc") { 24 }        // NtAllocateVirtualMemory
    else if (name == "free") { 30 }         // NtFreeVirtualMemory
    else if (name == "protect") { 80 }      // NtProtectVirtualMemory
    else if (name == "perf_counter") { 49 } // NtQueryPerformanceCounter
    else if (name == "delay") { 52 }        // NtDelayExecution
    else if (name == "system_time") { 90 }  // NtQuerySystemTime
    else { -1 }
};

// The Windows syscall self-test (ideas/WINDOWS.md, Risks): one Nt call per
// class, its NTSTATUS checked, run once at program start when the target is
// Windows. A number that drifted calls some other Nt function, and the honest
// failure for that is a program that says so at startup rather than one that
// misbehaves hours later. Memory (NtAllocateVirtualMemory), a file handle
// (NtClose on the standard output), time (NtQueryPerformanceCounter) and a
// thread (NtCreateThreadEx, whose failure path is "already probed": a real
// thread is not started, the call is only made when a program uses threads).
// Returns "" when every probe passed, else the name of the one that did not.
def w_self_test_lines() -> [str] { [] };

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
    if (target_is_windows()) { "    mov \$44, %rax\n    mov \$-1, %r10\n    xor %edi, %edi\n    mov %edi, %r9\n    syscall\n" }
    else { "    mov \$231, %rax\n    xor %edi, %edi\n    syscall\n" }
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
    if (target_is_windows()) { arch_windows_lines() } else { arch_asm_lines(PRELUDE_ASM) }
};

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
def arch_windows_lines() -> [str] {
    let blocks = arch_win_blocks(split(W_SYS_ASM, "\n"));
    let i = 0;
    while (i < len(blocks)) {
        if (blocks[i][1] == "2") {
            puts("error: arch/wsys.s: bad block marker ('" + blocks[i][0] + "'): want '#=== replace: NAME ===' or '#=== add: NAME ==='\n");
            exit(1);
        };
        i = i + 1;
    };
    let lines = arch_asm_lines(PRELUDE_ASM);
    arch_win_check(lines, blocks);
    arch_win_sub(lines, blocks)
};

// Every `replace:` name must be a block the prelude really has. This is the
// check that keeps the substitution honest: a marker naming a block that
// moved (or one whose marker line lost its leading "#", which drops the
// marker and silently substitutes nothing) would otherwise leave the SysV
// code in a Windows binary -- the failure mode with no symptom until the
// program calls the wrong syscall. It cost one whole debugging session to
// earn, which is why it is a hard error rather than a comment.
def arch_win_check(lines: [str], blocks: [[str]]) -> long {
    let i = 0;
    while (i < len(blocks)) {
        if (blocks[i][1] == "0") {
            if (arch_win_labeled(lines, blocks[i][0])) { } else {
                puts("error: arch/wsys.s replaces '" + blocks[i][0] + "', which src/y/arch/prelude.s does not define\n");
                exit(1);
            };
        };
        i = i + 1;
    };
    0
};

def arch_win_labeled(lines: [str], nm: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(lines)) {
        let l = lines[i];
        if (arch_is_label_line(l) && trim(l[0:len(l) - 1]) == nm) { found = true; };
        i = i + 1;
    };
    found
};

// wsys.s's blocks as [name, mode, line, line, ...] records, in the order the
// file gives them: mode 0 replaces the same-named prelude block, 1 is new.
def arch_win_blocks(lines: [str]) -> [[str]] {
    let out: [[str]] = [];
    let cur: [str] = [];
    let i = 0;
    while (i < len(lines)) {
        let l = lines[i];
        let mk = arch_win_marker(l);
        if (mk != "") {
            if (len(cur) > 0) { out += cur; };
            cur = arch_win_head(mk);
            i = i + 1;
        } else {
            // Comments are documentation here (GNU as reads them too) and
            // must not reach the assembler, which calls one a backend bug.
            if (len(l) == 0 || byte_at(l, 0) != 35) { cur += l; };
            i = i + 1;
        };
    };
    if (len(cur) > 0) { out += cur; };
    out
};

// "#=== replace: NAME ===" -> "replace: NAME", or "" when the line is not a
// marker. A line that starts with "#===" but does not parse comes back as "?"
// and arch_windows_lines makes it a hard error: a silently ignored marker is
// the one failure this substitution cannot be allowed to have, because the
// symptom -- a Linux block sitting in a Windows binary -- appears far away.
def arch_win_marker(l: str) -> str {
    if (l[0:4] != "#===") {
        ""
    } else {
        let body = l[4:];
        let colon = index_of(body, ":");
        if (colon < 0) { "?" } else { arch_win_tail(trim(body[0:colon]), trim(body[colon + 1:])) }
    }
};

// "replace: y_alloc_map ===" -> "replace: y_alloc_map". The closing "==="
// goes by SUFFIX: index_of would find the marker line's OWN leading "===".
def arch_win_tail(mode: str, name: str) -> str {
    let k = len(name) - 3;
    if (k >= 0 && name[k:] == "===") { mode + ": " + trim(name[0:k]) } else { "?" }
};

// The [name, mode] head of a block: 0 replaces the same-named prelude block,
// 1 is new, 2 is a malformed marker.
def arch_win_head(nm: str) -> [str] {
    if (nm[0:9] == "replace: ") {
        [nm[9:], "0"]
    } else if (nm[0:5] == "add: ") {
        [nm[5:], "1"]
    } else {
        ["?", "2"]
    }
};

def arch_is_label_line(l: str) -> bool {
    if (len(l) == 0) { false }
    else if (byte_at(l, 0) == 32 || byte_at(l, 0) == 9) { false }
    else if (l[len(l) - 1:] != ":") { false }
    else { index_of(l, " ") < 0 }
};

// `lines` walked; at a label a replacing block claims, that block's lines and
// not the prelude's. The new blocks go after the last replaced one.
def arch_win_sub(lines: [str], blocks: [[str]]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(lines)) {
        let l = lines[i];
        let b = -1;
        if (arch_is_label_line(l)) {
            b = arch_win_find(blocks, trim(l[0:len(l) - 1]));
        };
        if (b >= 0) {
            arch_win_push(out, join(blocks[b][2:len(blocks[b])], "\n"));
            i = i + 1;
            while (i < len(lines) && !arch_is_label_line(lines[i])) { i = i + 1; };
        } else {
            arch_win_push(out, l);
            i = i + 1;
        };
    };
    i = 0;
    while (i < len(blocks)) {
        if (blocks[i][1] == "1") { arch_win_push(out, join(blocks[i][2:len(blocks[i])], "\n")); };
        i = i + 1;
    };
    // one line per list element: arch_prelude_lines' contract with
    // native.y's prelude_blocks and shake_prelude.
    out = arch_win_split(out)
};

def arch_win_split(out: [str]) -> [str] {
    let res: [str] = [];
    let i = 0;
    while (i < len(out)) {
        let parts = split(out[i], "\n");
        let j = 0;
        while (j < len(parts)) {
            if (len(parts[j]) > 0) { res += parts[j]; };
            j = j + 1;
        };
        i = i + 1;
    };
    res
};

// The block that replaces `nm`, or -1 when wsys.s does not define one (mode
// "0", name `nm`).
def arch_win_find(blocks: [[str]], nm: str) -> long {
    let at = -1;
    let i = 0;
    while (i < len(blocks)) {
        if (blocks[i][1] == "0" && blocks[i][0] == nm) { at = i; };
        i = i + 1;
    };
    at
};

def arch_win_push(out: [str], l: str) -> [str] {
    if (len(l) > 0) { out += l; };
    out
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
