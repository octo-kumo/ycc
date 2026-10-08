// yfs_create: build a tiny image, CREATE a file in it, write four bytes through
// yfs_append, find it again by name, and read it back.  The image is CLEARED first:
// page_alloc does not zero, and yfs_create looks for a free inode by reading mode 0.
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
let ok = yfs.yfs_init(img);
let made = yfs.yfs_create("new");
let data: [byte] = [];
data += 97; data += 98; data += 99; data += 100;
let w = yfs.yfs_append(made, ptr_addr(&data[0]), 4);
let found = yfs.yfs_lookup_path("/new");
let n = yfs.yfs_read(found, 0, out, 4);
// removal: free the inode and shift the directory's entries down.  The proof is the
// CONTRAST -- the name resolved a moment ago and must not now.
let rm = yfs.yfs_unlink("new");
let gone = yfs.yfs_lookup_path("/new");
print("unlink rm=" + tostring(rm) + " gone=" + tostring(gone) + " "); print("create ok=" + tostring(ok) + " made=" + tostring(made) + " w=" + tostring(w) + " found=" + tostring(found) + " n=" + tostring(n) + " text=" + tostring(kernel.peek_va8(out)) + tostring(kernel.peek_va8(out + 1)) + tostring(kernel.peek_va8(out + 2)) + tostring(kernel.peek_va8(out + 3)) + "\n");
kernel.kexit(9);
