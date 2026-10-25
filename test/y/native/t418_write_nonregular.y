// scratch: fs.write_* with a mode on a device succeeds (no mode to set); a regular file still gets it.
import fs;

let b: [byte] = [1, 2, 3];
print(fs.write_bytes("/dev/null", b, 493), " ", fs.write_file("/dev/null", "x", 420));
print(fs.write_bytes("f.bin", b, 493), " ", fs.path_mode("f.bin") & 511);
print(fs.write_bytes("no/such/dir/f", b, 493));
fs.remove_file("f.bin");
