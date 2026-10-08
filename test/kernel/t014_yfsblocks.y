// YFS1 read ACROSS A BLOCK BOUNDARY.  The format contract (t013_yfsread) checks
// names and one small file; this checks that yfs_read walks blocks.
//
// 256-byte blocks, a 300-byte file in blocks 3 and 4, and a 100-byte read from
// offset 250 -- clamped to the file size (250 + 100 > 300), so 50 bytes come
// back: offset 250 is in block 3 and offset 299 is in block 4.
//
// The file's byte i is 65 + (i % 26), which makes the answer arithmetic rather
// than merely recorded: offset 250 -> 81, offset 299 -> 78.
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
let out = kernel.page_alloc();
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, 256);
p32(img + 16, 4);
p32(img + 20, 1);
p32(img + 24, 2);
p32(img + 320, 2);
p32(img + 324, 1);
p32(img + 328, 2);
p32(img + 384, 1);
p32(img + 388, 300);
p32(img + 392, 3);
p32(img + 396, 4);
p16(img + 512, 3);
p16(img + 514, 1);
p32(img + 516, 2);
p8(img + 520, 98);
p8(img + 521, 105);
p8(img + 522, 103);
let i = 0;
while (i < 300) {
    p8(img + 768 + i, 65 + (i % 26));
    i = i + 1;
};
let ok = yfs.yfs_init(img);
let ino = yfs.yfs_lookup("big");
let n = yfs.yfs_read(ino, 250, out, 100);
print("blk ok=" + tostring(ok) + " ino=" + tostring(ino) + " n=" + tostring(n) + " first=" + tostring(kernel.peek_va8(out)) + " last=" + tostring(kernel.peek_va8(out + n - 1)) + "\n");
kernel.kexit(9);
