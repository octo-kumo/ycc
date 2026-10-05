// std/args: the flag table, the accepted spellings, the usage text and the
// three outcomes of parse().
//
// The three outcomes are the contract: OK, HELP and USAGE, with the exit code
// each implies. parse_or_exit() turns USAGE into exit 2, so this file exercises
// parse() directly and decides its own exits -- which is what lets one program
// test all three without the test runner seeing a failure.
import args;
import test;

// the table several groups share
const T_OPTS: [args.Opt] = [
    { long: "fps", short: "f", kind: args.NUM, help: "frames per second (default 30)" },
    { long: "seed", short: "", kind: args.NUM, help: "random seed (default 1)" },
    { long: "color", short: "c", kind: args.STR, help: "color mode (default mono)" },
    { long: "stats", short: "s", kind: args.BOOL, help: "print stats at the end" }
];

// a table where one flag carries a help string and so makes --help ordinary
const T_HELP: [args.Opt] = [
    { long: "count", short: "n", kind: args.NUM, help: "how many lines to read" },
    { long: "quiet", short: "q", kind: args.BOOL, help: "say nothing on success" }
];

// a table whose only entry takes no value, so --option is a flag and
// --option=x is a usage error rather than a silently-ignored value
const T_FLAGONLY: [args.Opt] = [
    { long: "verbose", short: "v", kind: args.BOOL, help: "explain what is happening" }
];

def main() -> long {
    // ─────────────────────────────────────────── the table itself
    test.group("the option table");
    args.init("demo", "a table for the flag tests", T_OPTS, "[file...]");
    test.ck_eq("nopts counts the entries", args.nopts(), 4);
    test.ck_eq("a NUM flag is args.NUM", T_OPTS[0].kind, args.NUM);
    test.ck_eq("a STR flag is args.STR", T_OPTS[2].kind, args.STR);
    test.ck_eq("a BOOL flag is args.BOOL", T_OPTS[3].kind, args.BOOL);
    test.ck("the kinds are distinct",
        args.BOOL != args.STR && args.STR != args.NUM && args.BOOL != args.NUM,
        "so a table cannot confuse them");
    test.ck_str("the long name is the flag's name", T_OPTS[0].long, "fps");
    test.ck_str("and the short one is a str, possibly empty", T_OPTS[1].short, "");

    // ─────────────────────────────────────────── the outcome constants
    test.group("the three outcomes are distinct");
    test.ck("OK, HELP and USAGE are three different values",
        args.OK != args.HELP && args.HELP != args.USAGE && args.OK != args.USAGE,
        "so parse() cannot be read two ways");

    // ─────────────────────────────────────────── has / get_str / get_long
    test.group("reading a parsed flag");
    // The command line here is whatever the runner passed, which is not what
    // these checks need, so they are made against the module's OWN readers with
    // argv replaced. That is not possible either -- argv() is the process's --
    // so what is checked here is the defaulting behaviour, which does not need
    // a flag to have been seen.
    test.ck("an unseen flag is absent", !args.has("fps"), "nothing was passed");
    test.ck("and an absent one answers the default",
        args.get_str("color", "mono") == "mono", "the documented default");
    test.ck_eq("get_long answers its default too", args.get_long("seed", 7), 7);
    test.ck("so a default of 0 is distinguishable from a real 0 by asking",
        args.get_long("seed", 99) == 99, "the default is returned, not the field");

    // ─────────────────────────────────────────── num_ok
    test.group("num_ok: what counts as a whole number");
    test.ck("a plain integer is one", args.num_ok("42"), "42");
    test.ck("a negative integer is one", args.num_ok("-42"), "-42");
    test.ck("zero is one", args.num_ok("0"), "0");
    test.ck("a leading - is a sign, already counted above", args.num_ok("-7"), "-7");
    test.ck("a leading + is NOT accepted", !args.num_ok("+7"),
        "the only sign num_ok knows is -, which is what a flag value can carry");
    test.ck("an empty string is not", !args.num_ok(""), "nothing at all");
    test.ck("a float is not", !args.num_ok("1.5"), "num_ok is whole numbers only");
    test.ck("a float written with a dot and zeros is not either",
        !args.num_ok("1.0"), "still not a whole number as written");
    test.ck("trailing junk is not", !args.num_ok("42x"), "42x");
    test.ck("leading whitespace is not", !args.num_ok(" 42"), "no trimming");
    test.ck("a hex literal is not", !args.num_ok("0x2a"), "num_ok is decimal");
    test.ck("the empty default of a flag is not a number", !args.num_ok(""), "so --seed= is an error");

    // ─────────────────────────────────────────── the usage text
    test.group("the usage text");
    let u = args.usage();
    test.ck("usage names the program", u.index_of("demo") >= 0, "the name init was given");
    test.ck("and carries the blurb", u.index_of("a table for the flag tests") >= 0,
        "the line under the name");
    test.ck("and every long flag", u.index_of("--fps") >= 0, "--fps");
    test.ck("and the short one that exists", u.index_of("-s") >= 0, "-s");
    test.ck("and the positional summary", u.index_of("[file...]") >= 0, "the tail");
    test.ck("and each flag's help text", u.index_of("frames per second") >= 0,
        "the help string is what the table was given");
    test.ck("a flag with no short spelling has no bare -",
        u.index_of("--seed") >= 0, "and it is still listed");

    // ─────────────────────────────────────────── a table where --help is ordinary
    test.group("--help is an ordinary flag when the table declares one");
    args.init("counting", "reads lines", T_HELP, "");
    let u2 = args.usage();
    test.ck("usage names this program too", u2.index_of("counting") >= 0, "re-init replaced it");
    test.ck("and no longer the old one", u2.index_of("[file...]") < 0,
        "so init is not additive");

    // ─────────────────────────────────────────── the accepted spellings
    // parse() takes argv() ITSELF -- entry 0 is the program and is skipped --
    // which is what lets a fixture pass a synthetic command line and check all
    // three outcomes in one process.
    test.group("the accepted spellings");
    args.init("demo", "a table for the flag tests", T_OPTS, "[file...]");

    test.ck_eq("no flags at all is OK",
        args.parse(["demo"]), args.OK);
    test.ck("and every flag is absent",
        !args.has("fps") && !args.has("seed") && !args.has("color") && !args.has("stats"),
        "nothing was passed and nothing is claimed");

    test.ck_eq("--long value", args.parse(["demo", "--fps", "60"]), args.OK);
    test.ck_eq("  and get_long reads it", args.get_long("fps", 30), 60);

    test.ck_eq("--long=value", args.parse(["demo", "--fps=60"]), args.OK);
    test.ck_eq("  and reads the same", args.get_long("fps", 30), 60);

    test.ck_eq("-s value", args.parse(["demo", "-f", "25"]), args.OK);
    test.ck_eq("  short form reads it", args.get_long("fps", 30), 25);

    test.ck_eq("-sVALUE, glued", args.parse(["demo", "-f25"]), args.OK);
    test.ck_eq("  and still reads it", args.get_long("fps", 30), 25);

    test.ck_eq("-s=VALUE", args.parse(["demo", "-f=25"]), args.OK);
    test.ck_eq("  and that too", args.get_long("fps", 30), 25);

    test.ck_eq("a BOOL flag takes no value", args.parse(["demo", "--stats"]), args.OK);
    test.ck("  and is present", args.has("stats"), "--stats");
    test.ck_eq("its short form too", args.parse(["demo", "-s"]), args.OK);
    test.ck("  and present", args.has("stats"), "-s");

    test.ck_eq("a value that contains = is kept whole",
        args.parse(["demo", "--color=a=b"]), args.OK);
    test.ck_str("  including the second =", args.get_str("color", ""), "a=b");

    test.ck_eq("-- ends the flags", args.parse(["demo", "--", "--fps", "x"]), args.OK);
    test.ck_eq("  so the operands are the rest", args.positional().length, 2);
    test.ck_str("  and the first is the literal", args.positional()[0], "--fps");
    test.ck_str("  not a flag", args.positional()[1], "x");
    test.ck("  and no flag was set by them", !args.has("fps"), "-- ends parsing");

    test.ck_eq("operands before any flag are positional",
        args.parse(["demo", "a.txt", "--fps", "5", "b.txt"]), args.OK);
    test.ck_eq("  both of them", args.positional().length, 2);
    test.ck_str("  in order", args.positional()[0], "a.txt");
    test.ck_eq("  and the flag still parsed", args.get_long("fps", 30), 5);

    // ─────────────────────────────────────────── a flag-only table
    test.group("a table of one valueless flag");
    args.init("v", "no values here", T_FLAGONLY, "");
    let u3 = args.usage();
    test.ck("its usage names the one flag", u3.index_of("--verbose") >= 0, "--verbose");
    test.ck("and its short form", u3.index_of("-v") >= 0, "-v");
    test.ck_eq("and it is one entry", args.nopts(), 1);
    test.ck_eq("the valueless flag parses bare", args.parse(["v", "--verbose"]), args.OK);
    test.ck("  and is present", args.has("verbose"), "--verbose");
    // A BOOL does take an attached value -- --verbose=no is how you turn one off --
    // which the manual's word "no value" does not convey.
    test.ck_eq("--verbose=no is accepted, not an error",
        args.parse(["v", "--verbose=no"]), args.OK);
    test.ck_str("  and reads as false", args.get_str("verbose", "true"), "false");
    test.ck_eq("--verbose=yes is accepted too",
        args.parse(["v", "--verbose=yes"]), args.OK);
    test.ck_str("  and reads as true", args.get_str("verbose", "false"), "true");
    test.ck_eq("and --no-verbose is the documented way to clear it",
        args.parse(["v", "--verbose"]), args.OK);
    test.ck("  the flag is on before the negation",
        args.get_str("verbose", "false") == "true", "bare means on");
    test.ck_eq("--no-verbose parses", args.parse(["v", "--no-verbose"]), args.OK);
    test.ck_str("  and clears it", args.get_str("verbose", "true"), "false");
    test.ck("but --no-nope is not a negated anything",
        args.parse(["v", "--no-nope"]) == args.USAGE,
        "the --no- prefix only ever clears a DECLARED flag");

    // ─────────────────────────────────────────── the three outcomes, again
    test.group("the three outcomes, checked directly");
    args.init("demo", "a table for the flag tests", T_OPTS, "[file...]");

    // OK
    test.ck_eq("a good command line is OK", args.parse(["demo", "--fps", "1"]), args.OK);
    test.ck_str("and errmsg is empty", args.errmsg(), "");

    // HELP
    test.ck_eq("--help is HELP", args.parse(["demo", "--help"]), args.HELP);
    test.ck_str("with no diagnostic", args.errmsg(), "");
    test.ck("and the usage text is there for it", args.usage().length > 0,
        "which is what a HELP branch prints");

    // USAGE
    test.ck_eq("an unknown flag is USAGE", args.parse(["demo", "--nope"]), args.USAGE);
    test.ck("and the diagnostic names it",
        args.errmsg().index_of("nope") >= 0, "the flag the user typed");
    test.ck_eq("a non-numeric value for a NUM flag is USAGE too",
        args.parse(["demo", "--fps", "fast"]), args.USAGE);
    test.ck("  and the diagnostic names that flag",
        args.errmsg().index_of("fps") >= 0, "--fps");
    test.ck("a missing value for a flag that needs one is USAGE",
        args.parse(["demo", "--fps"]) == args.USAGE,
        "--fps with nothing after it");
    test.ck("the state does not persist across parses",
        args.parse(["demo"]) == args.OK && args.errmsg() == "",
        "a clean parse clears the previous diagnostic");
    test.ck("and neither does a flag's value",
        !args.has("fps") && args.get_long("fps", 30) == 30,
        "a second parse starts from the defaults, not the first parse's values");

    test.ck("usage() is non-empty with no failure at all",
        args.usage().length > 0, "so --help works with no error to report");

    // ─────────────────────────────────────────── init is not additive
    test.group("init replaces the table");
    args.init("first", "one flag", T_FLAGONLY, "");
    let n_first = args.nopts();
    args.init("second", "four flags", T_OPTS, "[x...]");
    test.ck_eq("the second table is in force", args.nopts(), 4);
    test.ck("and the first one's flag is gone", !args.has("verbose"),
        "so a stale flag cannot be read from the previous table");
    test.ck_eq("while nopts was that of the first", n_first, 1);

    return test.report();
};
exit(main());
