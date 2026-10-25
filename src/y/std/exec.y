// std/exec.y -- exec(cmd) and exit_status, written in Y. native.y embeds
// this file's text (`embed EXEC_SRC from "./std/exec.y";`) and splices it
// in front of a program that mentions `exec` (exec_names()). It is its own
// file so `ycc --exec=off` can leave it out entirely: the call then fails
// with "undefined function 'exec'" rather than compiling into a binary that
// can spawn a shell. exec() calls y_stdin_sync, a prelude name, so
// splicing this file always pulls std/prelude.y in as well.

// exec(cmd) -> long  (exit status, or -1 if the child died on a
// signal / could not be started). The command string goes to the system
// shell verbatim, the same contract system(3) has: /bin/sh -c on Linux,
// cmd.exe /d /s /c on Windows.
//
// SECURITY: there is no sanitizing here. Never pass untrusted
// input. ycc --exec=off omits this function entirely, so a binary
// built with it cannot reach a shell at all.
//
// The parent's environment is inherited as it stands; a Linux child gets
// `sh`'s default PATH only when the parent has none.
//
// The process is started by the named syscall layer's y_os_spawn: exec.y is one of the
// std units serialized into the std pack, which one compiler writes for one
// target, so a Linux fork(2)/execve(2) sequence compiled into it would be what
// every program on the other target ran too. y_os_spawn is fork + execve with
// its descriptors rearranged on Linux and CreateProcessW on Windows.
def exec(cmd: str) -> long {
    y_stdin_sync();
    let cmdb = bytes(cmd);
    cmdb += 0;
    let pid = os_call("y_os_spawn", ptr_addr(&cmdb[0]), -1, -1, -1, -1);
    if (pid < 0) {
        -1
    } else {
        let status: [long; 1] = [0; 1];
        let w = os_call("y_os_wait4", pid, ptr_addr(&status[0]));
        if (w < 0) { -1 } else { exit_status(status[0]) }
    }
};

// Decode wait(2) status: low 7 bits are the terminating signal
// (0 for a normal exit), next 8 bits the exit code.
def exit_status(raw: long) -> long {
    if (raw % 128 == 0) {(raw / 256) % 256 } else { -1 }
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
    let cmdb = bytes(cmd);
    cmdb += 0;
    // the child's stdin is the first pipe's read end and its stdout the
    // second's write end; the parent's two ends are named so the child does not
    // inherit them (or pread would never see end-of-file)
    let pid = os_call("y_os_spawn", ptr_addr(&cmdb[0]), pin0, pout1, pin1, pout0);
    if (pid < 0) {
        os_call("y_os_close", pin0);
        os_call("y_os_close", pin1);
        os_call("y_os_close", pout0);
        os_call("y_os_close", pout1);
        return [];
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
    if (len(p) < 3) { return -1; };
    let b = bytes(s);
    let total = len(b);
    let off = 0;
    while (off < total) {
        let w = os_call("y_os_write", p[1], ptr_addr(&b[off]), total - off);
        if (w <= 0) { return -1; };
        off = off + w;
    };
    total
};

// Close the child's stdin so a reader in it sees end-of-file. pclose does
// this too; call it earlier when the answer is wanted before the wait.
def pclose_in(p: [long]) -> long {
    if (len(p) < 3) { return -1; };
    let r = os_call("y_os_close", p[1]);
    p[1] = -1;
    if (r < 0) { -1 } else { 0 }
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
    if (len(p) < 3) { return -1; };
    if (p[1] >= 0) { os_call("y_os_close", p[1]); };
    if (p[2] >= 0) { os_call("y_os_close", p[2]); };
    p[1] = -1;
    p[2] = -1;
    let status: [long; 1] = [0; 1];
    let w = os_call("y_os_wait4", p[0], ptr_addr(&status[0]));
    if (w < 0) { -1 } else { exit_status(status[0]) }
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
