import io;

print(io.stdin_fd());
print(io.stdout_fd());
print(io.stderr_fd());
print([
    io.O_RDONLY(),
    io.O_WRONLY(),
    io.O_RDWR(),
    io.O_CREAT(),
    io.O_TRUNC()
]);

print(io.open("t102_io_missing.txt", io.O_RDONLY(), 0));
print(io.open(".", io.O_WRONLY(), 0));
print(io.chmod("t102_io_missing.txt", 384));

// /tmp, pid-unique: the repo may sit on a filesystem where a fresh file
// can be briefly locked, and concurrent runs must not share the file.
let path = "/tmp/ytest_t102_" + tostring(syscall(39)) + ".txt";
let fd = io.open(path, io.O_RDWR() + io.O_CREAT() + io.O_TRUNC(), 420);
print(fd > 2);
print(io.chmod(path, 384));
print(io.write_str(fd, "io:", 3));
let payload: [long; 2] = [0x0102030405060708, -1];
print(io.write(fd, &payload[0], 16));
print(io.close(fd));
print(io.close(fd));
print(io.close(-1));

let ro = io.open(path, io.O_RDONLY(), 0);
print(ro > 2);
let prefix: [long; 1] = [0];
let back: [long; 2] = [0; 2];
print(io.read(ro, &prefix[0], 3));
print(prefix[0] == 3829609);
print(io.read(ro, &back[0], 16));
print(back);
print(io.write_str(ro, "x", 1));
print(io.close(ro));

let wo = io.open(path, io.O_WRONLY(), 0);
let unused: [long; 1] = [0];
print(io.read(wo, &unused[0], 1));
print(io.close(wo));

print(syscall(87, path));
