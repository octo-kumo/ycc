// execve: print a marker, then replace this process with /prog -- itself, once.
// The replacement starts with an argv of ["prog", "again"], so it can tell it is
// the second run, say so and stop. If execve did not replace the process, the
// syscall would return and "execve returned" would appear instead; the expected
// text is the two markers and the "again", which a program that is never replaced
// cannot print.
//
// (This used to exec itself forever and ended only when the kernel ran out of
// pages, because exec freed nothing. It frees now, so "forever" is forever.)
let a = argv();
print("marker\n");
if (len(a) > 1) {
    print("again\n");
} else {
    let p: [byte] = [];
    let s = "/prog";
    let i = 0;
    while (i < len(s)) { p += s[i] & 255; i = i + 1; };
    p += 0;
    let a0: [byte] = [];
    let t0 = "prog";
    let i0 = 0;
    while (i0 < len(t0)) { a0 += t0[i0] & 255; i0 = i0 + 1; };
    a0 += 0;
    let a1: [byte] = [];
    let t1 = "again";
    let i1 = 0;
    while (i1 < len(t1)) { a1 += t1[i1] & 255; i1 = i1 + 1; };
    a1 += 0;
    let ptrs: [long] = [];
    ptrs += ptr_addr(&a0[0]);
    ptrs += ptr_addr(&a1[0]);
    ptrs += 0;
    let r = syscall(59, ptr_addr(&p[0]), ptr_addr(&ptrs[0]), 0);
    print("execve returned " + tostring(r) + "\n");
};
