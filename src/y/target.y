// target.y — which target the compiler emits for, as one global.
//
// The target is the operating system a program runs on (linux, win, kernel,
// web); the arch is the instruction set it runs (x64, aarch64, wasm32). They
// are separate command-line options and separate globals: a Linux AArch64
// program is the linux target with the aarch64 arch, not a target of its own.

import hostos from "./host_linux.y";
import targetshapes from "./target_shapes.y";

let res_target = hostos.name();
let res_arch = hostos.arch();

// The PE subsystem a Windows image declares: 3 is a console program, 2 a GUI program, which has no
// console (--subsystem=gui, or `subsystem = "gui"` in y.toml); 0 is "not asked", and a
// console program is the default. A flag on the command line wins over the manifest. Read by pe.y.
let res_subsystem = 0;

// ── the kernel's IRQ declarations ───────────────────────────────────────
type KernelIrq = { line: long, name: str };
type KernelIrqStub = { line: long, label: str };

let res_irqs: [KernelIrq] = [];
let res_irq_stubs: [KernelIrqStub] = [];

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
    res_target == "win"
};

// True when the instruction set is AArch64.  This is an arch test, not a
// target one: the ELF writer, the assembler and the emitter ask it.
def target_is_aarch64() -> bool { res_arch == "aarch64" };

// The web target: wasm32 memory, 64-bit values, a Linux syscall ABI answered
// by the JavaScript host.  Every target test for it goes
// through this predicate, like the Windows and kernel ones above.
def target_is_web() -> bool { res_target == "web" };

def target_is_kernel() -> bool {
    res_target == "kernel"
};

// The OS a program sees in YCC.os.  The target spells itself `win` on the
// command line; a program and its OS call themselves `windows`.
def target_os() -> str {
    if (res_target == "win") { "windows" } else { res_target }
};

// The arch a program sees in YCC.arch: x64, aarch64 or wasm32.
def target_arch() -> str { res_arch };