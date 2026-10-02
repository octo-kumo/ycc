import fs;
print("before write");
fs.write_file("/tmp/test_write.txt", "hello world");
print("after write");
