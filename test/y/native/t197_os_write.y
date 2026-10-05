// os_write(fd, s) -- the named-syscall-layer entry point rt.y's print/eputs go
// through, checked from a program rather than from inside the runtime.
//
// It returns the byte count the kernel accepted, so the count itself is the
// check: the write went to the standard output and the length is exactly the
// string's. Nothing else about it is target-specific, which is the property
// that lets std code call it: write(2) on Linux, NtWriteFile on Windows, one
// name, one shape, and the same bytes on the wire either way.
let n = os_write(1, "hello\n");
print(n);
let e = "";
print(os_write(1, e));
// a str argument flows in as its bytes, not as its header: the count is the
// payload's length, not length + 8
print(os_write(1, "0123456789"));
// a long is not a str: from_bytes makes one out of the bytes
let b: [byte] = [104, 105, 10];
print(os_write(1, from_bytes(b)));