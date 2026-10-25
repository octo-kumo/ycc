// The shape of every M4 command: take a PATH FROM ARGV, open it through the
// syscalls, and read.  argv[1] is "/prog" (the program's own ELF in the image),
// so the first byte is 0x7f -- 127 -- and the count is checkable.
let a = argv();
let path = a[1];
let p: [byte] = [];
let i = 0;
while (i < len(path)) { p += path[i] & 255; i = i + 1; };
p += 0;
let buf: [byte] = [];
let k = 0;
while (k < 16) { buf += 0; k = k + 1; };
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let n = syscall(0, f, ptr_addr(&buf[0]), 16);
print("cat " + path + " fd=" + tostring(f) + " n=" + tostring(n) + " b0=" + tostring(buf[0]) + "\n");
