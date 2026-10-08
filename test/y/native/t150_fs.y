// scratch: the harness runs this fixture in a scratch directory (relative paths)
// std/fs.y: whole files as text or bytes, appends, paths, directories and
// fds opened with a mode string.
import fs;
let root = fs.cwd();
let p = root + "/ynative_t150.txt";
let d = root + "/ynative_t150_d";
fs.remove_all(d);
print(fs.write_file(p, "hello\nworld\n"));
print(fs.read_file(p)!);
print(fs.append_file(p, "more\n"));
print(fs.read_lines(p)!);
print(fs.file_size(p)!, " ", fs.exists(p), " ", fs.is_file(p), " ", fs.is_dir(p), " ", fs.is_dir("."));
let bb: [byte] = [0, 1, 255];
let b7: [byte] = [7];
print(fs.write_bytes(p + ".bin", bb, 384), " ", fs.read_bytes(p + ".bin")!);
print(fs.append_bytes(p + ".bin", b7), " ", fs.file_size(p + ".bin")!);
// directories
print(fs.make_dirs(d + "/a/b"), " ", fs.make_dirs(d + "/a/b"), " ", fs.make_dir(d + "/a"));
print(fs.write_file(d + "/a/x.txt", "x"), " ", fs.list_dir(d + "/a")!);
print(fs.copy_file(p, d + "/c.txt"), " ", fs.rename(d + "/c.txt", d + "/e.txt"), " ", fs.read_file(d + "/e.txt")!.length);
print(fs.list_dir(d)!, " ", fs.remove_dir(d), " ", fs.remove_all(d), " ", fs.exists(d));
// fds
let fd = fs.open_file(p, "r");
print(fs.read_some(fd, 5), " ", fs.seek(fd, 0, 0), " ", fs.read_all(fd).length, " ", fs.close_file(fd));
let fd2 = fs.open_file(p, "r");
print(len(fs.read_all_bytes(fd2)), " ", fs.close_file(fd2));
let w = fs.open_file(p, "a");
print(fs.write_text(w, "end\n"), " ", fs.write_data(w, bytes("!\n")), " ", fs.close_file(w));
print(fs.read_lines(p)!);
print(fs.open_file(p, "x"), " ", fs.open_file(p, "q"), " ", fs.read_file("ynative_no_such")  == none);
print(fs.set_mode(p, 384), " ", fs.cwd().length > 0, " ", fs.chdir("/"), " ", fs.cwd());
print(fs.remove_file(p), " ", fs.remove_file(p + ".bin"), " ", fs.remove_file(p), " ", fs.exists(p));
