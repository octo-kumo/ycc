// scratch: the harness runs this fixture in a scratch directory (relative paths)
import fs;
let value: long = 7;
print(byte_at("A", 0));
let values = [1, 2];
// false: print(<integer>) formats into a stack buffer, so it allocates
// nothing (t379 pins that); heap_used stays 0 until something really does.
print(heap_used() > 0);
print(ptr_addr(&value) != 0);
eputs("eputs-called\n");
sleep(1);
print("awake");
// Scratch directory, pid-unique (see t102): syscall 39 is getpid.
let path = "ytest_t73_" + tostring(syscall(39)) + ".bin";
let written = fs.write_bytes(path, bytes("Y!"), 420);
print(written);
let data = fs.read_file(path);
print(unwrap(data));
syscall(87, path);
