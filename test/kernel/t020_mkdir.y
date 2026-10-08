// yfs_create: build a tiny image, CREATE a file in it, write four bytes through
// yfs_append, find it again by name, and read it back.  The image is CLEARED first:
// page_alloc does not zero, and yfs_create looks for a free inode by reading mode 0.
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
let spare = kernel.page_alloc();
let out = kernel.page_alloc();
let z = 0;
while (z < 4096) { p8(img + z, 0); z = z + 1; };
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, 256);
p32(img + 16, 8);
p32(img + 20, 1);
p32(img + 24, 2);
p32(img + 320, 2);
p32(img + 324, 1);
p32(img + 328, 3);
p16(img + 768, 4);
p16(img + 770, 1);
p32(img + 772, 2);
p8(img + 776, 112); p8(img + 777, 114); p8(img + 778, 111); p8(img + 779, 103);
let ok = yfs_init(img);
let made = yfs_create("new");
let data: [byte] = [];
data += 97; data += 98; data += 99; data += 100;
let w = yfs_append(made, ptr_addr(&data[0]), 4);
// a directory of its own, and a child inside it: mkdir takes a free inode with mode
// 2 and an entry count of 0, and yfs_add_entry with that inode as the parent puts the
// child's entry in the DIRECTORY's entry block, allocated lazily on this first child.
let d = yfs_mkdir("d");
print("M1 d=" + tostring(d) + "\n");
let child = yfs_add_entry(d, "child", 1);
print("M2 child=" + tostring(child) + "\n");
let deep = yfs_lookup_path("/d/child");
print("M3 deep=" + tostring(deep) + "\n");
let found = yfs_lookup_path("/new");
let n = yfs_read(found, 0, out, 4);
print("create ok=" + tostring(ok) + " made=" + tostring(made) + " w=" + tostring(w) + " found=" + tostring(found) + " n=" + tostring(n) + " text=" + tostring(kernel.peek_va8(out)) + tostring(kernel.peek_va8(out + 1)) + tostring(kernel.peek_va8(out + 2)) + tostring(kernel.peek_va8(out + 3)) + "\n");
kernel.kexit(9);
