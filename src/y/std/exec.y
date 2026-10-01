// std/exec.y -- exec(cmd) and exit_status, written in Y. native.y embeds
// this file's text (`embed EXEC_SRC from "./std/exec.y";`) and splices it
// in front of a program that mentions `exec` (exec_names()). It is its own
// file so `ycc --no-exec` can leave it out entirely: the call then fails
// with "undefined function 'exec'" rather than compiling into a binary that
// can spawn a shell. exec() calls y_stdin_sync, a prelude name, so
// splicing this file always pulls std/prelude.y in as well.

// exec(cmd) -> long  (exit status, or -1 if the child died on a
// signal / could not be started). The command string goes to
// /bin/sh -c verbatim, the same contract system(3) has.
//
// SECURITY: there is no sanitizing here. Never pass untrusted
// input. ycc --no-exec omits this function entirely, so a binary
// built with it cannot reach a shell at all.
//
// Written in Y over the raw syscalls: fork(57), execve(59),
// wait4(61), exit(60). envp is NULL -- sh supplies a default PATH
// -- so the parent's environment is not inherited; put VAR=val in
// the command string when a child needs one.
def exec(cmd: str) -> long {
    y_stdin_sync();
    let shpath = bytes("/bin/sh");
    shpath += 0;
    let dashc = bytes("-c");
    dashc += 0;
    let cmdb = bytes(cmd);
    cmdb += 0;
    let argv: [long; 4] = [0; 4];
    argv[0] = ptr_addr(&shpath[0]);
    argv[1] = ptr_addr(&dashc[0]);
    argv[2] = ptr_addr(&cmdb[0]);
    argv[3] = 0;
    let pid = syscall(57);
    if (pid == 0) {
        syscall(59, ptr_addr(&shpath[0]), ptr_addr(&argv[0]), 0);
        syscall(60, 127);
        0
    } else if (pid < 0) {
        0 - 1
    } else {
        let status: [long; 1] = [0; 1];
        let w = syscall(61, pid, ptr_addr(&status[0]), 0, 0);
        if (w < 0) { 0 - 1 } else { exit_status(status[0]) }
    }
};

// Decode wait(2) status: low 7 bits are the terminating signal
// (0 for a normal exit), next 8 bits the exit code.
def exit_status(raw: long) -> long {
    if (raw % 128 == 0) { (raw / 256) % 256 } else { 0 - 1 }
};
