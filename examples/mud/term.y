// term.y -- terminal control for Y: raw mode, window size, key decoding,
// the alt screen, truecolour SGR, and reliable restore.
//
// Toolkit revision: 1 (this file, examples/_toolkit/term.y). Vendored copies
// must be byte-identical; if you need different behaviour, add your own file
// next to the copy. Compiled and tested with refs/ycc.ref.
//
// ===========================================================================
// THE RESTORE RULE -- read this before writing any interactive program.
//
// A program that puts the terminal into raw mode and exits without putting
// it back leaves the user with a shell that has no echo and no Ctrl-C. That
// is the single worst failure mode in this whole module, so it is the one
// thing this file is built around.
//
// Y has NO destructors and NO signal handlers. Nothing runs on the way out
// of a `def`, nothing runs when the program returns from top level, and
// nothing runs on SIGINT, SIGTERM, SIGHUP, SIGSEGV or SIGKILL. There is no
// `atexit` and there is nothing to add. So:
//
//   GUARANTEED    Every exit path *you* write, as long as you route it
//                 through term.restore() / term.restore_exit(n).
//   GUARANTEED    restore() is idempotent: calling it when raw mode was
//                 never entered, or twice, or ten times, is harmless.
//   GUARANTEED    If you arm the watchdog (term.arm_watchdog()) then even
//                 a crash, an abort, or `kill -9` on this process restores
//                 the terminal, because a forked child is blocked in
//                 read(2) on a self-pipe that the parent holds open and
//                 rewrites the saved termios the instant the parent dies.
//   NOT GUARANTEED  SIGINT / SIGTERM / SIGHUP with the watchdog disarmed.
//                 Nothing in Y can catch them. If your program can be
//                 killed while it owns the terminal, ARM THE WATCHDOG.
//   NOT GUARANTEED  A machine crash, a power cut, or `kill -9` on the
//                 *watchdog child* as well. The watchdog is a plain child
//                 process; `kill -9 <child>` loses that one guarantee.
//   NOT GUARANTEED  Terminal size, scrollback and cursor position. restore()
//                 puts back the *termios* only. The alt screen and the
//                 cursor visibility are separate state, which only a write
//                 to fd 1 can put back -- that is what leave_screen() and
//                 restore_all_exit() do, and why they exist.
//
// THE PATTERN. Do this and you cannot forget. Note that leave_screen() is
// NOT an exit -- it only puts the alt screen and the cursor back. The thing
// that puts the MODE back is restore_all_exit(), and it is the last call:
//
//     if (term.raw_mode()) {          // returns false when not a tty
//         term.enter_screen();        // alt screen + hide cursor
//         term.arm_watchdog();        // one line; covers SIGKILL and crashes
//         run_the_program();          // every early exit inside must be
//         term.restore_all_exit(0);   //   `term.restore_exit(n)`
//     } else {
//         puts("not a terminal\n");
//         exit(1);
//     };
//
// If run_the_program() is worth reusing, have it return a code and do
// `term.restore_all_exit(code)` in exactly one place above.
//
// And inside the program, every early exit is
//
//     if (k == term.KEY_ESC || k == 'q') { term.restore_all_exit(0); };
//
// `restore_exit(n)` (alt screen left alone) or `restore_all_exit(n)` (alt
// screen and cursor put back too) restores and then exits, so it cannot be
// forgotten half-way. If you prefer a guard flag, use `term.active()` to
// test it.
//
// ===========================================================================
// THE KEYS. read_key() / read_key_timeout() return a `long`. Every plain
// byte comes back as itself, so `k == 'q'` / `k == 27` style tests work
// for letters, digits, punctuation, and the control bytes: 9 = TAB,
// 13 = ENTER/CR, 127 = BACKSPACE (some terminals send 8 instead -- both are
// returned raw, compare against whichever you care about), 3 = ^C (raw mode
// clears ISIG, so it arrives as a byte instead of a signal).
//
// Named keys are constants ABOVE the byte range, so they can never collide
// with a byte:
//
//     KEY_NONE    -1     no key: a timeout expired, or EOF, or the read
//                         failed. Never a panic, never a trap.
//     KEY_ESC     4096   a lone ESC. The raw byte 27 is NEVER returned by
//                         read_key(); it always becomes this.
//     KEY_UNKNOWN 4097   an escape sequence this table does not know. Its
//                         bytes were pushed back, so the next read_key()
//                         returns them as ordinary keys -- nothing is lost.
//
//     KEY_UP      4098  ESC [ A      (and ESC O A, application cursor mode)
//     KEY_DOWN    4099  ESC [ B      (and ESC O B)
//     KEY_RIGHT   4100  ESC [ C      (and ESC O C)
//     KEY_LEFT    4101  ESC [ D      (and ESC O D)
//     KEY_HOME    4102  ESC [ H, ESC [ 1 ~, ESC [ 7 ~, ESC O H
//     KEY_END     4103  ESC [ F, ESC [ 4 ~, ESC [ 8 ~, ESC O F
//     KEY_PGUP    4104  ESC [ 5 ~
//     KEY_PGDN    4105  ESC [ 6 ~
//     KEY_INSERT  4106  ESC [ 2 ~
//     KEY_DELETE  4107  ESC [ 3 ~
//     KEY_F1      4108  ESC O P, ESC [ 11 ~
//     KEY_F2      4109  ESC O Q, ESC [ 12 ~
//     KEY_F3      4110  ESC O R, ESC [ 13 ~
//     KEY_F4      4111  ESC O S, ESC [ 14 ~
//     KEY_F5      4112  ESC [ 15 ~
//     KEY_F6      4113  ESC [ 17 ~
//     KEY_F7      4114  ESC [ 18 ~
//     KEY_F8      4115  ESC [ 19 ~
//     KEY_F9      4116  ESC [ 20 ~
//     KEY_F10     4117  ESC [ 21 ~
//     KEY_F11     4118  ESC [ 23 ~
//     KEY_F12     4119  ESC [ 24 ~
//
// Deliberately absent: Ctrl-letter combinations. A terminal in raw mode
// with IEXTEN cleared sends ^A..^Z as bytes 1..26, which read_key returns
// raw, so `k == 1` is ^A and no table entry is needed. Nothing here
// interprets the Alt/ESC-prefixed forms (ESC followed by a letter) -- those
// come back as KEY_UNKNOWN with their bytes pushed back.
//
// A TRUNCATED SEQUENCE NEVER HANGS. After the ESC, continuation bytes are
// read non-blocking (VMIN=0, VTIME=5, i.e. up to 500 ms). A sequence the
// user started but did not finish -- ESC on its own, or ESC [ with nothing
// after it -- is resolved without blocking the program forever. Raise or
// lower ESC_WAIT_MS at the top of this file if 500 ms feels long or short.
//
// ===========================================================================
// WHY THE NUMBERS ARE WHAT THEY ARE (do not "fix" these -- they are right)
//
// syscall(n, a1..a6) binds in KERNEL REGISTER order: n->rax, a1->rdi,
// a2->rsi, a3->rdx, a4->r10, a5->r8, a6->r9. So C's ioctl(fd, request,
// arg) -- written in kernel order -- is syscall(16, fd, REQUEST, arg).
// Swapping the last two returns -25 (ENOTTY) and looks exactly like a
// compiler bug. It is not one.
//
//   TCGETS      0x5401   TCSETS      0x5402
//   TIOCGWINSZ  0x5413   TIOCSWINSZ  0x5414
//
// struct termios: c_iflag bytes 0-3, c_oflag 4-7, c_cflag 8-11, c_lflag
// 12-15, c_line 16, c_cc[32] 17-48. INSIDE c_cc, VTIME is byte 22 and
// VMIN is byte 23 -- not the other way round. Swapped, a blocking read
// becomes a 100 ms poll and the keyboard looks dead with no error at all.
//
//   Blocking one-byte read:        VMIN = 1, VTIME = 0.
//
// LFLAG_RAW, 32859 = 0x805b, is the c_lflag mask raw_mode() clears. It is
// exactly ISIG | ICANON | ECHO | ECHOE | ECHONL | IEXTEN: the four flags
// that matter, plus the two echo variants, so that no echo survives
// whatever the terminal emulator was doing. The individual bits are
// exported too -- note that IEXTEN is 0x8000, NOT 0x10 (0x10 is ECHOE):
//
//   ISIG 1   ICANON 2   ECHO 8   ECHOE 16   ECHONL 64   IEXTEN 32768
//
// c_iflag gets BRKINT | INPCK | ISTRIP | ICRNL | IXON cleared as well (mask
// 1330). Two of those matter a lot: ICRNL off means the Enter key arrives as
// 13 and not 10, and IXON off means Ctrl-S cannot freeze the terminal.
// c_oflag is left alone on purpose, so a bare "\n" still moves down a line.
//
// TIOCGWINSZ fills a [byte; 64] with {ws_row, ws_col, ws_xpixel, ws_ypixel}
// as four 16-bit LITTLE-ENDIAN values -- ROW FIRST, at bytes 0-1.
//
// `readline()` does not work in raw mode (its buffer assumes canonical
// mode). One keypress is read(0, &b[0], 1). There is no termios module in
// the standard library; see examples/SUGGESTIONS.md §3.
//
// ===========================================================================
// BUFFER POLICY. The heap is an arena and nothing is ever freed, so this
// module allocates NOTHING at run time. Every byte it emits is built in
// the module's own [byte; 64] ESC_BUF and written with one write(2). A
// renderer building a whole frame should never call the sgr_* emitters in
// its inner loop; it should use the esc_* appenders (which never syscall)
// and write the finished buffer itself. See tbrender.y in
// examples/badapple/ for the same technique.

// ===========================================================================
// EXPORTS. Every one of these is in the export list at the bottom; this is
// the index. Grouped by what a caller actually wants.
//
//   Constants
//     TCGETS TCSETS TIOCGWINSZ      the ioctl request numbers
//     ISIG ICANON ECHO ECHOE ECHONL IEXTEN LFLAG_RAW       c_lflag bits
//     BRKINT INPCK ISTRIP ICRNL IXON IFLAG_RAW             c_iflag bits
//     KEY_NONE KEY_ESC KEY_UNKNOWN   see THE KEYS above
//     KEY_UP KEY_DOWN KEY_RIGHT KEY_LEFT KEY_HOME KEY_END
//     KEY_PGUP KEY_PGDN KEY_INSERT KEY_DELETE
//     KEY_F1 .. KEY_F12              see THE KEYS above
//     ESC_WAIT_MS                    500; the truncated-sequence deadline
//
//   Lifecycle -- the restore guarantee lives here
//     raw_mode() -> bool             enter raw mode on fd 0; false if no tty
//     restore() -> void              put it back; idempotent, never traps
//     cooked_mode() -> void          alias for restore(), named for the kernel
//     restore_exit(code) -> void     restore, then exit(code)
//     restore_all_exit(code) -> void show cursor, leave alt screen, restore,
//                                    exit(code) -- use this one
//     arm_watchdog() -> bool         fork the crash backstop; see above
//     active() -> bool               is this module holding raw mode?
//
//   Queries
//     is_tty(fd) -> bool             TCGETS succeeding: C's isatty(2)
//     size() -> WinSize              {rows, cols}, 24x80 when unknown
//     set_size(rows, cols) -> bool   TIOCSWINSZ; for a test harness
//
//   Input
//     read_key() -> long             blocking one keypress, sequences decoded
//     read_key_timeout(ms) -> long   the same with a deadline; KEY_NONE on
//                                     timeout, ms rounded up to 10
//
//   Output -- APPENDERS, no syscall, no allocation; a renderer wants these
//     buf_reset() -> void            empty the build buffer
//     buf_len() -> long              how many bytes are in it
//     buf_at(i) -> long              byte i of it; 0 out of range, no trap
//     put_byte(b) -> void            append one byte
//     put_num(v) -> void             append a non-negative long in decimal
//     put_str(s) -> void             append a string's bytes
//     put_csi() -> void              append ESC [
//     flush() -> void                write the buffer to fd 1, one write(2)
//     esc_fg(r,g,b) -> long          -> ESC[0;38;2;R;G;Bm
//     esc_bg(r,g,b) -> long          -> ESC[0;48;2;R;G;Bm
//     esc_rg(fr,fg,fb,br,bg,bb) -> long
//                                     -> ESC[0;38;2;..;48;2;..m
//     esc_reset() -> long            -> ESC[0m
//     esc_clear() -> long            -> ESC[2J
//     esc_home() -> long             -> ESC[H
//     esc_cursor(row,col) -> long    -> ESC[R;CH
//
//   Output -- EMITTERS, one write(2) each; fine for setup, wrong per cell
//     sgr_fg(r,g,b) sgr_bg(r,g,b) sgr_rg(fr,fg,fb,br,bg,bb) sgr_reset()
//     enter_alt_screen() leave_alt_screen() hide_cursor() show_cursor()
//     clear_screen() home() cursor_to(row,col)
//     enter_screen() leave_screen()  the compound alt-screen pair
//
//   Little-endian helpers, for building struct buffers of your own
//     rd16(b,at) -> long    16 bits at `at`
//     rd32(b,at) -> long    32 bits at `at`
//     wr32(b,at,v) -> void  32 bits of `v` at `at`
//     They take a [byte]. A [byte; N] is NOT a [byte] in Y and cannot be
//     passed, which is why TM/SAVED/WS below are growable [byte].
//
type WinSize = { rows: long, cols: long };

// ---- ioctl requests and termios geometry (see the header) ---------------
let TCGETS = 0x5401;
let TCSETS = 0x5402;
let TIOCGWINSZ = 0x5413;

// c_lflag bits. LFLAG_RAW, 32859 (0x805b), is the mask raw_mode() clears:
// ISIG | ICANON | ECHO | ECHOE | ECHONL | IEXTEN. IEXTEN is 0x8000, not
// 0x10 -- 0x10 is ECHOE.
let ISIG = 1;
let ICANON = 2;
let ECHO = 8;
let ECHOE = 16;
let ECHONL = 64;
let IEXTEN = 32768;
let LFLAG_RAW = ISIG | ICANON | ECHO | ECHOE | ECHONL | IEXTEN;

// c_iflag bits raw_mode() clears, mask 1330 (0x532):
//   BRKINT 2    BREAK is not turned into SIGINT
//   ICRNL  256  CR is not translated to NL on input -- WITHOUT THIS, the
//               Enter key arrives as 10 and not 13, which is the classic
//               "my program cannot tell Enter from ^J" bug
//   INPCK  16   parity is not checked
//   ISTRIP 32   the 8th bit is not stripped, so Alt/meta keys survive
//   IXON    1024 Ctrl-S / Ctrl-Q are not flow control, so Ctrl-S cannot
//               appear to freeze the terminal
// c_oflag is deliberately LEFT ALONE: OPOST on means a plain "\n" still
// moves down a line, which a renderer that mixes CUP and newlines needs.
let BRKINT = 2;
let INPCK = 16;
let ISTRIP = 32;
let ICRNL = 256;
let IXON = 1024;
let IFLAG_RAW = BRKINT | INPCK | ISTRIP | ICRNL | IXON;

// Offsets inside struct termios. VTIME is 22, VMIN is 23.
let LFLAG_AT = 12;
let IFLAG_AT = 0;
let VTIME_AT = 22;
let VMIN_AT = 23;

// the VMIN/VTIME pair the terminal is believed to be in right now, or -1
// for "do not know" -- which is what stops every read_key() from paying for
// a redundant TCSETS.
let CUR_VT = -1;
let CUR_VM = -1;

// ---- the key table. See the header for the escape sequences. -----------
let KEY_NONE = -1;
let KEY_ESC = 4096;
let KEY_UNKNOWN = 4097;
let KEY_UP = 4098;
let KEY_DOWN = 4099;
let KEY_RIGHT = 4100;
let KEY_LEFT = 4101;
let KEY_HOME = 4102;
let KEY_END = 4103;
let KEY_PGUP = 4104;
let KEY_PGDN = 4105;
let KEY_INSERT = 4106;
let KEY_DELETE = 4107;
let KEY_F1 = 4108;
let KEY_F2 = 4109;
let KEY_F3 = 4110;
let KEY_F4 = 4111;
let KEY_F5 = 4112;
let KEY_F6 = 4113;
let KEY_F7 = 4114;
let KEY_F8 = 4115;
let KEY_F9 = 4116;
let KEY_F10 = 4117;
let KEY_F11 = 4118;
let KEY_F12 = 4119;

// ---- ESC_WAIT_MS: how long an unfinished escape sequence waits for its
// ---- continuation bytes, in milliseconds (rounded up to a decisecond).
let ESC_WAIT_MS = 500;

// ---- state ---------------------------------------------------------------
let IN_RAW = false;           // this module put the terminal in raw mode
let HAVE_SAVED = false;       // SAVED holds a real termios
let ARMED = false;            // a watchdog child is waiting to restore us

// NB: these three are growable [byte] rather than [byte; 64] on purpose --
// Y has no `*[T]` pointer type and a fixed array is not a `[byte]`, so a
// fixed buffer could not be passed to rd32/wr32/rd16 below or to any
// caller. They are still exactly 64 bytes and are never grown.
let TM: [byte] = [0; 64];       // termios scratch
let SAVED: [byte] = [0; 64];    // the termios to put back
let WS: [byte] = [0; 64];       // winsize scratch

// ---- the escape-sequence buffer (the only output buffer) ----------------
let ESC_BUF: [byte; 64] = [0; 64];
let ESC_LEN = 0;

// ---- scratch, at module scope on purpose -------------------------------
// A local `let ds: [byte; 20] = [0; 20];` ALLOCATES on every call: a Y
// array carries a {len, cap, data, front} header, so those 20 bytes cost a
// 64-byte heap block. In a per-frame loop that is 768 bytes a frame, and the
// heap is an arena, so it never comes back. Every scratch buffer this module
// uses is therefore a module-level fixed array and nothing here allocates,
// ever. term_test.y checks this with heap_used() around 2000 rounds.
let DEC_BUF: [byte; 20] = [0; 20];       // decimal digits of one put_num
let KEY_BUF: [byte; 1] = [0; 1];         // the one byte read_key reads
let PIPE_BUF: [byte; 8] = [0; 8];        // pipe(2)'s two out fds

// ---- input pushback, so a bad escape sequence never eats input ----------
let PB: [byte; 64] = [0; 64];
let PB_N = 0;

// ---- escape-sequence collection ------------------------------------------
let SQ: [byte; 16] = [0; 16];
let SQ_N = 0;

// ===========================================================================
// termios plumbing
// ===========================================================================

// le32 at offset `at` of a byte buffer
def rd32(b: [byte], at: long) -> long {
    b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (b[at + 3] << 24)
};

// wr32 at offset `at`
def wr32(b: [byte], at: long, v: long) {
    b[at] = v & 255;
    b[at + 1] = (v >> 8) & 255;
    b[at + 2] = (v >> 16) & 255;
    b[at + 3] = (v >> 24) & 255;
};

// rd16 at offset `at` -- TIOCGWINSZ hands back four of these, row first
def rd16(b: [byte], at: long) -> long {
    b[at] | (b[at + 1] << 8)
};

// is_tty(fd) -- true when `fd` is a terminal that answers TCGETS. This is
// exactly what C's isatty() does, and it is the check every other function
// in this module makes before touching termios.
def is_tty(fd: long) -> bool {
    syscall(16, fd, TCGETS, &TM[0]) >= 0
};

// set_cc(vtime_ds, vmin) -- put the terminal into VMIN/VTIME, but only if it
// is not already there. Re-reads the live struct first, so a `stty` run in
// another shell is never clobbered from a stale copy. NOTE the order:
// VTIME is byte 22, VMIN is byte 23.
def set_cc(vtime_ds: long, vmin: long) {
    if (!IN_RAW) {
        return;
    };
    if (vtime_ds == CUR_VT && vmin == CUR_VM) {
        return;
    };
    if (syscall(16, 0, TCGETS, &TM[0]) < 0) {
        return;
    };
    TM[VTIME_AT] = vtime_ds & 255;
    TM[VMIN_AT] = vmin & 255;
    if (syscall(16, 0, TCSETS, &TM[0]) >= 0) {
        CUR_VT = vtime_ds;
        CUR_VM = vmin;
    };
};

// blocking read settings: one byte, no timer. This is what an interactive
// loop wants -- read_key() parks in the kernel until a key arrives. After
// raw_mode() this costs nothing at all, because the state is cached.
def blocking_mode() {
    set_cc(0, 1);
};

// timed read settings: return after vtime_ds deciseconds even with nothing
// typed. vmin 0 means "zero bytes is a legitimate answer".
def timeout_mode(vtime_ds: long) {
    set_cc(vtime_ds, 0);
};

// install the raw lflag/iflags into TM. VMIN/VTIME are already in TM.
def install_raw() -> bool {
    wr32(TM, LFLAG_AT, rd32(TM, LFLAG_AT) & ~LFLAG_RAW);
    wr32(TM, IFLAG_AT, rd32(TM, IFLAG_AT) & ~IFLAG_RAW);
    syscall(16, 0, TCSETS, &TM[0]) >= 0
};

// ---------------------------------------------------------------------------
// raw_mode() -- enter raw mode on fd 0 and remember how to get back.
// Returns false, and changes nothing at all, when fd 0 is not a terminal.
// That is the whole not-a-tty contract: check the return value, print a
// message, exit non-zero. Nothing here can trap.
// ---------------------------------------------------------------------------
def raw_mode() -> bool {
    if (syscall(16, 0, TCGETS, &TM[0]) < 0) {
        return false;
    };
    for i in 0..64 {
        SAVED[i] = TM[i];
    };
    HAVE_SAVED = true;
    TM[VTIME_AT] = 0;
    TM[VMIN_AT] = 1;
    if (!install_raw()) {
        // TCSETS refused: put back what we took and report failure rather
        // than leaving the caller believing it owns a raw terminal.
        for i in 0..64 {
            TM[i] = SAVED[i];
        };
        syscall(16, 0, TCSETS, &TM[0]);
        HAVE_SAVED = false;
        return false;
    };
    IN_RAW = true;
    CUR_VT = 0;
    CUR_VM = 1;
    true
};

// active() -- is this module currently holding the terminal in raw mode?
// A program that keeps its own exit paths can use it as a guard flag.
def active() -> bool {
    IN_RAW
};

// cooked_mode() -- alias for restore(), named for what it means to the
// kernel. Identical behaviour; both are safe when raw mode was never
// entered, and safe to call any number of times.
def cooked_mode() -> void {
    restore()
};

// restore() -- put the saved termios back. Idempotent, and a no-op when
// raw_mode() never succeeded. NEVER fails, NEVER traps, and does not exit.
def restore() -> void {
    if (HAVE_SAVED) {
        syscall(16, 0, TCSETS, &SAVED[0]);
        HAVE_SAVED = false;
    };
    if (IN_RAW) {
        IN_RAW = false;
    };
    if (ARMED) {
        // The watchdog child restores the same bytes when we die; make it
        // harmless to fire after an orderly exit.
        ARMED = false;
    };
    CUR_VT = -1;
    CUR_VM = -1;
};

// restore_exit(code) -- restore, then exit(code). This is the one call a
// program should make on every exit path: it cannot be forgotten half way,
// because there is nothing after it.
def restore_exit(code: long) {
    restore();
    exit(code)
};

// ---------------------------------------------------------------------------
// arm_watchdog() -- fork a child that restores the terminal when this process
// dies, however it dies. Call it right after raw_mode(), while the mode is
// still installed.
//
// This is the only thing that covers a crash, `kill -9`, or a SIGSEGV: Y
// has no signal handlers, so nothing in-process can run on those paths. The
// child costs one process and no memory (fork is copy-on-write) and it
// restores exactly the bytes an orderly restore would, so the two can never
// disagree.
//
// HOW THE CHILD KNOWS. Not with wait4(2) -- that waits for the caller's
// CHILDREN, and a child waiting on its parent correctly fails with ECHILD
// (-10); that mistake silently restores the terminal immediately, on every
// keypress, which looks like "the terminal keeps snapping back to cooked
// mode". It is a self-pipe, the standard idiom:
//   * the parent keeps the WRITE end of a pipe(2) open for its whole life;
//   * the child closes the write end and blocks in read(2) on the read end;
//   * when the parent dies -- exit, crash, SIGKILL, anything -- the kernel
//     closes its write end, the child's read returns 0, and the child
//     rewrites the saved termios.
// Zero syscalls in the parent, no polling, no /proc, no signals.
//
// THE CHILD MUST CALL setsid(2), AND THIS IS NOT OPTIONAL. A forked child
// is in the terminal's foreground process group, so the moment the parent
// dies the kernel sends it SIGHUP -- and with the default disposition that
// kills it before it can restore anything. The symptom is a watchdog that
// never fires and a terminal left in raw mode after a SIGKILL, which looks
// exactly like the watchdog not existing. setsid(2) puts the child in a new
// session with no controlling terminal, so it receives no terminal-generated
// signal at all. It still holds fd 0, and TCSETS on a pty slave does not
// need a controlling terminal.
//
// WHAT IT DOES NOT COVER: a signal that kills the child too, a machine
// crash, or a terminal that is not fd 0. It also cannot restore the alt
// screen or the cursor -- that state lives in the terminal emulator, and
// only a write to fd 1 can put it back, which by then is not ours. For the
// paths you CAN control use restore_all_exit(), and use the watchdog as the
// backstop.
//
// Returns true if a watchdog is now armed. False means no watchdog (raw mode
// not held, or already armed, or fork failed) -- nothing is lost, you just
// have no crash coverage.
// ---------------------------------------------------------------------------
def arm_watchdog() -> bool {
    if (!IN_RAW || !HAVE_SAVED || ARMED) {
        return false;
    };
    // pipe(2) writes TWO 32-bit ints, not two longs: read them with rd32 or
    // you get 0x400000003 instead of 3, and every later fd is nonsense.
    // Every syscall whose out-params are C `int` rather than `long` has this
    // shape.
    // pipe(2) writes TWO 32-bit ints, not two longs: read them 4 bytes at a time
    // or you get 0x400000003 for the first fd and a nonsense second one, and
    // close(wfd) then fails with EBADF so the child's read never sees EOF and
    // the watchdog silently never fires. rd32 cannot be used here because it
    // takes a [byte] and PIPE_BUF is a [byte; 8] -- Y has no `*[T]`.
    if (syscall(22, &PIPE_BUF[0], 0, 0, 0, 0, 0) != 0) {   // pipe(2)
        return false;
    };
    let rfd = PIPE_BUF[0] | (PIPE_BUF[1] << 8) | (PIPE_BUF[2] << 16) | (PIPE_BUF[3] << 24);
    let wfd = PIPE_BUF[4] | (PIPE_BUF[5] << 8) | (PIPE_BUF[6] << 16) | (PIPE_BUF[7] << 24);
    if (rfd < 0 || wfd < 0) {
        syscall(3, rfd);
        syscall(3, wfd);
        return false;
    };
    let pid = syscall(57, 0, 0, 0, 0, 0, 0);          // fork(2): 0 in the child
    if (pid < 0) {
        syscall(3, rfd);
        syscall(3, wfd);
        return false;
    };
    if (pid == 0) {
        // ---- child. Leave the terminal's process group FIRST, or the
        // kernel's SIGHUP on the parent's death kills us mid-restore.
        syscall(112, 0, 0, 0, 0, 0, 0);              // setsid(2)
        syscall(3, wfd);
        syscall(0, rfd, &KEY_BUF[0], 1);             // 0 == the parent is gone
        syscall(16, 0, TCSETS, &SAVED[0]);           // TCSETS, from our own fd 0
        // The alt screen and the cursor are emulator state; cooked mode is
        // all we can put back from here.
        syscall(3, rfd);
        syscall(3, 0);
        syscall(3, 1);
        syscall(3, 2);
        syscall(231, 0);                             // exit_group(0)
    };
    syscall(3, rfd);                                 // parent: drop the read end
    ARMED = true;
    true
};

// ---------------------------------------------------------------------------
// size() -- the window size, as {rows, cols}.
//
// TIOCGWINSZ fills WS with {ws_row, ws_col, ws_xpixel, ws_ypixel} as four
// 16-bit little-endian values, row first. Falls back to 24x80 when the
// ioctl fails or reports a zero -- which is what a pty from pty.fork()
// looks like if nobody set TIOCSWINSZ, and a zero row would otherwise
// divide by zero in the first frame a renderer computes.
// ---------------------------------------------------------------------------
def size() -> WinSize {
    let r = 0;
    let c = 0;
    if (syscall(16, 1, TIOCGWINSZ, &WS[0]) >= 0) {
        r = rd16(WS, 0);
        c = rd16(WS, 2);
    };
    if (r < 1) { r = 24; };
    if (c < 1) { c = 80; };
    if (r > 1000) { r = 1000; };
    if (c > 1000) { c = 1000; };
    { rows: r, cols: c }
};

// set_size(rows, cols) -- ask the emulator to resize the window. Used by
// the test harness; almost never by a program. Returns false on failure.
def set_size(rows: long, cols: long) -> bool {
    wr32(WS, 0, 0);
    wr32(WS, 4, 0);
    WS[0] = rows & 255;
    WS[1] = (rows >> 8) & 255;
    WS[2] = cols & 255;
    WS[3] = (cols >> 8) & 255;
    syscall(16, 1, 0x5414, &WS[0]) >= 0     // TIOCSWINSZ
};

// ===========================================================================
// reading bytes
// ===========================================================================

// pop the pushback stack, or -1 when it is empty
def pb_pop() -> long {
    if (PB_N <= 0) {
        return -1;
    };
    PB_N = PB_N - 1;
    PB[PB_N]
};

// push `n` bytes of SQ back, in arrival order, so nothing is lost
def pb_push(n: long) {
    let room = 64 - PB_N;
    let take = n;
    if (take > room) { take = room; };
    let j = 0;
    while (j < take) {
        // SQ[n-1-j] first, so that popping gives SQ[0] first
        PB[PB_N + j] = SQ[n - 1 - j];
        j = j + 1;
    };
    PB_N = PB_N + take;
};

// raw_read() -- read exactly one byte from fd 0. -1 for EOF, for an error,
// and for "no byte arrived" when the terminal is in timed mode. Uses the
// current VMIN/VTIME, so it blocks in blocking mode and times out in timed
// mode. Pushback is drained first, so a pushed-back byte never costs a
// syscall.
def raw_read() -> long {
    let p = pb_pop();
    if (p >= 0) {
        return p;
    };
    let n = syscall(0, 0, &KEY_BUF[0], 1);
    if (n != 1) {
        return -1;
    };
    KEY_BUF[0]
};

// ---------------------------------------------------------------------------
// classify the bytes in SQ (SQ_N of them, everything after the ESC)
// ---------------------------------------------------------------------------
def classify() -> long {
    let n = SQ_N;
    if (n < 1) {
        return KEY_ESC;
    };
    let b0 = SQ[0];
    if (b0 == 91) {
        // CSI: ESC [ ...
        if (n == 2) {
            let c = SQ[1];
            if (c == 65) { return KEY_UP; };
            if (c == 66) { return KEY_DOWN; };
            if (c == 67) { return KEY_RIGHT; };
            if (c == 68) { return KEY_LEFT; };
            if (c == 70) { return KEY_END; };
            if (c == 72) { return KEY_HOME; };
            return KEY_UNKNOWN;
        };
        if (SQ[n - 1] != 126) {
            return KEY_UNKNOWN;
        };
        // ESC [ <digits> ~
        let num = 0;
        let bad = 0;
        let i = 1;
        while (i < n - 1) {
            let c = SQ[i];
            if (c >= 48 && c <= 57) {
                num = num * 10 + (c - 48);
                if (num > 99) { bad = 1; };
            } else {
                bad = 1;
            };
            i = i + 1;
        };
        if (bad != 0 || num < 1) {
            return KEY_UNKNOWN;
        };
        if (num == 1) { return KEY_HOME; };
        if (num == 2) { return KEY_INSERT; };
        if (num == 3) { return KEY_DELETE; };
        if (num == 4) { return KEY_END; };
        if (num == 5) { return KEY_PGUP; };
        if (num == 6) { return KEY_PGDN; };
        if (num == 7) { return KEY_HOME; };
        if (num == 8) { return KEY_END; };
        if (num == 11) { return KEY_F1; };
        if (num == 12) { return KEY_F2; };
        if (num == 13) { return KEY_F3; };
        if (num == 14) { return KEY_F4; };
        if (num == 15) { return KEY_F5; };
        if (num == 17) { return KEY_F6; };
        if (num == 18) { return KEY_F7; };
        if (num == 19) { return KEY_F8; };
        if (num == 20) { return KEY_F9; };
        if (num == 21) { return KEY_F10; };
        if (num == 23) { return KEY_F11; };
        if (num == 24) { return KEY_F12; };
        return KEY_UNKNOWN;
    };
    if (b0 == 79 && n == 2) {
        // SS3: ESC O x -- application cursor mode and F1..F4
        let c = SQ[1];
        if (c == 65) { return KEY_UP; };
        if (c == 66) { return KEY_DOWN; };
        if (c == 67) { return KEY_RIGHT; };
        if (c == 68) { return KEY_LEFT; };
        if (c == 70) { return KEY_END; };
        if (c == 72) { return KEY_HOME; };
        if (c == 80) { return KEY_F1; };
        if (c == 81) { return KEY_F2; };
        if (c == 82) { return KEY_F3; };
        if (c == 83) { return KEY_F4; };
        return KEY_UNKNOWN;
    };
    KEY_UNKNOWN
};

// ---------------------------------------------------------------------------
// decode_esc() -- called with the byte just after an ESC. Collects the rest
// of the sequence with a NON-BLOCKING read (ESC_WAIT_MS, rounded up to a
// decisecond -- VTIME has 100 ms granularity and 0.1 ms rounds down to
// nothing), then classifies it.
//
// A sequence the user never finished resolves to KEY_ESC or KEY_UNKNOWN
// instead of blocking, and an unrecognised sequence's bytes go back on the
// pushback stack so the next read_key() returns them as ordinary keys.
// ---------------------------------------------------------------------------
def decode_esc() -> long {
    SQ_N = 0;
    if (!IN_RAW) {
        // Not raw: no safe way to time out a partial sequence, so take one
        // byte and see. Good enough for a piped script, never hangs on a
        // tty because a tty always has raw mode set by now.
        let b = raw_read();
        if (b < 0) {
            return KEY_ESC;
        };
        SQ[0] = b;
        SQ_N = 1;
        let k = classify();
        if (k == KEY_UNKNOWN) {
            pb_push(SQ_N);
        };
        return k;
    };
    // deciseconds, at least 1
    let ds = (ESC_WAIT_MS + 99) / 100;
    if (ds < 1) { ds = 1; };
    if (ds > 255) { ds = 255; };
    timeout_mode(ds);
    let more = true;
    while (more) {
        let b = raw_read();
        if (b < 0) {
            more = false;
        } else {
            SQ[SQ_N] = b;
            SQ_N = SQ_N + 1;
            // Stop as soon as the sequence cannot continue with a digit,
            // ';', '<' or '?' -- a letter or '~' ends it. The SQ_N >= 2
            // guard matters: '[' and 'O' are both outside 48..63, and the
            // byte right after the ESC is always one of them, so without it
            // ESC [ A would be collected as one byte and never recognised.
            let last = SQ[SQ_N - 1];
            let stop = SQ_N >= 2 && (last < 48 || last > 63);
            if (SQ_N >= 15 || stop) {
                more = false;
            };
        };
    };
    blocking_mode();
    let k = classify();
    if (k == KEY_UNKNOWN) {
        pb_push(SQ_N);
    };
    k
};

// ---------------------------------------------------------------------------
// read_key() -- block until one key is pressed.
//
// A plain byte comes back as itself. A named key comes back as its
// KEY_* constant. ESC never comes back as 27: it is KEY_ESC, or the
// sequence it starts is decoded. KEY_NONE means EOF on stdin, or a read
// error, or an interrupt -- never a trap.
// ---------------------------------------------------------------------------
def read_key() -> long {
    blocking_mode();
    let b = raw_read();
    if (b < 0) {
        return KEY_NONE;
    };
    if (b != 27) {
        return b;
    };
    decode_esc()
};

// ---------------------------------------------------------------------------
// read_key_timeout(ms) -- the same decoding with a deadline.
//
// Implemented with VMIN=0 / VTIME on the terminal itself, NOT with poll(2)
// or select(2). VTIME counts deciseconds, so the deadline is rounded UP to
// the next 10 ms and a request below 10 ms becomes 10 ms; 0 ms is an
// immediate poll. Returns KEY_NONE when nothing arrived in time, and the
// usual key otherwise. While decoding an escape sequence the continuation
// gets ESC_WAIT_MS as well, so `read_key_timeout(10)` on a bare ESC can
// take about half a second -- pass a large ms only if that is what you
// want.
//
// If raw mode is not held this degrades to a plain blocking read, because
// VMIN/VTIME have no effect in canonical mode.
// ---------------------------------------------------------------------------
def read_key_timeout(ms: long) -> long {
    let b = -1;
    if (IN_RAW) {
        let ds = (ms + 99) / 100;
        if (ds < 0) { ds = 0; };
        if (ds > 255) { ds = 255; };
        timeout_mode(ds);
        b = raw_read();
        blocking_mode();
    } else {
        b = raw_read();
    };
    if (b < 0) {
        return KEY_NONE;
    };
    if (b != 27) {
        return b;
    };
    decode_esc()
};

// ===========================================================================
// output -- the module's own byte buffer, then one write(2)
// ===========================================================================

def buf_reset() {
    ESC_LEN = 0;
};

// buf_len() -- how many bytes are in the buffer right now
def buf_len() -> long {
    ESC_LEN
};

// buf_at(i) -- byte i of the buffer, for a caller that wants to inspect or
// copy what was built. Reads past the end return 0; ESC_BUF is 64 bytes.
def buf_at(i: long) -> long {
    if (i < 0 || i >= 64) {
        return 0;
    };
    ESC_BUF[i]
};

// put_byte(b) -- append one byte
def put_byte(b: long) {
    if (ESC_LEN < 64) {
        ESC_BUF[ESC_LEN] = b & 255;
    };
    ESC_LEN = ESC_LEN + 1;
};

// put_num(v) -- append a non-negative long in decimal, no leading zeros, and
// always at least one digit (0 prints "0", which cursor_to(1,1) needs).
// A long is at most 19 digits, so it always fits in the 64-byte buffer.
def put_num(v: long) {
    let n = v;
    if (n < 0) {
        n = 0;
    };
    let k = 0;
    let more = true;
    while (more) {
        DEC_BUF[k] = n % 10;
        k = k + 1;
        n = n / 10;
        more = n > 0;
    };
    let i = k;
    while (i > 0) {
        i = i - 1;
        put_byte(48 + DEC_BUF[i]);
    };
};

// put_str(s) -- append a string's bytes
def put_str(s: str) {
    for i in 0..len(s) {
        put_byte(byte_at(s, i));
    };
};

// put_csi() -- append ESC [
def put_csi() {
    put_byte(27);
    put_byte(91);
};

// ---------------------------------------------------------------------------
// esc_* APPENDERS. They never syscall and never allocate: they build the
// escape sequence into ESC_BUF and return the new length. A renderer in a
// per-frame loop wants THESE, not the sgr_* emitters below -- one write(2)
// per frame instead of one per colour change.
//
//   esc_fg(r,g,b)      -> ESC [ 0;38;2;R;G;B m
//   esc_bg(r,g,b)      -> ESC [ 0;48;2;R;G;B m
//   esc_rg(fr,fg,fb,br,bg,bb) -> ESC [ 0;38;2;R;G;B;48;2;R;G;B m
//   esc_reset()        -> ESC [ 0 m
//   esc_clear()        -> ESC [ 2 J   (whole screen, not the scrollback)
//   esc_home()         -> ESC [ H
//   esc_cursor(r,c)    -> ESC [ R ; C H  (1-based, as CUP wants them)
// ---------------------------------------------------------------------------
def esc_fg(r: long, g: long, b: long) -> long {
    put_csi();
    put_byte(48); put_byte(59);                 // 0;
    put_str("38;2;");
    put_num(clamp255(r)); put_byte(59);
    put_num(clamp255(g)); put_byte(59);
    put_num(clamp255(b));
    put_byte(109);                              // m
    ESC_LEN
};

def esc_bg(r: long, g: long, b: long) -> long {
    put_csi();
    put_byte(48); put_byte(59);
    put_str("48;2;");
    put_num(clamp255(r)); put_byte(59);
    put_num(clamp255(g)); put_byte(59);
    put_num(clamp255(b));
    put_byte(109);
    ESC_LEN
};

def esc_rg(fr: long, fg: long, fb: long, br: long, bg: long, bb: long) -> long {
    put_csi();
    put_byte(48); put_byte(59);
    put_str("38;2;");
    put_num(clamp255(fr)); put_byte(59);
    put_num(clamp255(fg)); put_byte(59);
    put_num(clamp255(fb)); put_byte(59);
    put_str("48;2;");
    put_num(clamp255(br)); put_byte(59);
    put_num(clamp255(bg)); put_byte(59);
    put_num(clamp255(bb));
    put_byte(109);
    ESC_LEN
};

def esc_reset() -> long {
    put_csi();
    put_byte(48);
    put_byte(109);
    ESC_LEN
};

def esc_clear() -> long {
    put_csi();
    put_byte(50); put_byte(74);                 // 2J
    ESC_LEN
};

def esc_home() -> long {
    put_csi();
    put_byte(72);                               // H
    ESC_LEN
};

def esc_cursor(row: long, col: long) -> long {
    put_csi();
    put_num(row);
    put_byte(59);
    put_num(col);
    put_byte(72);                               // H
    ESC_LEN
};

// clamp255 -- SGR colour components are one byte; a caller that divides or
// scales without clamping should not produce an illegal sequence.
def clamp255(v: long) -> long {
    let r = v;
    if (r < 0) { r = 0; };
    if (r > 255) { r = 255; };
    r
};

// ---------------------------------------------------------------------------
// sgr_* EMITTERS. Each builds its sequence with the esc_* appender above
// and writes ESC_BUF with ONE write(2). Fine for setup and for occasional
// highlights; wrong for a per-cell loop -- use the appenders there.
// ---------------------------------------------------------------------------
def sgr_fg(r: long, g: long, b: long) {
    buf_reset();
    esc_fg(r, g, b);
    flush();
};

def sgr_bg(r: long, g: long, b: long) {
    buf_reset();
    esc_bg(r, g, b);
    flush();
};

def sgr_rg(fr: long, fg: long, fb: long, br: long, bg: long, bb: long) {
    buf_reset();
    esc_rg(fr, fg, fb, br, bg, bb);
    flush();
};

def sgr_reset() {
    buf_reset();
    esc_reset();
    flush();
};

// flush() -- write whatever is in ESC_BUF to fd 1 and empty it. One write.
def flush() -> void {
    if (ESC_LEN > 0) {
        syscall(1, 1, &ESC_BUF[0], ESC_LEN);
    };
    ESC_LEN = 0;
};

// ---------------------------------------------------------------------------
// the screen-state helpers. Each is the esc_* appender plus one flush(), so
// each is exactly one write(2) of a few bytes.
// ---------------------------------------------------------------------------
def enter_alt_screen() {
    buf_reset();
    put_csi();
    put_str("?1049h");
    flush();
};

def leave_alt_screen() {
    buf_reset();
    put_csi();
    put_str("?1049l");
    flush();
};

def hide_cursor() {
    buf_reset();
    put_csi();
    put_str("?25l");
    flush();
};

def show_cursor() {
    buf_reset();
    put_csi();
    put_str("?25h");
    flush();
};

def clear_screen() {
    buf_reset();
    esc_clear();
    flush();
};

def home() {
    buf_reset();
    esc_home();
    flush();
};

def cursor_to(row: long, col: long) {
    buf_reset();
    esc_cursor(row, col);
    flush();
};

// ---------------------------------------------------------------------------
// enter_screen() / leave_screen() -- the compound pair, and the one the
// header's pattern calls. enter_screen hides the cursor and switches to the
// alternate screen buffer (ESC[?1049h: save cursor, switch, clear).
// leave_screen is the exact inverse and is safe to call when
// enter_screen() was never called.
// ---------------------------------------------------------------------------
def enter_screen() {
    enter_alt_screen();
    hide_cursor();
};

def leave_screen() {
    show_cursor();
    leave_alt_screen();
};

// restore_all_exit(code) -- the most forgettable exit there is: alt screen
// off, cursor on, cooked mode, exit. Use this instead of restore_exit()
// unless the program never entered the alt screen (calling it anyway is
// harmless: the two escape sequences are no-ops on a normal screen).
def restore_all_exit(code: long) {
    show_cursor();
    leave_alt_screen();
    restore_exit(code)
};

export {
    // constants
    TCGETS, TCSETS, TIOCGWINSZ,
    ISIG, ICANON, ECHO, ECHOE, ECHONL, IEXTEN, LFLAG_RAW,
    BRKINT, INPCK, ISTRIP, ICRNL, IXON, IFLAG_RAW,
    KEY_NONE, KEY_ESC, KEY_UNKNOWN,
    KEY_UP, KEY_DOWN, KEY_RIGHT, KEY_LEFT,
    KEY_HOME, KEY_END, KEY_PGUP, KEY_PGDN, KEY_INSERT, KEY_DELETE,
    KEY_F1, KEY_F2, KEY_F3, KEY_F4, KEY_F5, KEY_F6,
    KEY_F7, KEY_F8, KEY_F9, KEY_F10, KEY_F11, KEY_F12,
    ESC_WAIT_MS,
    // termios
    is_tty, raw_mode, cooked_mode, restore, restore_exit, active,
    arm_watchdog, rd32, wr32, rd16,
    // window size
    size, set_size,
    // input
    read_key, read_key_timeout,
    // buffered output
    buf_reset, buf_len, buf_at, put_byte, put_num, put_str, put_csi, flush,
    esc_fg, esc_bg, esc_rg, esc_reset, esc_clear, esc_home, esc_cursor,
    // immediate output
    sgr_fg, sgr_bg, sgr_rg, sgr_reset,
    enter_alt_screen, leave_alt_screen, hide_cursor, show_cursor,
    clear_screen, home, cursor_to,
    enter_screen, leave_screen, restore_all_exit
};