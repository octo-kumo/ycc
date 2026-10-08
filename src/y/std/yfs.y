// YFS1 in the kernel.  The format is specified in src/y/KERNEL.md: a
// superblock, a 64-byte inode table and data blocks, all read straight out of
// the image's physical memory (the multiboot module today, a page the fs server
// mapped later).  The path walk, the fd broker and the fs server build on these.

let yfs_phys: long = 0;
let yfs_ok: long = 0;
let yfs_total: long = 0;
let yfs_inodes: long = 0;
// The image's first free block.  A scan rather than a bitmap: images are small and
// it needs no format change.  Indirect blocks count as used, and their CONTENTS are
// scanned too, or a file past twelve blocks would hand out a block that is in use.
let yfs_next: long = 0;
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
    yfs_total = yfs_u32(12);
    yfs_inodes = yfs_u32(16);
    yfs_root = yfs_u32(20);
    yfs_recompute_next();
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
    // off == size is allowed: that is a write AT THE END, which yfs_append uses after
    // it has already moved the size.  Only a write strictly past the end is refused.
    if (off > size) { return 0; };
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
// Does the entry at image offset `e` name path[a..b)?  Bounds rather than a
// substring, so no string slicing is needed for a path walk.
def yfs_name_is(e: long, path: str, a: long, b: long) -> bool {
    if (yfs_u16(e) != b - a) { return false; };
    let i = 0;
    while (i < b - a) {
        if (kernel.peek8(yfs_phys + e + 8 + i) != path[a + i]) { return false; };
        i = i + 1;
    };
    true
};

def yfs_find_in(dir: long, path: str, a: long, b: long) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    let count = yfs_dir_count(dir);
    let idx = 0;
    while (idx < count) {
        let e = yfs_entry_off(dir, idx);
        if (e == 0) { return 0 - 1; };
        if (yfs_name_is(e, path, a, b)) { return yfs_u32(e + 4); };
        idx = idx + 1;
    };
    0 - 1
};

// One component, in the root directory.
def yfs_lookup(name: str) -> long {
    yfs_find_in(yfs_root, name, 0, len(name))
};

// A '/'-separated path, absolute or relative to the root.  Empty components
// (leading, trailing and doubled slashes) are skipped.
def yfs_lookup_path(path: str) -> long {
    let cur = yfs_root;
    let i = 0;
    while (i < len(path)) {
        while (i < len(path) && path[i] == 47) { i = i + 1; };
        if (i >= len(path)) { break; };
        let j = i;
        while (j < len(path) && path[j] != 47) { j = j + 1; };
        cur = yfs_find_in(cur, path, i, j);
        if (cur < 0) { return 0 - 1; };
        i = j;
    };
    cur
};

// The entry at `index`: its name is copied into the caller's buffer and its
// length returned, or -1 when there is no such entry.  yfs_dir_inode gives the
// same entry's inode; a path walk and `ls` are these two plus yfs_lookup.
def yfs_entry_off(ino: long, index: long) -> long {
    let base = yfs_inode_off(ino);
    let blk = yfs_u32(base + 8);
    if (blk == 0) { return 0; };
    let e = blk * yfs_block_size;
    let i = 0;
    while (i < index) {
        let nl = yfs_u16(e);
        if (nl == 0) { return 0; };
        e = e + ((8 + nl + 3) & (0 - 4));
        i = i + 1;
    };
    e
};

def yfs_dir_count(ino: long) -> long {
    yfs_u32(yfs_inode_off(ino) + 4)
};

def yfs_readdir(ino: long, index: long, buf: long) -> long {
    if (yfs_ok == 0 || index >= yfs_dir_count(ino)) { return 0 - 1; };
    let e = yfs_entry_off(ino, index);
    if (e == 0) { return 0 - 1; };
    let nl = yfs_u16(e);
    if (nl == 0) { return 0 - 1; };
    let k = 0;
    while (k < nl) {
        kernel.poke_va8(buf + k, kernel.peek8(yfs_phys + e + 8 + k));
        k = k + 1;
    };
    nl
};

def yfs_dir_inode(ino: long, index: long) -> long {
    if (yfs_ok == 0 || index >= yfs_dir_count(ino)) { return 0 - 1; };
    let e = yfs_entry_off(ino, index);
    if (e == 0) { return 0 - 1; };
    yfs_u32(e + 4)
};

// One byte of a file, BY VALUE.  yfs_read pokes into a virtual address in the
// CALLER's space, which execve cannot use while it is building another address
// space -- it has physical destinations and no VA for them.  This returns the byte
// instead, so a caller can place it with poke8 (physical) anywhere it likes.
def yfs_fetch(ino: long, off: long) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    if (off >= yfs_size(ino)) { return 0 - 1; };
    let blk = yfs_block_of(ino, off);
    if (blk == 0) { return 0 - 1; };
    kernel.peek8(yfs_phys + blk * yfs_block_size + off % yfs_block_size)
};

// The write counterpart of yfs_read, in the same physical terms as yfs_fetch: the
// bytes come FROM the caller's memory (peek_va8) and go INTO the image (poke8).
// It writes within the file's existing size -- growing a file needs an allocator,
// which is the next step.
def yfs_store(ino: long, off: long, buf: long, len: long) -> long {
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
        let d = blk * yfs_block_size + bo;
        kernel.poke8(yfs_phys + d, kernel.peek_va8(buf + done));
        done = done + 1;
    };
    done
};

def yfs_recompute_next() -> void {
    let m = 0;
    let i = 1;
    while (i < yfs_inodes) {
        let base = yfs_inode_off(i);
        if (yfs_u32(base) != 0) {
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
                while (e < yfs_block_size / 4) {
                    let b2 = yfs_u32(ind * yfs_block_size + e * 4);
                    if (b2 > m) { m = b2; };
                    e = e + 1;
                };
            };
        };
        i = i + 1;
    };
    yfs_next = m + 1;
};

// Append `len` bytes to a file, allocating blocks as needed and updating the size.
// The blocks are attached FIRST, then the size moves, then yfs_store can write them
// because they are inside the file.
def yfs_append(ino: long, buf: long, len: long) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    let size = yfs_size(ino);
    let base = yfs_inode_off(ino);
    let have = (size + yfs_block_size - 1) / yfs_block_size;
    let want = (size + len + yfs_block_size - 1) / yfs_block_size;
    let bi = have;
    while (bi < want) {
        let b = yfs_next;
        yfs_next = yfs_next + 1;
        if (bi < 12) {
            kernel.poke32(yfs_phys + base + 8 + bi * 4, b);
        } else {
            let ind = yfs_u32(base + 56);
            if (ind == 0) {
                ind = yfs_next;
                yfs_next = yfs_next + 1;
                kernel.poke32(yfs_phys + base + 56, ind);
            };
            kernel.poke32(yfs_phys + ind * yfs_block_size + (bi - 12) * 4, b);
        };
        bi = bi + 1;
    };
    kernel.poke32(yfs_phys + base + 4, size + len);
    let n = yfs_store(ino, size, buf, len);
    if (n != len) { return 0 - 1; };
    len
};

// Create an empty file named `name` in the root directory and return its inode, or
// -1.  This is the first half of write support that can ADD something: a free inode
// gets mode/size/empty block list, and the directory gains one entry at the end of
// its entry list (its size field is the ENTRY COUNT for a directory), reusing the
// 4-byte stride rule the reader walks.
def yfs_add_entry(dir: long, name: str, mode: long) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    // a free inode: mode 0, never used
    let ino = 0 - 1;
    let i = 1;
    while (i < yfs_inodes) {
        if (yfs_u32(yfs_inode_off(i)) == 0) { ino = i; i = yfs_inodes; } else { i = i + 1; };
    };
    if (ino < 0) { return 0 - 1; };
    let base = yfs_inode_off(ino);
    kernel.poke32(yfs_phys + base, mode);
    kernel.poke32(yfs_phys + base + 4, 0);      // size 0
    // the root directory's entry list: walk past the entries already there
    let rbase = yfs_inode_off(dir);
    let count = yfs_u32(rbase + 4);
    let blk = yfs_u32(rbase + 8);
    if (blk == 0) {
        blk = yfs_next;
        yfs_next = yfs_next + 1;
        kernel.poke32(yfs_phys + rbase + 8, blk);
    };
    let e = blk * yfs_block_size;
    let idx = 0;
    while (idx < count) {
        let nl = yfs_u16(e);
        if (nl == 0) { return 0 - 1; };
        e = e + ((8 + nl + 3) & (0 - 4));
        idx = idx + 1;
    };
    kernel.poke8(yfs_phys + e, len(name) & 255);
    kernel.poke8(yfs_phys + e + 1, (len(name) >> 8) & 255);
    kernel.poke8(yfs_phys + e + 2, 1);
    kernel.poke8(yfs_phys + e + 3, 0);
    kernel.poke32(yfs_phys + e + 4, ino);
    let k = 0;
    while (k < len(name)) { kernel.poke8(yfs_phys + e + 8 + k, name[k] & 255); k = k + 1; };
    kernel.poke32(yfs_phys + rbase + 4, count + 1);
    ino
};

// Remove a file from the root directory: free its inode and SHIFT the entries that
// follow it down over it, then shrink the count.  Shifting rather than marking the
// entry dead, because a reader stops at a zero name_len and would lose everything
// after the hole.
def yfs_unlink(name: str) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    let rbase = yfs_inode_off(yfs_root);
    let count = yfs_u32(rbase + 4);
    let blk = yfs_u32(rbase + 8);
    if (blk == 0) { return 0 - 1; };
    let e = blk * yfs_block_size;
    let idx = 0;
    // A leading slash is not part of the name -- the entries hold "msg", not "/msg" --
    // and byte_at is how a str's characters are read (indexing yields the length).
    let st = 0;
    if (len(name) > 0 && byte_at(name, 0) == 47) { st = 1; };
    while (idx < count) {
        let nl = yfs_u16(e);
        if (nl == 0) { return 0 - 1; };
        if (nl == len(name) - st && yfs_name_is(e, name, st, len(name))) {
            kernel.poke32(yfs_phys + yfs_inode_off(yfs_u32(e + 4)), 0);
            let src = e + ((8 + nl + 3) & (0 - 4));
            let j = idx + 1;
            while (j < count) {
                let sl = yfs_u16(src);
                if (sl == 0) { j = count; } else {
                    let sstride = (8 + sl + 3) & (0 - 4);
                    let k = 0;
                    while (k < sstride) { kernel.poke8(yfs_phys + e + k, kernel.peek8(yfs_phys + src + k)); k = k + 1; };
                    e = e + sstride;
                    src = src + sstride;
                    j = j + 1;
                };
            };
            let t = 0;
            while (t < 8) { kernel.poke8(yfs_phys + e + t, 0); t = t + 1; };
            kernel.poke32(yfs_phys + rbase + 4, count - 1);
            return 0;
        };
        e = e + ((8 + nl + 3) & (0 - 4));
        idx = idx + 1;
    };
    0 - 1
};

// A file, and a directory, in the root.  A directory's size field is its ENTRY COUNT,
// so it starts at 0 like a file's byte count does.
def yfs_create(name: str) -> long {
    yfs_add_entry(yfs_root, name, 1)
};

def yfs_mkdir(name: str) -> long {
    yfs_add_entry(yfs_root, name, 2)
};

// Put an entry for an EXISTING inode in `dir` -- the writing half of yfs_add_entry,
// without allocating an inode.  A leading slash is not part of the name, and a str's
// characters are read with byte_at.
def yfs_link(dir: long, name: str, ino: long) -> long {
    if (yfs_ok == 0) { return 0 - 1; };
    let st = 0;
    if (len(name) > 0 && byte_at(name, 0) == 47) { st = 1; };
    let n = len(name) - st;
    if (n <= 0) { return 0 - 1; };
    let rbase = yfs_inode_off(dir);
    let count = yfs_u32(rbase + 4);
    let blk = yfs_u32(rbase + 8);
    if (blk == 0) {
        blk = yfs_next;
        yfs_next = yfs_next + 1;
        kernel.poke32(yfs_phys + rbase + 8, blk);
    };
    let e = blk * yfs_block_size;
    let idx = 0;
    while (idx < count) {
        let nl = yfs_u16(e);
        if (nl == 0) { return 0 - 1; };
        e = e + ((8 + nl + 3) & (0 - 4));
        idx = idx + 1;
    };
    kernel.poke8(yfs_phys + e, n & 255);
    kernel.poke8(yfs_phys + e + 1, (n >> 8) & 255);
    kernel.poke8(yfs_phys + e + 2, 1);
    kernel.poke8(yfs_phys + e + 3, 0);
    kernel.poke32(yfs_phys + e + 4, ino);
    let k = 0;
    while (k < n) { kernel.poke8(yfs_phys + e + 8 + k, byte_at(name, st + k)); k = k + 1; };
    kernel.poke32(yfs_phys + rbase + 4, count + 1);
    ino
};

// Rename in the root: link the inode under the new name, drop the old entry.  The
// file's BLOCKS never move, which is what makes mv cheap.  Renaming onto an existing
// name replaces it, as POSIX says.
def yfs_rename(oldname: str, newname: str) -> long {
    let ino = yfs_lookup_path(oldname);
    if (ino < 0) { return 0 - 2; };
    let ex = yfs_lookup_path(newname);
    if (ex >= 0) { yfs_unlink(newname); };
    let r = yfs_link(yfs_root, newname, ino);
    if (r < 0) { return 0 - 1; };
    yfs_unlink(oldname)
};
