// A write that fails at the flush, not at the write. /dev/full accepts the
// bytes and fails when they are flushed, so the return that says whether
// they landed is the one from the close -- the Y twin writes with write(2),
// which fails on the spot, and the C twin buffers, so it has to read
// fclose's return. It did not, and `cycc -o /dev/full` exited 0.
import fs;

// the std function itself, both writers
print(fs.write_file("/dev/full", "hello\n"));
print(fs.write_bytes("/dev/full", b"hello"));

// and the ordinary case, so the check is not simply refusing everything
let p = "/tmp/ynative_t206.txt";
print(fs.write_file(p, "hello\n"), " ", fs.read_file(p)!);
print(fs.write_bytes(p + ".bin", b"\x00\x01"), " ", fs.read_bytes(p + ".bin")!);
print(fs.remove_file(p), " ", fs.remove_file(p + ".bin"));