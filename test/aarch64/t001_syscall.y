// Raw AArch64 Linux numbers; named std calls share the portable runtime.
let message = "native arm64\n";
print(syscall(64, 1, message, message.length));
let pid = syscall(172);
print(pid > 0);
print(syscall(0x7fffffff) == -38);
let fd = syscall(56, -100, "/dev/null", 0, 0);
print(fd >= 0);
print(syscall(57, fd));
