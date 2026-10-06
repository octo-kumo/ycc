// std/exec.y's pipes to a child: popen, pwrite, pclose_in, pread, pclose, and
// the exec_capture convenience. Every command is a POSIX shell builtin --
// `read`, `echo`, `true`, `exit` -- so the fixture needs nothing installed
// beyond the /bin/sh exec() already requires. The `[` `]` around each capture
// make a trailing newline and an empty answer visibly different.
print("capture one line: [" + exec_capture("echo hello") + "]");
print("capture fed input: [" + exec_capture_in("read x; echo R:$x", "line\n") + "]");
print("empty input, no output: [" + exec_capture("true") + "]");

// The long way round, which is what a caller that needs the status uses.
// `read` consumes the fed line; the echoed answer comes back through the
// second pipe.
let p = popen("read x; echo got:$x");
print("a session is three longs: " + tostring(len(p)));
print("pwrite bytes: " + tostring(pwrite(p, "hi\n")));
pclose_in(p);
print("read back: [" + pread(p) + "]");
print("status: " + tostring(pclose(p)));

// The exit status crosses as exec()'s does (exit_status's decode).
let q = popen("exit 3");
pclose_in(q);
print("status 3 comes back: " + tostring(pclose(q)));

// An empty command still forks a shell and exits 0: a session, not [].
let e = popen("");
print("empty command still forks: " + tostring(len(e)));
print("its status: " + tostring(pclose(e)));

// The convenience drops the status, as documented.
print("capture of an exit: [" + exec_capture("exit 3") + "]");
