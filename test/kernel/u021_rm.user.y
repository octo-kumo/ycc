// rm, from ring 3: open the file (it is there), remove it with unlinkat, then open it
// again -- which must fail.  The two opens are the proof: one succeeds and one does
// not, in the same transcript.
let s = "/msg";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
let un = syscall(263, -100, ptr_addr(&p[0]), 0);
let g = syscall(257, -100, ptr_addr(&p[0]), 0);
print("rm first=" + tostring(f) + " unlink=" + tostring(un) + " again=" + tostring(g) + "\n");
