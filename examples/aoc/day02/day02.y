// day02.y -- Advent of Code 2025, day 2: "Gift Shop".
//
//   build:  ../../../refs/ycc.ref day02.y -o day02
//   run:    ./day02              the deterministic run (this is EXPECTED)
//           ./day02 --check      the property check: hand-computed
//                                 micro-cases, two independent methods
//                                 compared, invariants, injected defects
//           ./day02 --brute      the element-by-element path for both parts
//           ./day02 --time      add a timing/allocation line
//           ./day02 --input FILE read another range file
//
// The puzzle, in one line: a young Elf typed invalid product IDs into
// the gift shop database, so every ID made of a block of digits repeated
// -- exactly twice for part 1, two or more times for part 2 -- is to be
// found in the given ranges and summed.  The real answers are in
// README.md, with the arithmetic to re-derive them.
//
// ids.y holds the arithmetic (and the parsing, the merge, and the three
// methods that are compared against each other); checks.y holds the
// property check.  Nothing here imports anything from outside this
// folder.

import fs;
import ids;
import checks;

const DEFAULT_INPUT: str = "day02.txt";

const USAGE: str = "day02 -- AoC 2025 day 2, Gift Shop: sum the invalid product IDs\n"
    + "\n"
    + "  day02                    both answers for day02.txt (this is EXPECTED)\n"
    + "  day02 --input FILE       both answers for another range file\n"
    + "  day02 --brute            the element-by-element path instead of the\n"
    + "                           generator: slower, and the independent\n"
    + "                           opinion on the same numbers\n"
    + "  day02 --check            the property check (no reference file)\n"
    + "  day02 --time             add a timing and allocation line\n"
    + "  day02 --help             this text\n"
    + "\n"
    + "Part 1 counts an ID made of a digit block repeated exactly twice;\n"
    + "part 2 counts any block repeated two or more times.";

// die(rc, msg) -> long -- never traps: every error path prints a message
// and exits non-zero, because a trap prints to STDOUT and would silently
// corrupt the golden output instead of failing.
def die(rc: long, msg: str) -> long {
    print("day02: " + msg);
    rc
};

// load(path) -> str -- the file's text, or "" with a message printed.
def load(path: str) -> str {
    let got = fs.read_file(path);
    if (is_some(got)) {
        return unwrap(got)
    };
    print("day02: cannot read " + path);
    ""
};

def main() -> long {
    let args = argv();
    let path = DEFAULT_INPUT;
    let check = false;
    let brute = false;
    let timing = false;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--help" || a == "-h") {
            print(USAGE);
            return 0
        };
        if (a == "--check") {
            check = true
        } else if (a == "--brute") {
            brute = true
        } else if (a == "--time") {
            timing = true
        } else if (a == "--input") {
            if (i + 1 >= len(args)) { return die(2, "--input needs a file") };
            i = i + 1;
            path = args[i]
        } else if (a.starts_with("--input=")) {
            path = a[8:a.length]
        } else {
            return die(2, "unknown option " + a + " (try --help)")
        };
        i = i + 1
    };

    ids.init();

    if (check) {
        return checks.run(path, timing)
    };

    let text = load(path);
    if (text == "") { return die(2, "no input in " + path) };

    let t0 = clock_us();
    let a = ids.solve(text, brute);
    let el = clock_us() - t0;
    if (a.ok == false) { return die(2, path + ": " + a.msg) };

    let g = a.g;
    print("day02 -- Advent of Code 2025, day 2: \"Gift Shop\"");
    print(f"  input    : {path} ({text.length} bytes)");
    print(f"  ranges   : {len(a.raw)} given, {len(a.merged)} after merging, "
        + f"{a.total} IDs in the union");
    print(f"  part 1   : {a.part1.sum}  ({a.part1.count} IDs: a digit block repeated exactly twice)");
    print(f"  part 2   : {a.part2.sum}  ({a.part2.count} IDs: a digit block repeated 2 or more times)");
    let how = "generator: walk (digit length, period)";
    if (brute) { how = "element by element: every ID in every range" };
    print(f"  method   : {how}");
    print("  part 2 by digit length:");
    let l = 2;
    while (l <= ids.MAXDIG) {
        if (g.perlen_n[l] > 0) {
            print(f"      {l:>2} digits: {g.perlen_n[l]:>4} IDs  {g.perlen[l]}")
        };
        l = l + 1
    };
    if (timing) {
        print(f"  time     : {el} us ({el / 1000} ms), heap {heap_used() / 1024} KiB")
    };
    0
}
exit(main())