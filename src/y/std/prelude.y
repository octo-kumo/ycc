// std/prelude.y -- readline() and the stdin buffer behind it, written in
// Y. It is a unit of the std pack, linked into a program that mentions one
// of prelude_names() -- readline, clear_eof, y_stdin_sync -- so a program
// that reads nothing carries none of it.
//
// WHY THIS EXISTS: every builtin used to mean another hand-written block of
// assembly in arch_x64.y. That does not scale and it is where the bugs
// live. The rule here is the opposite: the backend provides small, general
// PRIMITIVES (the `syscall` intrinsic, `bytes`/`from_bytes`), and the
// actual behaviour -- stopping at a newline, running a child process --
// is ordinary Y code that the compiler compiles like any other function.
//
// These are plain defs, not intrinsics: they go through the normal
// rename/typecheck/emit path, so a bug here is a bug in Y code, not in
// hand-rolled x86.

// The stdin buffer readline() fills 16 KB at a time: bytes
// y_rl_pos..y_rl_end of y_rl_buf are read but not yet returned.
// The buffer itself is allocated on the first read, so a program
// that only mentions readline pays for two zeroed cells.
let y_rl_buf: [byte] = [];
let y_rl_pos = 0;
let y_rl_end = 0;

// readline() -> str?  (a line of stdin, newline stripped; none at
// end of input). Buffered like C stdio: one read(2) per 16 KB, not
// one per byte. A terminal in canonical mode hands over one line per
// read(2) anyway. EOF is not latched -- once the buffer is empty
// every call issues a fresh read(2), so a REPL survives Ctrl-D and
// a FIFO that is reopened.
def readline() -> str? {
    let out: [byte] = [];
    let go = true;
    let got = false;
    while (go) {
        if (y_rl_pos < y_rl_end) {
            got = true;
            let buf = y_rl_buf;
            let end = y_rl_end;
            let i = y_rl_pos;
            while (i < end && buf[i] != 10) { i = i + 1; };
            out += buf[y_rl_pos:i];
            if (i < end) {
                y_rl_pos = i + 1;
                go = false;
            } else {
                y_rl_pos = end;
            };
        } else {
            if (len(y_rl_buf) == 0) {
                let fresh: [byte; 16384] = [0; 16384];
                y_rl_buf = fresh[0:16384];
            };
            let n = os_call("y_os_read", 0, &y_rl_buf[0], len(y_rl_buf));
            if (n <= 0) {
                go = false;
            } else {
                y_rl_pos = 0;
                y_rl_end = n;
            };
        };
    };
    if (got) { some(from_bytes(out)) } else { none }
};

// y_stdin_sync() -- exec() calls this before it forks. A child
// shares fd 0 with us, so whatever readline() buffered but did not
// return yet would be lost to it. When stdin is seekable (a
// redirected file) the unread bytes are given back with
// lseek(0, -unread, SEEK_CUR) and the child starts right after the
// last line we returned. A pipe cannot seek: those bytes stay ours,
// the same contract C stdio and Python have.
def y_stdin_sync() -> long {
    let unread = y_rl_end - y_rl_pos;
    if (unread > 0) {
        if (os_call("y_os_lseek", 0, 0 - unread, 1) >= 0) {
            y_rl_pos = 0;
            y_rl_end = 0;
        };
    };
    0
};

// clear_eof() -- clear the end-of-input condition so a later
// readline() reads again. Nothing to do here: EOF is never latched
// (an empty buffer always means a fresh read(2)), so there is no
// sticky flag to reset. It stays a def so sources written for a
// stdio-based implementation, which needs clearerr(stdin), compile.
def clear_eof() -> long { 0 };
