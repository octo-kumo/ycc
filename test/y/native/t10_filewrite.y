import io from "../../../src/y/std/io.y";
let flags = io.O_WRONLY() + io.O_CREAT() + io.O_TRUNC();
let fd = io.open("/tmp/ynative_test.txt", flags, 420);
print(fd > 2);
io.write_str(fd, "hello ", 6);
io.write_str(fd, "native\n", 7);
io.close(fd);
