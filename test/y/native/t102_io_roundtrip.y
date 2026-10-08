// scratch: the harness runs this fixture in a scratch directory (relative paths)
// std/fs.y at the fd level: every mode string, the errors (-1, false,
// []), positions, NUL bytes, and the standard fds (1 is stdout).
import fs;

print(fs.write_text(1, "fd 1 is stdout\n"));
print(fs.write_text(1, ""));
print(fs.open_file("t102_io_missing.txt", "r"));
print(fs.open_file(".", "w"));
print(fs.open_file(".", "rw"));
print(fs.set_mode("t102_io_missing.txt", 384));

// The harness runs each fixture in a scratch directory; pid-unique: the repo may sit on a filesystem where a fresh file
// can be briefly locked, and concurrent runs must not share the file.
let path = "ytest_t102_" + tostring(syscall(39)) + ".txt";
let fd = fs.open_file(path, "w+", 384);
print(fd > 2);
print(fs.write_text(fd, "io:"));
let payload: [byte] = [1, 2, 3, 0, 255];
print(fs.write_data(fd, payload));
print(fs.seek(fd, 0, 1), " ", fs.seek(fd, 0, 0));
print(fs.read_some(fd, 3), " ", fs.read_all_bytes(fd), " ", fs.read_some(fd, 10));
print(fs.seek(fd, -2, 2), " ", fs.seek(fd, -100, 0));
print(fs.close_file(fd), " ", fs.close_file(fd), " ", fs.close_file(-1));
print(fs.file_size(path)!);

// read-only: no writing; at most 65536 bytes a call
let ro = fs.open_file(path, "r");
print(fs.write_text(ro, "x"), " ", fs.read_some(ro, 0), " ", fs.read_some(ro, -5));
print(len(fs.read_some(ro, 100000)), " ", fs.close_file(ro));

// append: write-only, and every write lands at the end
let ap = fs.open_file(path, "a");
print(fs.read_some(ap, 1), " ", fs.write_text(ap, "!"));
print(fs.seek(ap, 0, 0), " ", fs.write_text(ap, "?"), " ", fs.close_file(ap));
print(fs.read_bytes(path)!);

// r+: both ways, from the start, no truncation
let rw = fs.open_file(path, "r+");
print(fs.write_text(rw, "IO"), " ", fs.read_some(rw, 1), " ", fs.close_file(rw));
print(fs.read_bytes(path)![0:4], " ", fs.file_size(path)!);

// x: the file must not exist; a+ reads and appends; w truncates
print(fs.open_file(path, "x"));
let nx = path + ".new";
let x = fs.open_file(nx, "x+");
print(x > 2, " ", fs.write_text(x, "new"), " ", fs.seek(x, 0, 0), " ", fs.read_all(x), " ", fs.close_file(x));
let ar = fs.open_file(nx, "a+");
print(fs.write_text(ar, "er"), " ", fs.seek(ar, 0, 0), " ", fs.read_all(ar), " ", fs.close_file(ar));
let wt = fs.open_file(nx, "w");
print(fs.close_file(wt), " ", fs.file_size(nx)!);
print(fs.remove_file(path), " ", fs.remove_file(nx));
