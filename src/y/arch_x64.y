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
// The float primitives std/math.y's kernels reach for (`ndef`s with no
// body -- see NATIVE.md, "Backend"), one embedded copy like the rest.
embed MATH_ASM from "./arch/math.s";
// The Windows syscall self-test: the probe w_self_test_lines returns, run
// from _start before anything else on that target. Its own file so GNU as
// reads it (make asm-check) like the other arch assembly.
embed WSELFTEST_ASM from "./arch/wselftest.s";
// ⚠ OPEN (kernel): master's collector (arch/prelude.s, a block of its own) is
// emitted AFTER the kernel's own prelude blocks, and label resolution is
// last-wins -- so its y_gc_maybe/y_gc_chunk_add override arch/kernel.s's
// no-ops and the collector runs in a kernel image again.  Measured: in a
// kernel -S listing built by refs/ycc.ref (pre-merge) `y_gc_maybe:` does not
// appear at all; built by the merged compiler it appears once, with the
// prelude's body.  The result is a kernel whose allocations go through a
// collector that has no valid heap: a user-mode read at 0 (err=5) before the
// first byte of output, reproducible with a program that never allocates.
// (Old kernel + program built by the NEW compiler works, which is what
// isolates this to the kernel image.)
//
// FIXED the second way: arch/kernel.s now declares the four no-ops as
// `#=== replace: NAME ===` blocks, and the listing confirms the kernel's body
// (`xor %eax, %eax; ret`) is the one emitted.  That closed THIS gap but not
// the failure: a kernel built by the merged compiler still faults with a
// user-mode read at 0 (err=5) on a program that never allocates -- and the
// same program runs on a pre-merge kernel image, so the remaining difference
// is elsewhere in the merged kernel image (the new allocator text is in it, and
// its fast path uses the runtime's y_heap cell pair, which the kernel's
// y_heap_region_set does not write -- worth checking next).
//
// The kernel half of the prelude (`ycc --kernel`): the blocks of prelude.s
// that touch the kernel, replaced whole -- mmap, serial, exit, the traps --
// plus the pieces a freestanding payload needs and a hosted program does not
// (port I/O, the PIC, the IDT, the halt loop). Same `#=== replace:` /
// `#=== add:` mechanism as wsys.s; see arch_replaced_lines.
embed KERNEL_ASM from "./arch/kernel.s";

// The ELF32 Multiboot writer's layout constants (base, header size, where
// .bss starts). The trampoline below bakes the same numbers into its 32-bit
// immediates, so both sides read them from kelf.y rather than spelling them.
import kelf from "./kelf.y";

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
    (text.split("\n")).foreach((l) => {
        if (len(l) > 0 && l[0] != 35) { out += l; };
    });
    out
};

def arch_id() -> str {
    if (target_is_windows()) { "x86_64-windows" }
    else if (target_is_kernel()) { "x86_64-kernel" }
    else { "x86_64-linux" }
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
// memory. w_self_test would probe one call per class at program start, and
// does not yet -- see its own comment below.
def arch_sysno(name: str) -> long {
    if (target_is_windows()) { w_sysno(name) }
    else if (target_is_kernel()) { -1 }
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
    // 196 is NOT what the public Windows 10 table suggests (it lists 62, whose
    // neighbour NtQueryAttributesFile really is 61); 62 answers
    // STATUS_INVALID_HANDLE. Read out of the installed ntdll's own stub by
    // test/sh/w_sysno.py, which is the only authority for what a probe under
    // this wine will do.
    else if (name == "attrs") { 196 }       // NtQueryFullAttributesFile
    else { -1 }
};

// The Windows syscall self-test (ideas/WINDOWS.md W3), its lines in
// arch/wselftest.s: one Nt call per class -- memory, time, file -- with its
// NTSTATUS checked once at program start, so a number that drifted on a
// different Windows build fails loudly instead of calling some other real Nt
// function. native.y feeds these lines to the prelude (so the shaker keeps
// y_os_write/y_os_exit for them) and the _start prologue calls
// y_w_self_test, both on the Windows target only: on Linux this returns no
// lines and no call is emitted.
def w_self_test_lines() -> [str] {
    if (target_is_windows()) { arch_asm_lines(WSELFTEST_ASM) } else {[] }
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
    if (target_is_kernel()) { kernel_head_text() } else { ".text\n.globl _start\n" }
};

def arch_rodata() -> str {
    ".section .rodata\n"
};

def arch_text() -> str {
    ".text\n"
};

// One zeroed 8-byte cell per global (see emit_program in native.y).
// ── the Windows imports ─────────────────────────────────────────────────
// Windows has no syscall for randomness (BCryptGenRandom is a DLL export), for
// sockets (Winsock) or for the console API, so those arrive as PE imports. The
// list lives here, in the arch module, because two things need it and they are
// on opposite sides of the build: the linker (native.y) reserves one .bss cell
// per imported function so the code can reach the resolved pointer, and the PE
// writer (pe.y) emits the descriptor, ILT and name table that fills those
// cells. One list, or the two would drift.
type WImport = { dll: str, funcs: [str] };

def w_imports() -> [WImport] {
    [
        { dll: "KERNEL32.dll", funcs: ["GetCurrentProcessId"] },
        { dll: "advapi32.dll", funcs: ["SystemFunction036"] }
    ]
};

// The .bss cell the loader writes an imported function's address into. The
// code calls through it -- `mov y_iat_X(%rip), %rax; call *%rax` -- which is
// why it has to be a cell with a label rather than a slot inside .idata: only
// .text, .bss and the unwind sections have addresses the assembler knows.
def w_iat_label(fn: str) -> str { "y_iat_" + fn };

// The terminator slot of a DLL's IAT: the image format wants the array to end
// in a zero entry, and the loader writes it along with the resolved addresses
// (it walks the ILT, which carries the names, and fills one IAT slot per
// entry plus that zero). One per DLL, named after it so two DLLs cannot share.
def w_iat_term_label(dll: str) -> str { "y_iatz_" + dll };

// The .bss block the Windows imports need: one 8-byte cell per imported
// function, then one zeroed terminator per DLL, in w_imports()' order. It is
// emitted as the FIRST thing in .bss, which is what makes each cell's offset a
// constant (0, 8, 16, ...) rather than something the writer has to ask the
// assembler's label map for -- and a wrong offset there is an image whose
// FirstThunk points outside .bss, so the loader writes the resolved addresses
// over whatever does live there.
def w_iat_bss_lines() -> [str] {
    let out: [str] = [];
    w_imports().foreach((e) => {
        for f in 0..len(e.funcs) {
            out += w_iat_label(e.funcs[f]) + ":\n.zero 8\n";
        };
        out += w_iat_term_label(e.dll) + ":\n.zero 8\n";
    });
    out
};

// The .bss offset of function `f` of DLL index `d`: the block above is first in
// the section, so this is arithmetic on the spec rather than a lookup.
def w_iat_offset(d: long, f: long) -> long {
    let imps = w_imports();
    let at = 0;
    for i in 0..d {
        at += 8 * (len(imps[i].funcs) + 1);
    };
    at + 8 * f
};

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
    // y_heap_base holds the main heap's bytes handed out before the program's
    // own top-level code runs -- the argv copies y_argv_init makes, which are
    // the one part of that baseline that changes with how the caller spelled
    // the command (SUGGESTIONS.md 24: heap_used() moved one byte per
    // character of argv[0]). y_heap_used subtracts it, on the main heap only:
    // a spawned thread gets a heap of its own, and the argv copies are not in
    // it.
    //
    // The y_gc_* cells are the collector's state (arch/prelude.s): the stack
    // top _start records, the heap's low/high bounds, the chunk list and its
    // hash table, the metadata bump, the free-list heads and mark stack, the
    // live-byte and trigger counters, and the running/off guards. They are
    // words, so a program that never allocates shakes them out with y_alloc
    // and every other program carries a few hundred zeroed .bss bytes.
    "y_heap:\n.zero 32\ny_heap_base:\n.zero 8\n" +
    "y_gc_stack_top:\n.zero 8\ny_gc_lo:\n.zero 8\ny_gc_hi:\n.zero 8\n" +
    "y_gc_all:\n.zero 8\ny_gc_tab:\n.zero 8\ny_gc_tabn:\n.zero 8\n" +
    "y_gc_meta_cur:\n.zero 8\ny_gc_meta_end:\n.zero 8\n" +
    "y_gc_free:\n.zero 8\ny_gc_ms_cur:\n.zero 8\ny_gc_ms_end:\n.zero 8\n" +
    "y_gc_ms_seg:\n.zero 8\n" +
    "y_gc_live:\n.zero 8\ny_gc_last:\n.zero 8\n" +
    "y_gc_run:\n.zero 8\ny_gc_off:\n.zero 8\n"
};

def arch_frame(slots: long) -> long {
    // slots * 8, rounded up to a multiple of 16 (call alignment)
    let bytes = slots * 8;
    if (bytes % 16 == 0) { bytes } else { bytes + (16 - bytes % 16) }
};

def arch_exit() -> str {
    if (target_is_windows()) { "    mov \$44, %rax\n    mov \$-1, %r10\n    xor %edi, %edi\n    mov %edi, %r9\n    syscall\n" }
    else if (target_is_kernel()) { "    jmp y_kernel_halt\n" }
    else { "    mov \$231, %rax\n    xor %edi, %edi\n    syscall\n" }
};

// The kernel's own .bss: the IDT and its descriptor, the kernel stack, the
// fixed heap arena `y_alloc_map` hands out of, and the multiboot info
// pointer.  None of it exists on a hosted target, so native.y emits this
// only for --kernel.
def arch_kernel_bss() -> str {
    // The 16 MB arena that used to live here is gone: it put the image's end
    // 18 MB up, which is where user space wants to be (a Linux executable is
    // linked at 0x400000), and the kernel is mapped by ONE 2 MB page.  The Y
    // heap now lives in RAM above the image, chosen by std/kernel.y's
    // y_heap_init the first time anything allocates.
    ".align 16\n" +
    "y_mb_info:\n.zero 8\n" +
    ".align 16\n" +
    "y_kernel_idt:\n.zero 4096\n" +
    "y_kernel_idtr:\n.zero 16\n" +
    ".align 16\n" +
    "y_kernel_stack_bottom:\n.zero 32768\n" +
    "y_kernel_stack_top:\n" +
    ".align 16\n" +
    // The Y heap's region, as a physical address and direct-map addresses:
    // set once by y_heap_region_set, bumped by y_alloc_map.
    // The kernel's own GDT (six entries), its descriptor and the TSS are
    // built by std/kernel.y's gdt_init in heap memory, not here: a descriptor
    // table is a data structure, and only `lgdt`/`ltr` have to be instructions.
    // The syscall path's two words: where the user stack was when SYSCALL
    // arrived, and the kernel stack it switched to (M2 gives each task one).
    "y_user_rsp:\n.zero 8\n" +
    // The running task: its kernel stack top (where SYSCALL lands and where the
    // TSS RSP0 points) and the %rsp of its suspended frame (the scheduler's
    // only view of a task's registers, because the frame IS the state).
    "y_irq_scratch:\n.zero 8\n" +
    "y_cur_kstack:\n.zero 8\n" +
    "y_cur_task_rsp:\n.zero 8\n" +
    "y_heap_start:\n.zero 8\n" +
    "y_heap_bias:\n.zero 8\n" +
    "y_heap_next:\n.zero 8\n" +
    "y_heap_limit:\n.zero 8\n" +
    // Where the kernel's own memory ends.  A physical page allocator starts
    // at the next page after this, and nothing in the image is above it.
    "y_kernel_end:\n"
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
    if (target_is_windows()) { arch_windows_lines() }
    else if (target_is_kernel()) { arch_kernel_lines() }
    else { arch_asm_lines(PRELUDE_ASM) }
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
//                              block calls it, so a block nothing calls costs
//                              a program nothing
//
// and the difference is not cosmetic: an `add:` block whose NAME the prelude
// also defines is DEAD. Both definitions reach the program and the assembler's
// label map keeps one -- and it is not the one wsys.s added -- so a block that
// is meant to REPLACE a Linux one must say `replace:`, or the Linux syscall
// stays in a Windows binary and the failure appears in whatever called it.
// (y_os_read, y_os_wait4, y_os_fork and y_os_execve were `add:` for one
// revision and a PE's y_os_wait4 answered STATUS_ACCESS_VIOLATION where Linux
// answered ECHILD, because the prelude's wait4(2) had won.)
// A `replace:` name the prelude does not define is a hard error (see
// arch_win_find): it means the Windows half was written against a block that
// moved, and the substitution would silently do nothing. `make asm-check`
// gives GNU as a second opinion on wsys.s as well.
def arch_windows_lines() -> [str] {
    arch_replaced_lines(W_SYS_ASM, "src/y/arch/wsys.s")
};

// The kernel's replacement blocks (`ycc --kernel`): the same substitution,
// against src/y/arch/kernel.s.
def arch_kernel_lines() -> [str] {
    arch_replaced_lines(KERNEL_ASM, "src/y/arch/kernel.s")
};

def arch_replaced_lines(sub: str, what: str) -> [str] {
    let blocks = arch_win_blocks(split(sub, "\n"));
    blocks.foreach((e) => {
        if (len(e) > 1 && e[1] == "2") {
            puts("error: " + what + ": bad block marker ('" + e[0] + "'): want '#=== replace: NAME ===' or '#=== add: NAME ==='\n");
            exit(1);
        };
    });
    let lines = arch_asm_lines(PRELUDE_ASM);
    arch_win_check(lines, blocks, what);
    arch_win_sub(lines, blocks)
};

// Every `replace:` name must be a block the prelude really has. This is the
// check that keeps the substitution honest: a marker naming a block that
// moved (or one whose marker line lost its leading "#", which drops the
// marker and silently substitutes nothing) would otherwise leave the SysV
// code in a Windows binary -- the failure mode with no symptom until the
// program calls the wrong syscall. It cost one whole debugging session to
// earn, which is why it is a hard error rather than a comment.
def arch_win_check(lines: [str], blocks: [[str]], what: str) -> void {
    blocks.foreach((e) => {
        if (e[1] == "0") {
            if (!(arch_win_labeled(lines, e[0]))) {
                puts("error: " + what + " replaces '" + e[0] + "', which src/y/arch/prelude.s does not define\n");
                exit(1);
            };
        };
    });
};

def arch_win_labeled(lines: [str], nm: str) -> bool {
    let i = 0;
    let found = false;
    while (i < len(lines)) {
        let l = lines[i];
        if (arch_is_label_line(l) && trim(l[0:len(l) - 1]) == nm) { found = true; };
        i++;
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
            i++;
        } else {
            // Comments are documentation here (GNU as reads them too) and
            // must not reach the assembler, which calls one a backend bug.
            if (len(l) > 0 && l[0] != 35) { cur += l; };
            i++;
        };
    };
    if (len(cur) > 0) { out += cur; };
    out
};

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
def arch_win_marker(l: str) -> str {
    if (len(l) < 4) {
        ""
    } else if (l[0:4] != "#===") {
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
    if (len(nm) >= 9 && nm[0:9] == "replace: ") {
        [nm[9:], "0"]
    } else if (len(nm) >= 5 && nm[0:5] == "add: ") {
        [nm[5:], "1"]
    } else {
        ["?", "2"]
    }
};

def arch_is_label_line(l: str) -> bool {
    if (len(l) == 0) { false }
    else if (l[0] == 32 || l[0] == 9) { false }
    else if (l[len(l) - 1:] != ":") { false }
    else { index_of(l, " ") < 0 }
};

// `lines` walked; at a label a replacing block claims, that block's lines and
// not the prelude's. The new blocks go after the last replaced one.
// Replace the block that starts at the column-0 label `name` (through the line
// before the next label) with `repl`.
def arch_block_sub(lines: [str], name: str, repl: [str]) -> [str] {
    let out: [str] = [];
    let i = 0;
    while (i < len(lines)) {
        let l = lines[i];
        if (arch_is_label_line(l) && trim(l[0:len(l) - 1]) == name) {
            repl.foreach((r) => {
                out += r;
            });
            i++;
            while (i < len(lines) && !(arch_is_label_line(lines[i]))) { i++; };
        } else {
            out += l;
            i++;
        };
    };
    out
};

// The GC-free runtime: a program whose heap cannot grow does not link the
// collector at all (--gc, or the auto analysis). The allocator itself is
// UNCHANGED -- only the collector's three entry points become stubs -- so the
// chunk layout and heap_used() accounting are bit-identical, and every other
// collector block (the registry, metadata arena, marker, sweeper, free lists)
// becomes unreachable and is shaken out.
//   y_gc_maybe      never runs a cycle
//   y_gc_alloc_free never recycles a block (0 = none)
//   y_gc_chunk_add  returns the base the allocator wants and registers nothing
def arch_nogc_lines(lines: [str]) -> [str] {
    let out = arch_block_sub(lines, "y_gc_maybe", ["y_gc_maybe:", "    ret"]);
    out = arch_block_sub(out, "y_gc_alloc_free",
        ["y_gc_alloc_free:", "    xor %eax, %eax", "    ret"]);
    arch_block_sub(out, "y_gc_chunk_add",
        ["y_gc_chunk_add:", "    mov %rdi, %rax", "    ret"])
};

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
            i++;
            while (i < len(lines) && !arch_is_label_line(lines[i])) { i++; };
        } else {
            arch_win_push(out, l);
            i++;
        };
    };
    i = 0;
    while (i < len(blocks)) {
        if (blocks[i][1] == "1") { arch_win_push(out, join(blocks[i][2:len(blocks[i])], "\n")); };
        i++;
    };
    // one line per list element: arch_prelude_lines' contract with
    // native.y's prelude_blocks and shake_prelude.
    out = arch_win_split(out)
};

def arch_win_split(out: [str]) -> [str] {
    let res: [str] = [];
    out.foreach((el) => {
        (split(el, "\n")).foreach((e) => {
            if (len(e) > 0) { res += e; };
        });
    });
    res
};

// The block that replaces `nm`, or -1 when wsys.s does not define one (mode
// "0", name `nm`).
def arch_win_find(blocks: [[str]], nm: str) -> long {
    let at = -1;
    blocks.foreach((e, i) => {
        if (e[1] == "0" && e[0] == nm) { at = i; };
    });
    at
};

def arch_win_push(out: [str], l: str) -> void {
    if (len(l) > 0) { out += l; };
    out
};

// The thread runtime (CHOICES_MADE.md 33), linked only when a program's
// code calls into it (native.y uses_threads): every compile looks at
// each line of the prelude it is given.
def arch_prelude_threads_lines() -> [str] {
    arch_asm_lines(THREADS_ASM)
};

// The floating-point primitives (src/y/arch/math.s): the four a std module
// reaches through `ndef`, and the only machine code between Y and a
// numeric library -- Y has no float-to-long conversion and no way to read a
// float's bits. Always given to the shaking (they are a few lines, unlike the
// thread runtime, so there is nothing to save by looking first).
def arch_math_lines() -> [str] {
    arch_asm_lines(MATH_ASM)
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
        "ystr_int: .ascii \"runtime error: a float with no integer part a long holds\\n\"",
        "ystr_int_end:",
        "ystr_wselftest: .ascii \"runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)\\n\"",
        "ystr_wselftest_end:",
        ], "\n") + "\n"
};

// ── the generated interrupt plumbing ─────────────────────────────────────
// One stub per `irq N def f()` the program declared (target.y's
// res_irq_stubs), plus the routine that installs them: fill all 256 IDT
// entries with a stop-the-machine default, overwrite the declared vectors,
// load the IDT.  Generated rather than kept in arch/kernel.s because it names
// the program's own handler labels; it is a text part, so the tree shaker
// never sees it -- which is also why it carries its own copy of the
// entry-packing helper instead of calling one the shaker could drop.
//
// The stub is the x86-64 interrupt entry:
//   - save the CALLER-saved registers.  The handler is an ordinary Y
//     function and is free to clobber rax/rcx/rdx/rsi/rdi/r8-r11; rbx, rbp
//     and r12-r15 are callee-saved and it preserves them itself.  %rbp is
//     saved too because the stub holds the pre-alignment stack in it.
//   - align %rsp to 16 and call the handler, so the handler's own calls see
//     the alignment the SysV convention wants (the interrupted stack has no
//     alignment guarantee).
//   - acknowledge the 8259 line (slave first, for IRQ8-15).
//   - iretq.
// A handler that clobbers an XMM register would need the SSE state saved as
// well; nothing does that yet, and the Y backend only touches XMM in float
// code.
// Is `v` in `xs`?  An index loop, not foreach: a foreach closure comparing
// its element to a captured value is broken (target.y has the note).
def name_in_ints(xs: [long], v: long) -> bool {
    let i = 0;
    let found = false;
    while (i < len(xs)) {
        if (xs[i] == v) { found = true; };
        i++;
    };
    found
};

def kernel_irq_text(has_trap: bool) -> str {
    let out = ".text\n";
    out += "y_kernel_irq_default:\n";
    out += "    jmp y_kernel_halt\n";
    // ── the CPU's own exceptions (vectors 0..31) ────────────────────────
    // Each stub saves the caller-saved set, puts its vector and the CPU's
    // error code on the stack and calls the Y handler y_kernel_trap(vec,
    // err); a fault is not resumed from, so there is no `iretq` here.  The
    // push of the vector is a register push rather than `push $N` because
    // the encoder has no immediate push -- and it runs AFTER the saves, so
    // the interrupt's own %rax is already safe.
    //
    // Vectors 8, 10-14, 17, 21, 29 and 30 push an error code (Intel SDM,
    // "Exception and Interrupt Vectors"); it sits just above the ten saved
    // registers, at 80(%rbp).  The rest push a zero so the handler always
    // reads a second argument.
    let errv = [8, 10, 11, 12, 13, 14, 17, 21, 29, 30];
    let v = 0;
    while (v < 32) {
        out += "y_trap_stub_" + tostring(v) + ":\n";
        out += "    push %rbp\n";
        out += "    push %rax\n";
        out += "    push %rcx\n";
        out += "    push %rdx\n";
        out += "    push %rsi\n";
        out += "    push %rdi\n";
        out += "    push %r8\n";
        out += "    push %r9\n";
        out += "    push %r10\n";
        out += "    push %r11\n";
        out += "    mov %rsp, %rbp\n";
        out += "    and $-16, %rsp\n";
        out += "    mov $" + tostring(v) + ", %eax\n";
        out += "    push %rax\n";
        if (name_in_ints(errv, v)) {
            out += "    mov 80(%rbp), %rax\n";
        } else {
            out += "    mov $0, %eax\n";
        };
        out += "    push %rax\n";
        out += "    call y_kernel_trap\n";
        out += "    jmp y_kernel_halt\n";
        v++;
    };
    if (!has_trap) {
        // No unit defines one: the stubs must still resolve.  std/kernel.y's
        // is the diagnostic version; this is what a bare kernel gets.
        out += "y_kernel_trap:\n";
        out += "    jmp y_kernel_halt\n";
    };
    // An interrupt stub is the syscall entry's shape, and that is the whole
    // contract between the two paths: [r9][r8][r10][rdx][rsi][rdi][rax][r11]
    // [rcx][RIP][CS][RFLAGS][RSP][SS], lowest first, so a task suspended in
    // one is resumed in the other.  That is what makes a TASK SWITCH possible from here: a
    // suspended task's %rsp always points at the lowest of those nine, whether
    // it was suspended on the way out of a syscall or on the way out of an
    // interrupt, so the scheduler can resume either.
    //
    // The switch only happens when the interrupted context was USER (CS's RPL
    // is 3): a ring-0 frame carries no RSP/SS words, so resuming one with the
    // user exit path would iretq the wrong stack.  The kernel is not
    // preemptible -- the plan's design -- so a ring-0 interrupt just returns.
    res_irq_stubs.foreach((e) => {
        out += "y_irq_stub_" + tostring(e.line) + ":\n";
        out += "    push %r15\n";
        out += "    push %r14\n";
        out += "    push %r13\n";
        out += "    push %r12\n";
        out += "    push %rbp\n";
        out += "    push %rbx\n";
        out += "    push %rcx\n";
        out += "    push %r11\n";
        out += "    push %rax\n";
        out += "    push %rdi\n";
        out += "    push %rsi\n";
        out += "    push %rdx\n";
        out += "    push %r10\n";
        out += "    push %r8\n";
        out += "    push %r9\n";
        // The stack is aligned for the handler's call, and the value to
        // restore is parked in a GLOBAL rather than in %rbp: the interrupt may
        // have arrived in the middle of the kernel's own frame-pointer code,
        // and clobbering %rbp there is a #GP a few instructions later with
        // nothing to connect it to the interrupt.  One word is enough -- an
        // interrupt gate clears IF, so an interrupt cannot interrupt one.
        out += "    mov %rsp, y_irq_scratch(%rip)\n";
        out += "    and $-16, %rsp\n";
        out += "    call " + e.label + "\n";
        out += "    mov y_irq_scratch(%rip), %rsp\n";
        if (e.line >= 8) {
            out += "    mov $160, %edx\n";
            out += "    mov $32, %eax\n";
            out += "    outb %al, %dx\n";
        };
        out += "    mov $32, %edx\n";
        out += "    mov $32, %eax\n";
        out += "    outb %al, %dx\n";
        // The switch point.  CS sits nine words above the frame's RIP: the
        // nine saved registers, then RIP, then CS.
        out += "    mov 128(%rsp), %rax\n";
        out += "    and $3, %rax\n";
        out += "    jz y_irq_same_" + tostring(e.line) + "\n";
        out += "    mov %rsp, y_cur_task_rsp(%rip)\n";
        // The scheduler is Y code and may use SSE, which faults on a
        // misaligned stack: the interrupt arrived with whatever alignment the
        // interrupted code had, so the call is aligned and the canonical %rsp
        // is kept in the scratch word for the "stay" case.  (The syscall path
        // needs no such thing: its stack top is page-aligned.)
        out += "    mov %rsp, y_irq_scratch(%rip)\n";
        out += "    and $-16, %rsp\n";
        out += "    call y_sched_pick\n";
        out += "    test %rax, %rax\n";
        out += "    jz y_irq_stay_" + tostring(e.line) + "\n";
        out += "    mov %rax, %rsp\n";
        out += "    jmp y_irq_same_" + tostring(e.line) + "\n";
        out += "y_irq_stay_" + tostring(e.line) + ":\n";
        out += "    mov y_irq_scratch(%rip), %rsp\n";
        out += "y_irq_same_" + tostring(e.line) + ":\n";
        out += "    pop %r9\n";
        out += "    pop %r8\n";
        out += "    pop %r10\n";
        out += "    pop %rdx\n";
        out += "    pop %rsi\n";
        out += "    pop %rdi\n";
        out += "    pop %rax\n";
        out += "    pop %r11\n";
        out += "    pop %rcx\n";
        out += "    pop %rbx\n";
        out += "    pop %rbp\n";
        out += "    pop %r12\n";
        out += "    pop %r13\n";
        out += "    pop %r14\n";
        out += "    pop %r15\n";
        out += "    iretq\n";
    });
    // %rax = a handler's address -> %rax = the first 8 bytes of its IDT
    // entry: offset[0:16] | selector 8 << 16 | type 0x8E << 40 |
    // offset[16:32] << 48.  The payload lives below 4 GB, so the entry's
    // high half is always zero (the `mov $0, +8` below).
    out += "y_kernel_idt_pack:\n";
    out += "    mov %rax, %rdx\n";
    out += "    shr $16, %rdx\n";
    out += "    shl $48, %rdx\n";
    out += "    and $65535, %rax\n";
    out += "    mov $156130651668480, %rcx\n";
    out += "    or %rcx, %rax\n";
    out += "    or %rdx, %rax\n";
    out += "    ret\n";
    out += "y_kernel_irq_init:\n";
    out += "    push %rbp\n";
    out += "    mov %rsp, %rbp\n";
    out += "    lea y_kernel_irq_default(%rip), %rax\n";
    out += "    call y_kernel_idt_pack\n";
    out += "    lea y_kernel_idt(%rip), %rdi\n";
    out += "    mov $256, %esi\n";
    out += "y_kii_loop:\n";
    out += "    mov %rax, (%rdi)\n";
    out += "    mov $0, 8(%rdi)\n";
    out += "    add $16, %rdi\n";
    out += "    sub $1, %esi\n";
    out += "    cmp $0, %esi\n";
    out += "    jne y_kii_loop\n";
    let tv = 0;
    while (tv < 32) {
        out += "    lea y_trap_stub_" + tostring(tv) + "(%rip), %rax\n";
        out += "    call y_kernel_idt_pack\n";
        out += "    lea y_kernel_idt(%rip), %rdi\n";
        out += "    mov %rax, " + tostring(tv * 16) + "(%rdi)\n";
        out += "    mov $0, " + tostring(tv * 16 + 8) + "(%rdi)\n";
        tv++;
    };
    res_irq_stubs.foreach((e) => {
        let v = 32 + e.line;
        out += "    lea y_irq_stub_" + tostring(e.line) + "(%rip), %rax\n";
        out += "    call y_kernel_idt_pack\n";
        out += "    lea y_kernel_idt(%rip), %rdi\n";
        out += "    mov %rax, " + tostring(v * 16) + "(%rdi)\n";
        out += "    mov $0, " + tostring(v * 16 + 8) + "(%rdi)\n";
    });
    // Unmask the declared lines.  The compiler knows which they are and the
    // program does not have to: y_pic_remap leaves every line masked, so a
    // handler installed without this would never fire and nothing would say
    // why.  One byte per 8259, computed here: a slave line also opens the
    // master's cascade (IRQ2), or the slave's request never reaches the CPU.
    let mm = 255;
    let sm = 255;
    let ii = 0;
    while (ii < len(res_irq_stubs)) {
        let ln = res_irq_stubs[ii].line;
        if (ln < 8) {
            mm = mm & ~(1 << ln);
        } else {
            sm = sm & ~(1 << (ln - 8));
            mm = mm & ~4;
        };
        ii++;
    };
    if (len(res_irq_stubs) > 0) {
        out += "    mov $33, %edx\n";
        out += "    mov $" + tostring(mm) + ", %eax\n";
        out += "    outb %al, %dx\n";
        out += "    mov $161, %edx\n";
        out += "    mov $" + tostring(sm) + ", %eax\n";
        out += "    outb %al, %dx\n";
    };
    out += "    lea y_kernel_idtr(%rip), %rdi\n";
    out += "    lea y_kernel_idt(%rip), %rax\n";
    out += "    shl $16, %rax\n";
    out += "    or $4095, %rax\n";
    out += "    mov %rax, (%rdi)\n";
    out += "    mov $0, 8(%rdi)\n";
    out += "    lidt y_kernel_idtr(%rip)\n";
    out += "    pop %rbp\n";
    out += "    ret\n";
    out
};

// ── the kernel head: a Multiboot header and a 32-bit trampoline ──────────
// `ycc --kernel` emits an ELF32 Multiboot-1 payload (kelf.y) whose entry is
// 32-bit code, because that is the mode every Multiboot loader starts an
// image in.  The 32-bit half does exactly four things and then disappears:
//
//   1. build the page tables that identity-map the first 1 GB with 2 MB
//      pages (the file carries them; the code only points CR3 at them),
//   2. turn on PAE, LME and paging,
//   3. load a flat 64-bit GDT and far-jump to the 64-bit entry, which is the
//      only way to change CS.L and so the only way into long mode,
//   4. hand %ebx (the Multiboot info pointer) to the 64-bit side.
//
// It cannot be written in the in-tree assembly: enc64.y is x86-64-only, and
// in 32-bit protected mode a `mov %cr4, %eax` has no REX prefix, a `mov
// $addr, %eax` is an absolute moffs, and rip-relative addressing does not
// exist at all.  So the trampoline is a byte blob, transcribed from
// experiments/kernel/boot.s -- the same payload booted under
// `qemu-system-x86_64 -kernel` with GNU as assembling the blob -- with the
// addresses patched to where this image actually puts the tables.
//
// The 64-bit entry (`y_kernel_entry64`) IS ordinary assembly text: it sets
// the stack, calls the program's top level (renamed y_kernel_main; the
// program's `_start` name belongs to the trampoline here) and falls into the
// halt loop kernel.s defines.
def kernel_head_text() -> str {
    let base = kelf.kelf_base();
    let code_off = kelf.kelf_code_off();
    let head = kelf.kelf_head_len();
    // The trampoline's length does not depend on the addresses in it (each
    // one is a 32-bit immediate), so a first pass with zeros measures it.
    let pre = ktramp_pre(0, 0);
    let tlen = len(pre) + 7;
    // The page tables must be aligned in PHYSICAL memory, so pad between the
    // trampoline and them until (base + code_off + head + tlen + pad) is a
    // page.  Everything after that is placed by construction: three 4 KB
    // tables, then the 24-byte GDT and its 6-byte descriptor.
    let start = base + code_off + head + tlen;
    let pad = 0;
    if (start % 4096 != 0) { pad = 4096 - start % 4096; };
    let pt = start + pad;
    let pdpt_low = pt + 4096;
    let pd_low = pt + 8192;
    let pdpt_dm = pt + 12288;
    let pd_dm = pt + 16384;
    let gdt = pt + 20480;
    let gdtr = gdt + 24;
    let entry = gdtr + 6;
    let tramp = ktramp(pre, pt, gdtr, entry);
    let text = ".text\n.globl _start\n";
    text += ".ascii \"" + kascii(mb_header_bytes()) + "\"\n";
    text += "_start:\n";
    text += ".ascii \"" + kascii(tramp) + "\"\n";
    // pad to the page the tables start on
    if (pad > 0) { text += ".zero " + tostring(pad) + "\n"; };
    // One PML4 entry for the kernel's own 2 MB and one for the direct map.
    // Nothing else is mapped: PML4[0]'s low half belongs to user space, and
    // 0x400000 -- where a Linux executable is linked -- has to be free, which
    // is why the kernel's identity map is one 2 MB page and not a gigabyte.
    text += "y_kernel_pml4:\n.quad " + tostring(pdpt_low + 3) + "\n";
    text += ".zero " + tostring(272 * 8) + "\n";
    text += ".quad " + tostring(pdpt_dm + 3) + "\n";
    text += ".zero " + tostring(238 * 8) + "\n";
    text += "y_kernel_pdpt_low:\n.quad " + tostring(pd_low + 3) + "\n.zero 4088\n";
    text += "y_kernel_pd_low:\n.quad 131\n.zero 4088\n";
    // The direct map: all RAM in 2 MB pages at 0xFFFF888000000000.  A kernel
    // that crosses the 1 GB this covers needs a second PDPT entry; every
    // guest this is tested on is smaller than that.
    text += "y_kernel_pdpt_dir:\n.quad " + tostring(pd_dm + 3) + "\n.zero 4088\n";
    text += "y_kernel_pd_dir:\n";
    for i in 0..512 {
        text += ".quad " + tostring(i * 2097152 + 131) + "\n";
    };
    // null, 64-bit code (L=1), data
    text += "y_kernel_gdt:\n.quad 0\n.quad 49427445715107839\n.quad 49418649622085631\n";
    // the 6-byte GDTR the 32-bit lgdt reads: limit 23, base gdt
    let gd = kbput32(kbput16([], 23), gdt);
    text += "y_kernel_gdtr:\n.ascii \"" + kascii(gd) + "\"\n";
    text += "y_kernel_entry64:\n";
    text += "    lea y_kernel_stack_top(%rip), %rsp\n";
    // A hosted program's _start records where the stack began, because the
    // collector scans the stack for roots; a kernel image has no _start, so
    // the kernel's own entry does it -- before anything can allocate.  Without
    // this the collector's stack base is 0 and the first allocation fails with
    // "out of memory".
    text += "    mov %rsp, y_gc_stack_top(%rip)\n";
    text += "    xor %rbp, %rbp\n";
    // The Multiboot loader left the info structure's physical address in
    // %ebx (multiboot spec: %eax = 0x2BADB002, %ebx = the info pointer).
    // Nothing in the 32-bit half touches %ebx, and the upper half of a GPR
    // is not architecturally defined across the mode switch, so the 32 bits
    // are zero-extended before the store: shl 32 then shr 32 (a logical
    // shift) is how Y reaches a zero-extension here, and the kernel's
    // memory map lives behind this one cell.
    text += "    mov %rbx, %rax\n";
    text += "    shl $32, %rax\n";
    text += "    shr $32, %rax\n";
    text += "    mov %rax, y_mb_info(%rip)\n";
    text += "    call y_kernel_main\n";
    text += "    jmp y_kernel_halt\n";
    text
};

// The 12-byte Multiboot-1 header: magic, flags 0 (no address fields, the
// ELF program headers say where everything goes), and the checksum that
// makes the three sum to zero.
def mb_header_bytes() -> [byte] {
    let b: [byte] = [];
    b = kbput32(b, 464367618);      // 0x1BADB002
    b = kbput32(b, 0);
    b = kbput32(b, 3830599678);     // 0xE4524FFE -- -(magic + flags)
    b
};

// The 32-bit half of the trampoline, everything up to and including the far
// jump.  `pre` is built twice: once with zeros (to measure it) and once with
// the real page-table and GDT addresses.
def ktramp(pre: [byte], pt: long, gdtr: long, entry: long) -> [byte] {
    let b = ktramp_pre(pt, gdtr);
    // ljmp $0x08, $entry: the mode switch.  A far jump is the only
    // instruction that reloads CS with L=1, and it has to name the target
    // absolutely -- hence the patched constant.
    b = kb1(b, 234);
    b = kbput32(b, entry);
    b = kb1(b, 8);
    b = kb1(b, 0);
    b
};

def ktramp_pre(pt: long, gdtr: long) -> [byte] {
    let b: [byte] = [];
    // No table entries are stored here any more: they are emitted as data
    // below, and the only thing the 32-bit code does with the tables is
    // point CR3 at them.
    b = kb1(b, 250);                        // cli
    b = kb1(b, 252);                        // cld
    b = kb3(b, 15, 32, 224);                // mov %cr4, %eax
    // or $0x620, %eax: PAE (5) plus OSFXSR (9) and OSXMMEXCPT (10).  The
    // last two are not optional: without OSFXSR every SSE instruction is
    // #UD, and the Y backend uses XMM for every float operation -- so
    // `print(1.0 * 2.0)` stopped the machine at its first `movq %rax,%xmm0`
    // while `print(7.0)` (a literal, passed in a GPR) worked.  A hosted
    // program never notices because Linux sets these before entering user
    // space.
    b = kb1(b, 13);
    b = kbput32(b, 1568);
    b = kb3(b, 15, 34, 224);                // mov %eax, %cr4
    b = kb_imm32(b, 0, pt);                 // mov $pml4, %eax
    b = kb3(b, 15, 34, 216);                // mov %eax, %cr3
    b = kb_imm32(b, 1, 3221225600);         // mov $0xC0000080, %ecx
    b = kb2(b, 15, 50);                     // rdmsr
    b = kb1(b, 13);                         // or $0x100, %eax    (LME)
    b = kbput32(b, 256);
    b = kb2(b, 15, 48);                     // wrmsr
    b = kb3(b, 15, 32, 192);                // mov %cr0, %eax
    b = kb1(b, 13);                         // or $0x80010001, %eax (PG|WP|PE)
    b = kbput32(b, 2147549185);
    b = kb3(b, 15, 34, 192);                // mov %eax, %cr0
    b = kb1(b, 102);                        // mov $0x10, %ax
    b = kb1(b, 184);
    b = kb1(b, 16);
    b = kb1(b, 0);
    b = kb2(b, 142, 216);                   // mov %ax, %ds
    b = kb2(b, 142, 192);                   // mov %ax, %es
    b = kb2(b, 142, 208);                   // mov %ax, %ss
    b = kb3(b, 15, 1, 21);                  // lgdt gdtr
    b = kbput32(b, gdtr);
    b
};

def kb1(b: [byte], v: long) -> [byte] {
    b += v % 256;
    b
};

def kb2(b: [byte], a: long, c: long) -> [byte] {
    b = kb1(b, a);
    b = kb1(b, c);
    b
};

def kb3(b: [byte], a: long, c: long, d: long) -> [byte] {
    b = kb2(b, a, c);
    b = kb1(b, d);
    b
};

// `mov $imm32, %reg`: B8+r id.
def kb_imm32(b: [byte], reg: long, v: long) -> [byte] {
    b = kb1(b, 184 + reg);
    b = kbput32(b, v);
    b
};

def kbput32(b: [byte], v: long) -> [byte] {
    b += v % 256;
    b += (v / 256) % 256;
    b += (v / 65536) % 256;
    b += (v / 16777216) % 256;
    b
};

def kbput16(b: [byte], v: long) -> [byte] {
    b += v % 256;
    b += (v / 256) % 256;
    b
};

// Bytes as the payload of an `.ascii "..."`: every byte an octal escape, so
// the assembler's decode_str (asm.y) reproduces them exactly.  `\0` is the
// one byte it cannot spell with a short escape.
def kascii(b: [byte]) -> str {
    let out = "";
    b.foreach((e) => {
        out += "\\";
        out += k_oct3(e);
    });
    out
};

def k_oct3(v: long) -> str {
    let a = v / 64;
    let b = (v / 8) % 8;
    let c = v % 8;
    tostring(a) + tostring(b) + tostring(c)
};

export { WImport, w_imports, w_iat_label, w_iat_term_label, w_iat_bss_lines, w_iat_offset, arch_id, arch_word, arch_sysno, arch_fn_label, arch_global_label, arch_loc_label, arch_str_label, arch_header, arch_rodata, arch_text, arch_bss, arch_global_cell, arch_heap_cells, arch_kernel_bss, arch_prelude_lines, arch_prelude_threads_lines, arch_math_lines, w_self_test_lines, arch_consts, arch_frame, arch_exit };
