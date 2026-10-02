import fs;

// argv: the harness runs the binary with no arguments, so argc is 1.
// (argv[0] itself is the temp binary path — nondeterministic, not printed.)
let a = argv();
print(len(a));

let ok = fs.write_file("/tmp/ynative_t20.txt", "hello file\n");
print(ok);
let back = fs.read_file("/tmp/ynative_t20.txt");
print(unwrap(back));
let missing = fs.read_file("/tmp/ynative_no_such_file.txt");
print(is_some(missing));

let fd = fs.open_file("/tmp/ynative_t20b.txt", "w");
print(fd > 0);
fs.write_text(fd, "via an fd");
fs.close_file(fd);
let back2 = fs.read_file("/tmp/ynative_t20b.txt");
print(unwrap(back2));
exit(0);
