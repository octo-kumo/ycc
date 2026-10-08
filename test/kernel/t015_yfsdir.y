// YFS1 directory reading: two entries with DIFFERENT name lengths, so the
// 4-byte entry stride is exercised (entry 1 starts at 8+1 rounded up = 12).
import kernel;
import yfs;

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
let buf = kernel.page_alloc();
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, 256);
p32(img + 16, 4);
p32(img + 20, 1);
p32(img + 24, 2);
// root: two entries in block 2 -- "a" -> inode 2, then "bb" -> inode 3
p32(img + 320, 2);
p32(img + 324, 2);
p32(img + 328, 2);
p16(img + 512, 1);
p16(img + 514, 1);
p32(img + 516, 2);
p8(img + 520, 97);
p16(img + 524, 2);
p16(img + 526, 1);
p32(img + 528, 3);
p8(img + 532, 98);
p8(img + 533, 98);
let ok = yfs.yfs_init(img);
let n0 = yfs.yfs_readdir(1, 0, buf);
let a = kernel.peek_va8(buf);
let i0 = yfs.yfs_dir_inode(1, 0);
let n1 = yfs.yfs_readdir(1, 1, buf);
let b0 = kernel.peek_va8(buf);
let b1 = kernel.peek_va8(buf + 1);
let i1 = yfs.yfs_dir_inode(1, 1);
print("dir ok=" + tostring(ok) + " n0=" + tostring(n0) + " a=" + tostring(a) + " i0=" + tostring(i0) + " n1=" + tostring(n1) + " b=" + tostring(b0) + tostring(b1) + " i1=" + tostring(i1) + "\n");
kernel.kexit(9);
