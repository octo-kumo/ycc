// sh, in the smallest honest form: take a command PATH from the arguments, resolve it
// in the filesystem, and run it with execve.  When the arguments run out it says so --
// which is also how the fixture observes execve's argv, since the replacement process
// starts with argv[0] alone.
let a = argv();
if (len(a) < 2) {
    print("sh: usage: sh <program>\n");
} else {
    let path = a[1];
    let p: [byte] = [];
    let i = 0;
    while (i < len(path)) { p += path[i] & 255; i = i + 1; };
    p += 0;
    print("sh run " + path + "\n");
    let r = syscall(59, ptr_addr(&p[0]), 0, 0);
    print("sh execve failed " + tostring(r) + "\n");
};
