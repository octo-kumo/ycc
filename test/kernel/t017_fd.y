// The fd broker: root -> bin -> sh ("ok"), opened through fd_open, read at the
// fd's offset, seeked and read again, then closed.  Every number is checkable:
// the first fd is 3, "ok" is 111 107, a seek to 1 leaves 107, and reading a
// closed fd is -14.
import kernel;

def p8(addr: long, v: long) -> void { kernel.poke_va8(addr, v & 255); };

def p32(addr: long, v: long) -> void {
    p8(addr, v & 255);
    p8(addr + 1, (v >> 8) & 255);
    p8(addr + 2, (v >> 16) & 255);
    p8(addr + 3, (v >> 24) & 255);
};

def p16(addr: long, v: long) -> void {
    p8(addr, v & 255);
    p8(addr + 1, (v >> 8) & 255);
};

kernel.init();
let img = kernel.page_alloc();
let out = kernel.page_alloc();
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, 256);
p32(img + 16, 8);
p32(img + 20, 1);
p32(img + 24, 2);
p32(img + 320, 2);
p32(img + 324, 1);
p32(img + 328, 2);
p16(img + 512, 3);
p16(img + 514, 1);
p32(img + 516, 2);
p8(img + 520, 98); p8(img + 521, 105); p8(img + 522, 110);
p32(img + 384, 2);
p32(img + 388, 1);
p32(img + 392, 3);
p16(img + 768, 2);
p16(img + 770, 1);
p32(img + 772, 3);
p8(img + 776, 115); p8(img + 777, 104);
p32(img + 448, 1);
p32(img + 452, 2);
p32(img + 456, 4);
p8(img + 1024, 111); p8(img + 1025, 107);
let ok = yfs_init(img);
fd_reset();
let f = fd_open("/bin/sh");
let n = fd_read(f, out, 2);
let a = kernel.peek_va8(out);
let b = kernel.peek_va8(out + 1);
let sk = fd_lseek(f, 1);
let n2 = fd_read(f, out, 1);
let c2 = kernel.peek_va8(out);
let cl = fd_close(f);
let bad = fd_read(f, out, 1);
print("fd ok=" + tostring(ok) + " open=" + tostring(f) + " n=" + tostring(n) + " c=" + tostring(a) + tostring(b) + " seek=" + tostring(sk) + " n2=" + tostring(n2) + " c2=" + tostring(c2) + " close=" + tostring(cl) + " bad=" + tostring(bad) + "\n");
kernel.kexit(9);
