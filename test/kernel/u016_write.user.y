// The WRITE path, from ring 3: open the text file, overwrite its first two bytes
// with "XY", seek back to 0 and read the file again.  The text changes from
// "hi from yfs" to "XY from yfs", so the transcript proves the bytes went in.
let s = "/msg";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let w: [byte] = [];
w += 88;
w += 89;
let nw = syscall(1, f, ptr_addr(&w[0]), 2);
let sk = syscall(8, f, 0, 0);
let buf: [byte] = [];
let k = 0;
while (k < 32) { buf += 0; k = k + 1; };
let n = syscall(0, f, ptr_addr(&buf[0]), 12);
let t = from_bytes(buf);
print("write f=" + tostring(f) + " nw=" + tostring(nw) + " lseek=" + tostring(sk) + " n=" + tostring(n) + " text=" + t + "|\n");
