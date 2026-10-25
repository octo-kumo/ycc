// ARGUMENTS through execve, in the RAW protocol the kernel walks: one [byte] buffer
// per argument, NUL-terminated, plus a [long] array of their addresses.  A [str] array
// would not do -- a Y string is length-prefixed, so its first byte is a count, not a
// character, and the kernel would read a one-letter argument.
let a = argv();
print("sh n=" + tostring(len(a)) + " a1=" + a[1] + "\n");
if (len(a) >= 3) {
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
    let t1 = "hello";
    let i1 = 0;
    while (i1 < len(t1)) { a1 += t1[i1] & 255; i1 = i1 + 1; };
    a1 += 0;
    let ptrs: [long] = [];
    ptrs += ptr_addr(&a0[0]);
    ptrs += ptr_addr(&a1[0]);
    ptrs += 0;
    let r = syscall(59, ptr_addr(&p[0]), ptr_addr(&ptrs[0]));
    print("exec failed " + tostring(r) + "\n");
} else {
    print("done\n");
};
