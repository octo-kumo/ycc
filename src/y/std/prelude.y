// std/prelude.y -- runtime library written in Y, spliced into the program
// by native.y when it is referenced.
//
// WHY THIS EXISTS: every builtin used to mean another hand-written block of
// assembly in arch_x64.y. That does not scale and it is where the bugs
// live. The rule here is the opposite: the backend provides small, general
// PRIMITIVES (the `syscall` intrinsic, `bytes`/`from_bytes`), and the
// actual behaviour -- stopping at a newline, growing a buffer, splitting a
// command line -- is ordinary Y code that the compiler compiles like any
// other function.
//
// These are plain defs, not intrinsics: they go through the normal
// rename/typecheck/emit path, so a bug here is a bug in Y code, not in
// hand-rolled x86.
//
// The text lives as a line array rather than a separate file because the
// shipped `ycc` is a standalone static ELF -- it cannot read a support
// file at run time. `join` puts it back together.

def prelude_lines() -> [str] {
    [
        "// ---- spliced from src/y/std/prelude.y ----",
        "",
        "// readline() -> str?  (a line of stdin, newline stripped; none at",
        "// end of input). Reads ONE BYTE at a time on purpose: a buffered",
        "// read would swallow input past the newline, which a REPL then",
        "// could not hand to a child process. EOF is not latched -- a later",
        "// call issues a fresh read(2), so a REPL survives Ctrl-D and a FIFO",
        "// that is reopened. The C engines call clearerr(stdin) to match.",
        "def readline() -> str? {",
        "    let one: [byte; 1] = [0; 1];",
        "    let out: [byte] = [];",
        "    let go = true;",
        "    let got = false;",
        "    while (go) {",
        "        let n = syscall(0, 0, &one[0], 1);",
        "        if (n <= 0) {",
        "            go = false;",
        "            0;",
        "        } else {",
        "            got = true;",
        "            let c = one[0];",
        "            if (c == 10) {",
        "                go = false;",
        "                0;",
        "            } else {",
        "                out = push(out, c);",
        "                0;",
        "            };",
        "            0;",
        "        };",
        "    };",
        "    if (got) { some(from_bytes(out)) } else { none }",
        "};",
        "",
        "// clear_eof() -- clear the end-of-input condition so a later",
        "// readline() reads again. Nothing to do here: readline() issues a",
        "// raw read(2) on fd 0 every call and there is no sticky flag to",
        "// reset. It exists so the same source runs on all three engines",
        "// (the C engines call clearerr(stdin), which is not a no-op there).",
        "def clear_eof() -> long { 0 };",
        ""
    ]
};

def prelude_src() -> str {
    join(prelude_lines(), "\n")
};

// exec() lives in its own chunk so --no-exec can leave it out entirely:
// the call then fails with "undefined function 'exec'" rather than
// compiling into a binary that can spawn a shell.
def exec_lines() -> [str] {
    [
        "// exec(cmd) -> long  (exit status, or -1 if the child died on a",
        "// signal / could not be started). Same contract as the C engines'",
        "// system(3): the command is interpreted by /bin/sh -c.",
        "//",
        "// SECURITY: there is no sanitizing here, exactly as in the C",
        "// toolchain. Never pass untrusted input. ycc --no-exec omits this",
        "// function entirely, so a binary built with it cannot reach a",
        "// shell at all.",
        "//",
        "// Written in Y over the raw syscalls: fork(57), execve(59),",
        "// wait4(61), exit(60). envp is NULL -- sh supplies a default PATH",
        "// -- so the parent's environment is not inherited; put VAR=val in",
        "// the command string when a child needs one.",
        "def exec(cmd: str) -> long {",
        "    let shpath = bytes(\"/bin/sh\");",
        "    shpath = push(shpath, 0);",
        "    let dashc = bytes(\"-c\");",
        "    dashc = push(dashc, 0);",
        "    let cmdb = bytes(cmd);",
        "    cmdb = push(cmdb, 0);",
        "    let argv: [long; 4] = [0; 4];",
        "    argv[0] = ptr_addr(&shpath[0]);",
        "    argv[1] = ptr_addr(&dashc[0]);",
        "    argv[2] = ptr_addr(&cmdb[0]);",
        "    argv[3] = 0;",
        "    let pid = syscall(57);",
        "    if (pid == 0) {",
        "        syscall(59, ptr_addr(&shpath[0]), ptr_addr(&argv[0]), 0);",
        "        syscall(60, 127);",
        "        0",
        "    } else if (pid < 0) {",
        "        0 - 1",
        "    } else {",
        "        let status: [long; 1] = [0; 1];",
        "        let w = syscall(61, pid, ptr_addr(&status[0]), 0, 0);",
        "        if (w < 0) { 0 - 1 } else { exit_status(status[0]) }",
        "    }",
        "};",
        "",
        "// Decode wait(2) status: low 7 bits are the terminating signal",
        "// (0 for a normal exit), next 8 bits the exit code.",
        "def exit_status(raw: long) -> long {",
        "    if (raw % 128 == 0) { (raw / 256) % 256 } else { 0 - 1 }",
        "};",
        ""
    ]
};

// Names the prelude defines. A program that mentions none of them gets no
// prelude at all, so a hello-world binary stays the size it was.
def prelude_names() -> [str] {
    ["readline", "clear_eof"]
};

def exec_names() -> [str] {
    ["exec"]
};

export { prelude_src, prelude_lines, prelude_names, exec_lines, exec_names };
