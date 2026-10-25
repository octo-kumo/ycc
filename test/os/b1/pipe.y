// b1_pipe -- pipe, fork, EOF at the last writer close, ECHILD, WNOHANG, wait status
import b1 from "./b1.y";

def run_pipe() -> void {
    let p = b1.pipe();
    b1.check("pipe fds", p[0] >= 3 && p[1] == p[0] + 1);
    let pid = b1.fork();
    if (pid == 0) {
        b1.close(p[0]);
        b1.spin(50);
        b1.wr(p[1], "hello");
        b1.wr(p[1], " world");
        exit(7);
    };
    b1.close(p[1]);
    let got = b1.rd_all(p[0]);
    puts("read: " + got + "\n");
    b1.eq("eof after writer exit", b1.t_st[0], 0);
    b1.eq("wait pid", b1.wait4(pid, 0), pid);
    b1.eq("exit status", b1.wstatus(), 7 * 256);
    b1.eq("no children left", b1.wait4(0 - 1, 0), 0 - 10);
    b1.close(p[0]);

    // WNOHANG: the child waits for EOF on a pipe the parent still writes
    let q = b1.pipe();
    let c = b1.fork();
    if (c == 0) {
        b1.close(q[1]);
        let s = b1.rd(q[0], 10);
        exit(if (len(s) == 0) { 3 } else { 4 });
    };
    b1.close(q[0]);
    b1.spin(100);
    b1.eq("wnohang running child", b1.wait4(c, 1), 0);
    b1.close(q[1]);
    b1.eq("wait blocking", b1.wait4(c, 0), c);
    b1.eq("child saw eof", b1.wstatus(), 3 * 256);

    // a blocking read is woken by the write
    let r = b1.pipe();
    let d = b1.fork();
    if (d == 0) {
        b1.close(r[1]);
        let s = b1.rd(r[0], 10);
        exit(if (s == "wake") { 0 } else { 1 });
    };
    b1.close(r[0]);
    b1.spin(100);
    b1.wr(r[1], "wake");
    b1.wait4(d, 0);
    b1.eq("blocked reader woke", b1.wstatus(), 0);

    // 100000 bytes through a 64 KB pipe: the writer sleeps and resumes
    let big = b1.pipe();
    let e = b1.fork();
    if (e == 0) {
        b1.close(big[1]);
        let total = 0;
        let more = true;
        while (more) {
            let s = b1.rd(big[0], 4096);
            if (len(s) == 0) { more = false; } else { total += len(s); };
        };
        exit(if (total == 100000) { 0 } else { 1 });
    };
    b1.close(big[0]);
    let chunk = "0123456789".repeat(1000);
    let n1 = b1.wr(big[1], chunk);
    let n2 = b1.wr(big[1], chunk.repeat(9));
    b1.eq("small big write", n1, 10000);
    b1.eq("long write completes", n2, 90000);
    b1.close(big[1]);
    b1.wait4(e, 0);
    b1.eq("reader counted 100000", b1.wstatus(), 0);
    puts("done\n");
};
