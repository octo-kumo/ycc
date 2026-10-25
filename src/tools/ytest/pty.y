// pty.y -- `ytest pty-test`: the pty driver for test/std/term_test.y.
//
// A terminal module cannot be tested honestly without a terminal: TCGETS and
// TIOCGWINSZ answer ENOTTY on a pipe, and a pipe's read() hits EOF at once,
// so every "the keyboard works" claim would be vacuous. This driver:
//
//   * opens a pty (/dev/ptmx), sizes the slave before exec (a fresh pty is 0x0)
//     and caps the child's memory like every process here;
//   * relays the program's output, and writes keystrokes on the master ONLY in
//     answer to a `<<FEED ..>>` marker in it (`<<FEED 1b 5b 41>>` sends those
//     bytes, `<<FEED>>` nothing), so every keystroke has a synchronisation
//     point and there is no timing race;
//   * checks the byte-exact escape sequences between `<<PROBE alt>>` and
//     `<<PROBE end>>` (the immediate emitters write and are gone);
//   * unless --skip-crash: checks that a program SIGKILLed with
//     tui.arm_watchdog() armed gets its terminal back and one without does
//     not (the control), and that restore_all_exit(7) exits 7 restored.
//
//   ytest pty-test [--rows R] [--cols C] [--no-tty] [--skip-crash] [--quiet] PROG [ARGS...]
//
// Exit 0 when the program and every driver-side check passed, 1 when one
// failed, 2 on bad usage.
import fs;
import yt;

let PROBE_SEQS = [
    ["\x1b[?1049h", "enter_alt_screen()"],
    ["\x1b[?25l", "hide_cursor()"],
    ["\x1b[0;38;2;1;2;3m", "sgr_fg(1,2,3)"],
    ["\x1b[0;48;2;10;20;30m", "sgr_bg(10,20,30)"],
    ["\x1b[0;38;2;1;2;3;48;2;4;5;6m", "sgr_rg(1,2,3,4,5,6)"],
    ["\x1b[0m", "sgr_reset()"],
    ["\x1b[2J", "clear_screen()"],
    ["\x1b[H", "home()"],
    ["\x1b[3;7H", "cursor_to(3,7)"],
    ["\x1b[?25h", "show_cursor()"],
    ["\x1b[?1049l", "leave_alt_screen()"],
];

let MEM_KB = 3670016;

/** A child on a pty: its pid and the master's fd (pid < 0 when none). */
type Pty = { pid: long, master: long };

def spawn(argv: [str], rows: long, cols: long) -> Pty {
    let ptmx = yt.cz("/dev/ptmx");
    let m = syscall(2, &ptmx[0], 2 + 256, 0);
    if (m < 0) { return { pid: -1, master: -1 }; };
    let n: [long; 1] = [0; 1];
    syscall(16, m, 1074025521, &n[0]);
    syscall(16, m, 2147767344, &n[0]);
    let slave = yt.cz("/dev/pts/" + tostring(n[0] & 4294967295));
    let keep: [[byte]] = [];
    let av: [long] = [];
    foreach (a in argv) {
        keep += [yt.cz(a)];
        av += ptr_addr(&keep[keep.length - 1][0]);
    };
    av += 0;
    let ev: [long] = [];
    foreach (e in yt.environ()) {
        keep += [yt.cz(e)];
        ev += ptr_addr(&keep[keep.length - 1][0]);
    };
    ev += 0;
    let ws: [long; 1] = [0; 1];
    ws[0] = rows + cols * 65536;
    let rl: [long; 2] = [0; 2];
    rl[0] = MEM_KB * 1024;
    rl[1] = MEM_KB * 1024;
    let pid = syscall(57);
    if (pid == 0) {
        syscall(3, m);
        syscall(112);
        let s = syscall(2, &slave[0], 2, 0);
        syscall(16, s, 21518, 0);
        syscall(16, s, 21524, &ws[0]);
        syscall(33, s, 0);
        syscall(33, s, 1);
        syscall(33, s, 2);
        if (s > 2) { syscall(3, s); };
        syscall(160, 9, &rl[0]);
        syscall(59, &keep[0][0], ptr_addr(&av[0]), ptr_addr(&ev[0]));
        syscall(231, 127);
    };
    { pid: pid, master: m }
};

// One read of the master, waiting at most `ms`: the bytes, [] on a timeout,
// none at the end (EIO: the slave is gone).
def read_some(m: long, ms: long) -> [byte]? {
    let pfd: [long; 1] = [0; 1];
    pfd[0] = m + 4294967296;
    let r = syscall(7, &pfd[0], 1, ms);
    if (r == 0) { return some([]); };
    let buf: [byte; 65536] = [0; 65536];
    let k = syscall(0, m, &buf[0], 65536);
    if (k <= 0) { none } else { some(buf[0:k]) }
};

def wait_code(pid: long) -> long {
    let st: [long; 1] = [0; 1];
    syscall(61, pid, &st[0], 0, 0);
    let s = st[0] & 65535;
    if ((s & 127) == 0) { (s >> 8) & 255 } else { 128 + (s & 127) }
};

// ICANON and ECHO set on the master's termios: true, false, or none.
def cooked(m: long) -> bool? {
    let t: [long; 8] = [0; 8];
    if (syscall(16, m, 21505, &t[0]) != 0) { return none; };
    let lflag = t[1] >> 32;
    some((lflag & 10) == 10)
};

def hexval(c: long) -> long {
    if (c >= 48 && c <= 57) { c - 48 } else if (c >= 97 && c <= 102) { c - 87 } else if (c >= 65 && c <= 70) { c - 55 } else { -1 }
};

/** The whole pty run: output (\r\n folded), exit code, errors. */
type Run = { out: str, code: long, errors: [str] };

def run(prog: str, args: [str], rows: long, cols: long) -> Run {
    let p = spawn([prog] + args, rows, cols);
    let errors: [str] = [];
    if (p.pid < 0) { return { out: "", code: -1, errors: ["cannot open a pty"] }; };
    let out: [byte] = [];
    let scan = "";
    let deadline = clock_us() + 120000000;
    let go = true;
    while (go) {
        if (clock_us() > deadline) {
            errors += "timed out after 120 s waiting for the program";
            syscall(62, p.pid, 9);
            go = false;
        } else {
            let d = read_some(p.master, 1000);
            if (d == none) {
                go = false;
            } else {
                out += d!;
                // a marker routinely arrives split across two reads: scan the
                // whole unscanned tail, and drop only what was acted on
                scan += from_bytes(d!);
                let i = scan.index_of("<<FEED");
                while (i >= 0) {
                    let j = scan.index_of(">>", i);
                    if (j < 0) {
                        i = -1;
                    } else {
                        let spec = scan[i + 6:j].replace(" ", "");
                        let bs: [byte] = [];
                        let k = 0;
                        while (k + 1 < spec.length) {
                            bs += hexval(spec[k]) * 16 + hexval(spec[k + 1]);
                            k += 2;
                        };
                        if (bs.length > 0) { syscall(1, p.master, &bs[0], bs.length); };
                        scan = scan[j + 2:];
                        i = scan.index_of("<<FEED");
                    };
                };
            };
        };
    };
    syscall(3, p.master);
    let code = wait_code(p.pid);
    { out: from_bytes(out).replace("\r\n", "\n"), code: code, errors: errors }
};

def probe(out: str) -> str {
    let start = out.last_index_of("<<PROBE alt>>");
    if (start < 0) { return "no <<PROBE alt>> block in the program's output"; };
    let b = out[start + 13:];
    let end = b.index_of("<<PROBE end>>");
    if (end >= 0) { b = b[0:end]; };
    let pos = 0;
    foreach (s in PROBE_SEQS) {
        let at = b.index_of(s[0], pos);
        if (at < 0) { return "byte-exact: " + s[1] + " did not emit its sequence in the probe block"; };
        pos = at + s[0].length;
    };
    ""
};

/** A run that announces `<<ARMED>>` then ends on its own terms: announced,
whether the terminal came back cooked, the output, the exit code. */
type Armed = { announced: bool, restored: bool?, out: str, code: long };

def armed(prog: str, args: [str], rows: long, cols: long) -> Armed {
    let p = spawn([prog] + args, rows, cols);
    let buf = "";
    let announced = false;
    let go = true;
    let t0 = clock_us();
    while (go && clock_us() - t0 < 60000000) {
        let d = read_some(p.master, 1000);
        if (d == none) {
            go = false;
        } else {
            buf += from_bytes(d!);
            if (buf.contains("<<ARMED>>")) { announced = true; };
        };
    };
    // read to the end: the slave stays open until a watchdog has written the
    // termios back, so by EIO the restore has happened and cannot race
    let r = cooked(p.master);
    syscall(3, p.master);
    { announced: announced, restored: r, out: buf, code: wait_code(p.pid) }
};

def no_tty(prog: str, rows: long, cols: long, quiet: bool) -> [str] {
    let c = yt.cmd([prog, "--expect-rows=" + tostring(rows), "--expect-cols=" + tostring(cols)]);
    c.mem_kb = MEM_KB;
    c.timeout = 120;
    let r = yt.run(c);
    if (!quiet) { puts(r.out); };
    let f: [str] = [];
    if (r.code != 0) { f += "not-a-tty run exited " + tostring(r.code) + ", want 0"; };
    if (!r.out.contains("not running under a pty")) { f += "not-a-tty run did not print the graceful message"; };
    if (r.out.contains("runtime error")) { f += "not-a-tty run trapped"; };
    if (f.length == 0 && !quiet) { print("term_pty_test: not-a-tty path OK"); };
    f
};

def main(av: [str]) -> long {
    let rows = 31;
    let cols = 97;
    let notty = false;
    let skip_crash = false;
    let quiet = false;
    let prog = "";
    let rest: [str] = [];
    let i = 0;
    while (i < av.length) {
        let a = av[i];
        if (a == "--rows" && i + 1 < av.length) { rows = yt.num(av[i + 1], 31); i += 1; }
        else if (a == "--cols" && i + 1 < av.length) { cols = yt.num(av[i + 1], 97); i += 1; }
        else if (a == "--no-tty") { notty = true; }
        else if (a == "--skip-crash") { skip_crash = true; }
        else if (a == "--quiet") { quiet = true; }
        else if (prog == "") { prog = a; }
        else { rest += a; };
        i += 1;
    };
    if (prog == "" || !fs.is_file(prog)) {
        eputs("pty-test: " + prog + " is not an executable file");
        return 2;
    };
    if (!prog.starts_with("/")) { prog = fs.cwd() + "/" + prog; };
    let fails: [str] = [];
    if (notty) {
        fails = no_tty(prog, rows, cols, quiet);
    } else {
        let r = run(prog, rest + ["--expect-rows=" + tostring(rows), "--expect-cols=" + tostring(cols)], rows, cols);
        if (!quiet) {
            puts(r.out);
            if (r.out != "" && !r.out.ends_with("\n")) { print(""); };
        };
        fails += r.errors;
        let pb = probe(r.out);
        if (pb != "") { fails += pb; };
        if (r.code != 0) { fails += "term_test.y exited " + tostring(r.code) + ", want 0"; };
        if (r.out.contains("runtime error")) { fails += "term_test.y trapped"; };
        let inner = 0;
        foreach (l in r.out.split("\n")) {
            if (l.starts_with("FAIL ")) { inner += 1; };
        };
        if (inner > 0) { fails += tostring(inner) + " check(s) inside term_test.y failed"; };
        if (!r.out.contains("term_test: OK")) { fails += "term_test.y did not print its OK line"; };
        if (!skip_crash) {
            foreach (arm in [true, false]) {
                let what = if (arm) { "with" } else { "without" };
                let c = armed(prog, [if (arm) { "--wd-crash" } else { "--wd-crash-nowatch" }], rows, cols);
                if (!c.announced) {
                    fails += "crash case " + what + " a watchdog: never saw <<ARMED>>";
                } else if (c.out.contains("runtime error")) {
                    fails += "crash case " + what + " a watchdog: the program trapped";
                } else if (c.restored == none) {
                    fails += "crash case " + what + " a watchdog: tcgetattr failed";
                } else if (arm && !c.restored!) {
                    fails += "SIGKILLed the program with a watchdog armed and the terminal was left in raw mode";
                    print("FAIL SIGKILL with a watchdog armed: terminal NOT restored");
                } else if (!arm && c.restored!) {
                    fails += "SIGKILLed the program with no watchdog and the terminal came back anyway, so the control case proves nothing";
                    print("FAIL SIGKILL without a watchdog: terminal unexpectedly restored");
                } else {
                    print("ok   SIGKILL " + what + " a watchdog: " + (if (c.restored!) { "terminal restored" }
                        else { "terminal left raw, which is what the watchdog exists to prevent" }));
                };
            };
            let e = armed(prog, ["--exit=7"], rows, cols);
            if (!e.announced) { fails += "--exit=7 run: never saw <<ARMED>>"; }
            else if (e.code != 7) { fails += "--exit=7 run exited " + tostring(e.code) + ", want 7"; }
            else if (e.restored == none) { fails += "--exit=7 run: tcgetattr failed"; }
            else if (!e.restored!) { fails += "restore_all_exit(7) left the terminal in raw mode"; }
            else if (!e.out.contains("\x1b[?25h\x1b[?1049l")) {
                fails += "restore_all_exit(7) did not emit ESC[?25h then ESC[?1049l";
            } else {
                print("ok   restore_all_exit(7): exit 7, terminal restored, alt screen and cursor left");
            };
        };
        if (fails.length == 0 && !quiet) { print("term_pty_test: OK"); };
    };
    foreach (f in fails) { eputs("FAIL " + f); };
    if (fails.length == 0) { 0 } else { 1 }
};

export { main };
