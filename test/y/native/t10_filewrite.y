// scratch: the harness runs this fixture in a scratch directory (relative paths)
// A file written through an fd (std/fs.y): the harness checks its bytes
// (t10_filewrite.file). The path is relative: the harness runs this fixture in
// a scratch directory.
import fs;
let fd = fs.open_file("ynative_test.txt", "w");
print(fd > 2);
fs.write_text(fd, "hello ");
fs.write_text(fd, "native\n");
fs.close_file(fd);
