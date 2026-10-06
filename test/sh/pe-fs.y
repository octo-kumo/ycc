// The Windows file path, end to end, in a program pe-gate.sh compiles and runs
// under wine: open/read/write/append/seek/close and the stat half
// (exists/is_file/is_dir/file_size), with RELATIVE paths -- which is what the
// PEB's CurrentDirectory resolution exists for, and what no fixture could do
// before it. Every line must match pe-fs.expected, which is the same program's
// output on Linux, so this is also a portable-path check rather than a
// Windows-only one.
//
// The fd itself is not printed (it is a handle number on one target and a
// descriptor on the other); whether it is usable is.
import fs;

let p = "peg_fs.txt";
print("w=" + tostring(fs.write_file(p, "one\n")));
print("r=" + tostring(fs.read_file(p)));
print("a=" + tostring(fs.append_file(p, "two\n")));
print("r2=" + tostring(fs.read_file(p)));
print("exists=" + tostring(fs.exists(p)));
print("file=" + tostring(fs.is_file(p)));
print("dir=" + tostring(fs.is_dir(p)));
let sz = fs.file_size(p);
if (sz == none) { print("size=none"); } else { print("size=" + tostring(sz!)); };
let fd = fs.open_file(p, "r");
print("opened=" + tostring(fd >= 0));
if (fd >= 0) {
    print("seek=" + tostring(fs.seek(fd, 0, 0)));
    print("close=" + tostring(fs.close_file(fd)));
};
print("missing=" + tostring(fs.exists("peg_nope.txt")));

// directories: make_dir, make_dirs, remove_dir -- and the EEXIST answer
// (mkdir twice is false the second time, which is what mkdirat(2) says and
// what fs.make_dirs depends on)
print("mkdir=" + tostring(fs.make_dir("peg_dir")));
print("isdir=" + tostring(fs.is_dir("peg_dir")));
print("mkdir2=" + tostring(fs.make_dir("peg_dir")));
print("mkdeep=" + tostring(fs.make_dirs("peg_d/a/b")));
print("deepdir=" + tostring(fs.is_dir("peg_d/a/b")));
print("rmdir=" + tostring(fs.remove_dir("peg_dir")));
print("dirgone=" + tostring(fs.exists("peg_dir")));

// and the file goes away
print("rmfile=" + tostring(fs.remove_file(p)));
print("gone=" + tostring(fs.exists(p)));

// rename, cwd and chdir. The cwd's TEXT differs between the two hosts
// ("/tmp/..." vs "Z:\..."), so only platform-neutral facts are printed: that
// cwd is non-empty, and that a chdir is visible to a later relative path.
print("wf2=" + tostring(fs.write_file("peg_a.txt", "r")));
print("ren=" + tostring(fs.rename("peg_a.txt", "peg_b.txt")));
print("went=" + tostring(fs.exists("peg_a.txt")));
print("arrived=" + tostring(fs.exists("peg_b.txt")));
let c0 = fs.cwd();
print("cwd_nonempty=" + tostring(len(c0) > 0));
print("mkd=" + tostring(fs.make_dir("pegcwd")));
print("chdir=" + tostring(fs.chdir("pegcwd")));
print("incwd=" + tostring(fs.cwd().ends_with("pegcwd")));
print("dot=" + tostring(fs.chdir(".")));
print("up=" + tostring(fs.chdir("..")));
print("back=" + tostring(fs.cwd().ends_with("pegcwd")));
print("rmb=" + tostring(fs.remove_file("peg_b.txt")));
print("rmd=" + tostring(fs.remove_dir("pegcwd")));
print("dgone=" + tostring(fs.exists("pegcwd")));
