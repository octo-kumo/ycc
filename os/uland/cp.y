// cp [-r] src... dst -- copy files; into dst when it is a directory; -r copies directories.
import ulib;

def join_path(dir: str, name: str) -> str {
    if (dir[len(dir) - 1] == 47) { dir + name } else { dir + "/" + name }
};

def base(p: str) -> str {
    let e = len(p);
    while (e > 1 && p[e - 1] == 47) { e = e - 1; };
    let k = e;
    while (k > 0 && p[k - 1] != 47) { k = k - 1; };
    p[k:e]
};

/** Copy the file `src` to `dst`, replacing it. */
def copy_file(src: str, dst: str) -> bool {
    let d = ulib.read_all(src);
    if (d == none) { puts("cp: " + src + ": no such file\n"); return false; };
    // replace rather than truncate: the same on every kernel
    ulib.unlink(dst);
    let fd = ulib.open(dst, ulib.O_CREAT | ulib.O_WRONLY | ulib.O_TRUNC);
    if (fd < 0) { puts("cp: cannot create " + dst + "\n"); return false; };
    let w = ulib.write_bytes(fd, d!);
    ulib.close(fd);
    if (w < 0) { puts("cp: write failed (the disk is full?)\n"); return false; };
    true
};

def copy_tree(src: str, dst: str) -> bool {
    if (!ulib.is_dir(src)) { return copy_file(src, dst); };
    if (!ulib.is_dir(dst) && ulib.mkdir(dst) < 0) { puts("cp: cannot create " + dst + "\n"); return false; };
    let ok = true;
    let ents = ulib.read_dir(src);
    ents!.foreach((e) => {
        if (e.name != "." && e.name != "..") {
            if (!copy_tree(join_path(src, e.name), join_path(dst, e.name))) { ok = false; };
        };
    });
    ok
};

let a = argv();
let rec = false;
let paths: [str] = [];
let i = 1;
while (i < len(a)) {
    if (a[i] == "-r" || a[i] == "-R") { rec = true; } else { paths += a[i]; };
    i = i + 1;
};
if (len(paths) < 2) {
    puts("usage: cp [-r] <src>... <dst>\n");
    exit(1);
};
let dst = paths[len(paths) - 1];
let into = ulib.is_dir(dst);
if (len(paths) > 2 && !into) {
    puts("cp: " + dst + ": not a directory\n");
    exit(1);
};
let bad = 0;
let k = 0;
while (k < len(paths) - 1) {
    let src = paths[k];
    let to = if (into) { join_path(dst, base(src)) } else { dst };
    let ok = if (ulib.is_dir(src)) {
        if (rec) { copy_tree(src, to) } else { puts("cp: " + src + ": is a directory (use -r)\n"); false }
    } else { copy_file(src, to) };
    if (!ok) { bad = 1; };
    k = k + 1;
};
exit(bad);
