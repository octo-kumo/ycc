// ls from RING 3: open the root directory, ask getdents64 for its entries, and
// decode the first linux_dirent64 record.  The image holds one entry, "prog" ->
// inode 2, so every number is checkable: fd 3, a 24-byte record (19 + 4 + 1 padded
// to 8), d_ino 2, and the name as four bytes 112 114 111 103.
let s = "/";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let buf: [byte] = [];
let k = 0;
while (k < 256) { buf += 0; k = k + 1; };
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let n = syscall(217, f, ptr_addr(&buf[0]), 256);
print("ls fd=" + tostring(f) + " n=" + tostring(n) + " ino=" + tostring(buf[0]) + " reclen=" + tostring(buf[16]) + " name=" + tostring(buf[19]) + tostring(buf[20]) + tostring(buf[21]) + tostring(buf[22]) + "\n");
