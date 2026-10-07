// YFS1 format contract: build an image in one page exactly as os/tools/mkfs.y
// lays one out, then read it back through os/kernel/yfs.y.  A 256-byte block
// size on purpose: the reader takes it from the superblock, so this also pins
// that it is not hard-wired to 4096.
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
// superblock: "YFS1", version 1, 256-byte blocks, root inode 1
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, 256);
p32(img + 16, 8);
p32(img + 20, 1);
p32(img + 24, 2);
// inode 1 (root) at 256 + 1*64: a directory with one entry in block 2
p32(img + 320, 2);
p32(img + 320 + 4, 1);
p32(img + 320 + 8, 2);
// inode 2 (the file) at 256 + 2*64: two bytes in block 3
p32(img + 384, 1);
p32(img + 384 + 4, 2);
p32(img + 384 + 8, 3);
// the directory entry in block 2: name_len 2, type 1, inode 2, "hi"
p16(img + 512, 2);
p16(img + 514, 1);
p32(img + 516, 2);
p8(img + 520, 104);
p8(img + 521, 105);
// the file's data in block 3
p8(img + 768, 104);
p8(img + 769, 105);
let ok = yfs.yfs_init(img);
let ino = yfs.yfs_lookup("hi");
let n = yfs.yfs_read(ino, 0, out, 2);
print("yfs " + tostring(ok) + " ino " + tostring(ino) + " n " + tostring(n) + " c " + tostring(kernel.peek_va8(out)) + tostring(kernel.peek_va8(out + 1)) + "\n");
kernel.kexit(9);
