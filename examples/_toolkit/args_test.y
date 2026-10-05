// args_test.y -- the self-test for the toolkit's args.y and time.y.
//
//   ycc args_test.y -o args_test && ./args_test
//
// argv_test is the args half: what it parses, what it diagnoses and what it
// exits with, plus the two error paths checked the honest way -- a real
// forked child with its stdout and stderr on a pipe, so the exit code and
// the stream are the ones a shell would see.  time_test is the time half:
// the clock, the nap, the pacer, the rate meter, and the promise that none
// of it allocates.
//
// Timing checks assert bounds, never values, and print what they measured
// on **stderr**, so stdout is byte-identical from run to run:
//
//   ./args_test > out.1 2>/dev/null && ./args_test > out.2 2>/dev/null
//   cmp out.1 out.2
//
// stderr also carries the "at: unknown option ..." lines of the in-process
// error checks, which is the point of them: the diagnostics really do go to
// stderr.  The forked children (5e..6d) have their own stdout and stderr on
// a pipe, so nothing they print reaches this process's.
//
// Exit status: 0 when every check passed, 1 otherwise.

import args;
import time;

// ── the harness ──────────────────────────────────────────────────────────

let n_checks = 0;
let n_fails = 0;

def ck(label: str, ok: bool) {
    n_checks = n_checks + 1;
    if (ok) {
        puts("ok   " + label + "\n");
    } else {
        n_fails = n_fails + 1;
        puts("FAIL " + label + "\n");
    }
};

// A measurement, on stderr, so stdout stays comparable between runs.
def note(s: str) {
    eputs("     [note] " + s + "\n")
};

def ok_contains(hay: str, needle: str) -> bool {
    index_of(hay, needle) >= 0
};

// ── the spec both halves share ───────────────────────────────────────────

const TEST_OPTS: [args.Opt] = [
    { long: "fps", short: "f", kind: args.NUM, help: "frames per second (default 30)" },
    { long: "seed", short: "", kind: args.NUM, help: "random seed (default 1)" },
    { long: "color", short: "c", kind: args.STR, help: "color mode (default mono)" },
    { long: "expr", short: "e", kind: args.STR, help: "an expression, may contain = (default none)" },
    { long: "stats", short: "s", kind: args.BOOL, help: "print stats at the end" }
];

// A SECOND spec, which DECLARES an option called `help`. It exists to close
// the hole this file had: the spec above declares no `help`, so every
// `--help` test in this suite was exercising only the UNDECLARED path.
// `--help` is recognised as the HELP request only when the name is ABSENT
// from the table -- a declared `help` takes the ordinary BOOL path and is
// stored instead. That is how `mud` came to have a `--help` that started a
// game, while its own error message told the user to run `mud --help`.
// A suite that tests one spelling of a rule cannot see the other spelling.
const DECLARES_HELP: [args.Opt] = [
    { long: "fps", short: "f", kind: args.NUM, help: "frames per second (default 30)" },
    { long: "help", short: "h", kind: args.BOOL, help: "this list" }
];

// Every parsed value, as one line of text.  Two runs over the same command
// line must produce the same line: that is the determinism check, and it
// covers the parse, the lookups and the diagnostics together.
def report(toks: [str]) -> str {
    args.init("at", "the args.y self-test", TEST_OPTS, "[file...]");
    let st = args.parse(toks);
    let err = args.errmsg();
    let fps = args.get_long("fps", 30);
    let seed = args.get_long("seed", 1);
    let color = args.get_str("color", "mono");
    let expr = args.get_str("expr", "none");
    let stats = args.has("stats");
    let pos = args.positional();
    let joined = ",".join(pos);
    f"st={st} err={err} fps={fps} seed={seed} color={color} expr={expr} stats={stats} pos={joined}\n"
};

// A DECLARED-`help` variant of report(), for checks 6f/6g. Same shape, the
// second spec, and it prints the flag so a test can see it was stored.
def report_declared(toks: [str]) -> str {
    args.init("at", "the args.y self-test", DECLARES_HELP, "[file...]");
    let st = args.parse(toks);
    let err = args.errmsg();
    let h = args.has("help");
    f"st={st} err={err} help={h}\n"
};

// ── the forked child: a real program, a real exit code ───────────────────
//
// `rest` is the command line a program would have been given, without its
// argv[0].  The child parses it with parse_or_exit() exactly as an example
// would, with both fd 1 and fd 2 pointed at a pipe, so what the parent reads
// back is what a shell would have seen on the terminal.  Three attempts at
// this shape showed the two traps, both worth writing down here:
//
//   - pipe(2) writes two 4-byte fds, so into a [long; 2] the read end is
//     the low half of the first long and the write end the high half.
//   - dup2 is syscall 33 and takes (oldfd, newfd): `syscall(33, wfd, 2)`
//     puts the pipe on fd 2.  The other order silently redirects the wrong
//     fd and the test still "passes" with an empty capture.
//   - wait for the child BEFORE reading.  A blocking read on the pipe is
//     interrupted by the SIGCHLD the child sends, and one restart lost and
//     the read never returns.

type Res = { code: long, text: str };

let pipe_buf: [long; 2] = [0; 2];

def run_child_spec(rest: [str], spec: [args.Opt]) -> Res {
    syscall(22, &pipe_buf[0]);
    let rfd = pipe_buf[0] % 4294967296;
    let wfd = (pipe_buf[0] / 4294967296) % 4294967296;
    let pid = fork {
        syscall(33, wfd, 1);
        syscall(33, wfd, 2);
        args.init("at", "the args.y self-test", spec, "[file...]");
        args.parse_or_exit([argv()[0]] + rest);
        exit(0);
    };
    let code = wait_pid(pid);
    syscall(3, wfd);
    let buf: [byte; 4096] = [0; 4096];
    let text = "";
    let more = true;
    while (more) {
        let n = syscall(0, rfd, &buf[0], 4096);
        if (n > 0) {
            text += from_bytes(buf[0:n]);
        } else {
            more = false;
        };
    };
    syscall(3, rfd);
    { code: code, text: text }
};

// The spec-parameterised runner is the general one; this is the common case.
def run_child(rest: [str]) -> Res {
    run_child_spec(rest, TEST_OPTS)
};

// ── the args half ────────────────────────────────────────────────────────

def test_args() {
    // 1. the two spellings of a value agree
    ck("1  --fps=60 and --fps 60 give the same result",
        report(["at", "--fps=60"]) == report(["at", "--fps", "60"]));
    ck("1b --color=red, --color red and -c red agree",
        report(["at", "--color=red"]) == report(["at", "--color", "red"])
        && report(["at", "--color", "red"]) == report(["at", "-c", "red"]));

    // 2. short flags: alone, clustered, with a value in the cluster, and
    // the negated form
    ck("2  -s sets a flag", ok_contains(report(["at", "-s"]), "stats=true"));
    ck("2b -se bundles a flag and a value option",
        ok_contains(report(["at", "-se", "x=y"]), "expr=x=y")
        && ok_contains(report(["at", "-se", "x=y"]), "stats=true"));
    ck("2c -e=x reads a value out of the cluster",
        ok_contains(report(["at", "-e=x"]), "expr=x"));
    ck("2d --no-stats turns a flag off again",
        ok_contains(report(["at", "--stats", "--no-stats"]), "stats=false"));
    ck("2e --stats=false turns a flag off too",
        ok_contains(report(["at", "--stats=false"]), "stats=false"));

    // 3. defaults when a flag is absent
    let d = report(["at"]);
    ck("3  an absent option gives its default",
        ok_contains(d, "fps=30") && ok_contains(d, "seed=1")
        && ok_contains(d, "color=mono") && ok_contains(d, "expr=none")
        && ok_contains(d, "stats=false"));
    ck("3b an undeclared name gives the default rather than trapping",
        args.nopts() == 5 && args.get_long("nosuch", -1) == 0 - 1
        && args.get_str("nosuch", "dflt") == "dflt" && !args.has("nosuch"));

    // 4. the operands, in order, and the -- that ends the options
    ck("4  positional() keeps the operands in order",
        report(["at", "a", "b", "c"]) == "st=0 err= fps=30 seed=1 color=mono expr=none stats=false pos=a,b,c\n");
    ck("4b options and operands mix, in either order",
        ok_contains(report(["at", "x", "--fps", "9", "y"]), "fps=9")
        && ok_contains(report(["at", "x", "--fps", "9", "y"]), "pos=x,y"));
    ck("4c -- ends the options, so flags after it are operands",
        report(["at", "--", "--fps", "99", "-s"]) == "st=0 err= fps=30 seed=1 color=mono expr=none stats=false pos=--fps,99,-s\n");
    ck("4d a lone - is an operand, not a flag",
        report(["at", "-"]) == "st=0 err= fps=30 seed=1 color=mono expr=none stats=false pos=-\n");

    // 5. an unknown option: the documented status, and the message
    let u = report(["at", "--bogus"]);
    ck("5  an unknown option is USAGE (2), not a silent accept",
        ok_contains(u, "st=2") && ok_contains(u, "err=unknown option '--bogus'"));
    ck("5b an unknown short option is diagnosed the same way",
        ok_contains(report(["at", "-z"]), "st=2")
        && ok_contains(report(["at", "-z"]), "err=unknown option '-z'"));
    ck("5c a value option with no value is diagnosed",
        ok_contains(report(["at", "--fps"]), "err=option '--fps' needs a value"));
    ck("5d --fps followed by another flag is a missing value, not a swallow",
        ok_contains(report(["at", "--fps", "--seed", "2"]), "err=option '--fps' needs a value"));
    let e5 = run_child(["--bogus"]);
    note(f"unknown option: exit {e5.code}, stderr {e5.text.trim()}");
    ck("5e the process exits 2 and says so on stderr",
        e5.code == 2 && ok_contains(e5.text, "unknown option '--bogus'"));
    ck("5f the diagnostic names the program and goes to stderr, not stdout",
        ok_contains(e5.text, "at: unknown option") && !ok_contains(e5.text, "usage:"));

    // 6. --help: generated from the spec, on stdout, exit 0
    let h = run_child(["--help"]);
    note(f"--help: exit {h.code}, {len(h.text)} bytes of usage");
    ck("6  --help exits 0", h.code == 0);
    ck("6b the usage text is generated and names every declared flag",
        ok_contains(h.text, "usage: at [options] [file...]")
        && ok_contains(h.text, "--fps") && ok_contains(h.text, "--seed")
        && ok_contains(h.text, "--color") && ok_contains(h.text, "--expr")
        && ok_contains(h.text, "--stats") && ok_contains(h.text, "--help"));
    ck("6c the usage text carries the short flags and the description",
        ok_contains(h.text, "-f, --fps") && ok_contains(h.text, "-h, --help")
        && ok_contains(h.text, "the args.y self-test"));
    ck("6d -h means --help too", ok_contains(report(["at", "-h"]), "st=1"));

    // 6e. THE OTHER SPELLING. Every `--help` test above uses a spec with NO
    // `help` option, so all of them exercise only the undeclared path. When
    // the spec DOES declare `help`, parse() finds the name, takes the
    // ordinary BOOL path and stores it -- so `--help` is NOT a help request,
    // nothing is printed, and the program runs on. That is documented in
    // args.y's header, and it is pinned here so it cannot change silently
    // in either direction.
    //
    // It matters because the failure it enables is invisible: `mud`
    // declared `help`, never read `args.has("help")`, and its own error
    // message told the user to run `mud --help` -- so `mud --help` started
    // a game, and the gate could not see it.
    let dh = run_child_spec(["--help"], DECLARES_HELP);
    note(f"declared help: exit {dh.code}, {len(dh.text)} bytes");
    ck("6e a DECLARED `help` makes --help an ordinary flag: no usage printed",
        dh.code == 0 && dh.text.length == 0);
    ck("6f it is readable with has(\"help\"), which is why a program declaring"
       + " it must check it",
        ok_contains(report_declared(["at", "--help"]), "help=true")
        && ok_contains(report_declared(["at", "-h"]), "help=true"));
    ck("6g and absent the flag it is false, so the two are distinguishable",
        ok_contains(report_declared(["at"]), "help=false"));
    // The control: the SAME runner against the spec WITHOUT `help` does
    // print usage. Without this, 6e would also pass if the child were simply
    // broken -- which is the failure mode this suite has been bitten by
    // before, so the control is not optional.
    ck("6h control: the same runner against a spec without `help` DOES print"
       + " usage, so 6e is about the declaration and not about the runner",
        run_child_spec(["--help"], TEST_OPTS).text.length > 20);

    // 7. nothing at all on the command line
    ck("7  an empty argv() parses and does not trap",
        report(["at"]) == "st=0 err= fps=30 seed=1 color=mono expr=none stats=false pos=\n");
    ck("7b even a zero-length argv() array is safe", ok_contains(report([]), "st=0"));

    // 8. a number, and a value that is not one
    ck("8  get_long reads a number out of a string flag",
        ok_contains(report(["at", "--fps", "144"]), "fps=144")
        && ok_contains(report(["at", "-f=-5"]), "fps=-5"));
    ck("8b a non-number is diagnosed, never a silent 0",
        ok_contains(report(["at", "--fps", "abc"]), "st=2")
        && ok_contains(report(["at", "--fps", "abc"]), "wants a number, got 'abc'"));
    ck("8c a near-number is diagnosed too (12abc, 1.5, an empty value)",
        ok_contains(report(["at", "--fps", "12abc"]), "st=2")
        && ok_contains(report(["at", "--fps", "1.5"]), "st=2")
        && ok_contains(report(["at", "--fps="]), "st=2"));
    ck("8d num_ok() agrees with what get_long() accepts",
        args.num_ok("0") && args.num_ok("-42") && !args.num_ok("")
        && !args.num_ok("4 2") && !args.num_ok("999999999999999999999"));

    // 9. awkward values
    ck("9  a value containing = keeps everything after the first one",
        ok_contains(report(["at", "--expr=a=b=c"]), "expr=a=b=c"));
    ck("9b an empty value is a value, not a missing one",
        ok_contains(report(["at", "--expr="]), "expr= stats=false"));
    ck("9c --expr with no value is still a missing value",
        ok_contains(report(["at", "--expr"]), "err=option '--expr' needs a value"));

    // 10. determinism: the same command line, the same line of text
    let a1 = report(["at", "-s", "--fps", "60", "a", "--expr=p=q", "b"]);
    let a2 = report(["at", "-s", "--fps", "60", "a", "--expr=p=q", "b"]);
    ck("10 parsing the same command line twice gives identical output", a1 == a2);
    ck("10b and that output is the expected one",
        a1 == "st=0 err= fps=60 seed=1 color=mono expr=p=q stats=true pos=a,b\n");
    ck("10c repeated options keep the last value",
        ok_contains(report(["at", "--fps", "1", "--fps", "2"]), "fps=2"));
};

// ── the time half ────────────────────────────────────────────────────────

def test_time() {
    // 11. the clock never runs backwards
    let prev = time.now_us();
    let back = 0;
    for i in 0..100000 {
        let v = time.now_us();
        if (v < prev) { back = back + 1; };
        prev = v;
    };
    ck("11 now_us() never goes backwards over 100000 calls", back == 0);
    ck("11b now_ms() is the same clock, coarser",
        time.now_ms() * 1000 <= time.now_us() + 2000
        && time.now_ms() * 1000 > 0);

    // 12. a nap waits
    let t0 = time.now_us();
    let slept = time.nap_us(2000);
    let el = time.now_us() - t0;
    note(f"nap_us(2000): returned {slept}, clock measured {el}");
    ck("12 nap_us(2000) waits at least 1900us and returns", el >= 1900 && slept >= 1900);
    let short = time.nap_us(0);
    ck("12b nap_us(0) returns at once without waiting", short == 0);

    // 13. the pacer holds a rate, and drops rather than lags
    let p = time.pacer_new(30);
    let per = time.pacer_period_us(p);
    let drew = 0;
    let skipped = 0;
    let t1 = time.now_us();
    for i in 0..15 {
        let w = time.pacer_next(p);
        if (w >= 0) { drew = drew + 1 } else { skipped = skipped + 1 };
    };
    let span = time.now_us() - t1;
    note(f"30fps x15: {drew} drawn, {skipped} skipped, {span}us, period {per}us");
    ck("13a 30 fps: fifteen frames, none dropped", drew == 15 && skipped == 0);
    ck("13b 30 fps: fifteen frames took 400..900ms", span >= 400000 && span <= 900000);
    ck("13c the period is 1e6/fps and the lag stays small",
        per > 33000 && per < 34000 && time.pacer_lag_us(p) > 0 - per);

    // starved: stall for six frames and the pacer must say so
    let q = time.pacer_new(30);
    let qper = time.pacer_period_us(q);
    time.pacer_next(q);
    time.nap_us(qper * 6);
    let w1 = time.pacer_next(q);
    let worst = w1;
    let recovered = false;
    for i in 0..8 {
        let w = time.pacer_next(q);
        if (w < worst) { worst = w };
        if (w >= 0) { recovered = true };
    };
    note(f"starved pacer: first late call {w1}, worst {worst}, recovered={recovered}");
    ck("13d a starved pacer reports skip", w1 < 0);
    ck("13e the skip is at least one whole frame late (the proven rule)",
        w1 <= 0 - qper);
    ck("13f the schedule recovers within a few frames of the stall", recovered);
    ck("13g the lag does not accumulate: it stays inside the stall",
        worst > 0 - 10 * qper && worst <= 0 - qper);
    ck("13h dropped frames are counted", time.pacer_dropped(q) >= 1);

    // 14. the rate meter
    let r = time.pacer_new(30);
    let m = time.fps_new(100000);
    for i in 0..12 {
        if (time.pacer_next(r) >= 0) { time.fps_tick(m) };
    };
    let now_x100 = time.fps_x100(m);
    let avg_x100 = time.fps_avg_x100(m);
    let line = time.fps_line(m);
    note(f"fps meter: now {now_x100} avg {avg_x100} line '{line}'");
    ck("14a the window rate is plausible for 30 fps (15..45 fps)",
        now_x100 > 1500 && now_x100 < 4500);
    ck("14b the average over the run is plausible", avg_x100 > 1500 && avg_x100 < 4500);
    ck("14c the meter counted every drawn frame",
        time.fps_frames(m) == time.pacer_frames(r) && time.fps_frames(m) == 12);
    ck("14d fps_line renders both rates", ok_contains(line, "fps now,")
        && ok_contains(line, "over 12 frames"));

    // 15. the pacing path allocates nothing
    //
    // Two loops, because they take different branches of pacer_next: a
    // 1 us period so every call is a skip with no sleeping at all, and a
    // 1000 fps period so every call sleeps.  A warmed-up heap is measured
    // either side of 5000 + 100 calls of now_us + pacer_next + fps_tick.
    let fast = time.pacer_new(1000000);
    let slow = time.pacer_new(1000);
    let fm = time.fps_new();
    for i in 0..200 {
        time.now_us();
        time.pacer_next(fast);
        time.fps_tick(fm);
    };
    let h0 = heap_used();
    for i in 0..5000 {
        time.now_us();
        time.pacer_next(fast);
        time.fps_tick(fm);
    };
    let h1 = heap_used();
    for i in 0..100 {
        time.now_us();
        time.pacer_next(slow);
        time.fps_tick(fm);
    };
    let h2 = heap_used();
    note(f"heap: {h0} -> {h1} after 5000 skip-path calls, -> {h2} after 100 sleeping calls");
    ck("15a 5000 skip-path pacing calls allocate nothing", h1 - h0 <= 0);
    ck("15b 100 sleeping pacing calls allocate nothing", h2 - h1 <= 0);
    ck("15c and the heap did not creep either", h2 - h0 <= 0);
    ck("15d the fast loop really did take the skip path (no sleeping in it)",
        time.pacer_dropped(fast) > 4000);

    // 16. determinism of the timing decisions that are not timing
    //
    // Being late is made here the only way it can be made deterministically:
    // a nap of three periods, so the next deadline is already in the past
    // whatever the machine's clock does.  The verdict must then be a skip,
    // every time, and the same every time -- which is the property an
    // animation can rely on, as opposed to how many frames a second fit.
    let d1 = time.pacer_new(1000);
    let all_skip_a = true;
    for i in 0..6 {
        time.nap_us(3000);
        if (time.pacer_next(d1) >= 0) { all_skip_a = false };
    };
    let d2 = time.pacer_new(1000);
    let all_skip_b = true;
    for i in 0..6 {
        time.nap_us(3000);
        if (time.pacer_next(d2) >= 0) { all_skip_b = false };
    };
    let lag1 = time.pacer_lag_us(d1);
    let lag2 = time.pacer_lag_us(d2);
    note(f"forced skips: {time.pacer_dropped(d1)} and {time.pacer_dropped(d2)}, lags {lag1} and {lag2}");
    ck("16a a pacer three periods late skips, deterministically, twice over",
        all_skip_a && all_skip_b && time.pacer_dropped(d1) == 6
        && time.pacer_dropped(d2) == 6 && lag1 < 0 && lag2 < 0);

    // The lag those six stalls built is finite: stop stalling and the very
    // next calls draw again, one dropped frame per frame of debt.  This is
    // the "a stall of k frames costs k frames, then the rate is normal"
    // half of the contract, and it is the one that would be missed by a
    // pacer that simply slept off its backlog in one long nap.
    let again = 0 - 1;
    let tries = 0;
    while (tries < 64 && again < 0) {
        again = time.pacer_next(d1);
        tries = tries + 1;
    };
    note(f"after six forced stalls: drew again on call {tries}, value {again}");
    ck("16b the lag is finite -- it draws again once the caller stops stalling",
        again >= 0 && time.pacer_dropped(d1) == 6 + tries - 1);
};

// ── the run ──────────────────────────────────────────────────────────────

def main() -> long {
    let av = argv();
    if (len(av) > 2 && av[1] == "--help") {
        puts("args_test -- the self-test for args.y and time.y\n\n");
        puts("  Takes no options.  Run it with no arguments; it prints one\n");
        puts("  line per check and exits 0 only when all of them passed.\n");
        puts("  Timing numbers go to stderr, so stdout is comparable:\n");
        puts("    ./args_test > out.1 2>/dev/null && ./args_test > out.2 2>/dev/null\n");
        exit(0);
    };
    puts("== args.y ==\n");
    test_args();
    puts("== time.y ==\n");
    test_time();
    puts("\n");
    if (n_fails == 0) {
        puts(f"all {n_checks} checks passed\n");
    } else {
        puts(f"{n_fails} of {n_checks} checks FAILED\n");
    };
    if (n_fails == 0) { 0 } else { 1 }
};

exit(main());
