#!/usr/bin/env python3
"""term_pty_test.py -- the pty driver for examples/_toolkit/term_test.y.

A terminal module cannot be tested honestly without a terminal: ioctl(2)
TCGETS and TIOCGWINSZ both return ENOTTY on a pipe, and a pipe's read() hits
EOF immediately, so every "the keyboard works" claim would be vacuous. This
driver does the plumbing:

  * fork(2) a pty with pty.fork() and set a real window size on the SLAVE
    before execv -- a pty from pty.fork() starts at 0x0, which would make the
    program under test compute a degenerate frame;
  * set RLIMIT_AS to 3.5 GiB in the child, because every process on this
    machine runs under `ulimit -S -v 3670016`;
  * read the program's output on the master and relay it;
  * write keystrokes on the master ONLY in response to a `<<FEED ..>>` marker
    on the output. The program prints the bytes it wants to be sent, so there
    is a synchronisation point on every keystroke and no timing race at all.
    An empty marker means "send nothing", which is how the timed read is
    tested;
  * check the byte-exact escape sequences the program emitted between the
    `<<PROBE alt>>` and `<<PROBE end>>` markers. The immediate emitters write
    and are gone, so they can only be checked from out here;
  * check, also from out here, that a program killed with SIGKILL still gets
    its terminal back when term.arm_watchdog() was armed, and does NOT when
    it was not. That is the restore guarantee, proven by the control case.

Usage
    term_pty_test.py [--rows R] [--cols C] [--no-tty] [--quiet] [--skip-crash]
                     PROG [args...]

    PROG                 the compiled term_test.y
    --rows / --cols      the window size to set on the pty, and the size the
                         program is told to expect (default 31 x 97)
    --no-tty             run PROG with pipes on stdin/stdout instead of a pty,
                         to check the graceful not-a-terminal path
    --skip-crash         skip the two SIGKILL watchdog cases
    --quiet              print only the FAIL lines and the verdict

Exit status
    0  the program passed every check (or took the documented graceful
       not-a-tty path) and every driver-side check passed
    1  a check failed somewhere
    2  bad usage, or PROG is missing or not executable

Deterministic by default: no clock, no randomness, one fixed window size. The
only wall-clock output is the `elapsed` line, which --quiet suppresses.
"""

import argparse
import errno
import fcntl
import os
import pty
import re
import resource
import struct
import sys
import termios
import time

# 3.5 GiB in bytes: the same cap as `ulimit -S -v 3670016`.
MEM_CAP_KB = 3670016

# The immediate emitters, as they must appear on the wire, in this order.
PROBE_SEQS = [
    (b"\x1b[?1049h", "enter_alt_screen()"),
    (b"\x1b[?25l", "hide_cursor()"),
    (b"\x1b[0;38;2;1;2;3m", "sgr_fg(1,2,3)"),
    (b"\x1b[0;48;2;10;20;30m", "sgr_bg(10,20,30)"),
    (b"\x1b[0;38;2;1;2;3;48;2;4;5;6m", "sgr_rg(1,2,3,4,5,6)"),
    (b"\x1b[0m", "sgr_reset()"),
    (b"\x1b[2J", "clear_screen()"),
    (b"\x1b[H", "home()"),
    (b"\x1b[3;7H", "cursor_to(3,7)"),
    (b"\x1b[?25h", "show_cursor()"),
    (b"\x1b[?1049l", "leave_alt_screen()"),
]

# c_lflag bits raw mode has to clear.
ICANON = 2
ECHO = 8
ISIG = 1
IEXTEN = 16

FEED_RE = re.compile(rb"<<FEED([^>]*)>>")


def exit_code_of(status):
    if hasattr(os, "waitstatus_to_exitcode"):
        return os.waitstatus_to_exitcode(status)
    return status


def child_setup(rows, cols, argv, stdin_fd=None):
    """Run in the forked child: size the pty, cap the memory, exec."""
    if stdin_fd is None:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    resource.setrlimit(resource.RLIMIT_AS, (MEM_CAP_KB * 1024,) * 2)
    try:
        os.execv(argv[0], argv)
    except Exception:
        os._exit(127)


def drain(master):
    """Read the master to EIO/EOF, returning everything."""
    out = b""
    while True:
        try:
            data = os.read(master, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        out += data
    return out


class PtyRun:
    """One pty-driven run of the program under test."""

    def __init__(self, prog, args, rows, cols):
        self.prog = prog
        self.args = args
        self.rows = rows
        self.cols = cols
        self.master = None
        self.out = b""
        self.scan = b""  # output not yet scanned for FEED markers
        self.errors = []

    def spawn(self, extra):
        argv = [self.prog] + self.args + extra
        pid, master = pty.fork()
        if pid == 0:
            child_setup(self.rows, self.cols, argv)
        self.master = master
        return pid, master

    def run(self):
        pid, master = self.spawn([])
        deadline = time.monotonic() + 120.0
        try:
            while True:
                if time.monotonic() > deadline:
                    self.errors.append("timed out after 120 s waiting for the program")
                    os.kill(pid, 9)
                    break
                try:
                    data = os.read(master, 65536)
                except OSError as exc:
                    # EIO on the master is how a pty says "the slave is gone",
                    # which is the normal end of this loop.
                    if exc.errno == errno.EIO:
                        break
                    raise
                if not data:
                    break
                self.consume(data)
        finally:
            os.close(master)
        _, status = os.waitpid(pid, 0)
        return exit_code_of(status)

    def consume(self, data):
        # A pty translates \n to \r\n on the way out; normalise it back.
        self.out += data.replace(b"\r\n", b"\n")
        # The program prints a marker with several small write(2)s, so a
        # marker routinely arrives split across two reads. Scan the whole
        # unscanned tail every time and only drop what has been acted on.
        self.scan += data
        done = 0
        for m in FEED_RE.finditer(self.scan):
            done = m.end()
            # "<<FEED>>" means send nothing -- that is how the timed read is
            # tested. "<<FEED 1b 5b 41>>" sends those three bytes.
            spec = m.group(1).replace(b" ", b"").strip()
            if spec:
                os.write(self.master, bytes.fromhex(spec.decode()))
        if done:
            self.scan = self.scan[done:]

    # ---- checks on what the program wrote ---------------------------------
    def probe_block(self):
        start = self.out.rfind(b"<<PROBE alt>>")
        if start < 0:
            self.errors.append("no <<PROBE alt>> block in the program's output")
            return None
        start += len(b"<<PROBE alt>>")
        end = self.out.find(b"<<PROBE end>>", start)
        return self.out[start:] if end < 0 else self.out[start:end]

    def check_probe(self):
        block = self.probe_block()
        if block is None:
            return
        pos = 0
        for seq, name in PROBE_SEQS:
            at = block.find(seq, pos)
            if at < 0:
                self.errors.append(
                    "byte-exact: %s did not emit %r in the probe block"
                    % (name, seq.decode("latin1"))
                )
                return
            pos = at + len(seq)

    def text(self):
        return self.out.decode("utf-8", "replace")


def run_with_pipes(prog, rows, cols):
    """The documented not-a-tty path: stdin /dev/null, stdout a pipe."""
    rd, wr = os.pipe()
    pid = os.fork()
    if pid == 0:
        null = os.open("/dev/null", os.O_RDONLY)
        os.dup2(null, 0)
        os.dup2(wr, 1)
        if null > 2:
            os.close(null)
        os.close(rd)
        os.close(wr)
        resource.setrlimit(resource.RLIMIT_AS, (MEM_CAP_KB * 1024,) * 2)
        try:
            os.execv(prog, [prog, "--expect-rows=%d" % rows, "--expect-cols=%d" % cols])
        except Exception:
            os._exit(127)
    os.close(wr)
    out = b""
    while True:
        try:
            d = os.read(rd, 65536)
        except OSError:
            break
        if not d:
            break
        out += d
    os.close(rd)
    _, status = os.waitpid(pid, 0)
    return exit_code_of(status), out.decode("utf-8", "replace")


def crash_case(prog, rows, cols, arm):
    """Run term_test.y in a mode that enters raw mode and then SIGKILLs
    itself. arm=True means it called term.arm_watchdog() first.

    Returns (announced, restored, saw_trap) -- `restored` is None when the
    termios could not be read back.
    """
    mode = "--wd-crash" if arm else "--wd-crash-nowatch"
    argv = [prog, mode]
    pid, master = pty.fork()
    if pid == 0:
        child_setup(rows, cols, argv)
    announced = False
    buf = b""
    while True:
        try:
            data = os.read(master, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        buf += data
        if b"<<ARMED>>" in buf:
            announced = True
            break
    # Read to the end. In the armed case the slave side stays open until the
    # watchdog child has written the termios back and closed its fds, so by
    # the time EIO arrives the restore has definitely happened: the check
    # below cannot race with it.
    buf += drain(master)
    restored = None
    try:
        lflags = termios.tcgetattr(master)[3]
        restored = (lflags & (ICANON | ECHO)) == (ICANON | ECHO)
    except Exception:
        pass
    os.close(master)
    os.waitpid(pid, 0)
    return announced, restored, (b"runtime error" in buf)


def exit_case(prog, rows, cols, code_want):
    """Run term_test.y --exit=N: enter raw mode, enter the alt screen, arm the
    watchdog, then leave through term.restore_all_exit(N). The exit status
    must be N and the terminal must be back in cooked mode."""
    argv = [prog, "--exit=%d" % code_want]
    pid, master = pty.fork()
    if pid == 0:
        child_setup(rows, cols, argv)
    announced = False
    buf = b""
    while True:
        try:
            data = os.read(master, 65536)
        except OSError as exc:
            if exc.errno == errno.EIO:
                break
            raise
        if not data:
            break
        buf += data
        if b"<<ARMED>>" in buf:
            announced = True
            break
    buf += drain(master)
    restored = None
    try:
        lflags = termios.tcgetattr(master)[3]
        restored = (lflags & (ICANON | ECHO)) == (ICANON | ECHO)
    except Exception:
        pass
    os.close(master)
    _, status = os.waitpid(pid, 0)
    # The alt screen is an emulator state, not a line-discipline one, so it
    # cannot be checked from here; what matters is that the escape codes for
    # leaving it went to the master before it closed.
    left_screen = b"\x1b[?25h\x1b[?1049l" in buf
    return exit_code_of(status), announced, restored, left_screen


def report_failures(failures, quiet):
    if failures:
        for f in failures:
            sys.stderr.write("FAIL %s\n" % f)
    return 1 if failures else 0


def main(argv):
    ap = argparse.ArgumentParser(
        description="pty driver for examples/_toolkit/term_test.y")
    ap.add_argument("prog")
    ap.add_argument("rest", nargs="*", help="extra arguments for the program")
    ap.add_argument("--rows", type=int, default=31)
    ap.add_argument("--cols", type=int, default=97)
    ap.add_argument("--no-tty", action="store_true",
                    help="run with pipes instead of a pty")
    ap.add_argument("--skip-crash", action="store_true",
                    help="skip the two SIGKILL watchdog cases")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args(argv)

    prog = os.path.abspath(args.prog)
    if not os.path.isfile(prog) or not os.access(prog, os.X_OK):
        sys.stderr.write("term_pty_test.py: %s is not an executable file\n" % args.prog)
        return 2

    failures = []
    t0 = time.monotonic()

    if args.no_tty:
        code, text = run_with_pipes(prog, args.rows, args.cols)
        if not args.quiet:
            sys.stdout.write(text)
            if text and not text.endswith("\n"):
                sys.stdout.write("\n")
        if code != 0:
            failures.append("not-a-tty run exited %d, want 0" % code)
        if "not running under a pty" not in text:
            failures.append("not-a-tty run did not print the graceful message")
        if "runtime error" in text:
            failures.append("not-a-tty run trapped")
        if not failures and not args.quiet:
            print("term_pty_test: not-a-tty path OK")
        return report_failures(failures, args.quiet)

    run = PtyRun(prog, list(args.rest) + [
        "--expect-rows=%d" % args.rows,
        "--expect-cols=%d" % args.cols,
    ], args.rows, args.cols)
    code = run.run()
    text = run.text()
    if not args.quiet:
        sys.stdout.write(text)
        if text and not text.endswith("\n"):
            sys.stdout.write("\n")
    run.check_probe()
    failures.extend(run.errors)

    if code != 0:
        failures.append("term_test.y exited %d, want 0" % code)
    if "runtime error" in text:
        failures.append("term_test.y trapped")
    inner = [ln for ln in text.splitlines() if ln.startswith("FAIL ")]
    if inner:
        failures.append("%d check(s) inside term_test.y failed" % len(inner))
    if "term_test: OK" not in text:
        failures.append("term_test.y did not print its OK line")

    if not args.skip_crash:
        for arm in (True, False):
            what = "with" if arm else "without"
            announced, restored, trapped = crash_case(prog, args.rows, args.cols, arm)
            if not announced:
                failures.append("crash case %s a watchdog: never saw <<ARMED>>" % what)
                continue
            if trapped:
                failures.append("crash case %s a watchdog: the program trapped" % what)
                continue
            if restored is None:
                failures.append("crash case %s a watchdog: tcgetattr failed" % what)
                continue
            if arm and not restored:
                failures.append(
                    "SIGKILLed the program with a watchdog armed and the terminal "
                    "was left in raw mode (ICANON and ECHO still clear)")
                print("FAIL SIGKILL with a watchdog armed: terminal NOT restored")
            elif not arm and restored:
                failures.append(
                    "SIGKILLed the program with no watchdog and the terminal came "
                    "back anyway, so the control case proves nothing")
                print("FAIL SIGKILL without a watchdog: terminal unexpectedly restored")
            else:
                print("ok   SIGKILL %s a watchdog: %s" % (
                    what, "terminal restored" if restored else "terminal left raw, "
                    "which is what the watchdog exists to prevent"))

    if not args.skip_crash:
        code, announced, restored, left_screen = exit_case(prog, args.rows, args.cols, 7)
        if not announced:
            failures.append("--exit=7 run: never saw <<ARMED>>")
        elif code != 7:
            failures.append("--exit=7 run exited %d, want 7" % code)
        elif restored is None:
            failures.append("--exit=7 run: tcgetattr failed")
        elif not restored:
            failures.append(
                "restore_all_exit(7) left the terminal in raw mode")
        elif not left_screen:
            failures.append(
                "restore_all_exit(7) did not emit ESC[?25h then ESC[?1049l, "
                "so the alt screen and the cursor were left as they were")
        else:
            print("ok   restore_all_exit(7): exit 7, terminal restored, "
                  "alt screen and cursor left")

    if not failures and not args.quiet:
        # stdout stays byte-for-byte reproducible: the wall clock goes to
        # stderr, so two runs of the documented command diff clean.
        print("term_pty_test: OK")
        sys.stderr.write("term_pty_test: %.1fs\n" % (time.monotonic() - t0))
    return report_failures(failures, args.quiet)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))