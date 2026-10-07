// YFS1 PATH WALK: root -> bin (a directory) -> sh (a file).  The entries of a
// subdirectory live in their own block, so this also pins that a directory
// inode's direct[0] is followed like any other file's.
import kernel;
import yfs from "../../os/kernel/yfs.y";

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
// inode 1 (root): one entry, "bin", in block 2
p32(img + 320, 2);
p32(img + 324, 1);
p32(img + 328, 2);
p16(img + 512, 3);
p16(img + 514, 1);
p32(img + 516, 2);
p8(img + 520, 98);
p8(img + 521, 105);
p8(img + 522, 110);
// inode 2 (bin, a directory): one entry, "sh", in block 3
p32(img + 384, 2);
p32(img + 388, 1);
p32(img + 392, 3);
p16(img + 768, 2);
p16(img + 770, 1);
p32(img + 772, 3);
p8(img + 776, 115);
p8(img + 777, 104);
// inode 3 (sh, a file): two bytes in block 4
p32(img + 448, 1);
p32(img + 452, 2);
p32(img + 456, 4);
p8(img + 1024, 111);
p8(img + 1025, 107);
let ok = yfs.yfs_init(img);
let ino = yfs.yfs_lookup_path("/bin/sh");
let n = yfs.yfs_read(ino, 0, out, 2);
let bad = yfs.yfs_lookup_path("/bin/nope");
print("path ok=" + tostring(ok) + " ino=" + tostring(ino) + " n=" + tostring(n) + " c=" + tostring(kernel.peek_va8(out)) + tostring(kernel.peek_va8(out + 1)) + " bad=" + tostring(bad) + "\n");
kernel.kexit(9);
