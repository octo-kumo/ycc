// b1_poll -- poll, ppoll, select over pipes
import b1 from "./b1.y";

let pf: [long; 2] = [0; 2];

/** pollfd {fd, events, revents} for one fd: revents. */
def poll1(fd: long, ev: long, ms: long) -> long {
    pf[0] = fd | (ev << 32);
    let r = b1.sc(7, ptr_addr(&pf[0]), 1, ms, 0);
    if (r < 0) { return r; };
    (pf[0] >> 48) & 65535
};

def run_poll() -> void {
    let p = b1.pipe();
    b1.eq("poll empty, timeout 0", b1.sc(7, ptr_addr(&pf[0]), 0, 0, 0), 0);
    b1.eq("empty pipe not readable", poll1(p[0], 1, 0), 0);
    b1.eq("empty pipe writable", poll1(p[1], 4, 0), 4);
    b1.eq("poll 20ms timeout", poll1(p[0], 1, 20), 0);
    let info: [long; 14] = [0; 14];
    b1.sc(99, ptr_addr(&info[0]), 0, 0, 0);
    let up0 = info[0];
    b1.eq("poll 2500ms timeout", poll1(p[0], 1, 2500), 0);
    b1.sc(99, ptr_addr(&info[0]), 0, 0, 0);
    b1.check("it really waited", info[0] - up0 >= 2);
    b1.wr(p[1], "x");
    b1.eq("readable after write", poll1(p[0], 1, 0), 1);
    b1.eq("bad fd", poll1(55, 1, 0), 32);
    b1.rd(p[0], 10);

    // a blocked poll is woken by a write from another process
    let c = b1.fork();
    if (c == 0) {
        b1.close(p[0]);
        b1.spin(200);
        b1.wr(p[1], "y");
        exit(0);
    };
    b1.eq("blocking poll wakes", poll1(p[0], 1, 0 - 1), 1);
    b1.wait4(c, 0);
    b1.rd(p[0], 10);

    // POLLHUP once the writers are gone
    b1.close(p[1]);
    b1.eq("hangup", poll1(p[0], 1, 0) & 16, 16);

    // ppoll with a timespec
    let q = b1.pipe();
    let ts: [long; 2] = [0, 30000000];
    pf[0] = q[0] | (1 << 32);
    b1.eq("ppoll timeout", b1.sc(271, ptr_addr(&pf[0]), 1, ptr_addr(&ts[0]), 0), 0);

    // select
    let rs: [long; 16] = [0; 16];
    let ws: [long; 16] = [0; 16];
    let tv: [long; 2] = [0, 20000];
    ws[0] = 1 << q[1];
    b1.eq("select one writable", b1.sc5(23, q[1] + 1, 0, ptr_addr(&ws[0]), 0, 0), 1);
    rs[0] = 1 << q[0];
    b1.eq("select timeout", b1.sc5(23, q[1] + 1, ptr_addr(&rs[0]), 0, 0, ptr_addr(&tv[0])), 0);
    b1.eq("select cleared the set", rs[0], 0);
    b1.wr(q[1], "z");
    rs[0] = 1 << q[0];
    b1.eq("select readable", b1.sc5(23, q[1] + 1, ptr_addr(&rs[0]), 0, 0, ptr_addr(&tv[0])), 1);
    b1.eq("select set bit", rs[0], 1 << q[0]);
    puts("done\n");
};
