// cp, from ring 3: read the source, CREATE the destination with openat(O_CREAT),
// write what was read, then read it back.  The copy's text must match the original.
let s = "/msg";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let buf: [byte] = [];
let k = 0;
while (k < 32) { buf += 0; k = k + 1; };
let n = syscall(0, f, ptr_addr(&buf[0]), 12);
let d = "/copy";
let q: [byte] = [];
let j = 0;
while (j < len(d)) { q += d[j] & 255; j = j + 1; };
q += 0;
let g = syscall(257, -100, ptr_addr(&q[0]), 64);
let w = syscall(1, g, ptr_addr(&buf[0]), n);
let sk = syscall(8, g, 0, 0);
let out2: [byte] = [];
let m = 0;
while (m < 32) { out2 += 0; m = m + 1; };
let n2 = syscall(0, g, ptr_addr(&out2[0]), 12);
let t = from_bytes(out2);
print("cp src=" + tostring(f) + " n=" + tostring(n) + " dst=" + tostring(g) + " w=" + tostring(w) + " back=" + tostring(sk) + " n2=" + tostring(n2) + " text=" + t + "|\n");
