// target.y — which target the compiler emits for, as one global.
//
// The whole compiler is ONE product that emits either an ELF (the default) or
// a Windows PE, chosen by ycc --target (ycc.y parse_cli_args writes this
// global before anything reads it).  Three consumers read it, in three
// different ways (ideas/WINDOWS.md, "The target reaches three places"):
//
//   asm.y          -- picks the object writer at link time (elf_build or
//                     pe_build; both are linked in and their names and types
//                     differ, so no splicer involvement);
//   arch_x64.y     -- dispatches inside itself on `target_is_windows()`,
//                     because a second arch *file* cannot coexist (a path
//                     import is flattened into its importer, so arch_frame
//                     would be defined twice and the second would win);
//   native.y       -- the entry point, the syscall convention and the ABI.
//
// WHY A MODULE OF ITS OWN rather than a `let` in native.y: native.y's own
// top-levels are spliced AFTER the modules it imports (asm.y among them), so
// a global declared there would be read before it is declared.  This file is
// imported first of all in ycc.y, so every reader sees the binding first.
//
// The name is `res_*` like native.y's res_pkgs/res_used: ambient state the
// pipeline threads by hand, not an argument.

let res_target = "linux";

// ── the kernel's IRQ declarations ───────────────────────────────────────
// `irq N def f() -> void { ... }` is a top-level declaration that exists
// only for `--kernel` (parser.y: parse_irq_def, gated on target_is_kernel so
// `irq` stays an ordinary identifier everywhere else).  It is the language's
// IRQ handler: the vector is bound at the declaration, the checker enforces
// the signature, and the emitter generates the interrupt stub that saves the
// caller-saved registers, calls `f`, acknowledges the 8259s and `iretq`s.
//
// Two lists, filled at three different times, which is why they are here
// rather than in one pass:
//   res_irqs      parser: (line, the def's name as written)
//   res_irq_stubs emitter: (line, the def's emitted label), once the hoisted
//                 defs have their labels
// The name/line pair is what the checker validates against; the label is what
// the generated stub calls.
type KernelIrq = { line: long, name: str };
type KernelIrqStub = { line: long, label: str };

let res_irqs: [KernelIrq] = [];
let res_irq_stubs: [KernelIrqStub] = [];

// NOTE: the lookups below are index loops rather than `foreach`.  A foreach
// closure that compares its ELEMENT to a CAPTURED value answers false in this
// compiler (`xs.foreach((x) => { if (x == v) { d = true; }; })` never sets
// d, whatever v is; `x == 4` and reading `v` both work), which is a
// pre-existing bug -- it reproduces with refs/ycc.ref -- and not one this
// work is here to fix.  The kernel's IRQ path therefore does not use that
// shape.

// The 8259 line a def is declared for, or -1: the one lookup every stage of
// the IRQ path goes through.
def kernel_irq_line(name: str) -> long {
    let out = -1;
    let i = 0;
    while (i < len(res_irqs)) {
        let e = res_irqs[i];
        if (e.name == name) { out = e.line; };
        i++;
    };
    out
};

// Record a handler's emitted label, replacing any earlier entry for the same
// line: a unit that is emitted twice must not produce two stubs for one
// vector (the assembler's duplicate-label error is the only other symptom).
def kernel_irq_stub(line: long, label: str) -> void {
    let out: [KernelIrqStub] = [];
    let done = false;
    let i = 0;
    while (i < len(res_irq_stubs)) {
        let e = res_irq_stubs[i];
        if (e.line == line && !done) {
            out += { line: line, label: label };
            done = true;
        } else {
            out += e;
        };
        i++;
    };
    if (!done) { out += { line: line, label: label }; };
    res_irq_stubs = out;
};

// True when the target is Windows.  Every target test in the tree goes
// through this one predicate, so a third target is a change here first.
def target_is_windows() -> bool {
    res_target == "windows"
};

// True for `ycc --kernel`: a freestanding x86-64 kernel image (an ELF32
// Multiboot-1 payload loaded at 1 MB, with no OS underneath).  It is a
// target, not a mode on top of linux: the emitter, the arch prelude, the
// object writer and the std set all change, and every one of those changes
// sits behind this predicate so a normal compile pays for none of it.
def target_is_kernel() -> bool {
    res_target == "kernel"
};

// The target name as a program sees it, for the `target` and `os` builtin
// constants the checker binds (types.y).  Kept next to the global so the
// name a flag accepts and the name a program reads cannot drift apart.
def target_os() -> str {
    if (res_target == "windows") { "windows" }
    else if (res_target == "kernel") { "kernel" }
    else { "linux" }
};
