// mv, from ring 3: open the file (it is there), rename it, then open BOTH names -- the
// old one must fail and the new one must succeed, in the same transcript.
let s = "/msg";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let d = "/out";
let q: [byte] = [];
let j = 0;
while (j < len(d)) { q += d[j] & 255; j = j + 1; };
q += 0;
let r = syscall(264, -100, ptr_addr(&p[0]), -100, ptr_addr(&q[0]));
let g = syscall(257, -100, ptr_addr(&p[0]), 0);
let h = syscall(257, -100, ptr_addr(&q[0]), 0);
print("mv old=" + tostring(f) + " ren=" + tostring(r) + " gone=" + tostring(g) + " new=" + tostring(h) + "\n");
