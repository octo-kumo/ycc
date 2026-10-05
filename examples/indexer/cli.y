// cli.y -- argument parsing and the program's own diagnostics.
//
// Split out of indexer.y for one reason: selftest.y has to be able to
// assert that a bad flag produces a MESSAGE and a non-zero code, and a
// `def` cannot be reached from a module that indexer.y imports.  The parser
// RETURNS the message rather than printing it, so the check can read it
// without the usage text landing in the middle of its own output.
//
// Nothing here traps.  Every failure is a returned code plus a non-empty
// message, and the check asserts both -- including that the message is not
// empty, which is the vacuous-pass shape this campaign keeps hitting: a
// check that compares two messages which are both "" proves nothing.

import ix;

let BENCH: long = 0;
let NROOT: long = 0;
let ROOTSET: bool = false;

// The last diagnostic parse() produced.  "" means "no complaint".
let ERR: str = "";
let WANT_CHECK: bool = false;
let SAW_VERSION: bool = false;
// --check runs this, so parse() is called dozens of times in one process and
// inject.py hands it dozens of argument lists.  Leaving the options alone
// between calls makes the result of a call depend on the PREVIOUS one --
// and that is not hypothetical: inject.py's `tworootsok` defect was masked
// for exactly this reason, because a leftover `--largest 0` from an earlier
// case supplied the non-zero error code the check was looking for.  Every
// call now starts from the documented defaults.
let ONLY: long = 0;

def set_err(m: str) -> long { ERR = m; 1 };

const USAGE =
    "indexer -- index a directory tree and query it\n"
    + "\n"
    + "usage: indexer [options] [ROOT]\n"
    + "\n"
    + "  ROOT                 directory to index (default \".\")\n"
    + "  --root DIR           the same, as a flag\n"
    + "  --ext EXT            list only this extension\n"
    + "  --find SUBSTR        list only paths containing SUBSTR\n"
    + "  --largest N          list the N largest files, biggest first\n"
    + "  --head N             show N columns of each file's first line\n"
    + "  --depth N            directory depth cap (default 64)\n"
    + "  --no-hash            skip content hashing (paths and sizes only)\n"
    + "  --follow-symlinks    descend through symlinked directories\n"
    + "  --strict             exit 3 if anything was unreadable or capped\n"
    + "  --bench N            time N indexes: throughput and heap use\n"
    + "  --color, --no-color  force colour on or off\n"
    + "  --no-tty             plain output: no colour, no terminal lookups\n"
    + "  --check              run the property check (selftest.y)\n"
    + "  --help, --version\n"
    + "\n"
    + "exit: 0 indexed, 1 usage, 2 bad root, 3 --strict found something\n";

def usage_here() -> str { USAGE };

// A decimal number, or -1.  Rejects "12x", "", "-3", "+3" and " 7": tonum on
// junk is a silent 0, and a silent 0 here is `--head 0` on nonsense, which
// reads downstream as "the indexer found no first lines".
def num_arg(s: str) -> long {
    let ok = s.length > 0;
    let i = 0;
    while (i < s.length && ok) {
        let c = byte_at(s, i);
        if (c < 48 || c > 57) { ok = false } else { i = i + 1 };
    };
    if (ok) { tonum(s) } else { -1 }
};

// -1 = --help/--version was printed, 7 = --check, 0 = carry on, 1 = usage error.
def parse(argv: [str]) -> long {
    // Reset the parser's OWN state, not just ERR: selftest.y calls parse()
    // dozens of times in one process, and ROOTSET surviving the first call
    // would make every later command line "two roots given".
    ERR = "";
    WANT_CHECK = false;
    SAW_VERSION = false;
    ROOTSET = false;
    BENCH = 0;
    ONLY = 0;
    ix.OPT_LARGEST = -1;
    ix.OPT_EXT = "";
    ix.OPT_FIND = "";
    ix.HEAD_COLS = 0;
    ix.DEPTH_CAP = 64;
    ix.WANT_HASH = true;
    ix.FOLLOW = false;
    ix.STRICT = false;
    ix.ROOT = ".";
    let i = 0;
    let rc = 0;
    let go = true;
    while (go && i < len(argv)) {
        let a = argv[i];
        if (a == "--help" || a == "-h") { ix.COLOR = 0; ix.COLOR_AUTO = false; return -1 };
        if (a == "--version") { SAW_VERSION = true; return -1 };
        if (a == "--check") { WANT_CHECK = true }
        else if (a == "--only") {
            if (i + 1 >= len(argv)) {
                rc = set_err("`--only` needs a section number");
                go = false;
            } else {
                ONLY = num_arg(argv[i + 1]);
                if (ONLY < 1 || ONLY > 9) {
                    rc = set_err("`--only` takes 1..9, got `" + argv[i + 1] + "`");
                    go = false;
                };
                i = i + 1;
            };
        }
        else if (a == "--no-tty") { ix.COLOR = 0; ix.COLOR_AUTO = false }
        else if (a == "--color" || a == "--colour") { ix.COLOR = 1; ix.COLOR_AUTO = false }
        else if (a == "--no-color" || a == "--no-colour") { ix.COLOR = 0; ix.COLOR_AUTO = false }
        else if (a == "--no-hash") { ix.WANT_HASH = false }
        else if (a == "--follow-symlinks") { ix.FOLLOW = true }
        else if (a == "--strict") { ix.STRICT = true }
        else if (a == "--root" || a == "--ext" || a == "--find" || a == "--largest"
                 || a == "--head" || a == "--depth" || a == "--bench") {
            if (i + 1 >= len(argv)) {
                rc = set_err("`" + a + "` needs a value");
                go = false;
            } else {
                let v = argv[i + 1];
                let n = num_arg(v);
                if (a == "--root") { ix.ROOT = v; ROOTSET = true }
                else if (a == "--ext") { ix.OPT_EXT = v.lower() }
                else if (a == "--find") { ix.OPT_FIND = v }
                else if (a == "--bench") {
                    // --bench takes a NUMBER, like every other value-taking
                    // flag.  It used to accept anything and fall back to one
                    // round, so `--bench abc` ran in silence.  S7's case list
                    // caught that only once parse() stopped carrying option
                    // state between calls -- see the note on ROOTSET above.
                    if (n < 0) {
                        rc = set_err("`" + a + "` needs a number, got `" + v + "`");
                        go = false;
                    } else if (n < 1) {
                        rc = set_err("`--bench` needs at least 1 round");
                        go = false;
                    } else {
                        BENCH = n;
                    };
                } else if (n < 0) {
                    rc = set_err("`" + a + "` needs a number, got `" + v + "`");
                    go = false;
                } else if (a == "--largest") {
                    ix.OPT_LARGEST = n;
                } else if (a == "--head") {
                    ix.HEAD_COLS = n;
                } else {
                    ix.DEPTH_CAP = n;
                };
                i = i + 1;
            };
        } else if (a.starts_with("-") && a.length > 1) {
            rc = set_err("unknown flag `" + a + "`");
            go = false;
        } else {
            if (ROOTSET) {
                rc = set_err("two roots given (`" + ix.ROOT + "` and `" + a + "`); one only");
                go = false;
            } else {
                ix.ROOT = a;
                ROOTSET = true;
            };
        };
        i = i + 1;
    };
    if (rc == 0 && ix.OPT_LARGEST == 0) { rc = set_err("`--largest 0` would list nothing") };
    if (rc == 0 && ix.DEPTH_CAP < 1) {
        rc = set_err("`--depth 0` would not visit even the root directory");
    };
    rc
};

// The message the CLI prints for a walk() return code.  2 and 3 are the two
// ways a root can be wrong; 0 is not an error.  A code outside this list is
// reported as itself rather than ignored, so a new walk() return cannot be
// swallowed by a stale `else`.
def root_message(code: long) -> str {
    let m = "";
    if (code == 2) { m = ix.ROOT + ": no such path" }
    else if (code == 3) { m = ix.ROOT + ": not a directory" }
    else if (code != 0) { m = ix.ROOT + ": cannot be indexed (code " + tostring(code) + ")" };
    m
};

def strict_message() -> str {
    "strict: " + tostring(ix.N_UNREAD) + " unreadable, " + tostring(ix.N_CAP) + " capped"
};

// C's isatty(2), as ioctl(TCGETS) on fd 1.  There is no isatty() in the std
// library, and term.size() would allocate a record per call for something
// that answers a boolean.
//
// The REQUEST and the buffer are both load-bearing.  This read
// `syscall(16, 1)` -- no request, no termios buffer -- which returns -ENOTTY
// on a pipe AND on a real terminal, so automatic colour detection was dead:
// the coloured path only ever ran under an explicit --color, and nothing in
// the check suite noticed because --no-tty is the golden.  pty_check.py found
// it, by stripping the SGR sequences off a pty capture and finding none.
// With the request and the buffer it answers 0 on a terminal and -ENOTTY on a
// pipe, which is what isatty(2) says.
let TTYBUF: [byte; 64] = [0; 64];

def is_tty() -> bool { syscall(16, 1, 21505, &TTYBUF[0]) == 0 };

export { USAGE, ERR, BENCH, NROOT, ROOTSET, WANT_CHECK, SAW_VERSION, ONLY, num_arg, parse,
         root_message, strict_message, usage_here, is_tty };