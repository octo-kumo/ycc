// YFS1 in the kernel.  The format is specified in src/y/KERNEL.md: a
// superblock, a 64-byte inode table and data blocks, all read straight out of
// the image's physical memory (the multiboot module today, a page the fs server
// mapped later).  The path walk, the fd broker and the fs server build on these.
import kernel;

let yfs_phys: long = 0;
let yfs_ok: long = 0;
let yfs_block_size: long = 4096;
let yfs_root: long = 1;

// u16 by hand: the kernel's peek helpers are for 8, 32 and 64 bits.
def yfs_u16(off: long) -> long {
    kernel.peek8(yfs_phys + off) + kernel.peek8(yfs_phys + off + 1) * 256
};

def yfs_u32(off: long) -> long {
    kernel.peek32(yfs_phys + off)
};

def yfs_init(phys: long) -> bool {
    yfs_phys = phys;
    yfs_ok = 0;
    if (kernel.peek8(phys) != 89) { return false; };
    if (kernel.peek8(phys + 1) != 70) { return false; };
    if (kernel.peek8(phys + 2) != 83) { return false; };
    if (kernel.peek8(phys + 3) != 49) { return false; };
    if (yfs_u32(4) != 1) { return false; };
    yfs_block_size = yfs_u32(8);
    yfs_root = yfs_u32(20);
    yfs_ok = 1;
    true
};

def yfs_inode_off(ino: long) -> long {
    yfs_block_size + ino * 64
};

def yfs_size(ino: long) -> long {
    yfs_u32(yfs_inode_off(ino) + 4)
};

// The block holding byte `pos` of an inode: the twelve direct slots, then one
// single-indirect block.
def yfs_block_of(ino: long, pos: long) -> long {
    let base = yfs_inode_off(ino);
    let bi = pos / yfs_block_size;
    if (bi < 12) { return yfs_u32(base + 8 + bi * 4); };
    let ind = yfs_u32(base + 56);
    if (ind == 0) { return 0; };
    yfs_u32(ind * yfs_block_size + (bi - 12) * 4)
};

// Copy up to `len` bytes at `off` into the caller's buffer, which is in the
// CURRENT address space -- at a syscall that is the caller's, at boot the
// kernel's.  Returns the number of bytes copied.
def yfs_read(ino: long, off: long, buf: long, len: long) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    let size = yfs_size(ino);
    if (off >= size) { return 0; };
    if (off + len > size) { len = size - off; };
    let done = 0;
    while (done < len) {
        let pos = off + done;
        let blk = yfs_block_of(ino, pos);
        if (blk == 0) { return done; };
        let bo = pos % yfs_block_size;
        let n = yfs_block_size - bo;
        if (n > len - done) { n = len - done; };
        let src = blk * yfs_block_size + bo;
        let i = 0;
        while (i < n) {
            kernel.poke_va8(buf + done + i, kernel.peek8(yfs_phys + src + i));
            i = i + 1;
        };
        done = done + n;
    };
    done
};

// `addr` is an offset INTO THE IMAGE, like the offsets yfs_u16/yfs_u32 take:
// the image address is added here.  (It was missed once, and the symptom was a
// name compare that read physical 520 instead of image+520.)
def yfs_name_at(addr: long, name: str) -> bool {
    let i = 0;
    while (i < len(name)) {
        if (kernel.peek8(yfs_phys + addr + i) != name[i]) { return false; };
        i = i + 1;
    };
    true
};

// One component, looked up in the root directory.  A path walk composes this.
def yfs_lookup(name: str) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    let base = yfs_inode_off(yfs_root);
    let count = yfs_u32(base + 4);
    let blk = yfs_u32(base + 8);
    if (blk == 0) { return 0 - 1; };
    let e = blk * yfs_block_size;
    let idx = 0;
    while (idx < count) {
        let nl = yfs_u16(e);
        if (nl == 0) { return 0 - 1; };
        if (nl == len(name) && yfs_name_at(e + 8, name)) { return yfs_u32(e + 4); };
        e = e + ((8 + nl + 3) & (0 - 4));
        idx = idx + 1;
    };
    0 - 1
};
