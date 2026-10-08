// Growing a file from ring 3: seek to the end (12 bytes), write four more, seek
// back and read the whole thing.  Every syscall result is USED -- an unused one is
// eliminated by the compiler, which cost this fixture five rounds of investigation.
let s = "/msg";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let sk = syscall(8, f, 12, 0);
let w: [byte] = [];
w += 88; w += 89; w += 90; w += 10;
let nw = syscall(1, f, ptr_addr(&w[0]), 4);
let sk2 = syscall(8, f, 0, 0);
let buf: [byte] = [];
let k = 0;
while (k < 32) { buf += 0; k = k + 1; };
let n = syscall(0, f, ptr_addr(&buf[0]), 16);
let t = from_bytes(buf);
print("grow f=" + tostring(f) + " seek=" + tostring(sk) + " nw=" + tostring(nw) + " back=" + tostring(sk2) + " n=" + tostring(n) + " text=" + t + "|\n");
