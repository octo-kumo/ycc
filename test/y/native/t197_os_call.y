// os_call("y_os_write", fd, s, len(s)) -- the named syscall layer rt.y's
// print/eputs go through, checked from a program rather than from inside the
// runtime.
//
// The block returns the byte count the kernel accepted, so the count is the
// check: the write reached the standard output and the length is exactly the
// string's. Nothing else about it is target-specific, which is the property
// that lets std code call it -- write(2) on Linux, NtWriteFile on Windows, one
// name, one shape, and the same bytes on the wire either way.
let n = os_call("y_os_write", 1, "hello\n", len("hello\n"));
print(n);
let e = "";
print(os_call("y_os_write", 1, e, len(e)));
// a str argument flows in as its bytes, not as its header: the count is the
// payload's length, not length + 8
print(os_call("y_os_write", 1, "0123456789", 10));
// a *T argument is the buffer shape, which is what a block that fills one wants
let ts: [long; 2] = [0; 2];
print(os_call("y_os_wait4", 0, &ts[0]));
// y_os_wait4 on a pid that is not a child answers ECHILD (-10), which is the
// shape of every "no such child" a Linux caller already checks for. (No fork
// here on purpose: y_os_fork really forks, so the fixture's output would carry
// a pid and come out twice.)