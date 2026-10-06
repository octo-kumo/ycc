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
