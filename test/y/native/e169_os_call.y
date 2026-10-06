// os_call("y_os_read", fd, buf, len) is the NAMED syscall layer: std code names
// an operation and the arch module decides which kernel call that name is --
// read(2) on Linux, NtReadFile on Windows. Both targets accept exactly this,
// which is the property that matters: rt.y, prelude.y and exec.y are compiled
// ONCE and serialized into one std pack, so anything they resolve at compile
// time (a syscall number, a struct layout, a branch on the target) is baked for
// whichever target wrote that pack, and a name is the one thing that survives.
//
// The list of legal names is types.y's os_call_names, and native.c/native.y
// check_os_call_names makes every one of them a label the arch lines really
// define -- so a name that exists in the list but in neither .s file is a
// compile error, not a link error on one target.

// expect-error: 23:8: error: os_call takes a name and 0-6 arguments
// expect-error: 24:8: error: os_call takes a name and 0-6 arguments
// expect-error: 25:8: error: os_call needs a literal call name
// expect-error: 26:8: error: os_call: 'y_os_reboot' is not a call name (see os_call_names)
// expect-error: 27:8: error: os_call arg 2 must be long/bool/str/*T, got float
//
// (a name in the right shape but not in the list; a float where the block
// wants a word. A str and a *T are both accepted: the emitter adds the str's
// header offset, and a *T is a buffer the block fills.)
os_call();
os_call("y_os_write", 1, "a", 1, 1, 1, 1, 1);
os_call(n);
os_call("y_os_reboot");
os_call("y_os_write", 1, 1.0);