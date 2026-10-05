// args -- command-line flag parsing.
//
// WHY THIS IS A std MODULE.  Twenty-five of the thirty-nine examples in
// examples/ vendored a copy of this file, 19 KB each, and each one wrote the
// same table.  SUGGESTIONS.md #23 ("`--help` should be reserved the way `y_`
// is, so a declared `help` cannot silently disable usage") is only a bug
// because there was no single implementation to fix once: with the table
// declared up front, `--help` is generated from the same data the parser
// reads, so the two cannot disagree.
//
// The public surface is ten functions and one type:
//
//   init / parse / parse_or_exit / has / get_str / get_long /
//   positional / nopts / usage / print_usage / errmsg
//   type Opt = { long: str, short: str, kind: long, help: str }
//
// The `ar_*` functions are internal to the parser and are not part of the
// module's surface.
//
// Vendored into an example folder beside the program that uses it (see
// ORCHESTRATOR.md, "The folder contract"); `import args;` and call through
// the namespace.  A module imported by name keeps its own scope (rename.y),
// so these names never meet the program's own -- the only collision to
// watch for is a local called `args`.
//
//   import args;
//
//   const OPTS: [args.Opt] = [
//       { long: "fps",   short: "f", kind: args.NUM,  help: "frames per second (default 30)" },
//       { long: "seed",  short: "",   kind: args.NUM,  help: "random seed (default 1)" },
//       { long: "color", short: "c", kind: args.STR,  help: "mono | gray | green" },
//       { long: "stats", short: "s", kind: args.BOOL, help: "print timings at the end" }
//   ];
//
//   args.init("donut", "spinning ASCII torus", OPTS, "[file...]");
//   args.parse_or_exit(argv());
//   let fps = args.get_long("fps", 30);
//   let seed = args.get_long("seed", 1);
//   let mode = args.get_str("color", "mono");
//   let stats = args.has("stats");
//   let files = args.positional();
//
// ── what it parses ───────────────────────────────────────────────────────
//
//   --name=value      one token; the value is everything after the first
//                     `=`, so it may contain more `=` ("--expr=a=b").
//   --name value      one token, then the next argv entry, when the option
//                     declares a kind other than BOOL.  The next entry is
//                     only taken when it does not look like a flag, so
//                     `--seed --color=x` reports the missing value instead
//                     of swallowing `--color=x`.
//   --name            a BOOL option; "--no-name" sets it false, and
//                     "--name=false" / "=0" / "=no" / "=off" do the same.
//   -x  -abc          short flags, and clusters of them: "-vsc".  A cluster
//                     that reaches a value-taking option takes the rest of
//                     the token as that value ("-scred"), with a leading
//                     `=` allowed ("-c=red"), or the next argv entry when
//                     nothing is left.
//   --                everything after it is an operand, flags included.
//   -                 an operand, not a flag (the usual "read stdin" form).
//                     So are "" and anything that does not begin with `-`.
//   -5, -3.5         operands would need `--` in front (or `--seed=-5`).
//
// The first entry of the array handed to parse() is argv[0] and is skipped,
// exactly as the shell means it: pass argv() itself, not argv()[1:].
//
// `--help` is always accepted and always the first line of the generated
// usage.  `-h` means --help too, unless the spec declares its own short
// "h" (so a `--height` example can keep the letter and get --help anyway).
// A repeated option keeps the last value.
//
// A DECLARED `help` TAKES `--help` OVER, AND NOTHING WARNS YOU.  If the spec
// lists a long option named "help", then `--help` is *that option*, not a
// HELP request: parse() returns OK having printed no usage, and has("help")
// is true.  So a program that declares `help` and then calls
// parse_or_exit() silently loses its usage text -- `--help` prints whatever
// the program decides to print, which may well be nothing.  There is no
// warning at the declaration and none at parse time, and the symptom is a
// program that appears to have no help.
//
//   // `help` here makes every --help below an ordinary flag:
//   { long: "help", short: "h", kind: args.BOOL, help: "show usage" }
//   args.init("prog", "what it does", OPTS, "");
//   args.parse_or_exit(argv());
//   if (args.has("help")) { print(args.usage()); return 0 };   // your job
//
// The distinguishing test is `has("help")`: false when --help was a HELP
// request, true when the spec declared it.  args_test.y checks 6e-6h pin
// all four of those statements in BOTH directions, so this behaviour cannot
// change without the suite failing.
//
// Filed as SUGGESTIONS.md #23: `--help` ought to be reserved the way the
// `y_` prefix is, or a spec that declares it ought to warn.  Until then this
// paragraph is the only place the behaviour is written down, which is why it
// is here rather than only in the test.
//
// ── exit codes ───────────────────────────────────────────────────────────
//
// parse() returns one of three constants and never exits:
//
//   OK      (0)  the command line parsed
//   HELP    (1)  --help was given; the caller prints usage()
//   USAGE   (2)  a usage error; the message is already on stderr
//
// parse_or_exit() applies the convention a program wants:
//
//   0   ran fine, or --help and the usage text, on stdout
//   2   a usage error, message on stderr: an unknown option, a value-taking
//       option with no value, or a NUM option given a non-number
//
// 1 is left to the program, so it can report a runtime failure.  Diagnostics
// go to stderr and the generated usage to stdout, so `prog --help | less`
// works and `prog --bogus 2>err` keeps stdout clean.
//
// ── the lookups ──────────────────────────────────────────────────────────
//
// get_str / get_long / has / positional are a linear scan over the spec,
// with no allocation and no map, so they are safe to call from anywhere --
// but read a flag once, before the render loop, and keep the value in a
// local.  A name that is not in the spec returns the default / false
// rather than trapping, because that is a bug in the caller, not in the
// command line.  A NUM option's value is checked during parse(), so
// get_long never hands back a silently-zero 0: a non-number was already
// reported and made the program exit 2.

type Opt = { long: str, short: str, kind: long, help: str };

// An Opt.kind: no value, a value of any shape, a value that must parse as a
// whole number.  The kind also picks the usage placeholder (nothing, VALUE,
// N) and the default help text.
const BOOL = 0;
const STR = 1;
const NUM = 2;

// What parse() returns; see "exit codes" above.
const OK = 0;
const HELP = 1;
const USAGE = 2;

// ── state ────────────────────────────────────────────────────────────────
//
// Module level, so a module's own: init() fills the spec into flat arrays
// and parse() fills one entry per option given.  The values live beside the
// names instead of in a map because a map lookup is a linear scan of its
// own and these are read once at start-up.
let ar_prog = "prog";
let ar_desc = "";
let ar_tail = "";
let ar_ln: [str] = [];        // the long names, as declared
let ar_sn: [str] = [];        // the short names, "" where there is none
let ar_kd: [long] = [];       // the kinds
let ar_hp: [str] = [];       // the help text
let ar_given: [long] = [];    // 1 once the option has been given
let ar_val: [str] = [];       // its value; "" until it is given
let ar_pos: [str] = [];       // the operands, in order
let ar_toks: [str] = [];     // what parse() was handed
let ar_i = 0;                // parse's cursor; the two helpers advance it
let ar_ntoks = 0;
let ar_st = OK;              // the status the helpers set
let ar_errmsg = "";

// ── the spec ─────────────────────────────────────────────────────────────

// init(prog, desc, spec, tail = "") -- declare the program's options.
//   prog   the name used in diagnostics and in the usage line
//   desc   one line of prose, printed under the usage line
//   spec   the options, in the order --help lists them
//   tail   the operand part of the usage line, e.g. "[file...]" (optional)
// Clears anything a previous parse() left behind.
def init(prog: str, desc: str, spec: [Opt], tail: str = "") {
    ar_prog = prog;
    ar_desc = desc;
    ar_tail = tail;
    ar_ln = [];
    ar_sn = [];
    ar_kd = [];
    ar_hp = [];
    ar_given = [];
    ar_val = [];
    ar_pos = [];
    ar_toks = [];
    ar_i = 0;
    ar_ntoks = 0;
    ar_st = OK;
    ar_errmsg = "";
    foreach (o in spec) {
        ar_ln += o.long;
        ar_sn += o.short;
        ar_kd += o.kind;
        ar_hp += o.help;
        ar_given += 0;
        ar_val += "";
    }
};

// nopts() -- how many options the spec declared.
def nopts() -> long { len(ar_ln) };

// The spec's index for a long name, -1 when it declares no such option.
def ar_find_long(name: str) -> long {
    let hit = 0 - 1;
    let i = 0;
    while (i < len(ar_ln)) {
        if (hit < 0 && ar_ln[i] == name) { hit = i; };
        i = i + 1;
    };
    hit
};

// The spec's index for a short name, -1 when it declares no such option.
def ar_find_short(c: str) -> long {
    let hit = 0 - 1;
    let i = 0;
    while (i < len(ar_sn)) {
        if (hit < 0 && len(ar_sn[i]) > 0 && ar_sn[i] == c) { hit = i; };
        i = i + 1;
    };
    hit
};

// ── parsing ──────────────────────────────────────────────────────────────

// ar_flagish(t): an entry that must not be eaten as an option's value.  A
// lone "-" is an operand, so it can be.
def ar_flagish(t: str) -> bool {
    len(t) > 1 && byte_at(t, 0) == 45
};

// The message, on stderr, and USAGE as the status.  errmsg() returns the
// message without the program's name, so a caller can reformat it.
def ar_fail(msg: str) {
    ar_errmsg = msg;
    ar_st = USAGE;
    eputs(ar_prog + ": " + msg + "\n")
};

// The value of a BOOL given as `--flag=v`: empty, "true", "yes" and "on"
// and "1" mean true, anything else false.
def ar_bool_val(v: str) -> bool {
    v == "" || v == "true" || v == "1" || v == "yes" || v == "on"
};

// Whole decimal numbers only, at most 18 digits so the value cannot
// overflow into a wrong long (tonum("999999999999999999999") wraps).
def ar_num_ok(s: str) -> bool {
    let n = len(s);
    let i = 0;
    if (n > 0 && byte_at(s, 0) == 45) { i = 1; };
    let ok = n - i >= 1 && n - i <= 18;
    let j = i;
    while (j < n && ok) {
        let c = byte_at(s, j);
        if (c < 48 || c > 57) { ok = false; };
        j = j + 1;
    };
    ok
};

def ar_store(k: long, v: str) {
    ar_given[k] = 1;
    ar_val[k] = v
};

// Give option `k` the value `v`, named `as` in any diagnostic.  A NUM
// option's value is checked here, once, at parse time.
def ar_take(k: long, as: str, v: str) {
    if (ar_kd[k] == NUM && !ar_num_ok(v)) {
        ar_fail("option '" + as + "' wants a number, got '" + v + "'");
    } else {
        ar_store(k, v)
    }
};

// One `--name`, `--name=value` or `--no-name` token.
def ar_long(t: str) {
    let body = t[2:];
    let eq = body.index_of("=");
    let name = body;
    let val = "";
    let attached = false;
    if (eq >= 0) {
        name = body[0:eq];
        val = body[eq + 1:];
        attached = true;
    };
    let k = ar_find_long(name);
    // --no-x only ever clears a declared BOOL; anything else is unknown.
    let off = false;
    if (k < 0 && name.starts_with("no-")) {
        let b = ar_find_long(name[3:]);
        if (b >= 0 && ar_kd[b] == BOOL) { k = b; off = true; };
    };
    ar_i = ar_i + 1;
    if (k < 0) {
        if (name == "help") {
            ar_st = HELP;
        } else {
            ar_fail("unknown option '--" + name + "'");
        };
    } else if (ar_kd[k] == BOOL) {
        let on = true;
        if (off) { on = false; };
        if (attached) { on = ar_bool_val(val); };
        ar_store(k, on ? "true" : "false");
    } else if (attached) {
        ar_take(k, "--" + name, val);
    } else if (ar_i < ar_ntoks && !ar_flagish(ar_toks[ar_i])) {
        ar_take(k, "--" + name, ar_toks[ar_i]);
        ar_i = ar_i + 1;
    } else {
        ar_fail("option '--" + name + "' needs a value");
    }
};

// One `-x` / `-abc` token.
def ar_short(t: str) {
    let n = len(t);
    let k = 1;
    let last = false;
    while (k < n && !last && ar_st == OK) {
        let c = chr(byte_at(t, k));
        let j = ar_find_short(c);
        if (j < 0 && c == "h") {
            ar_st = HELP;
            last = true;
        } else if (j < 0) {
            ar_fail("unknown option '-" + c + "'");
            last = true;
        } else if (ar_kd[j] == BOOL) {
            ar_store(j, "true");
            k = k + 1;
        } else {
            // The rest of the token is this option's value, if there is
            // any; a leading `=` is dropped so `-c=red` reads like
            // `--color=red`.
            let rest = t[k + 1:];
            if (len(rest) > 0 && byte_at(rest, 0) == 61) { rest = rest[1:]; };
            if (len(rest) > 0) {
                ar_take(j, "-" + c, rest);
                last = true;
            } else if (ar_i + 1 < ar_ntoks && !ar_flagish(ar_toks[ar_i + 1])) {
                ar_take(j, "-" + c, ar_toks[ar_i + 1]);
                ar_i = ar_i + 1;
                last = true;
            } else {
                ar_fail("option '-" + c + "' needs a value");
                last = true;
            }
        }
    };
    ar_i = ar_i + 1
};

// parse(toks) -> long -- parse a command line and return OK, HELP or
// USAGE.  `toks` is argv() itself: entry 0 is the program and is skipped.
// On USAGE the message is already on stderr; nothing here exits.
def parse(toks: [str]) -> long {
    ar_toks = toks;
    ar_ntoks = len(toks);
    ar_pos = [];
    ar_errmsg = "";
    ar_st = OK;
    ar_i = 1;
    // The store is cleared HERE, not in init(), so a second parse of a second
    // command line starts from the defaults. Without this, `has("fps")` stayed
    // true and `get_long("fps", 30)` kept the value from the PREVIOUS parse --
    // which matters to a caller that parses twice (a server reading one request
    // at a time is the obvious case) and is exactly what this unit's own test
    // found. init() still builds the table; it no longer doubles as a reset.
    let gi = 0;
    while (gi < len(ar_given)) {
        ar_given[gi] = 0;
        ar_val[gi] = "";
        gi = gi + 1
    };
    let only_pos = false;
    let go = ar_i < ar_ntoks;
    while (go && ar_st == OK) {
        let t: str = toks[ar_i];
        let n = len(t);
        if (only_pos || n == 0 || (n > 1 && byte_at(t, 0) != 45)) {
            // An operand: past a `--`, or an empty entry, or anything that
            // does not start with a dash.
            ar_pos += t;
            ar_i = ar_i + 1;
        } else if (n == 1) {
            // A lone "-" is the stdin convention, not a flag.
            ar_pos += t;
            ar_i = ar_i + 1;
        } else if (t[0:2] == "--") {
            if (t == "--") {
                only_pos = true;
                ar_i = ar_i + 1;
            } else {
                ar_long(t)
            }
        } else {
            ar_short(t)
        };
        go = ar_i < ar_ntoks;
    };
    ar_st
};

// parse_or_exit(toks) -- parse() and then act on its status: --help prints
// the usage on stdout and exits 0, a usage error exits 2 (its message is
// already on stderr), and a clean parse returns for the program to carry on.
def parse_or_exit(toks: [str]) {
    let st = parse(toks);
    if (st == HELP) {
        puts(usage());
        exit(0);
    };
    if (st == USAGE) {
        exit(2)
    }
};

// ── the lookups ──────────────────────────────────────────────────────────

// get_str(name, dflt) -- the option's value, or `dflt` when it was not
// given.  An option given as `--name=` gives "".
def get_str(name: str, dflt: str) -> str {
    let k = ar_find_long(name);
    let r = dflt;
    if (k >= 0 && ar_given[k] == 1) { r = ar_val[k]; };
    r
};

// get_long(name, dflt) -- the option's value as a number, or `dflt`.  The
// value was checked while parsing, so this cannot come back as a silent 0.
def get_long(name: str, dflt: long) -> long {
    let k = ar_find_long(name);
    let r = dflt;
    if (k >= 0 && ar_given[k] == 1) { r = tonum(ar_val[k]); };
    r
};

// has(name) -> bool -- is the option in effect?  A value option is in
// effect once given (an option given as `--name=` counts, and get_str then
// gives "").  A BOOL option is in effect unless it was turned off with
// `--no-name` or `--name=false`, so `has` never disagrees with what the
// option says about itself.
def has(name: str) -> bool {
    let k = ar_find_long(name);
    let r = false;
    if (k >= 0 && ar_given[k] == 1 && !(ar_kd[k] == BOOL && ar_val[k] == "false")) {
        r = true
    };
    r
};

// positional() -> [str] -- the operands, in the order they were given.  It
// is the live array, not a copy: read it, do not write to it.
def positional() -> [str] { ar_pos };

// errmsg() -> str -- the last usage error, without the program's name, or
// "" when the command line parsed.
def errmsg() -> str { ar_errmsg };

// num_ok(s) -> bool -- would get_long() accept this string as a value?  For
// a program that reads its operands itself.
def num_ok(s: str) -> bool { ar_num_ok(s) };

// ── the usage text ───────────────────────────────────────────────────────

// The option column: "  -f, --fps N", or "      --fps N" with no short.
def ar_left(k: long) -> str {
    let s = "  ";
    if (len(ar_sn[k]) > 0) { s += "-" + ar_sn[k] + ", "; };
    s += "--" + ar_ln[k];
    if (ar_kd[k] == NUM) {
        s += " N";
    } else if (ar_kd[k] != BOOL) {
        s += " VALUE"
    };
    s
};

// The help column: what the spec declared, or the kind's own words.
def ar_help(k: long) -> str {
    if (len(ar_hp[k]) > 0) {
        ar_hp[k]
    } else if (ar_kd[k] == BOOL) {
        "flag"
    } else if (ar_kd[k] == NUM) {
        "a number"
    } else {
        "a string"
    }
};

// usage() -> str -- the whole --help text, generated from the spec: the
// usage line, the description, and one line per option with the columns
// aligned.  The default of an option is whatever its help text says, so
// write it there ("frames per second (default 30)").
def usage() -> str {
    let out = "usage: " + ar_prog + " [options]";
    if (len(ar_tail) > 0) { out += " " + ar_tail; };
    out += "\n";
    if (len(ar_desc) > 0) { out += "\n  " + ar_desc + "\n"; };
    out += "\noptions:\n";
    let w = 0;
    let help_line = "  -h, --help";
    if (len(help_line) > w) { w = len(help_line); };
    for k in 0..len(ar_ln) {
        let l = ar_left(k);
        if (len(l) > w) { w = len(l); };
    };
    for k in 0..len(ar_ln) {
        let l = ar_left(k);
        out += l.pad_right(w + 2, " ") + ar_help(k) + "\n";
    };
    out += help_line.pad_right(w + 2, " ") + "print this message and exit\n";
    out
};

// print_usage() -- usage() on stdout, for a program that wants it at some
// other moment than --help.
def print_usage() {
    puts(usage())
};

export { Opt, BOOL, STR, NUM, OK, HELP, USAGE, init, parse, parse_or_exit, nopts, get_str, get_long, has, positional, errmsg, num_ok, usage, print_usage };
