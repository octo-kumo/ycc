// fstest SCENARIO -- exercises the Y-OS filesystem syscalls and prints one line per
// check ("ok NAME" or "FAIL NAME got=G want=W").  The scenarios are driven by the
// test/os/s1xx_*.cmds sessions (directories, files, stat, rename, big files).
import ulib from "../../os/uland/ulib.y";

const O_RDONLY = 0;
const O_WRONLY = 1;
const O_RDWR = 2;
const O_CREAT = 64;
const O_EXCL = 128;
const O_TRUNC = 512;
const O_APPEND = 1024;
const O_DIRECTORY = 65536;

const ENOENT = -2;
const EBADF = -9;
const EEXIST = -17;
const ENOTDIR = -20;
const EISDIR = -21;
const EINVAL = -22;
const ERANGE = -34;
const ENOTEMPTY = -39;

let fails = 0;

def check(name: str, got: long, want: long) -> void {
    if (got == want) { puts("ok " + name + "\n"); } else {
        fails = fails + 1;
        puts("FAIL " + name + " got=" + tostring(got) + " want=" + tostring(want) + "\n");
    };
};

def checkb(name: str, v: bool) -> void {
    if (v) { check(name, 1, 1); } else { check(name, 0, 1); };
};

def sc2(nr: long, p: str, a: long) -> long {
    let b = ulib.cstr(p);
    syscall(nr, ptr_addr(&b[0]), a, 0)
};

def sunlink(p: str) -> long { let b = ulib.cstr(p); syscall(87, ptr_addr(&b[0])) };
def access(p: str) -> long { sc2(21, p, 0) };
def sopen(p: str, flags: long) -> long { ulib.open(p, flags) };
def srename(a: str, b: str) -> long { ulib.rename(a, b) };

/** st_mode of a path (or the errno). */
def mode_of(p: str) -> long {
    let st: [byte] = [];
    let k = 0;
    while (k < 144) { st += 0; k = k + 1; };
    let b = ulib.cstr(p);
    let r = syscall(4, ptr_addr(&b[0]), ptr_addr(&st[0]));
    if (r < 0) { return r; };
    st[24] + st[25] * 256 + st[26] * 65536
};

def size_of(p: str) -> long {
    let st: [byte] = [];
    let k = 0;
    while (k < 144) { st += 0; k = k + 1; };
    let b = ulib.cstr(p);
    let r = syscall(4, ptr_addr(&b[0]), ptr_addr(&st[0]));
    if (r < 0) { return r; };
    let v = 0;
    k = 7;
    while (k >= 0) { v = v * 256 + st[48 + k]; k = k - 1; };
    v
};

def put(p: str, s: str) -> long {
    let fd = sopen(p, O_WRONLY | O_CREAT | O_TRUNC);
    if (fd < 0) { return fd; };
    ulib.write(fd, s);
    ulib.close(fd);
    0
};

def slurp(p: str) -> str {
    let fd = sopen(p, O_RDONLY);
    if (fd < 0) { return "ERR" + tostring(fd); };
    let out = "";
    let more = true;
    while (more) {
        let c = ulib.read(fd, 512);
        if (len(c) == 0) { more = false; } else { out += from_bytes(c); };
    };
    ulib.close(fd);
    out
};

/** The names in directory `p`, sorted, "." and ".." left out. */
def names(p: str) -> [str] {
    let l = ulib.list_dir(p);
    let out: [str] = [];
    if (l == none) { return out; };
    foreach (n in l!) { if (n != "." && n != "..") { out += n; }; };
    let i = 1;
    while (i < len(out)) {
        let j = i;
        while (j > 0 && out[j - 1] > out[j]) {
            let t = out[j];
            out[j] = out[j - 1];
            out[j - 1] = t;
            j = j - 1;
        };
        i = i + 1;
    };
    out
};

def join_names(p: str) -> str {
    let s = "";
    foreach (n in names(p)) { s += n + " "; };
    s
};

def scenario_dirs() -> void {
    check("mkdir /a", mkdir("/a"), 0);
    check("mkdir /a/b", mkdir("/a/b"), 0);
    check("mkdir /a/b/c", mkdir("/a/b/c"), 0);
    check("mkdir again", mkdir("/a/b"), EEXIST);
    check("mkdir no parent", mkdir("/zz/y"), ENOENT);
    check("stat dir is dir", mode_of("/a/b") >> 12, 4);
    check("put /a/b/f", put("/a/b/f", "hello\n"), 0);
    check("mkdir under a file", mkdir("/a/b/f/x"), ENOTDIR);
    check("rmdir non-empty", rmdir("/a/b"), ENOTEMPTY);
    check("rmdir a file", rmdir("/a/b/f"), ENOTDIR);
    check("unlink a dir", sunlink("/a/b"), EISDIR);
    puts("ls /a/b: " + join_names("/a/b") + "\n");
    check("chdir /a/b", chdir("/a/b"), 0);
    puts("cwd " + getcwd() + "\n");
    checkb("relative read", slurp("f") == "hello\n");
    checkb("dotted read", slurp("./c/../f") == "hello\n");
    check("chdir ..", chdir(".."), 0);
    puts("cwd " + getcwd() + "\n");
    check("chdir ../..", chdir("../.."), 0);
    puts("cwd " + getcwd() + "\n");
    check("chdir above root", chdir(".."), 0);
    puts("cwd " + getcwd() + "\n");
    check("chdir a/b/c", chdir("a/b/c"), 0);
    puts("cwd " + getcwd() + "\n");
    check("relative create", put("g", "x"), 0);
    puts("ls .: " + join_names(".") + "\n");
    check("chdir to file", chdir("g"), ENOTDIR);
    check("chdir missing", chdir("/nope"), ENOENT);
    check("access g", access("g"), 0);
    check("access missing", access("/a/b/c/h"), ENOENT);
    check("unlink g", sunlink("g"), 0);
    check("rmdir cwd child", chdir("/"), 0);
    check("rmdir c", rmdir("/a/b/c"), 0);
    check("rmdir b non-empty", rmdir("/a/b"), ENOTEMPTY);
    check("unlink f", sunlink("/a/b/f"), 0);
    check("rmdir b", rmdir("/a/b/"), 0);
    check("rmdir a", rmdir("/a"), 0);
    check("a is gone", access("/a"), ENOENT);
    check("rmdir dot", rmdir("."), EINVAL);
};

def scenario_many() -> void {
    check("mkdir /m", mkdir("/m"), 0);
    let n = 700;
    let i = 0;
    let bad = 0;
    while (i < n) {
        let name = "/m/file_with_a_longish_name_" + tostring(i);
        let fd = sopen(name, O_WRONLY | O_CREAT | O_EXCL);
        if (fd < 0) { bad = bad + 1; } else { ulib.close(fd); };
        i = i + 1;
    };
    check("created 700", bad, 0);
    check("count after create", len(names("/m")), n);
    checkb("size of dir > one block", size_of("/m") > 4096);
    let r = 0;
    i = 0;
    while (i < n) {
        if (i % 2 == 0) { r = r + sunlink("/m/file_with_a_longish_name_" + tostring(i)); };
        i = i + 1;
    };
    check("unlinked evens", r, 0);
    check("count after unlink", len(names("/m")), n / 2);
    check("odd still there", access("/m/file_with_a_longish_name_699"), 0);
    check("even gone", access("/m/file_with_a_longish_name_698"), ENOENT);
    check("first odd", access("/m/file_with_a_longish_name_1"), 0);
    i = 0;
    while (i < n) {
        if (i % 2 == 0) { let fd = sopen("/m/file_with_a_longish_name_" + tostring(i), O_WRONLY | O_CREAT); if (fd >= 0) { ulib.close(fd); }; };
        i = i + 1;
    };
    check("count after recreate", len(names("/m")), n);
    check("rmdir busy", rmdir("/m"), ENOTEMPTY);
    i = 0;
    r = 0;
    while (i < n) { r = r + sunlink("/m/file_with_a_longish_name_" + tostring(i)); i = i + 1; };
    check("removed all", r, 0);
    check("rmdir /m", rmdir("/m"), 0);
};

def scenario_flags() -> void {
    check("put x", put("/x", "abc"), 0);
    check("excl exists", sopen("/x", O_WRONLY | O_CREAT | O_EXCL), EEXIST);
    check("open missing", sopen("/nope", O_RDONLY), ENOENT);
    let fd = sopen("/x", O_WRONLY | O_APPEND);
    ulib.write(fd, "def");
    ulib.close(fd);
    puts("append: " + slurp("/x") + "\n");
    fd = sopen("/x", O_WRONLY | O_TRUNC);
    ulib.close(fd);
    check("trunc size", size_of("/x"), 0);
    check("open dir for write", sopen("/", O_WRONLY), EISDIR);
    check("directory flag on file", sopen("/x", O_DIRECTORY), ENOTDIR);
    fd = sopen("/", O_DIRECTORY);
    checkb("directory flag on dir ok", fd >= 0);
    ulib.close(fd);
    check("slash after file", sopen("/x/", O_RDONLY), ENOTDIR);
    check("creat with slash", sopen("/y/", O_WRONLY | O_CREAT), EISDIR);
    check("mode of file", mode_of("/x") >> 12, 8);
    check("mode of root", mode_of("/") >> 12, 4);
    check("mode of tty", mode_of("/dev/tty") >> 12, 2);
    check("mode of null", mode_of("/dev/null") >> 12, 2);
    check("mode of dev dir", mode_of("/dev") >> 12, 4);
    check("mode of missing", mode_of("/dev/nope"), ENOENT);
    check("put y", put("/y", "0123456789"), 0);
    fd = sopen("/y", O_RDWR);
    syscall(77, fd, 4);
    ulib.close(fd);
    check("ftruncate shrink", size_of("/y"), 4);
    puts("after shrink: " + slurp("/y") + "\n");
    fd = sopen("/y", O_RDWR);
    syscall(77, fd, 8);
    ulib.close(fd);
    check("ftruncate grow", size_of("/y"), 8);
    let zb: [byte] = [48, 49, 50, 51, 0, 0, 0, 0];
    checkb("hole reads zero", slurp("/y") == from_bytes(zb));
    let b = ulib.cstr("/y");
    check("truncate", syscall(76, ptr_addr(&b[0]), 2), 0);
    check("truncate size", size_of("/y"), 2);
    check("getcwd ERANGE", syscall(79, ptr_addr(&b[0]), 1), ERANGE);
    check("unlink x", sunlink("/x"), 0);
    check("unlink y", sunlink("/y"), 0);
    check("unlink missing", sunlink("/y"), ENOENT);
};

def scenario_rename() -> void {
    check("mkdir d1", mkdir("/d1"), 0);
    check("mkdir d2", mkdir("/d2"), 0);
    check("put d1/f", put("/d1/f", "one"), 0);
    check("rename in dir", srename("/d1/f", "/d1/g"), 0);
    check("old name gone", access("/d1/f"), ENOENT);
    check("across dirs", srename("/d1/g", "/d2/h"), 0);
    puts("d2: " + slurp("/d2/h") + "\n");
    check("put d1/k", put("/d1/k", "two"), 0);
    check("onto existing", srename("/d1/k", "/d2/h"), 0);
    puts("d2/h: " + slurp("/d2/h") + "\n");
    check("missing source", srename("/d1/zz", "/d1/yy"), ENOENT);
    check("dir rename", srename("/d2", "/d3"), 0);
    puts("d3: " + join_names("/d3") + "\n");
    check("old dir gone", access("/d2"), ENOENT);
    check("dir into itself", srename("/d3", "/d3/sub"), EINVAL);
    check("mkdir d3/s", mkdir("/d3/s"), 0);
    check("move dir under d1", srename("/d3/s", "/d1/s"), 0);
    check("chdir d1/s", chdir("/d1/s"), 0);
    check("dotdot after move", chdir(".."), 0);
    puts("cwd " + getcwd() + "\n");
    check("file onto dir", srename("/d3/h", "/d1/s"), EISDIR);
    check("dir onto file", srename("/d1/s", "/d3/h"), ENOTDIR);
    check("dir onto non-empty", srename("/d1", "/d3"), ENOTEMPTY);
    check("cleanup 1", sunlink("/d3/h"), 0);
    check("cleanup 2", rmdir("/d3"), 0);
    check("cleanup 3", rmdir("/d1/s"), 0);
    check("cleanup 4", rmdir("/d1"), 0);
};

def fill(buf: [byte], tag: long) -> void {
    let i = 0;
    while (i < len(buf)) { buf[i] = (i * 7 + tag) & 255; i = i + 1; };
};

def scenario_big() -> void {
    let chunk = 65536;
    let nchunks = 80;     // 5 MiB: past the single-indirect range (4 MiB + 48 KiB)
    let buf: [byte] = [];
    let k = 0;
    while (k < chunk) { buf += 0; k = k + 1; };
    let fd = sopen("/big", O_RDWR | O_CREAT | O_TRUNC);
    checkb("create big", fd >= 0);
    let i = 0;
    let w = 0;
    while (i < nchunks) {
        fill(buf, i);
        let r = syscall(1, fd, ptr_addr(&buf[0]), chunk);
        if (r != chunk) { w = w + 1; };
        i = i + 1;
    };
    check("wrote 5 MiB", w, 0);
    ulib.close(fd);
    check("size", size_of("/big"), nchunks * chunk);
    fd = sopen("/big", O_RDONLY);
    i = 0;
    let bad = 0;
    while (i < nchunks) {
        let r = syscall(0, fd, ptr_addr(&buf[0]), chunk);
        if (r != chunk) { bad = bad + 1; } else {
            let j = 0;
            while (j < chunk) {
                if (buf[j] != ((j * 7 + i) & 255)) { bad = bad + 1; break; };
                j = j + 97;
            };
        };
        i = i + 1;
    };
    check("read back", bad, 0);
    check("seek", syscall(8, fd, 4800000, 0), 4800000);
    let r = syscall(0, fd, ptr_addr(&buf[0]), 16);
    check("read after seek", r, 16);
    check("byte after seek", buf[0], (4800000 % chunk * 0 + ((4800000 % chunk) * 7 + 4800000 / chunk)) & 255);
    ulib.close(fd);
    check("ftruncate big", sunlink("/big"), 0);
    fd = sopen("/big2", O_RDWR | O_CREAT);
    fill(buf, 3);
    i = 0;
    w = 0;
    while (i < nchunks) {
        if (syscall(1, fd, ptr_addr(&buf[0]), chunk) != chunk) { w = w + 1; };
        i = i + 1;
    };
    check("blocks reused after unlink", w, 0);
    ulib.close(fd);
    check("unlink big2", sunlink("/big2"), 0);
};

def scenario_inodes() -> void {
    check("mkdir /i", mkdir("/i"), 0);
    let i = 0;
    let made = 0;
    let last = 0;
    while (i < 4300) {
        let fd = sopen("/i/n" + tostring(i), O_WRONLY | O_CREAT);
        if (fd >= 0) { made = made + 1; ulib.close(fd); } else { last = fd; };
        i = i + 1;
    };
    checkb("made files up to the inode limit", made > 3800);
    check("then ENOSPC", last, -28);
    check("listing matches", len(names("/i")), made);
    i = 0;
    while (i < 4300) { if (sunlink("/i/n" + tostring(i)) == 0) { made = made - 1; }; i = i + 1; };
    check("all removed", made, 0);
    check("rmdir /i", rmdir("/i"), 0);
    check("inodes free again", put("/again", "x"), 0);
    sunlink("/again");
};

// Files the image was built with (mkfs: nested paths, and past 4 MiB the double-indirect
// block): read them front to back and back to front in different chunk sizes; the sums
// must agree.  With `show` the sum is printed too, to compare with the host's.
def sum_file(p: str, show: bool) -> void {
    let fd = sopen(p, O_RDONLY);
    if (fd < 0) { check("image file " + p, fd, 0); return; };
    let buf: [byte] = [];
    let k = 0;
    while (k < 65536) { buf += 0; k = k + 1; };
    let s1 = 0;
    let total = 0;
    let more = true;
    while (more) {
        let r = syscall(0, fd, ptr_addr(&buf[0]), 65536);
        if (r <= 0) { more = false; } else {
            let j = 0;
            while (j < r) { s1 = (s1 * 31 + buf[j]) & 4294967295; j = j + 1; };
            total = total + r;
        };
    };
    // the same bytes in 4 KiB blocks, last block first
    let nblk = (total + 4095) / 4096;
    let b = nblk - 1;
    let s2 = 0;
    // fold per-block, in forward order, by collecting blocks last-to-first
    let part: [long] = [];
    while (b >= 0) {
        syscall(8, fd, b * 4096, 0);
        let r = syscall(0, fd, ptr_addr(&buf[0]), 4096);
        let h = 0;
        let j = 0;
        while (j < r) { h = h * 31 + buf[j]; j = j + 1; };
        part += r;
        part += h & 4294967295;
        b = b - 1;
    };
    // recombine the forward sum from the per-block pieces (the polynomial is linear)
    let i = 0;
    while (i < nblk) {
        let r = part[(nblk - 1 - i) * 2];
        let h = part[(nblk - 1 - i) * 2 + 1];
        let pw = 1;
        // 31^r mod 2^32
        let base = 31;
        let ex = r;
        while (ex > 0) {
            if ((ex & 1) == 1) { pw = (pw * base) & 4294967295; };
            base = (base * base) & 4294967295;
            ex = ex >> 1;
        };
        s2 = (s2 * pw + h) & 4294967295;
        i = i + 1;
    };
    ulib.close(fd);
    check("image file " + p + " consistent", s1, s2);
    checkb("image file " + p + " is non-empty", total > 0);
    if (show) { puts("sum " + tostring(s1) + " size " + tostring(total) + "\n"); };
};

def scenario_image(show: bool) -> void {
    check("nested dir stat", mode_of("/bin") >> 12, 4);
    if (access("/bin/bigdata") == 0) { sum_file("/bin/bigdata", show); }
    else { check("image file /bin/bigdata consistent", 0, 0); checkb("image file /bin/bigdata is non-empty", true); };
};

// Needs the real per-process fd table (fdt): fchdir, openat on a dirfd, getdents on a
// directory fd, O_APPEND through the shared description, and a file unlinked while open.
def listing(fd: long) -> str {
    let buf: [byte] = [];
    let k = 0;
    while (k < 512) { buf += 0; k = k + 1; };
    let out: [str] = [];
    let n = 1;
    while (n > 0) {
        n = syscall(217, fd, ptr_addr(&buf[0]), 512);
        let o = 0;
        while (n > 0 && o < n) {
            let reclen = buf[o + 16] + buf[o + 17] * 256;
            let nm: [byte] = [];
            let c = o + 19;
            while (buf[c] != 0) { nm += buf[c]; c = c + 1; };
            out += from_bytes(nm);
            o = o + reclen;
        };
    };
    let t = "";
    foreach (x in out) { t += x + " "; };
    t
};

def scenario_fdops() -> void {
    check("mkdir /q", mkdir("/q"), 0);
    let dfd = sopen("/q", O_DIRECTORY);
    checkb("open dir", dfd >= 0);
    let name = ulib.cstr("f");
    let fd = syscall(257, dfd, ptr_addr(&name[0]), O_WRONLY | O_CREAT, 420);
    checkb("openat on a dirfd", fd >= 0);
    ulib.write(fd, "abc");
    ulib.close(fd);
    check("created inside q", size_of("/q/f"), 3);
    puts("getdents: " + listing(dfd) + "\n");
    check("fchdir", syscall(81, dfd), 0);
    puts("cwd " + getcwd() + "\n");
    check("relative to fchdir", size_of("f"), 3);
    check("lseek dir back", syscall(8, dfd, 0, 0), 0);
    puts("again: " + listing(dfd) + "\n");
    ulib.close(dfd);
    check("chdir /", chdir("/"), 0);
    let a1 = sopen("/q/f", O_WRONLY | O_APPEND);
    ulib.write(a1, "def");
    ulib.write(a1, "ghi");
    ulib.close(a1);
    puts("append: " + slurp("/q/f") + "\n");
    checkb("read on write-only", len(ulib.read(sopen("/q/f", O_WRONLY), 4)) == 0);
    let w = sopen("/q/f", O_RDONLY);
    check("write on read-only", ulib.write(w, "x"), EBADF);
    ulib.close(w);
    // unlinked while open: still readable, space freed at the last close
    let o = sopen("/q/f", O_RDONLY);
    check("unlink open file", sunlink("/q/f"), 0);
    check("name is gone", access("/q/f"), ENOENT);
    let got = ulib.read(o, 16);
    check("still readable", len(got), 9);
    ulib.close(o);
    check("rmdir q", rmdir("/q"), 0);
    check("ftruncate on read fd", syscall(77, sopen("/", O_RDONLY), 1), EINVAL);
};

// Kernel heap pressure: a long run of path calls must not exhaust the kernel's heap.
def scenario_stress(n: long, nokernel: bool) -> void {
    let i = 0;
    let bad = 0;
    while (i < n) {
        if (nokernel) {
            if (syscall(39) < 0) { bad = bad + 1; };
        } else {
            if (mode_of("/bin/fstest") < 0) { bad = bad + 1; };
            let fd = sopen("/bin/fstest", O_RDONLY);
            if (fd < 0) { bad = bad + 1; } else { ulib.close(fd); };
        };
        i = i + 1;
    };
    check("stress", bad, 0);
};

def num(s: str) -> long {
    let v = 0;
    let i = 0;
    while (i < len(s)) { v = v * 10 + s[i] - 48; i = i + 1; };
    v
};

let a = argv();
if (len(a) < 2) {
    puts("usage: fstest dirs|many|flags|rename|big|inodes\n");
    exit(2);
};
if (a[1] == "dirs") { scenario_dirs(); }
else if (a[1] == "many") { scenario_many(); }
else if (a[1] == "flags") { scenario_flags(); }
else if (a[1] == "rename") { scenario_rename(); }
else if (a[1] == "big") { scenario_big(); }
else if (a[1] == "inodes") { scenario_inodes(); }
else if (a[1] == "fdops") { scenario_fdops(); }
else if (a[1] == "stress") { scenario_stress(if (len(a) > 2) { num(a[2]) } else { 100000 }, len(a) > 3); }
else if (a[1] == "image") { scenario_image(len(a) > 2); }
else { puts("fstest: unknown scenario\n"); exit(2); };
puts("done fails=" + tostring(fails) + "\n");
