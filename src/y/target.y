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
