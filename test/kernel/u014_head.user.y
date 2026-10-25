// head: read only the first N bytes of a file.  The cat loop with a bound -- the
// same syscalls, stopping early -- and the file is "hi from yfs\n", so the first
// four bytes are "hi f" and the transcript shows them.
let a = argv();
let path = a[1];
let p: [byte] = [];
let i = 0;
while (i < len(path)) { p += path[i] & 255; i = i + 1; };
p += 0;
let buf: [byte] = [];
let k = 0;
while (k < 8) { buf += 0; k = k + 1; };
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let n = syscall(0, f, ptr_addr(&buf[0]), 4);
let s = from_bytes(buf);
print("head " + path + " f=" + tostring(f) + " n=" + tostring(n) + " text=" + s + "|\n");
