// pulsed [-x] [-o file] [socket-path] -- a small PulseAudio server for Y-OS.
//
// It listens on /run/user/1000/pulse/native (or the path given) and speaks the
// subset of the Pulse native protocol that std/snd.y uses:
// AUTH, SET_CLIENT_NAME, CREATE_PLAYBACK_STREAM (REPLY with the channel and the
// bytes it wants, then REQUEST credits as it plays), data packets, DRAIN, FLUSH,
// DELETE_PLAYBACK_STREAM; CORK/TRIGGER/SUBSCRIBE are acknowledged; any other
// command gets an ERROR reply.  `-x` also honours the EXIT command, and `-o file` writes the
// PCM to `file` instead of /dev/dsp (tests use both).
//
// At most 4 streams are mixed (saturating 16-bit sum) into /dev/dsp.  The device
// takes the format of the first stream while any stream is alive (1 or 2
// channels); a stream of another rate or channel count is converted on the way
// in (nearest sample).  Without /dev/dsp (and without `-o`) the daemon is a null sink: the PCM is
// thrown away at the rate a card would play it, so a client is paced in real time and nothing
// piles up in RAM.
//
// One process, one poll loop: the listener, every client and (while mixed audio
// is waiting) the device.  Nothing here blocks on a single peer.
import ulib;

const MAXC = 8;
const MAXS = 4;
const ANY = 4294967295;
const CHUNK = 512;
const O_NONBLOCK = 2048;
const O_CLOEXEC = 524288;
const MSG_DONTWAIT = 64;
const EAGAIN = -11;
const POLLIN = 1;
const POLLOUT = 4;
const POLLERR = 8;
const POLLHUP = 16;
const PA_ERR_COMMAND = 2;
const PA_ERR_NOENTITY = 5;
const PA_ERR_INVALID = 3;
const PA_ERR_TOOLARGE = 18;
const DEFAULT_PATH = "/run/user/1000/pulse/native";

// clients
let c_fd: [long] = [];
let c_in: [[byte]] = [];
let c_out: [[byte]] = [];
// streams (the channel number a client sees is the slot)
let s_on: [long] = [];
let s_cl: [long] = [];
let s_idx: [long] = [];
let s_rate: [long] = [];
let s_ch: [long] = [];
let s_cap: [long] = [];
let s_minreq: [long] = [];
let s_want: [long] = [];
let s_phase: [long] = [];
let s_drain: [long] = [];
let s_buf: [[byte]] = [];

let next_stream = 0;
let allow_exit = false;
let quit = false;
let dsp_fd = -1;
let out_file = "";
let null_sink = false;
let null_t = 0;
let dev_rate = 0;
let dev_ch = 0;
let pending: [byte] = [];
let acc: [long; 1024] = [0; 1024];
let rbuf: [byte; 16384] = [0; 16384];
let pc = 0;

def setup() -> void {
    let i = 0;
    while (i < MAXC) {
        c_fd += -1;
        let e: [byte] = [];
        c_in += e;
        let o: [byte] = [];
        c_out += o;
        i = i + 1;
    };
    i = 0;
    while (i < MAXS) {
        s_on += 0;
        s_cl += -1;
        s_idx += 0;
        s_rate += 0;
        s_ch += 0;
        s_cap += 0;
        s_minreq += 0;
        s_want += 0;
        s_phase += 0;
        s_drain += -1;
        let b: [byte] = [];
        s_buf += b;
        i = i + 1;
    };
};

// ── tag-struct encoding (as std/snd.y writes it, and the replies mirror) ──
def be32(d: [byte], p: long) -> long {
    (d[p] << 24) | (d[p + 1] << 16) | (d[p + 2] << 8) | d[p + 3]
};

def u32(o: [byte], v: long) -> void {
    o += (v >> 24) & 255;
    o += (v >> 16) & 255;
    o += (v >> 8) & 255;
    o += v & 255;
};

def t_u32(o: [byte], v: long) -> void { o += 76; u32(o, v); };
def t_bool(o: [byte], b: bool) -> void { o += (if (b) { 49 } else { 48 }); };
def t_str(o: [byte], s: str) -> void {
    o += 116;
    let i = 0;
    while (i < len(s)) { o += s[i] & 255; i = i + 1; };
    o += 0;
};

/** The 20-byte frame descriptor + payload, queued for client `ci`. */
def queue_ctl(ci: long, payload: [byte]) -> void {
    let o: [byte] = [];
    u32(o, len(payload));
    u32(o, ANY);
    u32(o, 0);
    u32(o, 0);
    u32(o, 0);
    o += payload;
    c_out[ci] += o;
};

def reply_head(tag: long) -> [byte] {
    let p: [byte] = [];
    t_u32(p, 2);
    t_u32(p, tag);
    p
};

def send_ack(ci: long, tag: long) -> void { queue_ctl(ci, reply_head(tag)); };

def send_err(ci: long, tag: long, code: long) -> void {
    let p: [byte] = [];
    t_u32(p, 0);
    t_u32(p, tag);
    t_u32(p, code);
    queue_ctl(ci, p);
};

def send_request(ci: long, chan: long, n: long) -> void {
    let p: [byte] = [];
    t_u32(p, 61);
    t_u32(p, ANY);
    t_u32(p, chan);
    t_u32(p, n);
    queue_ctl(ci, p);
};

// ── tag-struct decoding: a cursor `pc` into one command body ──
/** The u32 ('L') at the cursor, or -1 when the tag does not match. */
def get_u32(d: [byte]) -> long {
    if (pc + 5 > len(d) || d[pc] != 76) { return -1; };
    let v = be32(d, pc + 1);
    pc = pc + 5;
    v
};

def get_bool(d: [byte]) -> long {
    if (pc + 1 > len(d)) { return -1; };
    let c = d[pc];
    pc = pc + 1;
    if (c == 49) { 1 } else if (c == 48) { 0 } else { -1 }
};

/** Skip a string ('t' text NUL, or 'N' null). */
def skip_str(d: [byte]) -> bool {
    if (pc >= len(d)) { return false; };
    if (d[pc] == 78) { pc = pc + 1; return true; };
    if (d[pc] != 116) { return false; };
    pc = pc + 1;
    while (pc < len(d) && d[pc] != 0) { pc = pc + 1; };
    pc = pc + 1;
    pc <= len(d)
};

// ── the device ──
def open_dsp() -> void {
    if (out_file != "") {
        dsp_fd = ulib.open(out_file, ulib.O_CREATE);
        return;
    };
    // write-only | non-blocking: a full card ring answers EAGAIN and the loop polls
    dsp_fd = ulib.open("/dev/dsp", 1 | O_NONBLOCK);
    if (dsp_fd < 0) { null_sink = true; };
};

def dsp_ioctl(req: long, v: long) -> void {
    let cell: [long; 1] = [v];
    syscall(16, dsp_fd, req, &cell[0]);
};

def dsp_format(rate: long, ch: long) -> void {
    dev_rate = rate;
    dev_ch = ch;
    // SNDCTL_DSP_RESET, SETFMT S16_LE, CHANNELS, SPEED (errors ignored: a file has none)
    dsp_ioctl(20480, 0);
    dsp_ioctl(3221508101, 16);
    dsp_ioctl(3221508102, ch);
    dsp_ioctl(3221508098, rate);
};

def active_streams() -> long {
    let n = 0;
    let i = 0;
    while (i < MAXS) { if (s_on[i] == 1) { n = n + 1; }; i = i + 1; };
    n
};

// ── streams ──
def stream_free(i: long) -> void {
    s_on[i] = 0;
    s_cl[i] = -1;
    let b: [byte] = [];
    s_buf[i] = b;
    s_drain[i] = -1;
    s_phase[i] = 0;
};

def find_stream(ci: long, chan: long) -> long {
    if (chan < 0 || chan >= MAXS) { return -1; };
    if (s_on[chan] == 1 && s_cl[chan] == ci) { chan } else { -1 }
};

def create_stream(ci: long, tag: long, d: [byte]) -> void {
    pc = 10;
    if (pc + 7 > len(d) || d[pc] != 97) { send_err(ci, tag, PA_ERR_INVALID); return; };
    let fmt = d[pc + 1];
    let ch = d[pc + 2];
    let rate = be32(d, pc + 3);
    pc = pc + 7;
    if (pc + 2 > len(d) || d[pc] != 109) { send_err(ci, tag, PA_ERR_INVALID); return; };
    pc = pc + 2 + d[pc + 1];
    let sink = get_u32(d);
    let named = skip_str(d);
    let maxlen = get_u32(d);
    let corked = get_bool(d);
    let tlen = get_u32(d);
    let prebuf = get_u32(d);
    let minreq = get_u32(d);
    if (sink < 0 || !named || maxlen < 0 || corked < 0 || tlen < 0 || prebuf < 0 || minreq < 0) {
        send_err(ci, tag, PA_ERR_INVALID);
        return;
    };
    if (fmt != 3 || ch < 1 || ch > 8 || rate < 4000 || rate > 192000) {
        send_err(ci, tag, PA_ERR_INVALID);
        return;
    };
    let i = 0;
    while (i < MAXS && s_on[i] == 1) { i = i + 1; };
    if (i >= MAXS) { send_err(ci, tag, PA_ERR_TOOLARGE); return; };
    if (active_streams() == 0) {
        let dc = if (ch > 1) { 2 } else { 1 };
        if (rate != dev_rate || dc != dev_ch) { dsp_format(rate, dc); };
        pending = [];
    };
    // the buffer: the client's tlength when it gave one, else a quarter second
    let cap = tlen;
    if (cap == 0 || cap > 65536) { cap = rate * 2 * ch / 4; };
    if (cap < 2048) { cap = 2048; };
    if (cap > 65536) { cap = 65536; };
    let mr = minreq;
    if (mr == 0 || mr > cap) { mr = cap / 4; };
    s_on[i] = 1;
    s_cl[i] = ci;
    s_idx[i] = next_stream;
    next_stream = next_stream + 1;
    s_rate[i] = rate;
    s_ch[i] = ch;
    s_cap[i] = cap;
    s_minreq[i] = mr;
    s_want[i] = cap;
    s_phase[i] = 0;
    s_drain[i] = -1;
    let b: [byte] = [];
    s_buf[i] = b;
    let p = reply_head(tag);
    t_u32(p, i);
    t_u32(p, s_idx[i]);
    t_u32(p, cap);
    t_u32(p, cap);
    t_u32(p, cap);
    t_u32(p, prebuf);
    t_u32(p, mr);
    p += 97;
    p += 3;
    p += ch;
    u32(p, rate);
    p += 109;
    p += ch;
    let k = 0;
    while (k < ch) { p += (if (ch == 1) { 0 } else if (k == 0) { 1 } else if (k == 1) { 2 } else { k + 1 }); k = k + 1; };
    t_u32(p, 0);
    t_str(p, "yunix");
    t_bool(p, false);
    queue_ctl(ci, p);
};

def client_close(ci: long) -> void {
    let i = 0;
    while (i < MAXS) {
        if (s_on[i] == 1 && s_cl[i] == ci) { stream_free(i); };
        i = i + 1;
    };
    if (c_fd[ci] >= 0) { syscall(3, c_fd[ci]); };
    c_fd[ci] = -1;
    let e: [byte] = [];
    c_in[ci] = e;
    let o: [byte] = [];
    c_out[ci] = o;
};

def command(ci: long, d: [byte]) -> void {
    if (len(d) < 10 || d[0] != 76 || d[5] != 76) { return; };
    let cmd = be32(d, 1);
    let tag = be32(d, 6);
    if (cmd == 8) {
        let p = reply_head(tag);
        t_u32(p, 35);
        queue_ctl(ci, p);
    } else if (cmd == 9) {
        let p = reply_head(tag);
        t_u32(p, ci);
        queue_ctl(ci, p);
    } else if (cmd == 3) {
        create_stream(ci, tag, d);
    } else if (cmd == 4 || cmd == 12 || cmd == 20) {
        // DELETE / DRAIN / FLUSH: the channel follows the tag
        let s = if (len(d) >= 15 && d[10] == 76) { find_stream(ci, be32(d, 11)) } else { -1 };
        if (s < 0) { send_err(ci, tag, PA_ERR_NOENTITY); }
        else if (cmd == 4) {
            stream_free(s);
            send_ack(ci, tag);
        } else if (cmd == 20) {
            let b: [byte] = [];
            s_buf[s] = b;
            s_phase[s] = 0;
            send_ack(ci, tag);
        } else if (len(s_buf[s]) == 0 && len(pending) == 0) {
            send_ack(ci, tag);
        } else {
            s_drain[s] = tag;
        };
    } else if (cmd == 18 || cmd == 19 || cmd == 35 || cmd == 56) {
        send_ack(ci, tag);
    } else if (cmd == 7 && allow_exit) {
        send_ack(ci, tag);
        quit = true;
    } else {
        send_err(ci, tag, PA_ERR_COMMAND);
    };
};

def data(ci: long, chan: long, body: [byte]) -> void {
    let s = find_stream(ci, chan);
    if (s < 0) { return; };
    let n = len(body);
    if (len(s_buf[s]) + n > s_cap[s] * 2) { n = s_cap[s] * 2 - len(s_buf[s]); };
    let frame = 2 * s_ch[s];
    n = n - n % frame;
    if (n > 0) { s_buf[s] += body[0:n]; };
    s_want[s] = s_want[s] - len(body);
    if (s_want[s] < 0) { s_want[s] = 0; };
};

/** Cut every whole packet out of client `ci`'s input and act on it. */
def parse(ci: long) -> void {
    while (c_fd[ci] >= 0) {
        let b = c_in[ci];
        if (len(b) < 20) { return; };
        let n = be32(b, 0);
        if (n > 1048576) { client_close(ci); return; };
        if (len(b) < 20 + n) { return; };
        let chan = be32(b, 4);
        let body = b[20:20 + n];
        c_in[ci] = b[20 + n:len(b)];
        if (chan == ANY) { command(ci, body); } else { data(ci, chan, body); };
    };
};

def client_read(ci: long) -> void {
    let r = syscall(0, c_fd[ci], &rbuf[0], 16384);
    if (r == EAGAIN || r == -4) { return; };
    if (r <= 0) { client_close(ci); return; };
    c_in[ci] += rbuf[0:r];
    parse(ci);
};

def client_flush(ci: long) -> void {
    while (c_fd[ci] >= 0 && len(c_out[ci]) > 0) {
        let ob = c_out[ci];
        let r = syscall(44, c_fd[ci], &ob[0], len(ob), MSG_DONTWAIT, 0, 0);
        if (r == EAGAIN || r == -4) { return; };
        if (r <= 0) { client_close(ci); return; };
        c_out[ci] = ob[r:len(ob)];
    };
};

// ── mixing ──
def sample16(b: [byte], off: long) -> long {
    let v = b[off] | (b[off + 1] << 8);
    if (v >= 32768) { v - 65536 } else { v }
};

/** Device frames stream `s` can supply now. */
def frames_ready(s: long) -> long {
    let have = len(s_buf[s]) / (2 * s_ch[s]);
    let step = (s_rate[s] << 16) / dev_rate;
    let top = (have << 16) - s_phase[s];
    if (have == 0 || top <= 0) { return 0; };
    (top - 1) / step + 1
};

/** Mix up to CHUNK device frames into `pending`; false when nothing is playable. */
def mix() -> bool {
    let nout = 0;
    let s = 0;
    while (s < MAXS) {
        if (s_on[s] == 1) {
            let f = frames_ready(s);
            if (f > nout) { nout = f; };
        };
        s = s + 1;
    };
    if (nout > CHUNK) { nout = CHUNK; };
    if (nout == 0) { return false; };
    let k = 0;
    while (k < nout * dev_ch) { acc[k] = 0; k = k + 1; };
    s = 0;
    while (s < MAXS) {
        if (s_on[s] == 1) {
            let used = frames_ready(s);
            if (used > nout) { used = nout; };
            let step = (s_rate[s] << 16) / dev_rate;
            let sch = s_ch[s];
            let b = s_buf[s];
            k = 0;
            while (k < used) {
                let at = ((s_phase[s] + k * step) >> 16) * sch * 2;
                if (dev_ch == 1) {
                    if (sch == 1) { acc[k] = acc[k] + sample16(b, at); }
                    else { acc[k] = acc[k] + (sample16(b, at) + sample16(b, at + 2)) / 2; };
                } else if (sch == 1) {
                    let v = sample16(b, at);
                    acc[2 * k] = acc[2 * k] + v;
                    acc[2 * k + 1] = acc[2 * k + 1] + v;
                } else {
                    acc[2 * k] = acc[2 * k] + sample16(b, at);
                    acc[2 * k + 1] = acc[2 * k + 1] + sample16(b, at + 2);
                };
                k = k + 1;
            };
            let moved = s_phase[s] + used * step;
            let eat = (moved >> 16) * sch * 2;
            if (eat > len(b)) { eat = len(b); };
            s_buf[s] = b[eat:len(b)];
            s_phase[s] = moved & 65535;
        };
        s = s + 1;
    };
    k = 0;
    while (k < nout * dev_ch) {
        let v = acc[k];
        if (v > 32767) { v = 32767; };
        if (v < -32768) { v = -32768; };
        if (v < 0) { v = v + 65536; };
        pending += v & 255;
        pending += v >> 8;
        k = k + 1;
    };
    true
};

/** The null sink "plays" what a card would have in the time since the last call. */
def null_drain() -> void {
    let now = clock_us();
    let dt = now - null_t;
    if (null_t == 0 || dt > 50000) { dt = 50000; };
    null_t = now;
    let n = dt * dev_rate * dev_ch * 2 / 1000000;
    n = n - n % 2;
    if (n >= len(pending)) { pending = []; } else { pending = pending[n:len(pending)]; };
};

def dsp_flush() -> void {
    if (len(pending) == 0) { return; };
    if (null_sink) { null_drain(); return; };
    let r = syscall(1, dsp_fd, &pending[0], len(pending));
    if (r > 0) { pending = pending[r:len(pending)]; }
    else if (r != EAGAIN && r != -4) { pending = []; };
};

/** Credits and drain acknowledgements, after buffers changed. */
def settle() -> void {
    let s = 0;
    while (s < MAXS) {
        if (s_on[s] == 1) {
            let ci = s_cl[s];
            let room = s_cap[s] - len(s_buf[s]) - s_want[s];
            if (room >= s_minreq[s] || (room > 0 && len(s_buf[s]) == 0 && s_want[s] == 0)) {
                send_request(ci, s, room);
                s_want[s] = s_want[s] + room;
            };
            if (s_drain[s] >= 0 && len(s_buf[s]) == 0 && len(pending) == 0) {
                send_ack(ci, s_drain[s]);
                s_drain[s] = -1;
            };
        };
        s = s + 1;
    };
};

def playable() -> bool {
    let s = 0;
    while (s < MAXS) {
        if (s_on[s] == 1 && frames_ready(s) > 0) { return true; };
        s = s + 1;
    };
    false
};

def mkdir(path: str) -> void {
    let p = ulib.cstr(path);
    syscall(83, &p[0], 493);
};

def set_pfd(pf: [byte; 160], i: long, fd: long, ev: long) -> void {
    pf[i * 8] = fd & 255;
    pf[i * 8 + 1] = (fd >> 8) & 255;
    pf[i * 8 + 2] = (fd >> 16) & 255;
    pf[i * 8 + 3] = (fd >> 24) & 255;
    pf[i * 8 + 4] = ev;
    pf[i * 8 + 5] = 0;
    pf[i * 8 + 6] = 0;
    pf[i * 8 + 7] = 0;
};

def revents(pf: [byte; 160], i: long) -> long { pf[i * 8 + 6] | (pf[i * 8 + 7] << 8) };

def sockaddr(path: str) -> [byte] {
    let a: [byte] = [1, 0];
    let i = 0;
    while (i < len(path)) { a += path[i] & 255; i = i + 1; };
    a += 0;
    a
};

def serve(path: str) -> long {
    ulib.unlink(path);
    let lfd = syscall(41, 1, 1 | O_CLOEXEC, 0);
    if (lfd < 0) { eputs("pulsed: no socket\n"); return 1; };
    let a = sockaddr(path);
    if (syscall(49, lfd, &a[0], len(a)) < 0) { eputs("pulsed: cannot bind " + path + "\n"); return 1; };
    if (syscall(50, lfd, 8) < 0) { eputs("pulsed: cannot listen\n"); return 1; };
    open_dsp();
    let pf: [byte; 160] = [0; 160];
    let owner: [long; 20] = [0; 20];
    while (!quit) {
        // the poll set: the listener, each client, the device while it has a backlog
        let n = 0;
        set_pfd(pf, n, lfd, POLLIN);
        owner[n] = -1;
        n = n + 1;
        let ci = 0;
        while (ci < MAXC) {
            if (c_fd[ci] >= 0) {
                set_pfd(pf, n, c_fd[ci], POLLIN | (if (len(c_out[ci]) > 0) { POLLOUT } else { 0 }));
                owner[n] = ci;
                n = n + 1;
            };
            ci = ci + 1;
        };
        let dev_at = -1;
        if (len(pending) > 0 && dsp_fd >= 0) {
            set_pfd(pf, n, dsp_fd, POLLOUT);
            dev_at = n;
            n = n + 1;
        };
        let wait = 200;
        if (len(pending) == 0 && playable()) { wait = 0; }
        else if (len(pending) > 0) { wait = 20; };
        let r = syscall(7, &pf[0], n, wait);
        if (r > 0) {
            if ((revents(pf, 0) & POLLIN) != 0) {
                let nfd = syscall(288, lfd, 0, 0, O_NONBLOCK | O_CLOEXEC);
                if (nfd >= 0) {
                    let slot = 0;
                    while (slot < MAXC && c_fd[slot] >= 0) { slot = slot + 1; };
                    if (slot >= MAXC) { syscall(3, nfd); } else { c_fd[slot] = nfd; };
                };
            };
            let k = 1;
            while (k < n) {
                if (k != dev_at) {
                    let who = owner[k];
                    let ev = revents(pf, k);
                    if (c_fd[who] >= 0 && (ev & (POLLIN | POLLHUP | POLLERR)) != 0) { client_read(who); };
                };
                k = k + 1;
            };
        };
        dsp_flush();
        if (len(pending) == 0 && playable()) {
            mix();
            dsp_flush();
        };
        settle();
        ci = 0;
        while (ci < MAXC) {
            client_flush(ci);
            ci = ci + 1;
        };
    };
    // let the last replies out
    let ci = 0;
    while (ci < MAXC) {
        client_flush(ci);
        ci = ci + 1;
    };
    0
};

let args = argv();
setup();
let path = DEFAULT_PATH;
let ai = 1;
while (ai < len(args)) {
    if (args[ai] == "-x") { allow_exit = true; }
    else if (args[ai] == "-o" && ai + 1 < len(args)) { out_file = args[ai + 1]; ai = ai + 1; }
    else { path = args[ai]; };
    ai = ai + 1;
};
if (path == DEFAULT_PATH) {
    // the directories may not exist yet (init makes /run/user/1000); errors are fine
    mkdir("/run");
    mkdir("/run/user");
    mkdir("/run/user/1000");
    mkdir("/run/user/1000/pulse");
};
exit(serve(path));
