// exec(): runs a command through /bin/sh -c, returns its exit status.
// NOTE: puts() everywhere, not print() — puts flushes, and the VM's
// stdout is block-buffered when redirected, so print() output would sort
// after the (unbuffered) child writes and the interleaving would differ
// between engines for reasons that have nothing to do with exec.
puts(tostring(exec("echo hello from exec")) + "\n");
puts(tostring(exec("exit 3")) + "\n");
puts(tostring(exec("true")) + "\n");
puts(tostring(exec("false")) + "\n");

// the command string is built at run time like any other string
let word = "world";
puts(tostring(exec("echo hello " + word)) + "\n");

// the child's output interleaves with ours in program order
puts("before\n");
puts(tostring(exec("echo middle")) + "\n");
puts("after\n");

// a command that does not exist: sh reports it and exits 127
puts(tostring(exec("definitely-not-a-real-command-xyz 2>/dev/null")) + "\n");

// clear_eof() is available on every engine (a no-op natively: readline()
// issues a raw read(2) each call, so there is no sticky flag to reset)
clear_eof();
puts("cleared\n");
