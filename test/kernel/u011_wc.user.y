// wc: read the whole file in a 512-byte loop until read answers 0, and check the
// count against the file's size in the image, which the driver passes as argv[2]:
// that pins that a file over one block is read in full rather than stopping at
// the first block.
let a = argv();
let path = a[1];
let p: [byte] = [];
let i = 0;
while (i < len(path)) { p += path[i] & 255; i = i + 1; };
p += 0;
let buf: [byte] = [];
let k = 0;
while (k < 512) { buf += 0; k = k + 1; };
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let total = 0;
let n = 1;
while (n > 0) {
    n = syscall(0, f, ptr_addr(&buf[0]), 512);
    if (n > 0) { total = total + n; };
};
print("wc " + path + " bytes_ok=" + tostring(tostring(total) == a[2]) + "\n");
