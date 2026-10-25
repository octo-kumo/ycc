import fs;
print("before write");
// /dev/null: the write path is the point, not a file left in the tree
fs.write_file("/dev/null", "hello world");
print("after write");
