// The file round trip on Windows, end to end: create, write, read back,
// append, read again, size, open, close. Every line is compared against the
// same program's output on Linux (fsrt.expected), so this is a portable
// check rather than a Windows-only one -- and it is the half of the file path
// that works, which `fs.y` (the known gap) is not.
//
// It lives here and not in test/y/native/ because it CREATES A FILE: the native
// suite runs its binaries from the repo root, and `ytest pe-gate` runs them in a
// temp dir, which is where a program that writes belongs.
import fs;
print(fs.write_file("pefsrt.txt", "hello round trip\n"));
print(fs.read_file("pefsrt.txt")!);
print(fs.append_file("pefsrt.txt", "second line\n"));
print(fs.read_file("pefsrt.txt")!);
print(fs.file_size("pefsrt.txt"));
print(fs.read_file("pefsrt.txt")!.length);
print(fs.exists("pefsrt.txt"));
// The directory half: mkdir must fail on an existing directory (that is what
// mkdir(2) does), unlink has to work for a file and for a directory, and
// set_mode answers success because NT has no mode bits to set.
print(fs.make_dir("pefsrt_dir"));
print(fs.is_dir("pefsrt_dir"));
print(fs.make_dir("pefsrt_dir"));
print(fs.write_file("pefsrt_dir/inner.txt", "inner\n"));
print(fs.read_file("pefsrt_dir/inner.txt")!);
print(fs.remove_dir("pefsrt_dir"));
print(fs.exists("pefsrt_dir"));
// lseek, all three whences: SET to 3, CUR back to where we are, END at the
// size, and a position past the end (legal), then one before the start
// (refused).
let fd = fs.open_file("pefsrt.txt", "r");
print(fs.seek(fd, 3, 0));
print(fs.seek(fd, 0, 1));
print(fs.seek(fd, 0, 2));
print(fs.seek(fd, 1000, 0));
print(fs.seek(fd, -1, 0));
print(fs.seek(fd, -12345, 0));
print(fs.close_file(fd));
// rename: the source is gone, the target has the content, and a source that
// does not exist fails.
print(fs.write_file("pefsrt_ren.txt", "renamed\n"));
print(fs.rename("pefsrt_ren.txt", "pefsrt_ren2.txt"));
print(fs.exists("pefsrt_ren.txt"));
print(fs.read_file("pefsrt_ren2.txt")!);
print(fs.rename("pefsrt_nope.txt", "pefsrt_x.txt"));
print(fs.remove_file("pefsrt_ren2.txt"));
print(fs.remove_file("pefsrt.txt"));
print(fs.exists("pefsrt.txt"));
// The current directory and chdir. Absolute paths differ between the targets by
// construction (Z:/... against /...), so what is compared is the SHAPE: a
// non-empty path that ends with the directory just entered, a chdir to
// something that is not there failing, and the directory not having moved when
// it did. `..` is deliberately NOT tested: NT's native API does not resolve it
// (that is user-space work), so a chdir("..") that Linux accepts fails here, and
// a fixture both targets must agree on is the wrong place to pin that down.
print(fs.cwd().length > 0);
// "." and ".." are resolved by the layer, not the kernel: NT takes a relative
// name literally, so these are normalised in y_w_path.
print(fs.exists("./pefsrt_dir/inner.txt"));
print(fs.is_dir("pefsrt_dir/../pefsrt_dir"));
// list_dir: one file, so the answer does not depend on the order a directory
// happens to come back in. "." and ".." are not listed on either target.
print(fs.make_dir("pefsrt_ls"));
print(fs.write_file("pefsrt_ls/only.txt", "x"));
let ls = fs.list_dir("pefsrt_ls")!;
print(ls.length);
print(ls[0]);
print(fs.remove_file("pefsrt_ls/only.txt"));
print(fs.remove_dir("pefsrt_ls"));
print(fs.make_dir("pefsrt_cd"));
print(fs.chdir("pefsrt_cd"));
print(fs.cwd().ends_with("pefsrt_cd"));
print(fs.chdir("pefsrt_missing"));
print(fs.cwd().ends_with("pefsrt_cd"));
print(fs.cwd().length > 0);
// "." and ".." are resolved by the layer, not the kernel: NT takes a relative
// name literally, so these are normalised in y_w_path.
print(fs.exists("./pefsrt_dir/inner.txt"));
print(fs.is_dir("pefsrt_dir/../pefsrt_dir"));
// list_dir: one file, so the answer does not depend on the order a directory
// happens to come back in. "." and ".." are not listed on either target.
print(fs.make_dir("pefsrt_ls"));
print(fs.write_file("pefsrt_ls/only.txt", "x"));
let ls = fs.list_dir("pefsrt_ls")!;
print(ls.length);
print(ls[0]);
print(fs.remove_file("pefsrt_ls/only.txt"));
print(fs.remove_dir("pefsrt_ls"));
