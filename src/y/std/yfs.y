// YFS1 in the kmem.  The format is specified in src/y/KERNEL.md: a
// superblock, a 64-byte inode table and data blocks, all read straight out of
// the image's physical memory (the multiboot module today, a page the fs server
// mapped later).  The path walk, the fd broker and the fs server build on these.
//
// Inode (64 bytes): mode u32 (low byte: 0 free, 1 file, 2 dir, 3 char device,
// 4 socket; byte 1: a char device's number), size u32 (bytes; for a directory the
// ENTRY COUNT), direct[12] at +8, the single-indirect block at +56 and at +60 a
// file's double-indirect block, or a directory's parent inode (0 = the root).
//
// A directory is a list of blocks of entries.  An entry never straddles a block;
// a zero name_len ends a block's entries (blocks are zeroed when allocated, and
// a removal shifts the later entries of that block down), so a walk goes block
// by block until the blocks run out.  "." and ".." are not stored: the path walk
// answers them (the parent is the inode's +60 field).
//
// Blocks come from a bump pointer past the image's last used block (bounded by the
// superblock's total, when it has one) and from a free list of the blocks given
// back this boot; a file or directory that is removed returns its blocks.

import kmem;

let yfs_phys: long = 0;
let yfs_ok: long = 0;
let yfs_total: long = 0;
let yfs_inodes: long = 0;
// The image's first never-used block.  A scan rather than a bitmap: images are small
// and it needs no format change.  Index blocks count as used, and their CONTENTS are
// scanned too, or a file past twelve blocks would hand out a block that is in use.
let yfs_next: long = 0;
let yfs_block_size: long = 4096;
let yfs_root: long = 1;
let yfs_free: [long] = [];
let yfs_nfree: long = 0;
let yfs_ihint: long = 1;

const YFS_REG = 1;
const YFS_DIR = 2;
const YFS_CHR = 3;
const YFS_SOCK = 4;

// u16 by hand: the kernel's peek helpers are for 8, 32 and 64 bits.
def yfs_u16(off: long) -> long {
    kmem.peek8(yfs_phys + off) + kmem.peek8(yfs_phys + off + 1) * 256
};

def yfs_u32(off: long) -> long {
    kmem.peek32(yfs_phys + off)
};

def yfs_w32(off: long, v: long) -> void {
    kmem.poke32(yfs_phys + off, v);
};

def yfs_w16(off: long, v: long) -> void {
    kmem.poke8(yfs_phys + off, v & 255);
    kmem.poke8(yfs_phys + off + 1, (v >> 8) & 255);
};

def yfs_init(phys: long) -> bool {
    yfs_phys = phys;
    yfs_ok = 0;
    if (kmem.peek8(phys) != 89) { return false; };
    if (kmem.peek8(phys + 1) != 70) { return false; };
    if (kmem.peek8(phys + 2) != 83) { return false; };
    if (kmem.peek8(phys + 3) != 49) { return false; };
    if (yfs_u32(4) != 1) { return false; };
    yfs_block_size = yfs_u32(8);
    yfs_total = yfs_u32(12);
    yfs_inodes = yfs_u32(16);
    yfs_root = yfs_u32(20);
    yfs_nfree = 0;
    yfs_ihint = 1;
    yfs_recompute_next();
    yfs_ok = 1;
    true
};

def yfs_inode_off(ino: long) -> long {
    yfs_block_size + ino * 64
};

def yfs_valid(ino: long) -> bool {
    ino >= 1 && ino < yfs_inodes && yfs_ok != 0
};

def yfs_size(ino: long) -> long {
    yfs_u32(yfs_inode_off(ino) + 4)
};

def yfs_set_size(ino: long, size: long) -> void {
    yfs_w32(yfs_inode_off(ino) + 4, size);
};

/** The whole mode word: 0 for a free inode. */
def yfs_mode(ino: long) -> long {
    yfs_u32(yfs_inode_off(ino))
};

/** YFS_REG, YFS_DIR, YFS_CHR or YFS_SOCK (0 for a free inode). */
def yfs_type(ino: long) -> long {
    yfs_mode(ino) & 255
};

/** A char device node's device number. */
def yfs_dev(ino: long) -> long {
    (yfs_mode(ino) >> 8) & 255
};

/** A directory's parent (the root's own parent is the root). */
def yfs_parent(ino: long) -> long {
    let p = yfs_u32(yfs_inode_off(ino) + 60);
    if (p == 0 || ino == yfs_root) { yfs_root } else { p }
};

def yfs_set_parent(ino: long, parent: long) -> void {
    yfs_w32(yfs_inode_off(ino) + 60, parent);
};

// ── blocks ──────────────────────────────────────────────────────────────
/** A zeroed block, or -1 when the image is full. */
def yfs_balloc() -> long {
    let b = 0;
    if (yfs_nfree > 0) {
        yfs_nfree = yfs_nfree - 1;
        b = yfs_free[yfs_nfree];
    } else {
        if (yfs_total != 0 && yfs_next >= yfs_total) { return -1; };
        b = yfs_next;
        yfs_next = yfs_next + 1;
    };
    kmem.kzero(kmem.DIRECT_BASE + yfs_phys + b * yfs_block_size, yfs_block_size);
    b
};

def yfs_bfree(b: long) -> void {
    if (b <= 0) { return; };
    if (yfs_nfree < len(yfs_free)) { yfs_free[yfs_nfree] = b; } else { yfs_free += b; };
    yfs_nfree = yfs_nfree + 1;
};

/** The image offset of the slot that holds block `bi` of the inode, 0 when the
 *  index blocks leading to it do not exist. */
def yfs_slot_off(ino: long, bi: long) -> long {
    let base = yfs_inode_off(ino);
    let bs = yfs_block_size;
    let per = bs / 4;
    if (bi < 12) { return base + 8 + bi * 4; };
    bi = bi - 12;
    if (bi < per) {
        let ind = yfs_u32(base + 56);
        if (ind == 0) { return 0; };
        return ind * bs + bi * 4;
    };
    bi = bi - per;
    if (yfs_type(ino) == YFS_DIR || bi >= per * per) { return 0; };
    let d = yfs_u32(base + 60);
    if (d == 0) { return 0; };
    let l1 = yfs_u32(d * bs + (bi / per) * 4);
    if (l1 == 0) { return 0; };
    l1 * bs + (bi % per) * 4
};

/** Block `bi` of the inode, 0 for a hole or past the end. */
def yfs_bget(ino: long, bi: long) -> long {
    let o = yfs_slot_off(ino, bi);
    if (o == 0) { return 0; };
    yfs_u32(o)
};

// The block in the slot at image offset `o`, allocated into it when empty.
def yfs_slot(o: long) -> long {
    let b = yfs_u32(o);
    if (b != 0) { return b; };
    b = yfs_balloc();
    if (b < 0) { return -1; };
    yfs_w32(o, b);
    b
};

/** Block `bi` of the inode, allocated (with the index blocks above it) when it
 *  is missing; -1 when the image is full. */
def yfs_bmap(ino: long, bi: long) -> long {
    let base = yfs_inode_off(ino);
    let bs = yfs_block_size;
    let per = bs / 4;
    if (bi < 12) { return yfs_slot(base + 8 + bi * 4); };
    bi = bi - 12;
    if (bi < per) {
        let ind = yfs_slot(base + 56);
        if (ind < 0) { return -1; };
        return yfs_slot(ind * bs + bi * 4);
    };
    bi = bi - per;
    if (yfs_type(ino) == YFS_DIR || bi >= per * per) { return -1; };
    let d = yfs_slot(base + 60);
    if (d < 0) { return -1; };
    let l1 = yfs_slot(d * bs + (bi / per) * 4);
    if (l1 < 0) { return -1; };
    yfs_slot(l1 * bs + (bi % per) * 4)
};

// The block holding byte `pos` of an inode.
def yfs_block_of(ino: long, pos: long) -> long {
    yfs_bget(ino, pos / yfs_block_size)
};

// Give back the index blocks that hold nothing once only the first `nb` blocks stay.
def yfs_trim_index(ino: long, nb: long) -> void {
    let base = yfs_inode_off(ino);
    let bs = yfs_block_size;
    let per = bs / 4;
    if (nb <= 12) {
        let ind = yfs_u32(base + 56);
        if (ind != 0) { yfs_bfree(ind); yfs_w32(base + 56, 0); };
    };
    if (yfs_type(ino) == YFS_DIR) { return; };
    let d = yfs_u32(base + 60);
    if (d == 0) { return; };
    let dstart = 12 + per;
    let j = 0;
    while (j < per) {
        let l1 = yfs_u32(d * bs + j * 4);
        if (l1 != 0 && nb <= dstart + j * per) {
            yfs_bfree(l1);
            yfs_w32(d * bs + j * 4, 0);
        };
        j = j + 1;
    };
    if (nb <= dstart) { yfs_bfree(d); yfs_w32(base + 60, 0); };
};

// Free the data blocks from index `from` up to (not including) `upto`.
def yfs_free_range(ino: long, from: long, upto: long) -> void {
    let bi = from;
    while (bi < upto) {
        let o = yfs_slot_off(ino, bi);
        if (o != 0) {
            let b = yfs_u32(o);
            if (b != 0) { yfs_bfree(b); yfs_w32(o, 0); };
        };
        bi = bi + 1;
    };
};

/** Set a file's size: growing leaves a hole that reads as zeros, shrinking gives
 *  the blocks back.  0, or a negative errno. */
def yfs_truncate(ino: long, newsize: long) -> long {
    if (yfs_ok == 0) { return -1; };
    if (newsize < 0 || newsize > 4294967295) { return -27; };
    let size = yfs_size(ino);
    let bs = yfs_block_size;
    if (newsize < size) {
        let nb_new = (newsize + bs - 1) / bs;
        let nb_old = (size + bs - 1) / bs;
        yfs_free_range(ino, nb_new, nb_old);
        yfs_trim_index(ino, nb_new);
        let rem = newsize % bs;
        if (rem != 0) {
            let b = yfs_bget(ino, nb_new - 1);
            if (b != 0) { kmem.kzero(kmem.DIRECT_BASE + yfs_phys + b * bs + rem, bs - rem); };
        };
    };
    yfs_set_size(ino, newsize);
    0
};

/** Free the inode and every block it holds. */
def yfs_release(ino: long) -> void {
    if (!yfs_valid(ino) || ino == yfs_root) { return; };
    let t = yfs_type(ino);
    if (t == YFS_DIR) {
        let bi = 0;
        while (yfs_bget(ino, bi) != 0) { bi = bi + 1; };
        yfs_free_range(ino, 0, bi);
        yfs_trim_index(ino, 0);
    } else if (t == YFS_REG) {
        yfs_truncate(ino, 0);
    };
    kmem.kzero(kmem.DIRECT_BASE + yfs_phys + yfs_inode_off(ino), 64);
    if (ino < yfs_ihint) { yfs_ihint = ino; };
};

/** A fresh inode with `mode` (type in the low byte): its number, or -1. */
def yfs_ialloc(mode: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let pass = 0;
    let i = yfs_ihint;
    if (i < 1) { i = 1; };
    while (pass < 2) {
        while (i < yfs_inodes) {
            if (yfs_u32(yfs_inode_off(i)) == 0) {
                kmem.kzero(kmem.DIRECT_BASE + yfs_phys + yfs_inode_off(i), 64);
                yfs_w32(yfs_inode_off(i), mode);
                yfs_ihint = i + 1;
                return i;
            };
            i = i + 1;
        };
        i = 1;
        pass = pass + 1;
    };
    -1
};

// Copy up to `len` bytes at `off` into the caller's buffer, which is in the
// CURRENT address space -- at a syscall that is the caller's, at boot the
// kernel's.  Returns the number of bytes copied.  A hole reads as zeros.
def yfs_read(ino: long, off: long, buf: long, len: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let size = yfs_size(ino);
    // off == size is allowed: that is a write AT THE END, which yfs_append uses after
    // it has already moved the size.  Only a write strictly past the end is refused.
    if (off > size) { return 0; };
    if (off + len > size) { len = size - off; };
    let done = 0;
    while (done < len) {
        let pos = off + done;
        let blk = yfs_block_of(ino, pos);
        let bo = pos % yfs_block_size;
        let n = yfs_block_size - bo;
        if (n > len - done) { n = len - done; };
        if (blk == 0) {
            kmem.kzero(buf + done, n);
        } else {
            let src = blk * yfs_block_size + bo;
            kmem.kcopy(buf + done, kmem.DIRECT_BASE + yfs_phys + src, n);
        };
        done = done + n;
    };
    done
};

/** Write `len` bytes from the caller's buffer (current address space) at `off`,
 *  allocating blocks and growing the file.  A gap past the old end is a hole.
 *  The count written (short when the image fills), or -28 when nothing fit. */
def yfs_write(ino: long, off: long, buf: long, len: long) -> long {
    if (yfs_ok == 0) { return -1; };
    if (len <= 0) { return 0; };
    if (off < 0 || off + len > 4294967295) { return -27; };
    let done = 0;
    while (done < len) {
        let pos = off + done;
        let blk = yfs_bmap(ino, pos / yfs_block_size);
        if (blk < 0) { break; };
        let bo = pos % yfs_block_size;
        let n = yfs_block_size - bo;
        if (n > len - done) { n = len - done; };
        kmem.kcopy(kmem.DIRECT_BASE + yfs_phys + blk * yfs_block_size + bo, buf + done, n);
        done = done + n;
    };
    if (done == 0) { return -28; };
    if (off + done > yfs_size(ino)) { yfs_set_size(ino, off + done); };
    done
};

// ── names and directories ───────────────────────────────────────────────
// `addr` is an offset INTO THE IMAGE, like the offsets yfs_u16/yfs_u32 take:
// the image address is added here.  (It was missed once, and the symptom was a
// name compare that read physical 520 instead of image+520.)
// Does the entry at image offset `e` name path[a..b)?  Bounds rather than a
// substring, so no string slicing is needed for a path walk.
def yfs_name_is(e: long, path: str, a: long, b: long) -> bool {
    if (yfs_u16(e) != b - a) { return false; };
    let i = 0;
    while (i < b - a) {
        if (kmem.peek8(yfs_phys + e + 8 + i) != byte_at(path, a + i)) { return false; };
        i = i + 1;
    };
    true
};

def yfs_stride(nl: long) -> long {
    (8 + nl + 3) & (-4)
};

// In-block offset just past the last entry of directory block `blk`.
def yfs_dir_end(blk: long) -> long {
    let o = 0;
    while (o + 8 <= yfs_block_size) {
        let nl = yfs_u16(blk * yfs_block_size + o);
        if (nl == 0) { break; };
        o = o + yfs_stride(nl);
    };
    o
};

/** The image offset of the entry of `dir` that names path[a..b), or 0. */
def yfs_dir_entry(dir: long, path: str, a: long, b: long) -> long {
    if (yfs_ok == 0 || yfs_type(dir) != YFS_DIR) { return 0; };
    let bi = 0;
    while (true) {
        let blk = yfs_bget(dir, bi);
        if (blk == 0) { return 0; };
        let o = 0;
        while (o + 8 <= yfs_block_size) {
            let e = blk * yfs_block_size + o;
            let nl = yfs_u16(e);
            if (nl == 0) { break; };
            if (nl == b - a && yfs_name_is(e, path, a, b)) { return e; };
            o = o + yfs_stride(nl);
        };
        bi = bi + 1;
    };
    0
};

def yfs_find_in(dir: long, path: str, a: long, b: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let e = yfs_dir_entry(dir, path, a, b);
    if (e == 0) { return -1; };
    yfs_u32(e + 4)
};

// One component, in the root directory.
def yfs_lookup(name: str) -> long {
    yfs_find_in(yfs_root, name, 0, len(name))
};

// A '/'-separated path, absolute or relative to the root.  Empty components
// (leading, trailing and doubled slashes) are skipped; "." stays and ".." goes up.
def yfs_lookup_path(path: str) -> long {
    let cur = yfs_root;
    let i = 0;
    while (i < len(path)) {
        while (i < len(path) && byte_at(path, i) == 47) { i = i + 1; };
        if (i >= len(path)) { break; };
        let j = i;
        while (j < len(path) && byte_at(path, j) != 47) { j = j + 1; };
        if (j - i == 1 && byte_at(path, i) == 46) {
            // "."
        } else if (j - i == 2 && byte_at(path, i) == 46 && byte_at(path, i + 1) == 46) {
            if (yfs_type(cur) != YFS_DIR) { return -1; };
            cur = yfs_parent(cur);
        } else {
            cur = yfs_find_in(cur, path, i, j);
            if (cur < 0) { return -1; };
        };
        i = j;
    };
    cur
};

/** The entry after the one at image offset `e` (0 = the first) of directory
 *  `dir`, as an image offset; 0 at the end. */
def yfs_dir_next(dir: long, e: long) -> long {
    if (yfs_ok == 0 || yfs_type(dir) != YFS_DIR) { return 0; };
    let bs = yfs_block_size;
    let blk = 0;
    let o = 0;
    if (e == 0) {
        blk = yfs_bget(dir, 0);
        if (blk == 0) { return 0; };
    } else {
        blk = e / bs;
        o = (e % bs) + yfs_stride(yfs_u16(e));
        if (o + 8 <= bs && yfs_u16(blk * bs + o) != 0) { return blk * bs + o; };
        // the next block of the directory after `blk`
        let bi = 0;
        while (yfs_bget(dir, bi) != blk) {
            if (yfs_bget(dir, bi) == 0) { return 0; };
            bi = bi + 1;
        };
        blk = yfs_bget(dir, bi + 1);
        o = 0;
    };
    while (blk != 0) {
        if (yfs_u16(blk * bs) != 0) { return blk * bs; };
        // an emptied block: on to the next one
        let bj = 0;
        while (yfs_bget(dir, bj) != blk) { bj = bj + 1; };
        blk = yfs_bget(dir, bj + 1);
    };
    0
};

// The entry at `index`: its name is copied into the caller's buffer and its
// length returned, or -1 when there is no such entry.  yfs_dir_inode gives the
// same entry's inode; a path walk and `ls` are these two plus yfs_lookup.
def yfs_entry_off(ino: long, index: long) -> long {
    let e = yfs_dir_next(ino, 0);
    let i = 0;
    while (e != 0 && i < index) {
        e = yfs_dir_next(ino, e);
        i = i + 1;
    };
    e
};

def yfs_dir_count(ino: long) -> long {
    yfs_u32(yfs_inode_off(ino) + 4)
};

def yfs_readdir(ino: long, index: long, buf: long) -> long {
    if (yfs_ok == 0 || index >= yfs_dir_count(ino)) { return -1; };
    let e = yfs_entry_off(ino, index);
    if (e == 0) { return -1; };
    let nl = yfs_u16(e);
    if (nl == 0) { return -1; };
    kmem.kcopy(buf, kmem.DIRECT_BASE + yfs_phys + e + 8, nl);
    nl
};

def yfs_dir_inode(ino: long, index: long) -> long {
    if (yfs_ok == 0 || index >= yfs_dir_count(ino)) { return -1; };
    let e = yfs_entry_off(ino, index);
    if (e == 0) { return -1; };
    yfs_u32(e + 4)
};

// One byte of a file, BY VALUE.  yfs_read pokes into a virtual address in the
// CALLER's space, which execve cannot use while it is building another address
// space -- it has physical destinations and no VA for them.  This returns the byte
// instead, so a caller can place it with poke8 (physical) anywhere it likes.
def yfs_fetch(ino: long, off: long) -> long {
    if (yfs_ok == 0) { return -1; };
    if (off >= yfs_size(ino)) { return -1; };
    let blk = yfs_block_of(ino, off);
    if (blk == 0) { return 0; };
    kmem.peek8(yfs_phys + blk * yfs_block_size + off % yfs_block_size)
};

// The write counterpart of yfs_read, in the same physical terms as yfs_fetch: the
// bytes come FROM the caller's memory and go INTO the image.  It writes within
// the file's existing size; yfs_write grows a file.
def yfs_store(ino: long, off: long, buf: long, len: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let size = yfs_size(ino);
    if (off >= size) { return 0; };
    if (off + len > size) { len = size - off; };
    yfs_write(ino, off, buf, len)
};

def yfs_recompute_next() -> void {
    let bs = yfs_block_size;
    let per = bs / 4;
    // the superblock and the inode table are never data
    let m = (yfs_inodes * 64 + bs - 1) / bs;
    if (yfs_u32(24) - 1 > m) { m = yfs_u32(24) - 1; };
    let i = 1;
    while (i < yfs_inodes) {
        let base = yfs_inode_off(i);
        let t = yfs_u32(base) & 255;
        if (t == YFS_REG || t == YFS_DIR) {
            let d = 0;
            while (d < 12) {
                let b = yfs_u32(base + 8 + d * 4);
                if (b > m) { m = b; };
                d = d + 1;
            };
            let ind = yfs_u32(base + 56);
            if (ind > m) { m = ind; };
            if (ind != 0) {
                let e = 0;
                while (e < per) {
                    let b2 = yfs_u32(ind * bs + e * 4);
                    if (b2 > m) { m = b2; };
                    e = e + 1;
                };
            };
            let dd = 0;
            if (t == YFS_REG) { dd = yfs_u32(base + 60); };
            if (dd > m) { m = dd; };
            if (dd != 0) {
                let j = 0;
                while (j < per) {
                    let l1 = yfs_u32(dd * bs + j * 4);
                    if (l1 > m) { m = l1; };
                    if (l1 != 0) {
                        let k = 0;
                        while (k < per) {
                            let b3 = yfs_u32(l1 * bs + k * 4);
                            if (b3 > m) { m = b3; };
                            k = k + 1;
                        };
                    };
                    j = j + 1;
                };
            };
        };
        i = i + 1;
    };
    yfs_next = m + 1;
};

// Append `len` bytes to a file, allocating blocks as needed and updating the size.
def yfs_append(ino: long, buf: long, len: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let n = yfs_write(ino, yfs_size(ino), buf, len);
    if (n != len) { return -1; };
    len
};

/** Put an entry for an EXISTING inode in `dir`; the name may start with a slash.
 *  The inode, or -1 (-28 when the image is full, -36 for a name over 255). */
def yfs_link(dir: long, name: str, ino: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let st = 0;
    if (len(name) > 0 && byte_at(name, 0) == 47) { st = 1; };
    let n = len(name) - st;
    if (n <= 0 || yfs_type(dir) != YFS_DIR) { return -1; };
    if (n > 255) { return -36; };
    let stride = yfs_stride(n);
    if (stride > yfs_block_size) { return -1; };
    let bs = yfs_block_size;
    let bi = 0;
    let blk = 0;
    let o = 0;
    while (true) {
        blk = yfs_bget(dir, bi);
        if (blk == 0) {
            blk = yfs_bmap(dir, bi);
            if (blk < 0) { return -28; };
            o = 0;
            break;
        };
        o = yfs_dir_end(blk);
        if (o + stride <= bs) { break; };
        bi = bi + 1;
    };
    let e = blk * bs + o;
    yfs_w16(e, n);
    yfs_w16(e + 2, 1);
    yfs_w32(e + 4, ino);
    let k = 0;
    while (k < n) { kmem.poke8(yfs_phys + e + 8 + k, byte_at(name, st + k)); k = k + 1; };
    let base = yfs_inode_off(dir);
    yfs_w32(base + 4, yfs_u32(base + 4) + 1);
    ino
};

/** Remove the entry `name` from `dir` (the inode itself is untouched): the inode
 *  it named, or -1. */
def yfs_dir_remove(dir: long, name: str) -> long {
    if (yfs_ok == 0) { return -1; };
    let st = 0;
    if (len(name) > 0 && byte_at(name, 0) == 47) { st = 1; };
    let e = yfs_dir_entry(dir, name, st, len(name));
    if (e == 0) { return -1; };
    let bs = yfs_block_size;
    let blk = e / bs;
    let o = e % bs;
    let ino = yfs_u32(e + 4);
    let stride = yfs_stride(yfs_u16(e));
    let end = yfs_dir_end(blk);
    let tail = end - o - stride;
    if (tail > 0) {
        kmem.kcopy(kmem.DIRECT_BASE + yfs_phys + e, kmem.DIRECT_BASE + yfs_phys + e + stride, tail);
    };
    kmem.kzero(kmem.DIRECT_BASE + yfs_phys + blk * bs + end - stride, stride);
    let base = yfs_inode_off(dir);
    yfs_w32(base + 4, yfs_u32(base + 4) - 1);
    ino
};

// Create an inode of type/mode `mode` and enter it as `name` in `dir`; -1 on failure.
// A directory's size field is its ENTRY COUNT, so it starts at 0 like a file's byte
// count does.
def yfs_add_entry(dir: long, name: str, mode: long) -> long {
    if (yfs_ok == 0) { return -1; };
    let ino = yfs_ialloc(mode);
    if (ino < 0) { return -1; };
    if (mode == YFS_DIR) { yfs_set_parent(ino, dir); };
    if (yfs_link(dir, name, ino) < 0) {
        yfs_release(ino);
        return -1;
    };
    ino
};

// Remove a file from the root directory and free it (its blocks too).
def yfs_unlink(name: str) -> long {
    if (yfs_ok == 0) { return -1; };
    let ino = yfs_dir_remove(yfs_root, name);
    if (ino < 0) { return -1; };
    yfs_release(ino);
    0
};

// A file, and a directory, in the root.
def yfs_create(name: str) -> long {
    yfs_add_entry(yfs_root, name, 1)
};

def yfs_mkdir(name: str) -> long {
    yfs_add_entry(yfs_root, name, 2)
};

// Rename in the root: link the inode under the new name, drop the old entry.  The
// file's BLOCKS never move, which is what makes mv cheap.  Renaming onto an existing
// name replaces it, as POSIX says.
def yfs_rename(oldname: str, newname: str) -> long {
    let ino = yfs_lookup_path(oldname);
    if (ino < 0) { return -2; };
    let ex = yfs_lookup_path(newname);
    if (ex == ino) { return 0; };
    if (ex >= 0) { yfs_unlink(newname); };
    let r = yfs_link(yfs_root, newname, ino);
    if (r < 0) { return -1; };
    yfs_dir_remove(yfs_root, oldname);
    0
};
