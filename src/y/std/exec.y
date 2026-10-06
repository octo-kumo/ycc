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
    // The named syscall layer, not raw syscall numbers: exec.y is one of the
    // four std units serialized into the std pack, which one compiler writes
    // for one target, so a Linux fork(2)/execve(2)/wait4(2)/_exit sequence
    // compiled into it would be what every program on the other target ran
    // too. y_os_fork and y_os_execve answer ENOSYS on Windows for now (there is
    // no fork, and NtCreateUserProcess wants Win32 structures rather than three
    // C arrays), which is what makes the `pid < 0` fallback below the path a PE
    // takes instead of a lie.
    let pid = os_call("y_os_fork");
    if (pid == 0) {
        os_call("y_os_execve", ptr_addr(&shpath[0]), ptr_addr(&argv[0]), 0);
        exit(127);
        0
    } else if (pid < 0) {
        0 - 1
    } else {
        let status: [long; 1] = [0; 1];
        let w = os_call("y_os_wait4", pid, ptr_addr(&status[0]));
        if (w < 0) { 0 - 1 } else { exit_status(status[0]) }
    }
};

// Decode wait(2) status: low 7 bits are the terminating signal
// (0 for a normal exit), next 8 bits the exit code.
def exit_status(raw: long) -> long {
    if (raw % 128 == 0) { (raw / 256) % 256 } else { 0 - 1 }
};

// ── a child's stdio: popen, pwrite, pread, pclose ────────────────────────
//
// exec() runs a command on the parent's own stdio. These run one with its
// stdin and stdout on pipes, so a Y program can call a tool and read its
// answer. A session is an ordinary [long] of three -- {pid, in, out} --
// because Y has no handle type and needs none: in is the parent's write end
// (the child's stdin), out the parent's read end (the child's stdout), and
// wait4 on p[0] is the wait. A pipe is unidirectional, hence two of them.
//
// On Windows y_os_fork, y_os_pipe and y_os_dup2 all answer ENOSYS, so popen
// answers [] (the EMPTY array) rather than a session that cannot work: the
// four functions below then do nothing but fail, and exec_capture answers "".
// A caller that must tell "no child" from "a child that printed nothing"
// checks len(p) == 3.
//
// DEADLOCK, named because a synchronous popen cannot avoid it: a child that
// fills its stdout pipe while the parent is still writing stdin blocks, and so
// does the parent. Feed input small enough for the pipe buffer, or read the
// answer before writing more. This is the same contract pclose(3) has.
def popen(cmd: str) -> [long] {
    y_stdin_sync();
    // pipe(2) writes an 8-byte int[2]; one long carries both descriptors
    // (fds[0] low half, fds[1] high half) and these four names split it.
    let ib: [long; 1] = [0; 1];
    let ob: [long; 1] = [0; 1];
    if (os_call("y_os_pipe", ptr_addr(&ib[0])) < 0) { return []; };
    if (os_call("y_os_pipe", ptr_addr(&ob[0])) < 0) {
        os_call("y_os_close", ib[0] & 4294967295);
        os_call("y_os_close", ib[0] >> 32);
        return [];
    };
    let pin0 = ib[0] & 4294967295;
    let pin1 = ib[0] >> 32;
    let pout0 = ob[0] & 4294967295;
    let pout1 = ob[0] >> 32;
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
    let pid = os_call("y_os_fork");
    if (pid < 0) {
        os_call("y_os_close", pin0);
        os_call("y_os_close", pin1);
        os_call("y_os_close", pout0);
        os_call("y_os_close", pout1);
        return [];
    };
    if (pid == 0) {
        os_call("y_os_dup2", pin0, 0);
        os_call("y_os_dup2", pout1, 1);
        os_call("y_os_close", pin0);
        os_call("y_os_close", pin1);
        os_call("y_os_close", pout0);
        os_call("y_os_close", pout1);
        os_call("y_os_execve", ptr_addr(&shpath[0]), ptr_addr(&argv[0]), 0);
        exit(127);
        0
    };
    // The parent keeps the write end of the first pipe and the read end of the
    // second; the other two are the child's and must not stay open here, or
    // pread never sees end-of-file.
    os_call("y_os_close", pin0);
    os_call("y_os_close", pout1);
    [pid, pin1, pout0]
};

// All of s to the child's stdin. The bytes written, or -1.
def pwrite(p: [long], s: str) -> long {
    if (len(p) < 3) { return 0 - 1; };
    let b = bytes(s);
    let total = len(b);
    let off = 0;
    while (off < total) {
        let w = os_call("y_os_write", p[1], ptr_addr(&b[off]), total - off);
        if (w <= 0) { return 0 - 1; };
        off = off + w;
    };
    total
};

// Close the child's stdin so a reader in it sees end-of-file. pclose does
// this too; call it earlier when the answer is wanted before the wait.
def pclose_in(p: [long]) -> long {
    if (len(p) < 3) { return 0 - 1; };
    let r = os_call("y_os_close", p[1]);
    p[1] = 0 - 1;
    if (r < 0) { 0 - 1 } else { 0 }
};

// Everything the child writes to stdout, to end-of-file.
def pread(p: [long]) -> str {
    if (len(p) < 3) { return ""; };
    let out: [byte] = [];
    let chunk: [byte; 65536] = [0; 65536];
    let go = true;
    while (go) {
        let k = os_call("y_os_read", p[2], &chunk[0], 65536);
        if (k <= 0) { go = false; } else { out += chunk[0:k]; };
    };
    from_bytes(out)
};

// Close both ends and reap the child: its decoded exit status, or -1. Closing
// an end twice is harmless here (the fd is marked spent), which is why
// exec_capture can call pclose_in and then pclose.
def pclose(p: [long]) -> long {
    if (len(p) < 3) { return 0 - 1; };
    if (p[1] >= 0) { os_call("y_os_close", p[1]); };
    if (p[2] >= 0) { os_call("y_os_close", p[2]); };
    p[1] = 0 - 1;
    p[2] = 0 - 1;
    let status: [long; 1] = [0; 1];
    let w = os_call("y_os_wait4", p[0], ptr_addr(&status[0]));
    if (w < 0) { 0 - 1 } else { exit_status(status[0]) }
};

// The call most programs want: run cmd, feed it input, answer its stdout. The
// status is dropped -- take popen apart when it matters. Two names and no
// default argument, because a defaulted parameter on a SPLICED std def is not
// resolved at the call site (the call is checked before the spliced body
// registers its defaults), and a fixture that needs `exec_capture("x")` is the
// common case.
def exec_capture(cmd: str) -> str {
    exec_capture_in(cmd, "")
};

def exec_capture_in(cmd: str, input: str) -> str {
    let p = popen(cmd);
    if (len(p) < 3) { return ""; };
    if (len(input) > 0) { pwrite(p, input); };
    pclose_in(p);
    let out = pread(p);
    pclose(p);
    out
};
