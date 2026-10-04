import fs;

// A directory is not a file. read(2) refuses one with EISDIR, which a read
// loop sees only as end-of-file, so every whole-file reader used to answer
// "an empty file exists here": read_file("<dir>") was some(""), read_bytes and
// read_lines were some([])/some([]), and `ycc <a dir>` compiled nothing into
// an empty executable. They now answer none, like a missing path does.

let dir = "/tmp";
let base = "/tmp/ytest_t167_" + tostring(syscall(39));
print("is_dir ", fs.is_dir(dir), " exists ", fs.exists(dir), " is_file ", fs.is_file(dir));
print("read_file none ", fs.read_file(dir) == none);
print("read_bytes none ", fs.read_bytes(dir) == none);
print("read_lines none ", fs.read_lines(dir) == none);
print("missing none ", fs.read_file("/no/such/path/at/all") == none);
print("list_dir ", len(fs.list_dir(dir)!) >= 0);

// A real file still reads, empty or not: the guard is about directories.
let path = base + ".txt";
print("write ", fs.write_file(path, "one\ntwo\n"));
print("read ", fs.read_file(path)!);
print("lines ", fs.read_lines(path)!.length);
let empty = base + "_empty.txt";
print("empty ", fs.write_file(empty, ""), " ", fs.read_file(empty)! == "");
print("make_dir ", fs.make_dir(base + "_dir"));
print("read the new dir none ", fs.read_file(base + "_dir") == none);
print("rmdir ", fs.remove_dir(base + "_dir"));
print("remove ", fs.remove_file(path));
print("remove ", fs.remove_file(empty));