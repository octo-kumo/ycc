// ls: open the root and walk its entries.  One getdents64 call can carry SEVERAL
// records (the kernel fills the buffer), so the records inside it are walked with
// d_reclen as the stride and the syscall is called again only when the buffer is
// exhausted; the loop ends when it answers 0.  Names are printed as bytes, so each
// line is checkable: "prog" is 112 114 111 103, "msg" is 109 115 103 then its NUL.
let s = "/";
let p: [byte] = [];
let i = 0;
while (i < len(s)) { p += s[i] & 255; i = i + 1; };
p += 0;
let buf: [byte] = [];
let k = 0;
while (k < 256) { buf += 0; k = k + 1; };
let f = syscall(257, -100, ptr_addr(&p[0]), 0);
print("ls open=" + tostring(f) + "\n");
let n = 1;
while (n > 0) {
    n = syscall(217, f, ptr_addr(&buf[0]), 256);
    let o = 0;
    while (o < n) {
        let rl = buf[o + 16];
        print("entry ino=" + tostring(buf[o]) + " reclen=" + tostring(rl) + " name=" + tostring(buf[o + 19]) + tostring(buf[o + 20]) + tostring(buf[o + 21]) + tostring(buf[o + 22]) + "\n");
        o = o + rl;
    };
};
print("ls done\n");
