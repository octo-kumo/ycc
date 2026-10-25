// exec, popen and the pipes on Windows: the shell is cmd.exe, so the commands are
// its builtins and sort.exe (the POSIX-shell test of the same module is
// native/t38_exec.y, t333_exec_pipe.y). Carriage returns are cut from what a
// child writes, since cmd.exe ends its lines with CR LF.
def clean(s: str) -> str { s.replace("\r", "") };
puts("before\n");
print(exec("echo hello from exec >nul"));
print(exec("exit 3"));
print(exec("ver >nul"));
print(exec("definitely-not-a-real-command-xyz 2>nul"));
puts("after\n");
print("[" + clean(exec_capture("echo hello")) + "]");
print("[" + clean(exec_capture_in("sort", "pear\r\napple\r\nfig\r\n")) + "]");
let p = popen("sort");
print(len(p));
print(pwrite(p, "b\r\na\r\n"));
pclose_in(p);
print("[" + clean(pread(p)) + "]");
print(pclose(p));
let q = popen("exit 5");
pclose_in(q);
print(pclose(q));
print("[" + clean(exec_capture("exit 3")) + "]");
