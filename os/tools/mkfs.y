// mkfs -- pack files into a YFS1 image (the format is in src/y/KERNEL.md).
//
//   mkfs <out.img> <name> <hostpath> [<name> <hostpath> ...]
//
// 4096-byte blocks: superblock, a 256-entry 64-byte inode table, then data.
// Inode 1 is the root directory; files get inodes 2.. in argument order.
import fs;

const BS = 4096;
const INODES = 256;

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

def round4(n: long) -> long { (n + 3) & (0 - 4) };
def blocks_for(n: long) -> long { (n + BS - 1) / BS };

let a = argv();
if (len(a) < 3 || ((len(a) - 2) % 2) != 0) {
    eputs("usage: mkfs <out.img> <name> <hostpath> ...\n");
} else {
    let names: [str] = [];
    let datas: [[byte]] = [];
    let i = 2;
    while (i + 1 < len(a)) {
        let d = fs.read_bytes(a[i + 1]);
        if (d == none) {
            eputs("mkfs: cannot read " + a[i + 1] + "\n");
        } else {
            names += a[i];
            datas += d!;
        };
        i = i + 2;
    };
    let n = len(names);
    let inode_blocks = (INODES * 64 + BS - 1) / BS;
    let data_start = 1 + inode_blocks;
    let total_data = 0;
    let k = 0;
    while (k < n) { total_data = total_data + blocks_for(len(datas[k])); k = k + 1; };
    let root_block = data_start;
    let total = data_start + 1 + total_data;
    let img: [byte] = [];
    let z = 0;
    while (z < total * BS) { img += 0; z = z + 1; };
    img[0] = 89; img[1] = 70; img[2] = 83; img[3] = 49;
    put32(img, 4, 1);
    put32(img, 8, BS);
    put32(img, 12, total);
    put32(img, 16, INODES);
    put32(img, 20, 1);
    put32(img, 24, data_start);
    let root_off = BS + 64;
    put32(img, root_off, 2);
    put32(img, root_off + 4, n);
    put32(img, root_off + 8, root_block);
    let eoff = root_block * BS;
    let blk = root_block + 1;
    let j = 0;
    while (j < n) {
        let nm = names[j];
        put16(img, eoff, len(nm));
        put16(img, eoff + 2, 1);
        put32(img, eoff + 4, j + 2);
        let c = 0;
        while (c < len(nm)) { img[eoff + 8 + c] = nm[c]; c = c + 1; };
        eoff = eoff + round4(8 + len(nm));
        let foff = BS + (j + 2) * 64;
        put32(img, foff, 1);
        put32(img, foff + 4, len(datas[j]));
        put32(img, foff + 8, blk);
        let off = blk * BS;
        let c2 = 0;
        while (c2 < len(datas[j])) { img[off + c2] = datas[j][c2]; c2 = c2 + 1; };
        blk = blk + blocks_for(len(datas[j]));
        j = j + 1;
    };
    if (fs.write_bytes(a[1], img)) { eputs("mkfs: " + a[1] + " written\n"); }
    else { eputs("mkfs: cannot write " + a[1] + "\n"); };
};
