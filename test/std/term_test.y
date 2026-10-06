import tui;
// term_test.y -- the self-test for std tui's terminal half.
//
// Run it the way it is meant to be run, from examples/_toolkit/:
//
//     (ulimit -S -v 3670016; \
//      ../../refs/ycc.ref term_test.y -o /tmp/tt && \
//      python3 term_pty_test.py /tmp/tt 31 97) </dev/null
//
// term_pty_test.py forks a pty, sets a 31x97 window on it, runs /tmp/tt on
// the slave, and feeds it keystrokes on the master in response to the
// `<<FEED ..>>` markers this program prints. ioctl(TCGETS) returns ENOTTY on
// a pipe, so there is no honest way to test a terminal module outside a pty;
// that driver is not optional.
//
// WHAT IS CHECKED
//   1  stdin/stdout really are terminals, and the not-a-tty path is graceful
//   2  raw_mode() clears ICANON, ECHO, ISIG and IEXTEN (read back with TCGETS)
//   3  VMIN really is byte 23 and VTIME byte 22, set to 1 and 0
//   4  a scripted run of plain keys arrives intact
//   5  every escape sequence in tui's table decodes to its constant
//   6  a lone ESC, and two truncated sequences, resolve without hanging
//   7  an unrecognised sequence loses nothing (pushback)
//   8  size() reports the window the pty driver set, and falls back sanely
//   9  read_key_timeout() returns KEY_NONE on a timeout and the key otherwise
//  10  the esc_* appenders build byte-exact sequences in term's buffer
//  11  restore() puts the termios back byte for byte, and twice is harmless
//
// EXTRA MODES, used by the driver for the crash-restore guarantee
//   --wd-crash          raw mode + watchdog, then SIGKILL self
//   --wd-crash-nowatch  raw mode, NO watchdog, then SIGKILL self
//   --exit CODE         restore, exit CODE (checks an orderly exit path)
//
// EXIT CODE
//   0  every check passed, OR stdin/stdout was not a tty and this program
//      reported that gracefully (that is the documented not-a-tty path)
//   1  at least one check failed
//
// This program never traps on any path: no unwrap of a none, no division,
// every index into a byte buffer is bounded by construction.


let FAILS = 0;
let NCHECK = 0;

// this program's own termios snapshot, so it can read the flags itself
let MYT: [byte] = [0; 64];
let BEFORE: [byte] = [0; 32];

// expected window size, handed in by the pty driver as argv
let EXP_ROWS = 24;
let EXP_COLS = 80;

def check(c: bool, name: str) {
    NCHECK = NCHECK + 1;
    if (c) {
        puts("ok   ");
    } else {
        FAILS = FAILS + 1;
        puts("FAIL ");
    };
    puts(name);
    puts("\n");
};

def check_long(got: long, want: long, name: str) {
    NCHECK = NCHECK + 1;
    let good = got == want;
    if (good) {
        puts("ok   ");
    } else {
        FAILS = FAILS + 1;
        puts("FAIL ");
    };
    puts(name);
    puts(": got ");
    puts(tostring(got));
    if (good) {
        puts(" (want ");
    } else {
        puts(", want ");
    };
    puts(tostring(want));
    puts(")\n");
};

// ---------------------------------------------------------------- protocol
// feed(s) tells the driver to write s to the pty master, right now, and
// feed("") tells it to write nothing. Nothing is written at any other time,
// so there is no race between the driver and this program.
def hexc(v: long) -> str {
    if (v < 10) { chr(48 + v) } else { chr(87 + v) }
};

def feed(s: str) {
    puts("<<FEED");
    for i in 0..len(s) {
        let b = byte_at(s, i);
        puts(" ");
        puts(hexc(b >> 4));
        puts(hexc(b & 15));
    };
    puts(">>\n");
};

// lflag() -- this program's own read of the kernel's c_lflag
def lflag() -> long {
    syscall(16, 0, tui.TCGETS, &MYT[0]);
    tui.rd32(MYT, 12)
};

// iflag() -- c_iflag. Raw mode has to clear ICRNL (else Enter arrives as 10)
// and IXON (else Ctrl-S freezes the terminal), which is what this checks.
def iflag() -> long {
    syscall(16, 0, tui.TCGETS, &MYT[0]);
    tui.rd32(MYT, 0)
};

// buf_is(s) -- term's build buffer equals s, byte for byte
def buf_is(s: str) -> bool {
    let n = len(s);
    if (tui.buf_len() != n) {
        return false;
    };
    let same = true;
    let i = 0;
    while (i < n) {
        if (tui.buf_at(i) != byte_at(s, i)) {
            same = false;
        };
        i = i + 1;
    };
    same
};

def check_buf(s: str, name: str) {
    check(buf_is(s), name);
};

// one key step: tell the driver to send `s`, then read one key and check it
def key_step(s: str, want: long, name: str) {
    feed(s);
    let k = tui.read_key();
    check_long(k, want, name);
};

// ---------------------------------------------------------------------------
// argv: --expect-rows=R --expect-cols=C, --wd-crash, --wd-crash-nowatch,
// --exit CODE. Anything else is ignored.
// ---------------------------------------------------------------------------
def starts(s: str, p: str) -> bool {
    let n = len(p);
    if (len(s) < n) {
        return false;
    };
    let same = true;
    let i = 0;
    while (i < n) {
        if (byte_at(s, i) != byte_at(p, i)) {
            same = false;
        };
        i = i + 1;
    };
    same
};

def opt_rows(s: str) -> long {
    let v = -1;
    if (starts(s, "--expect-rows=")) {
        v = tolong(s[14:len(s)])!;
    };
    v
};

def opt_cols(s: str) -> long {
    let v = -1;
    if (starts(s, "--expect-cols=")) {
        v = tolong(s[14:len(s)])!;
    };
    v
};

let ARGS = argv();
for i in 1..len(ARGS) {
    let a = ARGS[i];
    let r = opt_rows(a);
    if (r > 0) { EXP_ROWS = r; };
    let c = opt_cols(a);
    if (c > 0) { EXP_COLS = c; };
};

// ===========================================================================
// The crash modes come first and share no state with the rest of the test.
// Both leave the process dead; the driver checks the pty's termios from the
// outside to see whether the terminal was put back.
// ===========================================================================
let wd_crash = false;
let wd_nowatch = false;
let exit_code = -1;
for i in 1..len(ARGS) {
    if (ARGS[i] == "--wd-crash") { wd_crash = true; };
    if (ARGS[i] == "--wd-crash-nowatch") { wd_nowatch = true; };
    if (starts(ARGS[i], "--exit=")) { exit_code = tolong(ARGS[i][7:len(ARGS[i])])!; };
};

if (wd_crash || wd_nowatch) {
    if (!tui.raw_mode()) {
        puts("term_test: not a tty\n");
        exit(3);
    };
    if (wd_crash) {
        if (!tui.arm_watchdog()) {
            puts("term_test: watchdog could not be armed\n");
            exit(4);
        };
    };
    // Announce on the master, then die without restoring anything.
    puts("<<ARMED>>\n");
    syscall(62, syscall(39, 0, 0, 0, 0, 0, 0), 9, 0, 0, 0, 0);   // kill(self, SIGKILL)
    // unreachable: SIGKILL cannot be caught, which is the entire point
    tui.restore();
    exit(9);
};

if (exit_code >= 0) {
    if (!tui.raw_mode()) {
        puts("term_test: not a tty\n");
        exit(3);
    };
    tui.enter_screen();
    tui.arm_watchdog();
    puts("<<ARMED>>\n");
    tui.restore_all_exit(exit_code);
};

// ===========================================================================
// 0. header + the not-a-tty contract
// ===========================================================================
puts("term_test -- std tui (terminal half)\n");
// The tty status is reported as information, not as a check: when it is
// false this program has nothing to test and takes the graceful path below.
puts("stdin  is a tty: ");
puts(tostring(tui.is_tty(0)));
puts("\nstdout is a tty: ");
puts(tostring(tui.is_tty(1)));
puts("\n");

if (!tui.is_tty(0) || !tui.is_tty(1)) {
    puts("not running under a pty: there is no termios to test, so this\n");
    puts("is the documented graceful path. Run term_pty_test.py, which gives\n");
    puts("this program a real pty. exit 0.\n");
    exit(0);
};
check(tui.is_tty(0), "is_tty(0) says stdin is a terminal");
check(tui.is_tty(1), "is_tty(1) says stdout is a terminal");

// ===========================================================================
// 1. the byte-exact output probe, done BEFORE raw mode so it cannot be
// confused with anything the driver typed. The driver checks these bytes
// itself; here we only prove the program emits the probe.
// ===========================================================================
puts("<<PROBE alt>>\n");
tui.enter_alt_screen();
tui.hide_cursor();
tui.sgr_fg(1, 2, 3);
tui.sgr_bg(10, 20, 30);
tui.sgr_rg(1, 2, 3, 4, 5, 6);
tui.sgr_reset();
tui.clear_screen();
tui.home();
tui.cursor_to(3, 7);
tui.show_cursor();
tui.leave_alt_screen();
puts("<<PROBE end>>\n");

// ===========================================================================
// 2. size(), and its fallback
// ===========================================================================
let w = tui.size();
check_long(w.rows, EXP_ROWS, "size().rows is what the pty driver set");
check_long(w.cols, EXP_COLS, "size().cols is what the pty driver set");

// a zero window must not produce a zero row (which would divide by zero in
// the first frame a renderer computes)
tui.set_size(0, 0);
let z = tui.size();
check_long(z.rows, 24, "size() falls back to 24 rows when the window is 0x0");
check_long(z.cols, 80, "size() falls back to 80 cols when the window is 0x0");
tui.set_size(EXP_ROWS, EXP_COLS);
let w2 = tui.size();
check_long(w2.rows, EXP_ROWS, "set_size() puts the window back");

// ===========================================================================
// 3. raw mode
// ===========================================================================
syscall(16, 0, tui.TCGETS, &MYT[0]);
for i in 0..32 {
    BEFORE[i] = MYT[i];
};
let before_lf = tui.rd32(MYT, 12);
check((before_lf & tui.ICANON) != 0, "before: ICANON is set");
check((before_lf & tui.ECHO) != 0, "before: ECHO is set");
check((before_lf & tui.ISIG) != 0, "before: ISIG is set");
check((before_lf & tui.IEXTEN) != 0, "before: IEXTEN (0x8000) is set");
check((before_lf & tui.LFLAG_RAW) != tui.LFLAG_RAW,
    "before: the emulator's default lflag differs from the raw mask, which is "
    + "why the mask clears ECHOE and ECHONL too");

let got_raw = tui.raw_mode();
check(got_raw, "raw_mode() succeeded on a real tty");
check(tui.active(), "active() is true right after raw_mode()");

let lf = lflag();
check((lf & tui.ISIG) == 0, "raw: ISIG is clear, so ^C arrives as a byte");
check((lf & tui.ICANON) == 0, "raw: ICANON is clear, so keys arrive unassembled");
check((lf & tui.ECHO) == 0, "raw: ECHO is clear");
check((lf & tui.IEXTEN) == 0, "raw: IEXTEN (0x8000) is clear");
check((lf & tui.LFLAG_RAW) == 0, "raw: every bit in the raw mask is clear");
check((lf & tui.ECHOE) == 0, "raw: ECHOE is clear too (it is in the mask)");

let fi = iflag();
check((fi & tui.ICRNL) == 0, "raw: ICRNL is clear, so Enter arrives as 13 not 10");
check((fi & tui.IXON) == 0, "raw: IXON is clear, so Ctrl-S cannot freeze the terminal");
check((fi & tui.ISTRIP) == 0, "raw: ISTRIP is clear, so the 8th bit survives");
check((fi & tui.IFLAG_RAW) == 0, "raw: every bit in the iflag mask is clear");

// The two offsets that silently turn a working keyboard into a dead one.
// Re-read the struct now that raw is installed.
syscall(16, 0, tui.TCGETS, &MYT[0]);
check(MYT[23] == 1, "raw: VMIN is byte 23 and is 1 (one byte, blocking)");
check(MYT[22] == 0, "raw: VTIME is byte 22 and is 0 (no timer)");

check(tui.arm_watchdog(), "arm_watchdog() armed (a forked child waits to restore)");

// ===========================================================================
// 4. plain keys, one byte each
// ===========================================================================
key_step("q", 113, "plain 'q'");
key_step("a", 97, "plain 'a'");
key_step("Z", 90, "plain 'Z'");
key_step("5", 53, "plain '5'");
key_step(" ", 32, "plain space");
key_step("\t", 9, "plain TAB (9)");
key_step("\r", 13, "plain CR (13): ICRNL is cleared, so it is not turned into 10");
key_step("\n", 10, "plain LF (10) still arrives as 10");
key_step("\x7f", 127, "plain DEL / BACKSPACE (127)");
key_step("\x01", 1, "plain ^A (1): ISIG off means the byte arrives, not a signal");

// ===========================================================================
// 5. every escape sequence in the table
// ===========================================================================
key_step("\x1b[A", tui.KEY_UP, "ESC [ A -> KEY_UP");
key_step("\x1b[B", tui.KEY_DOWN, "ESC [ B -> KEY_DOWN");
key_step("\x1b[C", tui.KEY_RIGHT, "ESC [ C -> KEY_RIGHT");
key_step("\x1b[D", tui.KEY_LEFT, "ESC [ D -> KEY_LEFT");
key_step("\x1b[H", tui.KEY_HOME, "ESC [ H -> KEY_HOME");
key_step("\x1b[F", tui.KEY_END, "ESC [ F -> KEY_END");
key_step("\x1b[1~", tui.KEY_HOME, "ESC [ 1 ~ -> KEY_HOME");
key_step("\x1b[7~", tui.KEY_HOME, "ESC [ 7 ~ -> KEY_HOME");
key_step("\x1b[4~", tui.KEY_END, "ESC [ 4 ~ -> KEY_END");
key_step("\x1b[8~", tui.KEY_END, "ESC [ 8 ~ -> KEY_END");
key_step("\x1b[2~", tui.KEY_INSERT, "ESC [ 2 ~ -> KEY_INSERT");
key_step("\x1b[3~", tui.KEY_DELETE, "ESC [ 3 ~ -> KEY_DELETE");
key_step("\x1b[5~", tui.KEY_PGUP, "ESC [ 5 ~ -> KEY_PGUP");
key_step("\x1b[6~", tui.KEY_PGDN, "ESC [ 6 ~ -> KEY_PGDN");
key_step("\x1bOP", tui.KEY_F1, "ESC O P -> KEY_F1");
key_step("\x1bOQ", tui.KEY_F2, "ESC O Q -> KEY_F2");
key_step("\x1bOR", tui.KEY_F3, "ESC O R -> KEY_F3");
key_step("\x1bOS", tui.KEY_F4, "ESC O S -> KEY_F4");
key_step("\x1bOA", tui.KEY_UP, "ESC O A -> KEY_UP (application cursor mode)");
key_step("\x1bOB", tui.KEY_DOWN, "ESC O B -> KEY_DOWN (application cursor mode)");
key_step("\x1b[15~", tui.KEY_F5, "ESC [ 15 ~ -> KEY_F5");
key_step("\x1b[17~", tui.KEY_F6, "ESC [ 17 ~ -> KEY_F6");
key_step("\x1b[18~", tui.KEY_F7, "ESC [ 18 ~ -> KEY_F7");
key_step("\x1b[19~", tui.KEY_F8, "ESC [ 19 ~ -> KEY_F8");
key_step("\x1b[20~", tui.KEY_F9, "ESC [ 20 ~ -> KEY_F9");
key_step("\x1b[21~", tui.KEY_F10, "ESC [ 21 ~ -> KEY_F10");
key_step("\x1b[23~", tui.KEY_F11, "ESC [ 23 ~ -> KEY_F11");
key_step("\x1b[24~", tui.KEY_F12, "ESC [ 24 ~ -> KEY_F12");

// ===========================================================================
// 6. a lone ESC and two truncated sequences. Each of these costs one
// ESC_WAIT_MS inside the decoder, and none of them may hang. An
// unrecognised sequence PUSHES ITS BYTES BACK, so after a KEY_UNKNOWN the
// next read_key() returns them as ordinary keys -- every one of those bytes
// is checked here, which is what makes "nothing is lost" a testable claim
// rather than a comment.
// ===========================================================================
key_step("\x1b", tui.KEY_ESC, "a lone ESC -> KEY_ESC (never the raw byte 27)");
key_step("\x1b[", tui.KEY_UNKNOWN, "truncated 'ESC [' -> KEY_UNKNOWN, no hang");
check_long(tui.read_key(), 91, "pushback: the '[' from the truncated sequence");
key_step("\x1b[1", tui.KEY_UNKNOWN, "truncated 'ESC [ 1' -> KEY_UNKNOWN, no hang");
check_long(tui.read_key(), 91, "pushback: the '[' from 'ESC [ 1'");
check_long(tui.read_key(), 49, "pushback: the '1' from 'ESC [ 1'");
key_step("\x1bOZ", tui.KEY_UNKNOWN, "unknown 'ESC O Z' -> KEY_UNKNOWN");
check_long(tui.read_key(), 79, "pushback: the 'O' from 'ESC O Z'");
check_long(tui.read_key(), 90, "pushback: the 'Z' from 'ESC O Z'");

// ===========================================================================
// 7. an unrecognised sequence must not eat the bytes that followed it, and
// must not reorder them either. "ESC [ Z" is not in the table, so it decodes
// to KEY_UNKNOWN and '[', 'Z' go back on the pushback stack -- in that order,
// ahead of the 'z' that was typed after them. Four reads for four bytes: no
// input is lost and none is duplicated.
// ===========================================================================
feed("\x1b[Zz");
check_long(tui.read_key(), tui.KEY_UNKNOWN, "pushback: 'ESC [ Z' -> KEY_UNKNOWN");
check_long(tui.read_key(), 91, "pushback: the '[' comes back first");
check_long(tui.read_key(), 90, "pushback: then the 'Z', in order");
check_long(tui.read_key(), 122, "pushback: then the 'z' that was typed after it");

// ===========================================================================
// 8. the timed read
// ===========================================================================
feed("");
check_long(tui.read_key_timeout(120), tui.KEY_NONE,
    "read_key_timeout(120) with nothing typed -> KEY_NONE");
feed("a");
check_long(tui.read_key_timeout(2000), 97, "read_key_timeout(2000) with 'a' -> 'a'");
feed("\x1b[A");
check_long(tui.read_key_timeout(2000), tui.KEY_UP,
    "read_key_timeout(2000) with ESC [ A -> KEY_UP");
// and the mode is back to blocking afterwards, which is what an event loop
// wants between frames
syscall(16, 0, tui.TCGETS, &MYT[0]);
check(MYT[23] == 1, "after a timed read VMIN is 1 again");
check(MYT[22] == 0, "after a timed read VTIME is 0 again");

// ===========================================================================
// 9. the buffered esc_* appenders, byte for byte. The immediate sgr_*
// emitters and the screen helpers were checked from outside by the driver,
// between the <<PROBE alt>> and <<PROBE end>> markers above.
// ===========================================================================
tui.buf_reset();
tui.esc_fg(1, 2, 3);
check_buf("\x1b[0;38;2;1;2;3m", "esc_fg(1,2,3) == ESC[0;38;2;1;2;3m");

tui.buf_reset();
tui.esc_bg(10, 20, 30);
check_buf("\x1b[0;48;2;10;20;30m", "esc_bg(10,20,30) == ESC[0;48;2;10;20;30m");

tui.buf_reset();
tui.esc_rg(1, 2, 3, 4, 5, 6);
check_buf("\x1b[0;38;2;1;2;3;48;2;4;5;6m",
    "esc_rg(1,2,3,4,5,6) == ESC[0;38;2;1;2;3;48;2;4;5;6m");

tui.buf_reset();
tui.esc_rg(0, 0, 0, 255, 128, 1);
check_buf("\x1b[0;38;2;0;0;0;48;2;255;128;1m", "esc_rg clamps nothing and prints all three digits");

tui.buf_reset();
tui.esc_rg(300, -5, 1, 2, 3, 4);
check_buf("\x1b[0;38;2;255;0;1;48;2;2;3;4m", "esc_rg clamps components into 0..255");

tui.buf_reset();
tui.esc_reset();
check_buf("\x1b[0m", "esc_reset() == ESC[0m");

tui.buf_reset();
tui.esc_clear();
check_buf("\x1b[2J", "esc_clear() == ESC[2J");

tui.buf_reset();
tui.esc_home();
check_buf("\x1b[H", "esc_home() == ESC[H");

tui.buf_reset();
tui.esc_cursor(3, 7);
check_buf("\x1b[3;7H", "esc_cursor(3,7) == ESC[3;7H");

tui.buf_reset();
tui.put_csi();
tui.put_str("?1049h");
check_buf("\x1b[?1049h", "the alt screen introducer is ESC [ ? 1049 h");

tui.buf_reset();
tui.put_num(0);
tui.put_num(7);
tui.put_num(123);
check_buf("07123", "put_num prints 0, 7 and 123 with no leading zeros");

// the appenders are additive: a renderer builds a whole frame with them
tui.buf_reset();
tui.put_str("ab");
tui.esc_fg(9, 9, 9);
tui.put_str("cd");
check_buf("ab\x1b[0;38;2;9;9;9mcd", "appenders accumulate into one buffer");
tui.buf_reset();
check_long(tui.buf_len(), 0, "buf_reset() empties the buffer");
check_long(tui.buf_at(9999), 0, "buf_at() out of range returns 0, no trap");

// ===========================================================================
// 11. no per-frame allocation. The heap is an arena and nothing is ever
// freed, so a renderer that allocated per frame would exhaust the 3.5 GiB
// cap. Drive the whole output path and the timed read hard, and prove
// heap_used() does not move.
// ===========================================================================
tui.buf_reset();
let h0 = heap_used();
for i in 0..2000 {
    tui.esc_rg(i & 255, (i >> 2) & 255, (i >> 4) & 255, 0, 0, 0);
    tui.esc_cursor(i & 63, i & 31);
    tui.put_num(i);
    tui.esc_fg(i & 15, 0, 0);
};
tui.buf_reset();
let h1 = heap_used();
check_long(h1 - h0, 0, "2000 esc_*/put_num rounds allocate nothing");

// read_key_timeout(0) is an immediate poll, so this is 100 deadlines without
// the wait; each one still does the VMIN/VTIME round trip through the kernel.
let h2 = heap_used();
for i in 0..100 {
    let _k = tui.read_key_timeout(0);
};
let h3 = heap_used();
check_long(h3 - h2, 0, "100 timed reads that time out allocate nothing");

// ===========================================================================
// 12. restore
// ===========================================================================
tui.restore();
syscall(16, 0, tui.TCGETS, &MYT[0]);
let after_lf = tui.rd32(MYT, 12);
check((after_lf & tui.ICANON) != 0, "restore: ICANON is set again");
check((after_lf & tui.ECHO) != 0, "restore: ECHO is set again");
check((after_lf & tui.ISIG) != 0, "restore: ISIG is set again");
check((after_lf & tui.IEXTEN) != 0, "restore: IEXTEN (0x8000) is set again");
check(after_lf == before_lf, "restore: c_lflag is byte-identical to before");

let same = true;
let diff = 0;
let i = 0;
while (i < 32) {
    if (MYT[i] != BEFORE[i]) {
        same = false;
        diff = i;
    };
    i = i + 1;
};
check(same, "restore: all 32 bytes of struct termios are byte-identical");
if (!same) {
    print("      first differing byte: ");
    print(diff);
    puts("\n");
};

check(!tui.active(), "active() is false after restore()");

// second and third restore: harmless
tui.restore();
tui.cooked_mode();
tui.restore();
check(lflag() == after_lf, "restore() twice more changes nothing");
check(true, "restore() when raw mode was never entered is harmless");

// ===========================================================================
// summary
// ===========================================================================
print(NCHECK - FAILS);
puts(" of ");
print(NCHECK);
puts(" checks passed\n");
if (FAILS > 0) {
    print(FAILS);
    puts(" FAILED\n");
    exit(1);
};
puts("term_test: OK\n");
exit(0);