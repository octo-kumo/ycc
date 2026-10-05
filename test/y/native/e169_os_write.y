// os_write(fd, s) is the named-syscall-layer entry point: the checker fixes
// its arity and its two argument types, and the arch module decides which
// kernel call it is (write(2) on Linux, NtWriteFile on Windows). Both targets
// accept exactly this, which is the point: shared std code can call it and the
// std pack stays target-independent.
//
// expect-error: 14:9: error: os_write takes exactly 2 arguments (fd, string)
// expect-error: 15:9: error: os_write takes exactly 2 arguments (fd, string)
// expect-error: 16:9: error: os_write fd must be a number, got str
// expect-error: 17:9: error: os_write needs a string, got long
//
// (a `str` fd and a `long` payload: the two things write(2) and NtWriteFile
// do not agree a caller may supply)
os_write(1);
os_write();
os_write("out", "hello");
os_write(1, 1);