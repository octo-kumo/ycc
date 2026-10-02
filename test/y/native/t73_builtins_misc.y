import fs;
let value: long = 7;
print(byte_at("A", 0));
let values = [1, 2];
print(heap_used() > 0);
print(ptr_addr(&value) != 0);
eputs("eputs-called\n");
sleep(1);
print("awake");
// /tmp, pid-unique (see t102): syscall 39 is getpid.
let path = "/tmp/ytest_t73_" + tostring(syscall(39)) + ".bin";
let written = fs.write_bytes(path, bytes("Y!"), 420);
print(written);
let data = fs.read_file(path);
print(unwrap(data));
syscall(87, path);
