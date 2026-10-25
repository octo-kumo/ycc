// A thread blocked in a raw syscall never reaches a safepoint, so the
// collector used to give up on every cycle and the heap only grew. The gc suite
// runs this under a small cap: 1.5M allocations of garbage (~90 MB) must fit
// while the other thread sits in read(2) on a pipe nothing writes to until the
// work is done.
def work(n: long) -> long {
    let i = 0;
    let acc = 0;
    while (i < n) {
        let s = "x" + tostring(i) + "-abcdefghijklmnop";
        acc = acc + s.length;
        i = i + 1;
    };
    acc
};
let fds: [byte] = [0, 0, 0, 0, 0, 0, 0, 0];
os_call("y_os_pipe", &fds[0]);
let rfd = fds[0] + 256 * fds[1];
let wfd = fds[4] + 256 * fds[5];
let t = spawn {
    let note = "reader " + tostring(rfd);
    let buf: [byte] = [0];
    let r = os_call("y_os_read", rfd, &buf[0], 1);
    note.length * 100 + r
};
print(work(1500000));
let go: [byte] = [120];
os_call("y_os_write", wfd, &go[0], 1);
print(join t > 0);
