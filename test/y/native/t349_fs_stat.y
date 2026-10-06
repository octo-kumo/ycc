// The stat half of the file system on both targets: exists, is_file, is_dir,
// path_mode and file_size, over paths that a suite run from the repo root
// always has. On NT these go through the PEB's current directory -- NT's
// kernel does NOT resolve a relative name, so the body assembles
// `\??\` + the CWD's DOS path + the relative part itself, and translates the
// Unix separator. file_size is compared rather than printed exactly: what
// matters is that a real size comes back, and an exact literal would have to
// change with fs.y.
import fs;
print(fs.exists("src"));
print(fs.is_dir("src"));
print(fs.is_file("src/y/std/fs.y"));
print(fs.is_dir("src/y/std/fs.y"));
print((fs.path_mode("src/y/std/fs.y") & 61440) == 32768);
print(fs.file_size("src/y/std/fs.y")! > 1000);
print(fs.exists("no-such-path-here-at-all"));
print(fs.exists("src/no-such-child"));
print(fs.file_size("no-such-path-here-at-all") == none);
