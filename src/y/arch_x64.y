// arch_x64.y — Linux x86_64 code emitters for the native backend (ycc).

// The ELF32 Multiboot writer's layout constants (base, header size, where
// .bss starts). The trampoline below bakes the same numbers into its 32-bit
// immediates, so both sides read them from kelf.y rather than spelling them.
import kelf from "./kelf.y";

def arch_asm_lines(text: str) -> [str] {
    let out: [str] = [];
    (text.split("\n")).foreach((l) => {
        if (len(l) > 0 && l[0] != 35) { out += l; };
    });
    out
};

def arch_id() -> str {
    if (target_is_aarch64()) { "aarch64-linux" }
    else if (target_is_web()) { "wasm32-web" }
    else { "x64-" + target_os() }
};
def arch_word() -> long { target_word() };
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
    else if (name == "yield") { 70 }        // NtYieldExecution
    else if (name == "attrs") { 196 }       // NtQueryFullAttributesFile
    else { -1 }
};

def arch_set_files(which: str) -> [str] {
    if (target_known(which)) { target_info(which).runtime } else { [which] }
};
// `texts` holds the files arch_set_files names, in that order.
def arch_set_lines(which: str, texts: [str]) -> [str] {
    if (which == "win") { arch_windows_lines(texts[0], texts[1] + "\n" + texts[2] + "\n" + texts[3] + "\n" + texts[4] + "\n" + texts[5]) }
    else if (which == "web") { arch_replaced_lines(texts[0], texts[1], "src/y/arch/web.s") }
    else if (which == "kernel") { arch_kernel_lines(texts[0], texts[1]) }
    else if (which == "linux" || which == "wselftest" || which == "threads" || which == "wthreads" || which == "math" || which == "regions") {
        arch_asm_lines(texts[0])
    } else {
        puts("ycc: internal error: no arch block set '" + which + "'\n");
        exit(1);
        []
    }
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

type WImport = { dll: str, funcs: [str] };

def w_imports() -> [WImport] {
    [
        { dll: "KERNEL32.dll", funcs: ["GetCurrentProcessId", "LoadLibraryA", "GetProcAddress", "IsDebuggerPresent"] },
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

def arch_heap_cells() -> str {
    let base = "y_heap:\n.zero 128\ny_heap_base:\n.zero 8\n" +
    "y_gc_stack_top:\n.zero 8\ny_gc_lo:\n.zero 8\ny_gc_hi:\n.zero 8\n" +
    "y_gc_all:\n.zero 8\ny_gc_tab:\n.zero 8\ny_gc_tabn:\n.zero 8\n" +
    "y_gc_meta_cur:\n.zero 8\ny_gc_meta_end:\n.zero 8\n" +
    "y_gc_free:\n.zero 8\ny_gc_ms_cur:\n.zero 8\ny_gc_ms_end:\n.zero 8\n" +
    "y_gc_ms_seg:\n.zero 8\n" +
    "y_gc_live:\n.zero 8\ny_gc_last:\n.zero 8\n" +
    "y_gc_run:\n.zero 8\ny_gc_off:\n.zero 8\n" +
    // The thread registry and the stop-the-world protocol (arch/threads.s
    // registers, arch/prelude.s's collector stops): the tcb list head, how
    // many threads are registered, how many are parked at the allocator's
    // slow path, and the flag that asks them to park.
    "y_gc_threads:\n.zero 8\ny_gc_nthr:\n.zero 8\n" +
    "y_gc_parked:\n.zero 8\ny_gc_stw:\n.zero 8\n" +
    // The two locks the allocation side needs once threads allocate at once:
    // the free lists and the chunk registry (y_gc_lk), then the metadata arena
    // (y_gc_mlk). Always taken in that order, and never while parked.
    "y_gc_lk:\n.zero 8\ny_gc_mlk:\n.zero 8\n" +
    // The allocator's safepoint, as a pointer: only the thread runtime
    // installs one, so a program that never spawns carries no parking code.
    "y_gc_safe_fn:\n.zero 8\n" +
    // The locked halves of the slow path, as pointers the thread runtime
    // installs: a program that never spawns calls the plain functions and
    // carries neither the locks nor their call sites.
    "y_gc_free_fn:\n.zero 8\ny_gc_chunk_fn:\n.zero 8\n" +
    // The region runtime's cell (arch/regions.s): the innermost open region,
    // the `heap { .. }` suspensions, the root walk the first one installs, the
    // arena (top chunk, position, chunk cache, size); and the two hooks a
    // `heap { .. }` calls through, which the first region installs.
    "y_region:\n.zero 80\ny_rg_henter:\n.zero 8\ny_rg_hleave:\n.zero 8\n";
    if (target_is_windows()) { base + arch_windows_cells() } else { base }
};

// The Windows runtime's .bss cells -- only in a PE, so an ELF is the same bytes
// it always was.
def arch_windows_cells() -> str {
    // The API cache (arch/wsys.s y_w_api): one cell per DLL function a block
    // resolves on first use, indexed by the number its block documents.
    "yw_apis:\n.zero 1024\n" +
    // The runtime's state: the lock and the next hint address of the allocator's
    // mappings (y_alloc_map), whether one fell outside the hinted range, the child
    // table of fork/spawn, what a fork hands its copy, whether Winsock is started,
    // and the console's VMIN/VTIME.
    "yw_lock:\n.zero 8\nyw_hint:\n.zero 8\nyw_ovf:\n.zero 8\nyw_procs:\n.zero 1024\n" +
    "yw_fork_hook:\n.zero 8\nyw_fork_closure:\n.zero 8\nyw_fork_tcb:\n.zero 8\nyw_fork_r15:\n.zero 8\nyw_wsa:\n.zero 8\nyw_vmin:\n.zero 8\nyw_vtime:\n.zero 8\n" +
    // the window procedure's ring of messages and the DefWindowProc it hands on to (arch/wgui.s)
    "yw_gui_ring:\n.zero 8\nyw_gui_defproc:\n.zero 8\n"
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
    ".align 16\n" +
    "y_mb_info:\n.zero 8\n" +
    ".align 16\n" +
    "y_kernel_idt:\n.zero 4096\n" +
    "y_kernel_idtr:\n.zero 16\n" +
    ".align 16\n" +
    "y_kernel_stack_bottom:\n.zero 32768\n" +
    "y_kernel_stack_top:\n" +
    ".align 16\n" +
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

// ── the Windows half of the prelude ─────────────────────────────────────
def arch_windows_lines(prelude: str, wsys: str) -> [str] {
    // a thread's block address lives in the TEB (%gs), not in %fs (arch/wthreads.s)
    arch_replaced_lines(join(split(prelude, "%fs:24"), "%gs:5752"), wsys, "src/y/arch/wsys.s")
};

// The kernel's replacement blocks (`ycc --target=kernel`): the same substitution,
// against src/y/arch/kernel.s.
def arch_kernel_lines(prelude: str, kernel: str) -> [str] {
    arch_replaced_lines(prelude, kernel, "src/y/arch/kernel.s")
};

def arch_replaced_lines(prelude: str, sub: str, what: str) -> [str] {
    let blocks = arch_win_blocks(split(sub, "\n"));
    blocks.foreach((e) => {
        if (len(e) > 1 && e[1] == "2") {
            puts("error: " + what + ": bad block marker ('" + e[0] + "'): want '#=== replace: NAME ===' or '#=== add: NAME ==='\n");
            exit(1);
        };
    });
    let lines = arch_asm_lines(prelude);
    arch_win_check(lines, blocks, what);
    arch_win_sub(lines, blocks)
};

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

def arch_nogc_subs() -> [[str]] {
    [["y_gc_maybe", "y_gc_maybe:", "    ret"],
     ["y_gc_alloc_free", "y_gc_alloc_free:", "    xor %eax, %eax", "    ret"],
     ["y_gc_chunk_add", "y_gc_chunk_add:", "    mov %rdi, %rax", "    ret"]]
};

def arch_gc_stress_subs() -> [[str]] {
    [["y_gc_maybe", "y_gc_maybe:", "    call y_gc_collect", "    ret"],
     ["y_bad_trap",
        "y_bad_trap:",
        "    push %rbx",
        "    push %r12",
        "    push %r13",
        "    mov 0(%rbx), %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov 8(%rbx), %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov %r12, %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov 0(%r12), %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov -8(%r12), %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov 8(%r12), %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov %r13, %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    mov 0(%r13), %rax",
        "    push %rax",
        "    call y_os_print_int",
        "    add $8, %rsp",
        "    pop %r13",
        "    pop %r12",
        "    pop %rbx",
        "    mov $1, %rax",
        "    mov $1, %rdi",
        "    syscall"]]
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
        "ystr_region: .ascii \"runtime error: regions are one-thread only (a spawn inside a region, or a region after a spawn)\\n\"",
        "ystr_region_end:",
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
def name_in_ints(xs: [long], v: long) -> bool {
    let i = 0;
    let found = false;
    while (i < len(xs)) {
        if (xs[i] == v) { found = true; };
        i++;
    };
    found
};

def kernel_irq_text(has_trap: bool, has_pf: bool, has_uf: bool) -> str {
    let out = ".text\n";
    out += "y_kernel_irq_default:\n";
    out += "    jmp y_kernel_halt\n";
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
        if (v == 14 && has_pf) {
            out += "    mov 80(%rbp), %rax\n";
            out += "    push %rax\n";
            out += "    call y_cr2_get\n";
            out += "    push %rax\n";
            out += "    call y_kernel_pf\n";
            out += "    add $16, %rsp\n";
            out += "    test %rax, %rax\n";
            out += "    jz y_trap_pf_fail\n";
            out += "    mov %rbp, %rsp\n";
            out += "    pop %r11\n";
            out += "    pop %r10\n";
            out += "    pop %r9\n";
            out += "    pop %r8\n";
            out += "    pop %rdi\n";
            out += "    pop %rsi\n";
            out += "    pop %rdx\n";
            out += "    pop %rcx\n";
            out += "    pop %rax\n";
            out += "    pop %rbp\n";
            out += "    add $8, %rsp\n";
            out += "    iretq\n";
            out += "y_trap_pf_fail:\n";
        };
        if (has_uf && v != 2 && v != 8) {
            // A fault taken in RING 3 ends the task, not the machine: std/kernel.y's
            // y_kernel_user_fault exits it as 128+signal, and the next task is resumed
            // through the syscall path's tail. CS sits above the saved set, and above
            // the error code when the CPU pushed one.
            let has_err = name_in_ints(errv, v);
            if (has_err) { out += "    mov 96(%rbp), %rax\n"; } else { out += "    mov 88(%rbp), %rax\n"; };
            out += "    and $3, %rax\n";
            out += "    jz y_trap_kern_" + tostring(v) + "\n";
            out += "    mov $" + tostring(v) + ", %eax\n";
            out += "    push %rax\n";
            if (has_err) { out += "    mov 80(%rbp), %rax\n"; } else { out += "    mov $0, %eax\n"; };
            out += "    push %rax\n";
            out += "    call y_kernel_user_fault\n";
            out += "    add $16, %rsp\n";
            out += "    call y_sched_pick\n";
            out += "    test %rax, %rax\n";
            out += "    jz y_kernel_halt\n";
            out += "    mov %rax, %rsp\n";
            out += "    jmp y_se_same\n";
            out += "y_trap_kern_" + tostring(v) + ":\n";
        };
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
    text += "    mov %rsp, y_gc_stack_top(%rip)\n";
    text += "    xor %rbp, %rbp\n";
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

export { WImport, w_imports, w_iat_label, w_iat_term_label, w_iat_bss_lines, w_iat_offset, arch_id, arch_word, arch_sysno, arch_fn_label, arch_global_label, arch_loc_label, arch_str_label, arch_header, arch_rodata, arch_text, arch_bss, arch_global_cell, arch_heap_cells, arch_kernel_bss, arch_set_files, arch_set_lines, arch_nogc_subs, arch_gc_stress_subs, arch_consts, arch_frame, arch_exit };
