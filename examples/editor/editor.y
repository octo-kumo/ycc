// editor.y -- a Vi-style modal terminal editor: raw mode, an event-driven
// redraw, a scripted `--no-tty` mode that dumps the buffer and the screen, and
// a property-check mode with no golden file behind it.
//
// ===========================================================================
// THE THREE THINGS THAT SHAPE THIS FILE
//
// 1. THE REDRAW IS EVENT-DRIVEN, AND THE POLL MUST NOT HAVE A TIMEOUT.
//    `tui.read_key_timeout(ms)` cannot be finer than 100 ms: VTIME counts
//    DECISECONDS, so any non-zero ms rounds UP to the next 100 ms -- measured on
//    the pinned compiler at ~104 ms per call, and five calls taking 518 ms.
//    An editor that polled with read_key_timeout(16) would spend 100 ms per
//    frame, feel broken, and report nothing wrong.  So the loop polls with
//    read_key_timeout(0) -- non-blocking, returns KEY_NONE at once -- and naps
//    with tui.nap_us() when there is nothing to do.  A frame is drawn only
//    because something changed, never because a timer fired.
//
// 2. THE WINDOW SIZE IS QUERIED WITH OUR OWN winsize(), NOT tui.size().
//    tui.size() builds a fresh record on every call (~40 bytes, measured with
//    heap_used()); calling it once per redraw is a per-frame leak with no
//    diagnostic.  screen.winsize() does the TIOCGWINSZ ioctl into a
//    module-level buffer and assigns two module-level longs, so it is free
//    however often it runs.  tui is vendored byte-identical and tui.size()
//    is simply not on this path.
//
// 3. THE TERMINAL IS ALWAYS RESTORED, ON EVERY EXIT PATH.
//    Y has no atexit and no signal handlers, so the ONLY way is tui's
//    pattern, used verbatim:
//        if (tui.raw_mode()) {
//            tui.enter_screen();
//            tui.arm_watchdog();
//            <one place: tui.restore_all_exit(code)>
//        }
//    and every early exit inside is `return <code>` -- one exit point at the
//    bottom, so nothing can forget half of it.  The watchdog child calls
//    setsid(2) (tui does that already), which is what makes it survive the
//    parent's death instead of being SIGHUP'd before it can restore.
//
// ===========================================================================
// THE `--no-tty` MODE
//
// `--no-tty` never touches the terminal: it decodes `--keys` into the same
// longs tui.read_key() returns, feeds them through the same modes.feed(), and
// then prints the buffer, the screen and the message log.  That is what makes
// the example testable without a pty AND what makes a diagnostic that reached
// only the status line show up in `diff EXPECTED`.
//
// It is deterministic by construction: no clock, no terminal size, no
// randomness, and `--seed` defaults to a fixed value.  `./editor --bench`
// reports timings and is the one mode that is not byte-reproducible.

import buf;
import modes;
import screen;
import args;
import check;
import tui;

// ---- the option spec -----------------------------------------------------
// A module-level literal, not one inside main(): a record or array literal in
// a function body allocates, and args.init()
// stores its own copy besides.
const OPTS: [args.Opt] = [
    { long: "check",    short: "",   kind: args.BOOL, help: "run the property checks and exit (no reference file involved)" },
    { long: "no-tty",   short: "n",  kind: args.BOOL, help: "scripted mode: no terminal at all, dump the buffer and the screen" },
    { long: "keys",     short: "k",  kind: args.STR,  help: "the key script to run in --no-tty mode, e.g. \"ggdwiw<Esc>:wq\"" },
    { long: "bench",    short: "b",  kind: args.NUM,  help: "build N frames without drawing and report the cost (default 2000)" },
    { long: "rows",     short: "",   kind: args.NUM,  help: "screen rows for --no-tty (default 12)" },
    { long: "cols",     short: "",   kind: args.NUM,  help: "screen columns for --no-tty (default 44)" },
    { long: "numbers",  short: "",   kind: args.STR,  help: "on | off -- the line-number gutter (default on)" },
    { long: "seed",     short: "",   kind: args.NUM,  help: "seed for the property checks' edit fuzz (default 1)" },
    { long: "version",  short: "v",  kind: args.BOOL, help: "print the version and exit" }
];

const VERSION = "editor 0.1 -- a Vi-style modal terminal editor in Y";

// ===========================================================================
// helpers
// ===========================================================================

// FNV-1a over 64 bits, as two 32-bit halves so there is no shift past bit 63
// and no float anywhere.  Used by check.y's undo invariant to print a hash
// instead of 4000 lines of text.
def fnv(s: str, seed0: long, seed1: long) -> str {
    let h0 = seed0;
    let h1 = seed1;
    let i = 0;
    while (i < len(s)) {
        h0 = (h0 ^ byte_at(s, i)) & 65535;
        h1 = (h1 + h0 * 16777619) & 65535;
        i = i + 1
    };
    tostring(h1) + ":" + tostring(h0)
};

def pad_left(s: str, w: long) -> str { s.pad_left(w, " ") };
def pad_right(s: str, w: long) -> str { s.pad_right(w, " ") };

// ===========================================================================
// the dump
// ===========================================================================

// The scripted run's output.  Everything here is a plain byte append into a
// module-level buffer: this is not a redraw path, but it is on the
// determinism path, so nothing in it may depend on a clock or an address.
const DMAX = 262144;
let DBUF: [byte; 262144] = [0; 262144];
let DLEN = 0;

def d_byte(b: long) -> void {
    if (DLEN < DMAX) {
        DBUF[DLEN] = b & 255;
        DLEN = DLEN + 1
    }
};

def d_str(s: str) -> void {
    let i = 0;
    while (i < len(s)) { d_byte(byte_at(s, i)); i = i + 1 }
};

def d_num(v: long) -> void { d_str(tostring(v)) };

// One line into the dump buffer.
def d_line(s: str) -> void {
    d_str(s);
    d_byte(10)
};

// A screen row from the plain buffer, inside a ruled box so a width mistake is
// visible rather than a run of trailing spaces nobody can see.
def d_rule(cols: long) -> void {
    d_str("+");
    let i = 0;
    while (i < cols) { d_byte(45); i = i + 1 };
    d_str("+");
    d_byte(10)
};

def dump_screen(rows: long, cols: long) -> void {
    screen.build_grid(rows, cols);
    screen.emit_plain(rows, cols);
    d_rule(cols);
    let r = 0;
    while (r < rows) {
        d_str("|");
        let n = screen.plain_row_len(r);
        let c = 0;
        while (c < n) { d_byte(screen.plain_at(screen.plain_row_start(r) + c)); c = c + 1 };
        // Padded to the full width so the box stays rectangular.  Exact for ASCII,
        // which is what the golden file is.
        let pad = cols - n;
        let q = 0;
        while (q < pad) { d_byte(32); q = q + 1 };
        d_str("|");
        d_byte(10);
        r = r + 1
    };
    d_rule(cols)
};

// ===========================================================================
// the interactive loop
// ===========================================================================

// Returns the process exit code.  Every early exit is a `return` from here, and
// the caller has exactly one `tui.restore_all_exit(...)` -- so there is one
// place the terminal is put back and it cannot be missed half way.
def interactive() -> long {
    let act = 0;
    let alive = true;
    // A frame is drawn because something CHANGED -- a key, or the window -- and
    // never because a timer fired.  The first version called screen.render()
    // unconditionally at the top of the loop, so with nothing typed it repainted
    // every 6 ms forever: ~166 frames a second of pure waste, and a pty capture
    // of 618 KB instead of 3.  The pty test is what measured it.
    let dirty = true;
    let last_r = 0;
    let last_c = 0;
    while (alive) {
        if (dirty) {
            screen.winsize();
            last_r = screen.rows();
            last_c = screen.cols();
            screen.render(last_r, last_c);
            dirty = false
        };
        // read_key_timeout(0) is a real poll: VTIME=0 with VMIN=0 returns at
        // once.  Any non-zero ms would round UP to the next 100 ms because VTIME
        // counts deciseconds, so polling with read_key_timeout(16) would spend
        // 100 ms per frame and feel broken with nothing wrong anywhere.
        let k = tui.read_key_timeout(0);
        if (k != tui.KEY_NONE) {
            act = modes.feed(k);
            dirty = true;
            if (act != modes.ACT_CONTINUE) { alive = false }
        } else {
            // Nothing typed: ask the kernel whether the window moved, and yield.
            // Nothing tells the editor a SIGWINCH -- Y has no signal handlers --
            // so polling the window size is the only way to notice, and it costs
            // one ioctl into a module-level buffer.
            screen.winsize();
            if (screen.rows() != last_r || screen.cols() != last_c) { dirty = true };
            tui.nap_us(6000)
        }
    };
    if (act == modes.ACT_FAIL) { 1 } else { 0 }
};

// ===========================================================================
// the scripted run
// ===========================================================================

def run_scripted(rows: long, cols: long) -> long {
    buf.msg("--" + modes.mode_name(modes.mode()) + "--");
    // `more` has to be RE-EVALUATED each round, not just tested: with no
    // `break` in Y and no re-read of the condition, the first version ran until
    // the script ran out AND an action stopped the loop, which for a script with
    // no :q never happens -- it spun for ever.
    let act = 0;
    let more = true;
    // `applied` counts the keys THIS loop handed to the mode machine, rather
    // than re-reading the script's read index after the fact.  The two agree
    // when the script simply runs out and differ the moment a command ends the
    // run early -- a queued key that was never reached is not a key that was
    // applied -- so the number in the dump is an observation rather than a
    // restatement of "how long the script was".  check.y's group (g) drives
    // both shapes through the real binary and reads the count back.
    //
    // A key that is not a key at all is not counted: modes.feed ignores
    // KEY_NONE, so counting one would credit the loop with work it declined.
    let applied = 0;
    while (more) {
        let k = modes.script_take();
        if (k != tui.KEY_NONE) { applied = applied + 1 };
        act = modes.feed(k);
        if (act != modes.ACT_CONTINUE) {
            more = false
        } else {
            more = modes.script_more()
        }
    };
    dump_screen(rows, cols);
    // The buffer, one line per row, with its 1-based line number.  Byte-for-byte
    // what the editor holds, which is what a property check has to agree with.
    d_line("--- buffer  " + tostring(buf.nlines()) + " lines, " + tostring(buf.nbytes()) + " bytes ---");
    let i = 0;
    while (i < buf.nlines()) {
        d_line(f"{i + 1:4} |{buf.line_at(i)}");
        i = i + 1
    };
    d_line("--- messages ---");
    let log = buf.log();
    let j = 0;
    while (j < len(log)) {
        d_str(f"{j + 1:3} ");
        d_line(log[j]);
        j = j + 1
    };
    if (len(log) == 0) { d_line("  (none)") };
    d_line("--- state ---");
    d_line("mode      " + modes.mode_name(modes.mode()));
    d_line("cursor    line " + tostring(buf.cursor_line() + 1) + " col " + tostring(buf.cursor_col() + 1) + " byte " + tostring(cursor_byte()));
    d_line("viewport  rows " + tostring(buf.top() + 1) + ".." + tostring(buf.top() + buf.view_rows()) + "  cols " + tostring(buf.hcol() + 1) + ".." + tostring(buf.hcol() + buf.textw()));
    d_line("scroll    top " + tostring(buf.top()) + "  hcol " + tostring(buf.hcol()) + "  gutter " + tostring(buf.gutter()) + "  textw " + tostring(buf.textw()));
    d_line("undo      " + tostring(buf.undo_depth()) + " entries   redo " + tostring(buf.redo_depth()));
    d_line("register  " + tostring(len(buf.reg())) + " bytes " + (buf.reg_lw() ? "linewise" : "charwise"));
    d_line("modified  " + (buf.dirty() ? "yes" : "no"));
    d_line("text      fnv1a " + fnv(buf.text(), 0, 0));
    // The two halves are deliberately not the same number: `applied` is what ran,
    // `script_count()` is what the script held.  They are equal only when the
    // whole script ran, and printing them as equal when it did not is the
    // vacuous success this line used to be able to claim.
    d_line("--- keys " + tostring(applied) + " of " + tostring(modes.script_count()) + " ---");
    if (act == modes.ACT_FAIL) { 1 } else { 0 }
};

// The cursor's position as a byte offset from the start of the file -- the one
// number that does not care how the viewport is scrolled.
def cursor_byte() -> long {
    let n = 0;
    let i = 0;
    while (i < buf.cursor_line()) { n = n + len(buf.line_at(i)) + 1; i = i + 1 };
    n + buf.cursor_col()
};

// ===========================================================================
// --bench
// ===========================================================================

// Build N frames without writing one byte, and report the heap either side.  The
// delta is the claim the gate asks for; the time is here so the claim is
// about a real frame rather than a stripped-down one.
def run_bench(rows: long, cols: long, frames: long) -> long {
    screen.build_grid(rows, cols);
    screen.emit_ansi(rows, cols);
    let h0 = heap_used();
    let t0 = clock_us();
    let i = 0;
    let total = 0;
    while (i < frames) {
        total = total + screen.render_capture(rows, cols);
        i = i + 1
    };
    let t1 = clock_us();
    let h1 = heap_used();
    d_line("bench     rows " + tostring(rows) + " cols " + tostring(cols) + "  frames " + tostring(frames));
    let per = total;
    if (frames > 0) { per = total / frames };
    d_line("frame     " + tostring(per) + " bytes per redraw, " + tostring(total) + " in all");
    d_line("heap      " + tostring(h0) + " -> " + tostring(h1) + "   delta " + tostring(h1 - h0));
    let dt = t1 - t0;
    let fps = 0;
    if (dt > 0) { fps = frames * 1000000 / dt };
    d_line("time      " + tostring(dt / 1000) + " ms   " + tostring(fps) + " fps");
    let ok = 0 - 1;
    if (h1 == h0) { ok = 0 };
    d_line("verdict   " + (ok == 0 ? "zero allocation per redraw" : "ALLOCATES " + tostring(h1 - h0) + " bytes per " + tostring(frames) + " frames"));
    if (syscall(1, 1, &DBUF[0], DLEN) < 0) { return 1 };
    if (ok != 0) { return 1 };
    0
};

// ===========================================================================
// main
// ===========================================================================

def usage_exit() -> void { exit(2) };

def main() -> long {
    args.init("editor", "a Vi-style modal terminal editor, in Y", OPTS, "[file]");
    args.parse_or_exit(argv());
    if (args.has("version")) {
        puts(VERSION + "\n");
        return 0
    };
    if (args.has("check")) {
        // argv()[0] goes down because group (g) has to run THIS binary to see an
        // exit code and a stream separation; in process it could only see
        // buf.load's answer, which is not the claim being made.
        return check.run(args.get_long("seed", 1), argv()[0])
    };

    let no_tty = args.has("no-tty");
    let ops = args.positional();

    // --- argument validation, all of it before anything is touched --------
    let rows = 12;
    let cols = 44;
    if (args.has("rows")) { rows = args.get_long("rows", 12) };
    if (args.has("cols")) { cols = args.get_long("cols", 44) };
    if (rows < 4 || rows > screen.MAXR) {
        eputs("editor: --rows wants 4.." + tostring(screen.MAXR) + ", got " + tostring(rows) + "\n");
        return 2
    };
    if (cols < 12 || cols > screen.MAXC) {
        eputs("editor: --cols wants 12.." + tostring(screen.MAXC) + ", got " + tostring(cols) + "\n");
        return 2
    };
    let script_err = 0;
    if (args.has("keys")) {
        script_err = modes.script_decode(args.get_str("keys", ""))
    };
    if (script_err != 0) {
        eputs("editor: --keys: " + modes.SCRIPT_ERR + "\n");
        return 2
    };
    if (args.has("keys") && !no_tty) {
        eputs("editor: --keys needs --no-tty; there is no way to type a script into a real terminal\n");
        return 2
    };
    if (no_tty && !args.has("keys")) {
        // With no script there is nothing to drive the editor with.  Rather than
        // sit in a loop reading </dev/null forever, say so.
        eputs("editor: --no-tty needs --keys \"...\"\n");
        return 2
    };
    if (len(ops) > 1) {
        eputs("editor: one file at a time; got " + tostring(len(ops)) + "\n");
        return 2
    };
    // args's has() cannot tell "not given" from "given as false", so a BOOL
    // option cannot express "on unless you turn it off".  A STR option with an
    // explicit value can, which is why the gutter is spelled --numbers on|off.
    let nums = args.get_str("numbers", "on");
    if (nums == "off" || nums == "no" || nums == "0" || nums == "false") { buf.numbers_on(false) };

    // --- load -------------------------------------------------------------
    let path = "";
    if (len(ops) == 1) { path = ops[0] };
    if (len(path) > 0) {
        // A file that was NAMED and cannot be read is a FAILURE, not an empty
        // buffer.  The first version carried on: buf.load() had already put a
        // one-line blank buffer in place, an E484 went into the message log
        // where nothing could see it, and the whole key script then ran against
        // nothing --
        //
        //     $ ./editor --no-tty --keys '<96 keys>' --rows 10 --cols 44 \
        //           data/no-such-file.txt ; echo $?
        //     ... one empty line where the screen should be, and ...
        //     --- keys 96 of 96 ---
        //     0
        //
        // A success report for work that never touched a byte of text: 96 of 96
        // keys "applied" to a buffer that had none, and exit 0 to whoever ran
        // it.  buf.load's `false` is the verdict and it is honoured here.  The
        // message goes to STDERR -- never stdout, where an index trap prints
        // instead and corrupts a diff -- and nothing at all is dumped, so there
        // are no golden bytes to mistake for a result.  check.y's group (g)
        // runs this exact invocation and asserts all three of those.
        if (!buf.load(path)) {
            eputs("editor: cannot read " + path + "\n");
            return 1
        };
        buf.msg("\"" + path + "\" " + tostring(buf.nlines()) + "L, " + tostring(buf.nbytes()) + "B")
    } else {
        // No file named: a new buffer is a normal thing to want, and vi's
        // "[No Name]" is the honest label for it.
        buf.set_path("[No Name]");
        buf.msg("\"[No Name]\" new buffer")
    };

    // --- bench ------------------------------------------------------------
    if (args.has("bench")) {
        let frames = args.get_long("bench", 2000);
        if (frames < 1 || frames > 1000000) {
            eputs("editor: --bench wants 1..1000000, got " + tostring(frames) + "\n");
            return 2
        };
        DLEN = 0;
        let code = run_bench(rows, cols, frames);
        return code
    };

    // --- scripted ---------------------------------------------------------
    if (no_tty) {
        DLEN = 0;
        screen.build_grid(rows, cols);
        let code = run_scripted(rows, cols);
        if (syscall(1, 1, &DBUF[0], DLEN) < 0) { return 1 };
        return code
    };

    // --- interactive: tui's pattern, verbatim -------------------------
    if (!tui.raw_mode()) {
        eputs("editor: standard input is not a terminal; try --no-tty --keys \"...\"\n");
        return 1
    };
    tui.enter_screen();
    tui.arm_watchdog();
    let code = interactive();
    tui.restore_all_exit(code);
    code
};

let CODE = main();
exit(CODE);