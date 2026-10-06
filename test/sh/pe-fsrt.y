// The file round trip on Windows, end to end: create, write, read back,
// append, read again, size, open, close. Every line is compared against the
// same program's output on Linux (pe-fsrt.expected), so this is a portable
// check rather than a Windows-only one -- and it is the half of the file path
// that works, which `pe-fs.y` (the known gap) is not.
//
// It lives here and not in test/y/native/ because it CREATES A FILE: the native
// suite runs its binaries from the repo root, and pe-gate.sh runs them in a
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
print(fs.remove_file("pefsrt.txt"));
print(fs.exists("pefsrt.txt"));
