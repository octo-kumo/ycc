// indexer.y -- the command line around ix.y.
//
// Build:  ../../refs/ycc.ref indexer.y -o indexer
// Run:    ./indexer data/tree              the report, coloured if stdout is a tty
//         ./indexer --no-tty data/tree     the same, plain (this is the golden)
//         ./indexer --check                 the property check (selftest.y)
//
// It walks a directory tree, records path / size / extension / content hash /
// first line per file, aggregates per extension, and answers queries over the
// index.  There is no sort in Y and no map_get, so both the order and the
// index are built by hand in ix.y, which says why.
//
//   ix.y       the engine: total-order comparator, two open-addressed hash
//              tables, a bounded directory walk, and the report
//   cli.y      argument parsing and the program's own diagnostics, so that
//              selftest.y can assert on both without this file
//   selftest.y the property check: no reference file, no golden
//
// ─────────────────────────────────────────────────────────────────────────
// EXIT CODES, and why no path here reaches a trap
// ─────────────────────────────────────────────────────────────────────────
//
//   0  indexed
//   1  usage error (unknown flag, missing or malformed value, two roots)
//   2  the root does not exist, is not a directory, or cannot be listed
//   3  --strict, and something was unreadable or a cap was hit
//
// Each of those prints to STDERR and exits non-zero.  Y's runtime traps
// print to STDOUT and exit 1, which would splice "runtime error: index out of
// bounds" into the middle of EXPECTED and read as a rendering bug, so no path
// here is allowed to reach one.  selftest.y forks a child per hostile input
// and asserts the child's exit status and its message text, so that is
// measured rather than promised -- and it asserts the message is NON-EMPTY,
// because a check that compares two messages which are both absent proves
// nothing.
//
// ─────────────────────────────────────────────────────────────────────────
// `def main()` is NOT called for you
// ─────────────────────────────────────────────────────────────────────────
//
// It is an ordinary function.  A file ending in a `def main()` the runtime
// never invokes compiles clean, runs, exits 0 and PRINTS NOTHING -- which
// looks exactly like success, and is how a missing call hides from a reader.
// So the last line of this file is `exit(main())`.
//
// Note that `main();` would exit 0 even when main "returned" 1, which turns
// every error path in main into a success to any caller.  Hence exit(main()).

import fs;
import ix;
import cli;
import selftest;

const VERSION = "1.0";

// ── --bench ─────────────────────────────────────────────────────────────
//
// Behind a flag because it reads the clock, so it can never be the golden.
// Reports heap_used() across rounds: the walk's own heap cost is CONSTANT in
// the size of the tree (one getdents buffer for the process, not one per
// directory as fs.list_dir allocates), and that is the number worth having.

def bench(rounds: long) -> long {
    if (rounds < 1) { rounds = 1 };
    print("bench  root " + ix.ROOT + ", " + tostring(rounds) + " round(s)");
    let h0 = heap_used();
    let t0 = clock_us();
    let i = 0;
    while (i < rounds) {
        let r = ix.walk(ix.ROOT);
        if (r != 0) { eputs("indexer: " + cli.root_message(r) + "\n"); return 2 };
        i = i + 1;
    };
    let t1 = clock_us();
    let h1 = heap_used();
    let files = ix.N_FILE;
    let bytes = ix.N_BYTES;
    let us = t1 - t0;
    let per = 0;
    if (rounds > 0) { per = us / rounds };
    print("  files          " + tostring(files));
    print("  bytes          " + tostring(bytes));
    print("  total          " + tostring(us) + " us over " + tostring(rounds) + " round(s)");
    print("  per round      " + tostring(per) + " us");
    if (files > 0) {
        print("  per file       " + tostring(per / files) + " us");
        if (bytes > 0 && per > 0) {
            // long / float is a float quotient, and per is microseconds, so
            // dividing by 1000000.0 is the seconds conversion.
            print("  throughput     " + f"{bytes / (per / 1000000.0):.0f}" + " B/s");
        };
    };
    print("  heap before    " + tostring(h0) + " B");
    print("  heap after     " + tostring(h1) + " B");
    print("  heap growth    " + tostring(h1 - h0) + " B over " + tostring(rounds) + " round(s)");
    0
};

// ── main ────────────────────────────────────────────────────────────────

def run(argv: [str]) -> long {
    let pr = cli.parse(argv);
    if (pr == -1) {
        if (cli.SAW_VERSION) { print("indexer " + VERSION) }
        else {
            print("indexer " + VERSION);
            print(cli.USAGE);
        };
        return 0;
    };
    if (cli.ONLY > 0) { return selftest.only(cli.ONLY) };
    if (pr == 7 || cli.WANT_CHECK) { return selftest.run(argv) };
    if (pr != 0) {
        // eputs is "e puts": fd 2 WITHOUT a trailing newline, unlike
        // puts, so every line carries its own.  A diagnostic that runs into
        // the next one is a diagnostic nobody can read.
        eputs("indexer: " + cli.ERR + "\n");
        eputs("indexer: try 'indexer --help' for the list of flags\n");
        eputs("\n");
        eputs(cli.USAGE + "\n");
        return 1;
    };
    // One ioctl(2) on fd 1, once.  --no-tty settles COLOUR_AUTO first, so the
    // golden path never touches the terminal at all.
    if (ix.COLOR_AUTO) {
        if (cli.is_tty()) { ix.COLOR = 1 } else { ix.COLOR = 0 };
    };
    let rc = ix.walk(ix.ROOT);
    if (rc != 0) {
        eputs("indexer: " + cli.root_message(rc) + "\n");
        return 2;
    };
    if (cli.BENCH > 0) { return bench(cli.BENCH) };
    let i = 0;
    while (i < len(ix.DIAG)) {
        eputs("indexer: warning: " + ix.DIAG[i] + "\n");
        i = i + 1;
    };
    print(ix.report());
    if (ix.STRICT && (ix.N_UNREAD > 0 || ix.N_CAP > 0)) {
        eputs("indexer: " + cli.strict_message() + "\n");
        return 3;
    };
    0
};

def main() -> long {
    // argv() INCLUDES argv[0], the program path.  Passing the whole thing to
    // the parser makes "./indexer" the root and the real one a second root,
    // which is a usage error on every single invocation.
    let a = argv();
    let rest: [str] = [];
    let i = 1;
    while (i < len(a)) {
        rest += a[i];
        i = i + 1;
    };
    let rc = run(rest);
    rc
};

exit(main());