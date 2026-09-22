import io from "../../../src/y/std/io.y";

// argv: the harness runs the binary with no arguments, so argc is 1.
// (argv[0] itself is the temp binary path — nondeterministic, not printed.)
let a = argv();
print(len(a));

let ok = write_file("/tmp/ynative_t20.txt", "hello file\n");
print(ok);
let back = read_file("/tmp/ynative_t20.txt");
print(unwrap(back));
let missing = read_file("/tmp/ynative_no_such_file.txt");
print(is_some(missing));

let fd = io.open("/tmp/ynative_t20b.txt", 577, 420);
print(fd > 0);
let vbuf = "via io";
io.write_str(fd, vbuf, 6);
io.close(fd);
let back2 = read_file("/tmp/ynative_t20b.txt");
print(unwrap(back2));
exit(0);
