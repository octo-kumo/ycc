// mkfs -- pack files into a YFS1 image (the format is in std/yfs.y and src/y/KERNEL.md).
//
//   mkfs <out.img> <name> <hostpath> [<name> <hostpath> | -d <dir> | -c <name> <dev> ...]
//
// Names are paths in the image, with or without the leading slash; the directories
// on the way are made as needed (`a/b/c` makes `a` and `a/b`).  `-d dir` asks for
// an (empty) directory, `-c name dev` for a character device node (dev = 1 tty,
// 2 null, 3 zero, 4 dsp, 5 fb0, 6 input; /dev/tty, /dev/null, /dev/zero, /dev/dsp, /dev/fb0
// and /dev/input are always made).
//
// 4096-byte blocks: superblock, a 4096-entry 64-byte inode table, then data.  Inode 1
// is the root directory; the rest are handed out in argument order.  A file's blocks
// are twelve direct, one single-indirect and one double-indirect (files up to
// about 4 GiB); a directory's entries live in as many blocks as they need.
import fs;

const BS = 4096;
const INODES = 4096;
const SPARE = 4096;      // free blocks (16 MiB) at the end of the image
const PER = 1024;        // block numbers per index block

// inode types (low byte of the mode word)
const T_REG = 1;
const T_DIR = 2;
const T_CHR = 3;

let itab: [byte] = [];   // the inode table
let data: [byte] = [];   // the data blocks, block DATA_START first
let zero_block: [byte] = [];
let next_ino = 2;
let dir_paths: [str] = [];   // "" is the root
let dir_inos: [long] = [];
let dir_tail: [long] = [];   // by inode: where the next entry goes in the last block
let dir_nblk: [long] = [];   // by inode: blocks of entries so far
let failed = false;

const DATA_START = 65;       // 1 superblock block + 64 inode table blocks

def put32(b: [byte], off: long, v: long) -> void {
    b[off] = v & 255;
    b[off + 1] = (v >> 8) & 255;
    b[off + 2] = (v >> 16) & 255;
    b[off + 3] = (v >> 24) & 255;
};

def put16(b: [byte], off: long, v: long) -> void {
    b[off] = v & 255;
    b[off + 1] = (v >> 8) & 255;
};

def get32(b: [byte], off: long) -> long {
    b[off] + b[off + 1] * 256 + b[off + 2] * 65536 + b[off + 3] * 16777216
};

def num(s: str) -> long {
    let v = 0;
    let i = 0;
    while (i < len(s)) { v = v * 10 + s[i] - 48; i = i + 1; };
    v
};

def round4(n: long) -> long { (n + 3) & (0 - 4) };

/** A new zeroed data block: its number. */
def alloc_block() -> long {
    data += zero_block;
    DATA_START + len(data) / BS - 1
};

def inode_off(ino: long) -> long { ino * 64 };

/** The block number stored in the slot at data offset `o` (allocating when empty). */
def slot_block(o: long) -> long {
    let b = get32(data, o);
    if (b == 0) {
        b = alloc_block();
        put32(data, o, b);
    };
    b
};

def data_off(blk: long) -> long { (blk - DATA_START) * BS };

/** Make block `bi` of inode `ino` be `blk`, allocating the index blocks. */
def map_block(ino: long, bi: long, blk: long) -> void {
    let io = inode_off(ino);
    if (bi < 12) {
        put32(itab, io + 8 + bi * 4, blk);
    } else if (bi < 12 + PER) {
        let ind = get32(itab, io + 56);
        if (ind == 0) { ind = alloc_block(); put32(itab, io + 56, ind); };
        put32(data, data_off(ind) + (bi - 12) * 4, blk);
    } else {
        let r = bi - 12 - PER;
        let d = get32(itab, io + 60);
        if (d == 0) { d = alloc_block(); put32(itab, io + 60, d); };
        let l1 = slot_block(data_off(d) + (r / PER) * 4);
        put32(data, data_off(l1) + (r % PER) * 4, blk);
    };
};

def block_of(ino: long, bi: long) -> long {
    let io = inode_off(ino);
    if (bi < 12) { return get32(itab, io + 8 + bi * 4); };
    let ind = get32(itab, io + 56);
    if (ind == 0) { return 0; };
    get32(data, data_off(ind) + (bi - 12) * 4)
};

def new_inode(mode: long) -> long {
    let ino = next_ino;
    next_ino = next_ino + 1;
    put32(itab, inode_off(ino), mode);
    ino
};

/** Enter `name` -> `ino` into directory `dino`. */
def dir_add(dino: long, name: str, ino: long, ty: long) -> void {
    let stride = round4(8 + len(name));
    let io = inode_off(dino);
    if (dir_nblk[dino] == 0 || dir_tail[dino] + stride > BS) {
        let blk = alloc_block();
        map_block(dino, dir_nblk[dino], blk);
        dir_nblk[dino] = dir_nblk[dino] + 1;
        dir_tail[dino] = 0;
    };
    let blk = block_of(dino, dir_nblk[dino] - 1);
    let e = data_off(blk) + dir_tail[dino];
    put16(data, e, len(name));
    put16(data, e + 2, ty);
    put32(data, e + 4, ino);
    let c = 0;
    while (c < len(name)) { data[e + 8 + c] = name[c]; c = c + 1; };
    dir_tail[dino] = dir_tail[dino] + stride;
    put32(itab, io + 4, get32(itab, io + 4) + 1);
};

def lookup_dir(path: str) -> long {
    let i = 0;
    while (i < len(dir_paths)) {
        if (dir_paths[i] == path) { return dir_inos[i]; };
        i = i + 1;
    };
    0
};

/** Find the entry `name` in `dino`: its inode, or 0. */
def dir_find(dino: long, name: str) -> long {
    let nb = dir_nblk[dino];
    let bi = 0;
    while (bi < nb) {
        let o = data_off(block_of(dino, bi));
        let end = if (bi == nb - 1) { dir_tail[dino] } else { BS };
        let p = 0;
        while (p + 8 <= end) {
            let nl = data[o + p] + data[o + p + 1] * 256;
            if (nl == 0) { break; };
            if (nl == len(name)) {
                let same = true;
                let c = 0;
                while (c < nl) { if (data[o + p + 8 + c] != name[c]) { same = false; }; c = c + 1; };
                if (same) { return get32(data, o + p + 4); };
            };
            p = p + round4(8 + nl);
        };
        bi = bi + 1;
    };
    0
};

def new_dir(parent: long, name: str, path: str) -> long {
    let ino = new_inode(T_DIR);
    put32(itab, inode_off(ino) + 60, parent);
    while (len(dir_nblk) <= ino) { dir_nblk += 0; dir_tail += 0; };
    dir_paths += path;
    dir_inos += ino;
    dir_add(parent, name, ino, T_DIR);
    ino
};

/** Split "a/b/c" (leading slashes dropped) into its components. */
def components(name: str) -> [str] {
    let out: [str] = [];
    let cur = "";
    let i = 0;
    while (i < len(name)) {
        if (name[i] == 47) {
            if (len(cur) > 0) { out += cur; cur = ""; };
        } else {
            cur += chr(name[i]);
        };
        i = i + 1;
    };
    if (len(cur) > 0) { out += cur; };
    out
};

/** The directory inode of the first n components of `parts`, making the missing ones. */
def ensure_dirs(parts: [str], n: long) -> long {
    let cur = 1;
    let path = "";
    let i = 0;
    while (i < n) {
        path = path + "/" + parts[i];
        let d = lookup_dir(path);
        if (d == 0) {
            if (dir_find(cur, parts[i]) != 0) {
                eputs("mkfs: " + path + " exists and is not a directory\n");
                failed = true;
                return 0;
            };
            d = new_dir(cur, parts[i], path);
        };
        cur = d;
        i = i + 1;
    };
    cur
};

def add_file(name: str, bytes: [byte]) -> void {
    let parts = components(name);
    if (len(parts) == 0) { eputs("mkfs: empty name\n"); failed = true; return; };
    let par = ensure_dirs(parts, len(parts) - 1);
    if (par == 0) { return; };
    let last = parts[len(parts) - 1];
    if (dir_find(par, last) != 0) { eputs("mkfs: " + name + " given twice\n"); failed = true; return; };
    let ino = new_inode(T_REG);
    let io = inode_off(ino);
    let nb = (len(bytes) + BS - 1) / BS;
    let bi = 0;
    while (bi < nb) {
        let blk = alloc_block();
        map_block(ino, bi, blk);
        let o = data_off(blk);
        let from = bi * BS;
        let n = len(bytes) - from;
        if (n > BS) { n = BS; };
        let c = 0;
        while (c < n) { data[o + c] = bytes[from + c]; c = c + 1; };
        bi = bi + 1;
    };
    put32(itab, io + 4, len(bytes));
    dir_add(par, last, ino, T_REG);
};

def add_dir(name: str) -> void {
    let parts = components(name);
    if (len(parts) == 0) { return; };
    ensure_dirs(parts, len(parts));
};

def add_dev(name: str, dev: long) -> void {
    let parts = components(name);
    if (len(parts) == 0) { return; };
    let par = ensure_dirs(parts, len(parts) - 1);
    if (par == 0) { return; };
    let last = parts[len(parts) - 1];
    if (dir_find(par, last) != 0) { return; };
    let ino = new_inode(T_CHR + dev * 256);
    dir_add(par, last, ino, T_CHR);
};

let a = argv();
if (len(a) < 2) {
    eputs("usage: mkfs <out.img> <name> <hostpath> | -d <dir> | -c <name> <dev> ...\n");
} else {
    let z = 0;
    while (z < BS) { zero_block += 0; z = z + 1; };
    z = 0;
    while (z < INODES * 64) { itab += 0; z = z + 1; };
    // the root directory
    put32(itab, inode_off(1), T_DIR);
    while (len(dir_nblk) <= 1) { dir_nblk += 0; dir_tail += 0; };
    dir_paths += "";
    dir_inos += 1;
    let i = 2;
    while (i + 1 < len(a)) {
        if (a[i] == "-d") {
            add_dir(a[i + 1]);
        } else if (a[i] == "-c") {
            if (i + 2 < len(a)) { add_dev(a[i + 1], num(a[i + 2])); };
            i = i + 1;
        } else {
            let d: [byte]? = fs.read_bytes(a[i + 1]);
            if (d == none) {
                eputs("mkfs: cannot read " + a[i + 1] + "\n");
                failed = true;
            } else {
                add_file(a[i], d!);
            };
        };
        i = i + 2;
    };
    // the standard devices, unless the manifest made them already
    add_dev("dev/tty", 1);
    add_dev("dev/null", 2);
    add_dev("dev/zero", 3);
    add_dev("dev/dsp", 4);
    add_dev("dev/fb0", 5);
    add_dev("dev/input", 6);
    if (next_ino > INODES) { eputs("mkfs: more than " + tostring(INODES) + " inodes\n"); failed = true; };
    let total = DATA_START + len(data) / BS + SPARE;
    let img: [byte] = [];
    let sb = zero_block + [];
    img += sb;
    put32(img, 0, 89 + 70 * 256 + 83 * 65536 + 49 * 16777216);
    put32(img, 4, 1);
    put32(img, 8, BS);
    put32(img, 12, total);
    put32(img, 16, INODES);
    put32(img, 20, 1);
    put32(img, 24, DATA_START);
    img += itab;
    img += data;
    let s = 0;
    while (s < SPARE) { img += zero_block; s = s + 1; };
    if (failed) {
        eputs("mkfs: failed\n");
        exit(1);
    } else if (fs.write_bytes(a[1], img)) { eputs("mkfs: " + a[1] + " written\n"); }
    else { eputs("mkfs: cannot write " + a[1] + "\n"); exit(1); };
};
