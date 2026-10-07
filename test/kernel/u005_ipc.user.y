let a = argv();
if (a[1] == "srv") {
    let buf: [long; 5] = [0, 0, 0, 0, 0];
    puts("S1\n");
    let p: long = ptr_addr(&buf[0]);
    let tag = syscall(1025, p);
    puts("S2\n");
    syscall(1026, buf[0] * 2);
    puts("S2b\n");
    puts("S3\n");
    let tag2 = syscall(1025, p);
    puts("S4\n");
    syscall(1026, tag2 * 2);
    puts("server done\n");
} else {
    puts("C1\n");
    let port: long = a[2].tolong()!;
    let r1 = syscall(1024, port, 21, 0, 0, 0);
    puts("C2\n");
    print("client got " + tostring(r1));
    let r2 = syscall(1024, port, 5, 0, 0, 0);
    print("client got " + tostring(r2));
};
