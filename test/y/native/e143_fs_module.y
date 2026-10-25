// expect-error: 5:10: error: undefined function 'read_file'
// expect-error: 6:11: error: undefined function 'write_file'
// The file system is std/fs.y: without `import fs;` there is no read_file
// or write_file (they were builtins once).
read_file("in");
write_file("out", "x");
