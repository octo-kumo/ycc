// flags: --gc=always --regions=off
import memstat;
// The reader's raw ARM read must publish its stack while a peer collects.
let fds: [long; 1] = [0];
print(syscall(59, &fds[0], 0));
let ready = sem(0);
let reader = spawn {
    let text = "still live";
    let buf: [byte] = [0];
    post ready;
    let n = syscall(63, fds[0] & 0xffffffff, &buf[0], 1);
    text + tostring(n) + tostring(buf[0])
};
wait ready;
sleep(10);
let total = 0;
for i in 0..1500000 {
    let s = "garbage-" + tostring(i);
    total += s.length;
};
print(total);
print(memstat.rss_kb() < 65536);
let go: [byte] = [65];
print(syscall(64, fds[0] >>> 32, &go[0], 1));
print(join reader);
print(syscall(57, fds[0] & 0xffffffff));
print(syscall(57, fds[0] >>> 32));
