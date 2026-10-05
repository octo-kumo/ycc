// mud.y -- a MUD server and client over loopback TCP, with threads.
//
//   usage: mud [options]
//
//   A threaded server binds an ephemeral port on 127.0.0.1, hands every
//   connection to a worker from a FIXED-SIZE pool, and runs a world of rooms
//   generated from --seed.  Clients log in, walk, take, drop, fight and talk to
//   each other, and render a transcript of the whole thing.
//
//   ./mud                  the deterministic run: two clients, a bounded
//                          script, a transcript on stdout that is a pure
//                          function of --seed and --frames
//   ./mud --live           the interactive terminal client, same server
//   ./mud --check          the property checks, no reference file involved
//   ./mud --bench N        N connections through the pool, then throughput
//                          and heap numbers
//
//   build: refs/ycc.ref mud.y -o mud
//          (world.y sockio.y server.y client.y driver.y props.y
//           tui tui args must sit beside it)
//   run:   ./mud --frames 20 --seed 1
//
// ---------------------------------------------------------------------------
// THE MODULES
// ---------------------------------------------------------------------------
//
//   world.y    rooms, exits, items, monsters (built from std/random.y); and
//              the BFS that proves the generated graph is connected and two-way
//   sockio.y   sockets, a fixed-buffer line reader, and the byte appends every
//              reply is built through
//   server.y   the accept loop, the worker pool, sessions, the verbs, the
//              protocol
//   client.y   the client's parsed view, the protocol parser, the renderers
//   driver.y   starting the pool, running a client, the two paired scripts
//              the property checks use
//   props.y    the four property checks
//   mud.y      flags, modes, the run summary, the live view, main
//
// ---------------------------------------------------------------------------
// DETERMINISM
// ---------------------------------------------------------------------------
//
// There is no unseeded randomness and no clock on the default path.  `--seed`
// defaults to 1 and the run is a pure function of (seed, frames, clients,
// workers), so EXPECTED is a real assertion rather than a snapshot.  The kernel
// picks the port (bind to 0) and that port is never printed: it differs every run
// and printing it would make the output irreproducible for nothing.  tui
// appears only in `--live` (the frame pacer) and `--bench` (the rate report),
// and the clock only in the `--time` line on stderr.
//
// Note that `--frames` is NOT the frame count here (there are no frames in the
// headless run); it is the number of commands each client sends, which is what
// bounds the transcript and keeps the gate's diff small.

import net;
import sockio;
import world;
import server;
import client;
import driver;
import props;
import args;
import tui;

const OPTS: [args.Opt] = [
    { long: "frames", short: "f", kind: args.NUM, help: "commands per client in the deterministic run (default 20)" },
    { long: "seed", short: "s", kind: args.NUM, help: "world seed (default 1)" },
    { long: "clients", short: "c", kind: args.NUM, help: "concurrent clients, 1..8 (default 2)" },
    { long: "workers", short: "w", kind: args.NUM, help: "pool size, 1..8 (default 4)" },
    { long: "check", short: "k", kind: args.BOOL, help: "run the property checks and exit" },
    { long: "bench", short: "b", kind: args.NUM, help: "drive N connections through the pool, then report" },
    { long: "live", short: "l", kind: args.BOOL, help: "interactive terminal client" },
    { long: "time", short: "t", kind: args.BOOL, help: "print elapsed ms and heap to stderr" }
    // NOTE: do NOT declare a `help` option here.
    //
    // `args.parse_or_exit()` returns HELP only when `--help` is *not* in the
    // option table: it looks the name up, and an unknown name called "help"
    // is the HELP request, while a DECLARED "help" is an ordinary flag that
    // gets stored and otherwise ignored. This program used to declare
    // `{ long: "help", short: "h", ... }` and never read `args.has("help")`
    // -- so `mud --help` stored a bool nobody looked at and then started a
    // game. The error path just below tells the user to run `mud --help`,
    // which is exactly the invocation that did nothing. Leaving "help"
    // undeclared is what makes both of those true.
    //
    // Found by the orchestrator's flag audit, not by the gate: item 2 only
    // proves the DEFAULT run reproduces EXPECTED, and a `--help` that starts
    // a game is a different program entirely.
];

def bad(msg: str) -> long {
    eputs("mud: " + msg + "\n");
    eputs("try `mud --help'\n");
    exit(1);
    0
};

// "  key .......... value" -- aligned, because a report is read by eye.  It writes
// into the SUMMARY region, not into a client's transcript.
def kv(n: long, k: str, v: long) -> long {
    n = client.ss(n, "  ");
    n = client.ss(n, k);
    let i = len(k);
    while (i < 22) { n = client.ss(n, "."); i = i + 1 };
    n = client.ss(n, " ");
    n = client.sv(n, v);
    client.sn(n, 10)
};

// ---------------------------------------------------------------------------
// the deterministic run
// ---------------------------------------------------------------------------
//
// Two clients, each a thread, each running the step table in driver.y.  They are
// spawned TOGETHER and the transcripts are printed in slot order, so the byte
// stream does not depend on which finished first.
//
// The clients are connected to the SAME server through the pool, so this run
// already exercises: concurrent connections, a bounded pool, per-session state,
// cross-session chat through the pending region, and the whole render path.
// Only the live view is left to --live.

def run(seed: long, frames: long, ncli: long, nw: long) -> long {
    let rooms = world.generate(seed);
    // The checks that need no client run first, so a broken world is reported
    // before a socket is opened.
    let bad_rooms = world.unreachable();
    let bad_exits = world.one_way();
    let dup = world.dup_dirs();

    let port = sockio.port_of(driver.serve(nw, ncli, ncli, seed));
    let h0 = heap_used();
    let i = 0;
    while (i < ncli) {
        let c = i;
        spawn {
            // one buffer set per client THREAD, which is once per client
            let tx: [byte; 4096] = [0; 4096];
            let rx: [byte; 4096] = [0; 4096];
            let hold: [long; 2] = [0; 2];
            let tv: [long; 2] = [0; 2];
            let sa: [byte; 16] = [0; 16];
            driver.run_client(c, port, frames, ncli, tx, rx, hold, tv, sa)
        };
        i = i + 1;
    };
    let fin = driver.wait_done(ncli);
    let h1 = heap_used();
    driver.stop(nw);

    // ---- the run's own summary, into its OWN 64 KiB region (client.SUM) and
    // printed with one write(1).  It deliberately does NOT go into a client's
    // transcript region: an earlier version ended a paragraph with
    // `client.tnl(0, n)` -- the TRANSCRIPT family's newline, whose first argument
    // is the client slot -- which wrote a single 0x0A into client 0's transcript
    // at the summary's current length.  Byte 437 of the transcript became a
    // newline, so `on the floor:` printed as `on the fl` / `or:` and the golden
    // file recorded it.  The summary family is sn/ss/sv; the transcript family is
    // tc/ts/tn/tnl; mixing them is now a compile-time-visible difference in the
    // argument list.
    let n = 0;
    n = client.ss(n, "================================================================\n");
    n = client.ss(n, "  mud -- a threaded MUD over loopback TCP\n");
    n = client.ss(n, "================================================================\n");
    n = kv(n, "seed", seed);
    n = kv(n, "rooms", rooms);
    n = kv(n, "exits", world.exits_total());
    n = kv(n, "item instances", world.insts());
    n = kv(n, "clients", ncli);
    n = kv(n, "pool workers", nw);
    n = kv(n, "commands per client", frames);
    n = kv(n, "unreachable rooms", bad_rooms);
    n = kv(n, "one-way exits", bad_exits);
    n = kv(n, "duplicate directions", dup);
    n = client.sn(n, 10);
    n = kv(n, "connections served", server.N_CONN[0]);
    n = kv(n, "peak concurrent", server.N_PEAK[0]);
    n = kv(n, "commands handled", server.n_cmd());
    n = kv(n, "turns played", server.n_turn());
    n = kv(n, "chat lines spoken", server.n_say());
    n = kv(n, "errors reported", server.n_err());
    n = kv(n, "replies too large", server.n_long());
    n = kv(n, "over-long lines", server.n_trunc());
    n = kv(n, "clients finished", fin);
    n = kv(n, "main heap delta", h1 - h0);
    n = kv(n, "worker heap growth", worker_growth(nw));
    n = kv(n, "worst worker growth", worst_worker(nw));
    n = client.sn(n, 10);
    client.SUMLEN[0] = n;

    let c = 0;
    while (c < ncli) {
        client.emit(c);
        c = c + 1;
    };
    client.emit_summary();

    // A run that did not finish its script is a FAILURE, loudly: a truncated
    // transcript that still matched EXPECTED would be the worst possible outcome.
    let v = 0;
    let why = 0;
    while (v < ncli) {
        if (client.V_STEPS[v] != frames || client.V_STALLS[v] != 0 || client.V_OVF[v] != 0
            || client.V_RC[v] != 0) {
            why = why + 1;
        };
        v = v + 1;
    };
    if (why > 0) {
        bad("a client did not finish its script (" + tostring(why) + " of " + tostring(ncli) + ")");
    };
    if (bad_rooms != 0 || bad_exits != 0 || dup != 0) {
        bad("the generated world is not a sound graph");
    };
    0
};

def worker_growth(nw: long) -> long {
    let g = 0;
    let i = 0;
    while (i < nw) {
        if (server.WK_GROW[i] > g) { g = server.WK_GROW[i] };
        i = i + 1;
    };
    g
};

def worst_worker(nw: long) -> long {
    let g = 0;
    let i = 0;
    while (i < nw) {
        if (server.WK_PEAK[i] > g) { g = server.WK_PEAK[i] };
        i = i + 1;
    };
    g
};

// ---------------------------------------------------------------------------
// --bench: N connections through the pool, with throughput and heap numbers
// ---------------------------------------------------------------------------

def bench(seed: long, want: long) -> long {
    world.generate(seed);
    let nw = 8;
    let port = sockio.port_of(driver.serve(nw, want, 1, seed));
    let h0 = heap_used();
    let w0 = worker_growth(nw);
    let p0 = worst_worker(nw);
    let t0 = clock_us();
    // The clients run ONE AT A TIME on purpose: the point is connections per
    // second through the pool, and eight client threads each waiting on their
    // own round trip would measure the scheduler instead.
    // ONE buffer set for the whole bench, reused by every connection -- see
    // driver.run_client for why the buffers are the caller's
    let btx: [byte; 4096] = [0; 4096];
    let brx: [byte; 4096] = [0; 4096];
    let bhold: [long; 2] = [0; 2];
    let btv: [long; 2] = [0; 2];
    let bsa: [byte; 16] = [0; 16];
    let i = 0;
    while (i < want) {
        driver.run_client(i % client.MAXC, port, 6, 1, btx, brx, bhold, btv, bsa);
        i = i + 1;
    };
    let t1 = clock_us();
    let h1 = heap_used();
    let w1 = worker_growth(nw);
    let p1 = worst_worker(nw);
    driver.stop(nw);
    let cps = 0;
    if (t1 > t0) { cps = want * 1000000 / (t1 - t0) };
    let n = 0;
    n = client.ss(n, "  mud --bench\n");
    n = kv(n, "connections", want);
    n = kv(n, "commands per client", 8);
    n = kv(n, "commands served", server.n_cmd());
    n = kv(n, "elapsed ms", (t1 - t0) / 1000);
    n = kv(n, "connections/second", cps);
    n = kv(n, "commands/second", (if (t1 > t0) { server.n_cmd() * 1000000 / (t1 - t0) } else { 0 }));
    n = kv(n, "main heap delta", h1 - h0);
    n = kv(n, "worker heap growth", w1 - w0);
    n = kv(n, "worst worker growth", p1 - p0);
    client.SUMLEN[0] = n;
    client.emit_summary();
    0
};

// ---------------------------------------------------------------------------
// --live: the interactive client
// ---------------------------------------------------------------------------
//
// The same server, the same protocol, the same renderers -- only the sink
// differs.  The live view draws the tail of client 0's transcript region, which
// is the same bytes the headless run prints, so the two views cannot disagree.

let IN: [byte; 80] = [0; 80];       // the input line; never a str

// TIOCGWINSZ into ONE module-level buffer.  tui.size() returns a FRESH record on
// every call (~40 bytes, ORCHESTRATOR.md 2.3) and a per-frame resize poll that
// calls it leaks; this does the ioctl into [byte; 64] and reads the four 16-bit
// little-endian values out of it -- row FIRST, at bytes 0-1.
let WS: [byte; 64] = [0; 64];
def probe_winsize() -> long {
    syscall(16, 1, 0x5413, &WS[0])
};

def live(seed: long, nw: long) -> long {
    world.generate(seed);
    let port = sockio.port_of(driver.serve(nw, 1, 1, seed));
    let sa: [byte; 16] = [0; 16];
    let fd = sockio.dial(sa, port);
    if (fd < 0) { bad("cannot reach the server") };
    let tx: [byte; 4096] = [0; 4096];
    let rx: [byte; 4096] = [0; 4096];
    let hold: [long; 2] = [0; 2];
    let tv: [long; 2] = [0; 2];
    sockio.set_timeout(fd, 30, tv);
    sockio.line_reset(hold);
    client.reset(0, "ranger", 0, 1);
    if (!tui.raw_mode()) {
        bad("cannot put the terminal in raw mode; use --frames N for the headless run");
    };
    driver.send_cmd(0, fd, tx, rx, hold, "login ", "ranger");
    let rows = 24;
    let cols = 80;
    probe_winsize();
    let r = WS[0] + WS[1] * 256;
    let c = WS[2] + WS[3] * 256;
    if (r > 2) { rows = r };
    if (c > 2) { cols = c };
    tui.enter_screen();
    let ll = 0;
    let running = true;
    let p = tui.pacer_new(30);
    let polls = 0;
    while (running) {
        tui.pacer_next(p);
        // read_key_timeout(0) -- NEVER a non-zero timeout.  VTIME counts
        // DECISECONDS, so any non-zero ms rounds UP to the next 100 ms
        // (ORCHESTRATOR.md 2.3, measured: five read_key_timeout(1) calls took
        // 518 ms).  A client that polls for a key with a 1 ms timeout spends
        // 100 ms per frame, drops every frame at the pacer, and reports a
        // fraction of the rate it is really achieving.  The pacer owns the
        // deadline; the key poll is non-blocking.
        let k = tui.read_key_timeout(0);
        polls = polls + 1;
        if (k == 13 || k == 10) {
            let m = 0;
            while (m < ll) { tx[m] = IN[m]; m = m + 1 };
            tx[ll] = 10;
            client.TLEN[0] = client.ts(0, client.TLEN[0], "> ");
            client.TLEN[0] = client.tmem(0, client.TLEN[0], tx, 0, ll);
            client.TLEN[0] = client.tnl(0, client.TLEN[0]);
            sockio.send_buf(fd, tx, ll + 1);
            if (ll == 4 && (IN[0] == 113 || IN[0] == 81)) { running = false };
            driver.drain(0, fd, rx, hold);
            ll = 0;
        } else if (k == 127 || k == 8) {
            if (ll > 0) { ll = ll - 1 };
        } else if (k == 27) {
            running = false;
        } else if (k >= 32 && k < 127) {
            if (ll < 78) { IN[ll] = k; ll = ll + 1 };
        };
        draw_live(rows, cols, ll);
    };
    tui.leave_screen();
    tui.restore();
    sockio.shut(fd);
    driver.stop(nw);
    eputs("mud: " + tostring(polls) + " key polls at a "
          + tostring(tui.pacer_period_us(p) / 1000) + " ms period\n");
    0
};

// The live view: the last few transcript lines, a status line, and the input
// line.  Drawn from the SAME transcript region the headless run prints, so there
// is one renderer and two sinks.
//
// ITS OWN FRAME BUFFER, AND NOT term's.  tui's ESC_BUF is 64 bytes and its
// `sgr_*` emitters each do buf_reset() + flush() -- they are one-shot helpers,
// not appenders.  A first version of this drew with them and so threw the whole
// frame away every time it changed colour: `esc_clear()` and `esc_home()` went
// into ESC_BUF, then `sgr_fg(120, 200, 255)` reset the length to zero and wrote
// only its own sequence, and the screen never cleared, never homed the cursor
// and never showed a transcript line.  What reached the terminal was the tail of
// each frame (about 50 bytes: a colour and the input echo), which is exactly
// what pty_check.py's captured bytes looked like before this was rewritten.
//
// So the frame is built here, in one module-level buffer allocated once, and
// written with ONE write(2) per frame -- which is what tui's own buffer
// policy asks a renderer to do, only with a buffer the size of a frame.  8 KiB
// holds a 45-row pane at 160 columns with room for the escapes; the largest
// frame this program can draw (rows - 3 lines of cols - 1 bytes, plus two
// status lines) is under 8 KiB, and lb() drops anything past the end rather
// than overrunning.

let LBUF: [byte; 8192] = [0; 8192];
let LN: [long] = [0];

def lb(b: long) -> long {
    if (LN[0] < 8192) { LBUF[LN[0]] = b & 255 };
    LN[0] = LN[0] + 1;
    LN[0]
};

def lstr(s: str) -> long {
    let i = 0;
    while (i < len(s)) { lb(byte_at(s, i)); i = i + 1 };
    LN[0]
};

// lnum: a decimal long, no leading zeros, written back to front.
//
// The front index has to be a LOCAL: `lb` grows LN[0] as it goes, so a loop
// bounded by `p > LN[0]` stops one digit early and leaves the length wrong --
// which is what the first version did, and the status line read "hp 0/0".
def lnum(v: long) -> long {
    if (v < 0) { lb(45); v = 0 - v };
    let k = 1;
    let t = v;
    while (t >= 10) { t = t / 10; k = k + 1 };
    let start = LN[0];
    let p = start + k;
    let w = v;
    while (p > start) {
        p = p - 1;
        if (p < 8192) { LBUF[p] = 48 + (w % 10) };
        w = w / 10;
    };
    LN[0] = start + k;
    LN[0]
};

// ESC [ row ; col H
def lgoto(row: long, col: long) -> long {
    lb(27); lb(91); lnum(row); lb(59); lnum(col); lb(72);
    LN[0]
};

def lfg(r: long, g: long, b: long) -> long {
    lb(27); lb(91); lb(48); lb(59); lb(51); lb(56); lb(59); lb(50);
    lnum(r); lb(59); lnum(g); lb(59); lnum(b); lb(109);
    LN[0]
};

def lflush() -> long {
    if (LN[0] > 0) { syscall(1, 1, &LBUF[0], LN[0]) };
    LN[0] = 0;
    LN[0]
};

def draw_live(rows: long, cols: long, ll: long) -> long {
    LN[0] = 0;
    let pane = rows - 3;
    if (pane < 1) { pane = 1 };
    lb(27); lb(91); lb(50); lb(74);              // clear
    lgoto(1, 1);
    let total = client.TLEN[0];
    // walk back to the start of the last `pane` lines
    let breaks = 0;
    let i = total - 1;
    let start = 0;
    while (i >= 0 && breaks < pane) {
        if (client.T[i] == 10) {
            breaks = breaks + 1;
            start = i + 1;
        };
        i = i - 1;
    };
    let row = 1;
    let j = start;
    while (j < total && row <= pane) {
        let e = j;
        while (e < total && client.T[e] != 10) { e = e + 1 };
        lgoto(row, 1);
        let w = e - j;
        let lim = cols - 1;
        if (w > lim) { w = lim };
        while (w > 0) {
            lb(client.T[j]);
            j = j + 1;
            w = w - 1;
        };
        j = e + 1;
        row = row + 1;
    };
    lgoto(rows - 1, 1);
    lfg(120, 200, 255);
    lstr(" hp ");
    lnum(client.V_HP[0]);
    lstr("/");
    lnum(client.V_MAXHP[0]);
    lstr("  coin ");
    lnum(client.V_COIN[0]);
    lstr("  room ");
    lnum(client.V_ROOM[0]);
    lstr("  turn ");
    lnum(client.V_TURN[0]);
    lb(27); lb(91); lb(48); lb(109);            // reset
    lgoto(rows, 1);
    lfg(255, 255, 255);
    lstr("> ");
    let z = 0;
    while (z < ll) {
        lb(IN[z]);
        z = z + 1;
    };
    lflush();
    ll
};

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

def main() -> long {
    args.init("mud", "a MUD server and client over loopback TCP, with threads", OPTS, "");
    args.parse_or_exit(argv());
    let frames = args.get_long("frames", 20);
    let seed = args.get_long("seed", 1);
    let ncli = args.get_long("clients", 2);
    let nw = args.get_long("workers", 4);
    let docheck = args.has("check");
    let dolive = args.has("live");
    let nb = args.get_long("bench", 0);
    let timing = args.has("time");

    // Every bound is checked and named; nothing here divides by a value the
    // command line supplied without checking it first.
    if (frames < 0 || frames > 400) { bad("--frames must be 0..400") };
    if (ncli < 1 || ncli > client.MAXC) { bad("--clients must be 1.." + tostring(client.MAXC)) };
    if (nw < 1 || nw > server.MAXS) { bad("--workers must be 1.." + tostring(server.MAXS)) };
    if (nb < 0 || nb > 4000) { bad("--bench must be 0..4000") };
    if (docheck && dolive) { bad("--check and --live are different modes") };
    if (nb > 0 && dolive) { bad("--bench and --live are different modes") };
    if (dolive && !tui.is_tty(1)) {
        bad("--live needs a terminal; use --frames N for the headless run");
    };
    // A worker serves ONE session for its whole life (server.y: serve() loops
    // until the session ends), so a run with more simultaneous clients than
    // workers cannot finish: the second client waits at a barrier that the only
    // worker cannot reach, because it is still inside the first session.
    //
    // Left alone this cost twelve seconds and then `a client did not finish its
    // script (1 of 2)` -- a true report of a situation the caller created, but a
    // useless one.  --bench is exempt: it connects its clients one at a time on
    // purpose (see bench), so the pool only has to be big enough for one.
    if (nb == 0 && !dolive && !docheck && ncli > nw) {
        bad("--workers must be at least --clients: a worker serves one session at a time");
    };
    // ...and --check is no exception: checks (b) and (d) put two sessions in the
    // same room on purpose, so one worker is one short of what they need.  It
    // failed with "ada heard bo", which is true and useless.
    if (docheck && nw < 2) { bad("--check needs at least 2 workers") };
    let t0 = clock_us();
    if (docheck) {
        props.run(seed, nw);
        if (props.TOTAL[0] != 0) { exit(1) };
    } else if (nb > 0) {
        bench(seed, nb);
    } else if (dolive) {
        live(seed, nw);
    } else {
        run(seed, frames, ncli, nw);
    };
    if (timing) {
        eputs("mud: " + tostring((clock_us() - t0) / 1000) + " ms, heap "
              + tostring(heap_used()) + "\n");
    };
    0
};

main();