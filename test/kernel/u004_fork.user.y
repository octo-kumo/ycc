// fork and wait4: the child is a copy of this process, and its exit status
// comes back through the parent's suspended syscall frame.
let pid = syscall(57);
if (pid == 0) {
    puts("child\n");
    exit(3);
};
puts("parent\n");
let st: [long; 1] = [0];
let reaped = syscall(61, pid, ptr_addr(&st[0]), 0, 0);
print("reaped " + tostring(reaped) + " status " + tostring(st[0] >> 8));
