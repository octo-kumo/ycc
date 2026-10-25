// b1_fd -- dup family, fcntl, O_NONBLOCK, EPIPE, redirecting stdout into a pipe
import b1 from "./b1.y";

def run_fd() -> void {
    let p = b1.pipe();
    let r = p[0];
    let w = p[1];

    // dup / dup2 / dup3 share one description
    let d = b1.dup(w);
    b1.check("dup lowest free", d > w);
    b1.eq("dup2 target", b1.dup2(w, 20), 20);
    b1.eq("dup2 same fd", b1.dup2(w, w), w);
    b1.eq("dup2 bad old", b1.dup2(99, 5), 0 - 9);
    b1.eq("dup3 same fd", b1.sc(292, w, w, 0, 0), 0 - 22);
    b1.eq("dup3 cloexec", b1.sc(292, w, 21, 524288, 0), 21);
    b1.eq("getfd 20", b1.sc(72, 20, 1, 0, 0), 0);
    b1.eq("getfd 21", b1.sc(72, 21, 1, 0, 0), 1);
    b1.eq("setfd", b1.sc(72, 20, 2, 1, 0), 0);
    b1.eq("getfd 20 now", b1.sc(72, 20, 1, 0, 0), 1);
    b1.eq("dupfd >= 30", b1.sc(72, w, 0, 30, 0), 30);
    b1.eq("dupfd cloexec >= 40", b1.sc(72, w, 1030, 40, 0), 40);
    b1.eq("getfd 40", b1.sc(72, 40, 1, 0, 0), 1);
    b1.eq("close bad", b1.close(77), 0 - 9);
    b1.eq("write via dup", b1.wr(d, "ab"), 2);
    b1.eq("write via dup2", b1.wr(20, "cd"), 2);
    b1.eq("read gets both", len(b1.rd(r, 100)), 4);
    b1.eq("write to read end", b1.wr(r, "x"), 0 - 9);
    b1.eq("read from write end", b1.sc(0, w, 0, 1, 0), 0 - 9);

    // the description (not the fd) carries O_NONBLOCK
    b1.eq("getfl rd", b1.sc(72, r, 3, 0, 0) & 3, 0);
    b1.eq("getfl wr", b1.sc(72, w, 3, 0, 0) & 3, 1);
    b1.eq("setfl nonblock", b1.sc(72, r, 4, 2048, 0), 0);
    b1.eq("getfl nonblock", b1.sc(72, r, 3, 0, 0) & 2048, 2048);
    b1.rd(r, 10);
    b1.eq("empty nonblocking read", b1.t_st[0], 0 - 11);
    b1.eq("setfl clear", b1.sc(72, r, 4, 0, 0), 0);
    b1.check("pipe2 nonblock", b1.pipe2(2048)[0] >= 0);

    // FIONREAD
    b1.wr(w, "12345");
    b1.eq("fionread", b1.sc(16, r, 21531, ptr_addr(&b1.t_pair[0]), 0), 0);
    b1.eq("fionread value", b1.t_pair[0] & 4294967295, 5);
    b1.rd(r, 100);
    b1.eq("ioctl on bad fd", b1.sc(16, 66, 21531, 0, 0), 0 - 9);
    b1.eq("lseek on pipe", b1.sc(8, r, 0, 0, 0), 0 - 29);

    // stdout redirected into a pipe: a child dup2s and prints, the parent reads it back
    let q = b1.pipe();
    let c = b1.fork();
    if (c == 0) {
        b1.close(q[0]);
        b1.dup2(q[1], 1);
        b1.close(q[1]);
        puts("redirected text\n");
        exit(0);
    };
    b1.close(q[1]);
    let got = b1.rd_all(q[0]);
    b1.check("stdout redirect", got == "redirected text\n");
    b1.wait4(c, 0);

    // EPIPE with SIGPIPE ignored
    let act: [long; 4] = [1, 0, 0, 0];
    b1.eq("sigaction ignore", b1.sc(13, 13, ptr_addr(&act[0]), 0, 8), 0);
    let z = b1.pipe();
    b1.close(z[0]);
    b1.eq("write to broken pipe", b1.wr(z[1], "boom"), 0 - 32);
    // the reader of a pipe whose write end the parent still holds is not at EOF
    let y = b1.pipe();
    b1.eq("close read side", b1.close(y[0]), 0);
    puts("done\n");
};
