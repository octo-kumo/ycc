// b1_sig -- kill, SIGPIPE, exit statuses, ids, uname
import b1 from "./b1.y";

def run_sig() -> void {
    // SIGPIPE kills a writer to a pipe with no reader
    let z = b1.pipe();
    b1.close(z[0]);
    let c0 = b1.fork();
    if (c0 == 0) {
        b1.wr(z[1], "x");
        exit(0);
    };
    b1.close(z[1]);
    b1.wait4(c0, 0);
    b1.eq("SIGPIPE status", b1.wstatus(), 141 * 256);

    // a child spinning in syscalls
    let c1 = b1.fork();
    if (c1 == 0) { while (true) { b1.getpid(); }; };
    b1.spin(20);
    b1.eq("kill sig 0", b1.kill(c1, 0), 0);
    b1.eq("kill SIGTERM", b1.kill(c1, 15), 0);
    b1.eq("wait killed", b1.wait4(c1, 0), c1);
    b1.eq("SIGTERM status", b1.wstatus(), 143 * 256);

    // a child blocked in read
    let q = b1.pipe();
    let c2 = b1.fork();
    if (c2 == 0) { b1.rd(q[0], 10); exit(0); };
    b1.spin(50);
    b1.eq("kill blocked", b1.kill(c2, 9), 0);
    b1.wait4(c2, 0);
    b1.eq("SIGKILL status", b1.wstatus(), 137 * 256);

    // a child in a loop that makes no syscalls
    let c3 = b1.fork();
    if (c3 == 0) { let i = 0; while (true) { i = i + 1; }; };
    b1.spin(20);
    b1.kill(c3, 2);
    b1.wait4(c3, 0);
    b1.eq("SIGINT on a busy child", b1.wstatus(), 130 * 256);

    // SIG_IGN: the child survives SIGUSR1, a default signal kills it
    let act: [long; 4] = [1, 0, 0, 0];
    let sync = b1.pipe();
    let c4 = b1.fork();
    if (c4 == 0) {
        b1.sc(13, 10, ptr_addr(&act[0]), 0, 8);
        b1.wr(sync[1], "r");
        b1.spin(300);
        exit(5);
    };
    b1.rd(sync[0], 1);
    b1.kill(c4, 10);
    b1.wait4(c4, 0);
    b1.eq("ignored signal", b1.wstatus(), 5 * 256);
    b1.eq("kill unknown pid", b1.kill(99999, 15), 0 - 3);
    b1.eq("kill bad signal", b1.kill(1, 99), 0 - 22);
    b1.eq("SIGCHLD does nothing", b1.kill(b1.getpid(), 17), 0);

    // ids
    b1.check("pid", b1.getpid() > 0);
    b1.eq("uid", b1.sc(102, 0, 0, 0, 0), 1000);
    b1.eq("gid", b1.sc(104, 0, 0, 0, 0), 1000);
    b1.eq("euid", b1.sc(107, 0, 0, 0, 0), 1000);
    b1.eq("egid", b1.sc(108, 0, 0, 0, 0), 1000);
    b1.eq("tid is pid", b1.sc(186, 0, 0, 0, 0), b1.getpid());
    b1.check("ppid", b1.sc(110, 0, 0, 0, 0) > 0);
    let c5 = b1.fork();
    if (c5 == 0) {
        let before = b1.sc(121, 0, 0, 0, 0);
        let sid = b1.sc(112, 0, 0, 0, 0);
        exit(if (sid == b1.getpid() && b1.sc(121, 0, 0, 0, 0) == sid && before != sid && b1.sc(124, 0, 0, 0, 0) == sid) { 0 } else { 1 });
    };
    b1.wait4(c5, 0);
    b1.eq("setsid in a child", b1.wstatus(), 0);
    b1.eq("setpgid", b1.sc(109, 0, 0, 0, 0), 0);
    b1.eq("getpgrp", b1.sc(111, 0, 0, 0, 0), b1.sc(121, 0, 0, 0, 0));


    // uname
    let u: [byte; 400] = [0; 400];
    b1.eq("uname", b1.sc(63, ptr_addr(&u[0]), 0, 0, 0), 0);
    b1.check("sysname", from_bytes(u[0:5]) == "yunix");
    b1.check("machine", from_bytes(u[260:266]) == "x86_64");

    // limits, umask, signals accepted
    let lim: [long; 2] = [0; 2];
    b1.eq("prlimit64 nofile", b1.sc(302, 0, 7, 0, ptr_addr(&lim[0])), 0);
    b1.eq("nofile cur", lim[0], 128);
    b1.eq("getrlimit stack", b1.sc(97, 3, ptr_addr(&lim[0]), 0, 0), 0);
    b1.eq("stack cur", lim[0], 8388608);
    b1.eq("umask old", b1.sc(95, 63, 0, 0, 0), 18);
    b1.eq("umask new", b1.sc(95, 18, 0, 0, 0), 63);
    let mask: [long; 1] = [5];
    b1.eq("sigprocmask", b1.sc(14, 0, 0, ptr_addr(&mask[0]), 8), 0);
    b1.eq("sigprocmask old", mask[0], 0);
    puts("done\n");
};
