// The microkernel's real boot path: a YFS1 image is built in memory, the
// program's ELF is copied into it as the file /prog, and the kernel then loads
// and runs that program OUT OF THE FILESYSTEM -- lookup, read, elf_map, ring 3.
// The image's data block IS the ELF's physical home, so elf_map is handed the
// block rather than a buffer.
import kernel;
import elf from "../../os/kernel/elfload.y";

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

const BS = 4096;

kernel.init();
let mphys = kernel.mb_mod_start(0);
let msize = kernel.mb_mod_end(0) - mphys;
kernel.sched_init(kernel.vm_current(), kernel.kernel_stack_top());

// superblock, a four-block inode table (256 * 64 bytes), one block of root
// directory entries, then the file's data.
let data_start = 5;
let npages = data_start + 1 + (msize + BS - 1) / BS;
let img = 0;
let i = 0;
while (i < npages) {
    let p = kernel.page_alloc();
    if (i == 0) { img = p; };
    i = i + 1;
};
p8(img, 89); p8(img + 1, 70); p8(img + 2, 83); p8(img + 3, 49);
p32(img + 4, 1);
p32(img + 8, BS);
p32(img + 12, npages);
p32(img + 16, 256);
p32(img + 20, 1);
p32(img + 24, data_start);
// inode 1 (root): one entry, "prog", in block data_start
p32(img + BS + 64, 2);
p32(img + BS + 68, 1);
p32(img + BS + 72, data_start);
p16(img + data_start * BS, 4);
p16(img + data_start * BS + 2, 1);
p32(img + data_start * BS + 4, 2);
p8(img + data_start * BS + 8, 112);
p8(img + data_start * BS + 9, 114);
p8(img + data_start * BS + 10, 111);
p8(img + data_start * BS + 11, 103);
// inode 2: the program, one block past the directory
p32(img + BS + 128, 1);
p32(img + BS + 132, msize);
let dib = 0;
while (dib < (msize + BS - 1) / BS) {
    if (dib < 12) { p32(img + BS + 136 + dib * 4, data_start + 1 + dib); };
    dib = dib + 1;
};
let bsrc = (data_start + 1) * BS;
let k = 0;
while (k < msize) { p8(img + bsrc + k, kernel.peek8(mphys + k)); k = k + 1; };
let ok = yfs_init(img);
let ino = yfs_lookup_path("/prog");
let size = yfs_size(ino);
print("fs ok=" + tostring(ok) + " ino=" + tostring(ino) + " size=" + tostring(size) + "\n");
let dir = kernel.vm_new_dir();
kernel.vm_switch(dir);
let entry = elf.elf_map(img + bsrc, size);
let sp = elf.elf_setup_stack(["sh", "/prog", "hello"]);
let kstack = kernel.pages_alloc_va(65536);
let ktop = kstack + 65536;
let frame = kernel.task_frame(ktop, entry, sp);
let pid = kernel.sched_add(dir, ktop, frame, "prog");
kernel.task_start(pid);
kernel.kexit(9);
