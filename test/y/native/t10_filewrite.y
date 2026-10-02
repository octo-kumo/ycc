// A file written through an fd (std/fs.y): the harness checks its bytes
// (t10_filewrite.file).
import fs;
let fd = fs.open_file("/tmp/ynative_test.txt", "w");
print(fd > 2);
fs.write_text(fd, "hello ");
fs.write_text(fd, "native\n");
fs.close_file(fd);
