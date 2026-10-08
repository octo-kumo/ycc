// cat a TEXT file out of the kernel's filesystem: open the path from argv, read
// it, and print the bytes as a string.  The file is "hi from yfs\n", so the
// transcript shows the text itself.
let a = argv();
let path = a[1];
let p: [byte] = [];
let i = 0;
while (i < len(path)) { p += path[i] & 255; i = i + 1; };
p += 0;
let buf: [byte] = [];
let k = 0;
while (k < 32) { buf += 0; k = k + 1; };
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let n = syscall(0, f, ptr_addr(&buf[0]), 32);
let s = from_bytes(buf);
print("cat " + path + " f=" + tostring(f) + " n=" + tostring(n) + " text=" + s + "|\n");
