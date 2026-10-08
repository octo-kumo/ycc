// The fd broker: a small table in the kernel mapping an fd to {inode, offset},
// with YFS1 underneath.  It sits beside the syscalls for now and is shared by
// every task -- per-process tables arrive with the fs server -- and fds 0,1,2 are
// the console, so the first allocated fd is 3.
import yfs from "./yfs.y";

const FD_MAX = 16;

let fd_inode: [long] = [];
let fd_off: [long] = [];
let fd_used: [long] = [];

def fd_reset() -> void {
    fd_inode = [];
    fd_off = [];
    fd_used = [];
};

def fd_open(path: str) -> long {
    let ino = yfs.yfs_lookup_path(path);
    if (ino < 0) { return 0 - 1; };
    let i = 0;
    while (i < len(fd_used)) {
        if (fd_used[i] == 0) {
            fd_used[i] = 1;
            fd_inode[i] = ino;
            fd_off[i] = 0;
            return i + 3;
        };
        i = i + 1;
    };
    if (len(fd_used) >= FD_MAX) { return 0 - 1; };
    fd_used += 1;
    fd_inode += ino;
    fd_off += 0;
    len(fd_used) + 2
};

def fd_valid(fd: long) -> bool {
    let i = fd - 3;
    if (i < 0 || i >= len(fd_used)) { return false; };
    fd_used[i] != 0
};

// Reads at the fd's offset and advances it, so two reads walk the file.
def fd_read(fd: long, buf: long, len: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    let i = fd - 3;
    let n = yfs.yfs_read(fd_inode[i], fd_off[i], buf, len);
    if (n > 0) { fd_off[i] = fd_off[i] + n; };
    n
};

def fd_lseek(fd: long, off: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    fd_off[fd - 3] = off;
    off
};

def fd_close(fd: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    fd_used[fd - 3] = 0;
    0
};

// What a directory listing needs: the inode behind an fd and its position, with
// the position settable so getdents64 can walk a directory across calls.
def fd_ino(fd: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    fd_inode[fd - 3]
};

def fd_tell(fd: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    fd_off[fd - 3]
};

def fd_seek_set(fd: long, off: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    fd_off[fd - 3] = off;
    off
};

// Writes at the fd's offset and advances it, the mirror of fd_read.  The filesystem
// is still read-only in the sense that it cannot GROW a file: this overwrites bytes
// that are already there.
def fd_write(fd: long, buf: long, len: long) -> long {
    if (!fd_valid(fd)) { return 0 - 14; };
    let i = fd - 3;
    let n = yfs.yfs_store(fd_inode[i], fd_off[i], buf, len);
    if (n > 0) { fd_off[i] = fd_off[i] + n; };
    n
};
