// pulsetest [socket [pulsed]] -- exercise pulsed through std/snd.y's own stream code.
//
// Starts `pulsed -x -o dsp.out` (default /bin/pulsed) on `socket` (default /pulse.sock), so the
// PCM lands in dsp.out whatever sound card there is; plays through snd.write/drain and checks the
// bytes: one stream passes through unchanged, two streams (22050 and 44100 Hz) mix
// to the sum of their samples, an unknown command is refused, and EXIT ends the daemon.
import ulib;
import ipc;
import snd;

def be32(d: [byte], p: long) -> long {
    (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3]
};

def nap(ms: long) -> void { syscall(7, 0, 0, ms); };

/** One packet from `fd`: the control body, skipping data frames; none at EOF. */
def read_ctl(fd: long) -> [byte]? {
    while (true) {
        let h = ipc.recv_exact(fd, 20);
        if (h == none) { return none; };
        let n = be32(h!, 0);
        let body: [byte] = [];
        if (n > 0) {
            let b = ipc.recv_exact(fd, n);
            if (b == none) { return none; };
            body = b!;
        };
        if (be32(h!, 4) == 4294967295 && len(body) >= 10 && be32(body, 1) != 61) { return some(body); };
    };
    none
};

def call(fd: long, pkt: [byte]) -> [byte]? {
    if (!ipc.send(fd, pkt)) { return none; };
    read_ctl(fd)
};

def connect(path: str) -> long {
    let fd = -1;
    let tries = 0;
    while (fd < 0 && tries < 300) {
        fd = ipc.connect_unix(path);
        if (fd < 0) { nap(20); };
        tries = tries + 1;
    };
    fd
};

def open_stream(path: str, rate: long, ch: long) -> snd.Stream? {
    let fd = connect(path);
    if (fd < 0) { return none; };
    let cookie: [byte] = [];
    let i = 0;
    while (i < 256) { cookie += 0; i = i + 1; };
    let a = call(fd, snd.auth_packet(cookie));
    let n = call(fd, snd.name_packet(1, "pulsetest"));
    let r = call(fd, snd.create_packet(2, rate, ch, "pulsetest"));
    if (a == none || n == none || r == none || be32(r!, 1) != 2 || len(r!) < 25) { return none; };
    let s: snd.Stream = { fd: fd, chan: be32(r!, 11), avail: be32(r!, 21), tag: 3, ok: true, rate: rate, channels: ch };
    some(s)
};

/** `frames` mono s16 samples, all `v`, or (v < 0) a ramp 0, 1, 2 ... */
def pcm(frames: long, v: long) -> [byte] {
    let b: [byte] = [];
    let i = 0;
    while (i < frames) {
        let x = if (v < 0) { i } else { v };
        b += x & 255;
        b += (x >> 8) & 255;
        i = i + 1;
    };
    b
};

def s16(b: [byte], at: long) -> long {
    let v = b[at] | (b[at + 1] << 8);
    if (v >= 32768) { v - 65536 } else { v }
};

def put32(o: [byte], v: long) -> void {
    o += (v >> 24) & 255;
    o += (v >> 16) & 255;
    o += (v >> 8) & 255;
    o += v & 255;
};

/** A bare control packet: command `cmd`, tag `tag`, no arguments. */
def command(cmd: long, tag: long) -> [byte] {
    let o: [byte] = [];
    put32(o, 10);
    put32(o, 4294967295);
    put32(o, 0);
    put32(o, 0);
    put32(o, 0);
    o += 76;
    put32(o, cmd);
    o += 76;
    put32(o, tag);
    o
};

def report(name: str, ok: bool) -> void {
    puts((if (ok) { "ok " } else { "FAIL " }) + name + "\n");
};

let a = argv();
let path = if (len(a) > 1) { a[1] } else { "/pulse.sock" };
let daemon = if (len(a) > 2) { a[2] } else { "/bin/pulsed" };
ulib.unlink("dsp.out");
let pid = ulib.fork();
if (pid == 0) {
    ulib.exec(daemon, ["pulsed", "-x", "-o", "dsp.out", path], ulib.environ());
    exit(127);
};

// 1. a ramp through one stream arrives unchanged
let s1 = open_stream(path, 22050, 1);
report("create stream", s1 != none);
if (s1 == none) { exit(1); };
let ramp = pcm(4000, -1);
report("write", snd.write(s1!, ramp));
report("drain", snd.drain(s1!));
snd.close(s1!);
let out = ulib.read_all("dsp.out");
report("ramp passes through", out != none && len(out!) == 8000 && out![0:8000] == ramp);

// 2. two streams, 22050 and 44100 Hz, mix to the sum
let sa = open_stream(path, 22050, 1);
let sb = open_stream(path, 44100, 1);
report("two streams", sa != none && sb != none);
if (sa == none || sb == none) { exit(1); };
let pa = pcm(4000, 1000);
let pb = pcm(8000, 2000);
report("write a", snd.write(sa!, pa));
report("write b", snd.write(sb!, pb));
report("drain a", snd.drain(sa!));
report("drain b", snd.drain(sb!));
snd.close(sa!);
snd.close(sb!);
nap(100);
let out2 = ulib.read_all("dsp.out");
let sum = 0;
let frames = 0;
if (out2 != none) {
    let at = 8000;
    while (at + 1 < len(out2!)) {
        sum = sum + s16(out2!, at);
        frames = frames + 1;
        at = at + 2;
    };
};
let mixed_ok = sum == 12000000 && frames >= 4000 && frames <= 8000;
report("mixed sum", mixed_ok);
if (!mixed_ok) { puts("  sum " + tostring(sum) + " in " + tostring(frames) + " frames\n"); };

// 3. an unknown command is refused; EXIT ends the daemon
let fd = connect(path);
let e = call(fd, command(99, 7));
report("unknown command refused", e != none && be32(e!, 1) == 0 && be32(e!, 6) == 7);
let x = call(fd, command(7, 8));
report("exit acknowledged", x != none && be32(x!, 1) == 2);
ipc.close(fd);
let w = ulib.wait_child();
report("daemon gone", w == pid);
exit(0);
