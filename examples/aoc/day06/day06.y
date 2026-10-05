// day06.y -- Advent of Code 2025, day 6 ("Trash Compactor"), in Y.
//
// A math worksheet is unrolled into one very long horizontal line.  Each
// problem is a block of columns: the numbers sit above the operator that
// joins them, and problems are separated by a column of nothing but spaces.
// The alignment inside a block is arbitrary (rows are ragged), and the
// operator row is shorter than the number rows.
//
//   part 1  read every problem's numbers the human way -- one number per
//           row, top to bottom -- and add up the answers
//   part 2  read them the cephalopod way -- one number per COLUMN, the
//           digits of a column read top to bottom, columns right to left
//
// Part 2's definition is NOT in the puzzle statement (AoC gates part 2
// behind a login).  It comes from public write-ups; see README.md, which
// names the sources and the anchors this program is checked against.
//
// build: ../../../refs/ycc.ref day06.y -o day06
// run:   ./day06            (input.txt -> both answers)
//        ./day06 --check    (property check, no reference file)
//        ./day06 --help
import fs;

const OP_ADD = 43;              // '+'
const OP_MUL = 42;              // '*'
const CH_SPACE = 32;
const CH_ZERO = 48;             // '0'
const MAX_DIGITS = 18;          // past this a number could overflow a long
const CEIL = 4611686018427387904;   // 2^62: every total is checked under it

// One parsed worksheet.  Both readings are kept side by side, because part 2
// needs the digits of every column and part 1 needs the digits of every row,
// and a parser that computed only one of them cannot serve the other.
//
// `vals` holds part 1's numbers (one per row-run, flattened problem by
// problem); `cvals` holds part 2's (one per column of the problem, already in
// the right-to-left order the cephalopods read them).  `lens`/`clens` are
// those numbers' digit counts, kept so a check can assert that no digit was
// dropped or counted twice by either reading.
type Sheet = {
    rows: long,                 // rows in the worksheet (operand rows + the operator row)
    oprow: long,                // which row is the operator row
    width: long,                // columns in the widest row
    nprob: long,                // number of problems
    nadd: long,                 // problems whose operator is '+'
    nmul: long,                 // problems whose operator is '*'
    nruns: long,                // operand numbers the row scan counted
    nops: long,                 // operator characters the row scan counted
    ndig: long,                 // digit characters in the operand rows
    offs: [long],               // vals[offs[p]] is problem p's first operand
    vals: [long],
    lens: [long],
    ops: [long],                // per problem: OP_ADD or OP_MUL
    counts: [long],             // operands per problem
    coffs: [long],              // cvals[coffs[p]] is problem p's first column number
    cvals: [long],
    clens: [long],
    ccounts: [long]             // column numbers per problem
};

// Why the last parse failed ("" when it did not).  Module-level, so the
// parse helpers can report without threading a reason through every call.
let perr = "";
let prow = 0;
let pcol = 0;

// The rows being parsed.  A row is indexed by number from every helper, so
// it lives in one place rather than in every signature.
let g_lines: [str] = [];
let g_rows = 0;
let g_oprow = -1;

// How many digits the last parse_col read.  A separate module-level slot
// because Y has no out-parameters, and "007" is 3 digits but the value 7.
let g_clen = 0;

// What a problem adds to the sheet.  Appended in place by add_problem and
// read back by parse; they are reset at the top of every parse, and nothing
// else touches them.
let a_vals: [long] = [];
let a_lens: [long] = [];
let a_ops: [long] = [];
let a_counts: [long] = [];
let a_cvals: [long] = [];
let a_clens: [long] = [];
let a_ccounts: [long] = [];

// --check bookkeeping.  Globals (not captures), so every expect can tally.
let checks_run = 0;
let checks_failed = 0;
let first_failure = "";

// ── parsing ───────────────────────────────────────────────────────────────────

// Row `r`, column `c`, as a long.  Rows are ragged (the operator row is
// shorter than the number rows, and a number may sit anywhere inside its
// block), so past a row's end is blank paper rather than an error.
def cell(r: long, c: long) -> long {
    let line = g_lines[r];
    // `line[c] + 0` rather than `line[c]`: Y lets `if` arms disagree in type
    // (the VOID law), and a byte arm against a long arm makes the whole `if`
    // void -- so both arms are widened on purpose.
    let v = CH_SPACE + 0;
    if (c < line.length) { v = line[c] + 0 };
    v
}

def is_digit(ch: long) -> bool { ch >= CH_ZERO && ch <= CH_ZERO + 9 }

// True when column `c` is a problem separator: blank in EVERY row, the
// operator row included.
def col_blank(c: long) -> bool {
    let r = 0;
    let blank = true;
    while (r < g_rows && blank) {
        if (cell(r, c) != CH_SPACE) { blank = false };
        r = r + 1;
    };
    blank
}

// The number in row `r` between columns `s` and `e` (exclusive), or a
// reported parse failure.  The statement guarantees a run of digits; a
// stray sign or a letter is reported rather than guessed at.
def parse_num(r: long, s: long, e: long) -> long {
    let v = 0;
    if (e - s > MAX_DIGITS) {
        perr = "number has more than " + tostring(MAX_DIGITS) + " digits";
        prow = r;
        pcol = s + 1;
        return 0;
    };
    let c = s;
    while (c < e) {
        let ch = cell(r, c);
        if (!is_digit(ch)) {
            perr = "not a digit in a number";
            prow = r;
            pcol = c + 1;
            return 0;
        };
        v = v * 10 + (ch - CH_ZERO);
        c = c + 1;
    };
    v
}

// The cephalopod reading of one column: its digits, top to bottom, with the
// blank cells skipped.  Returns -1 with `perr` set when the column cannot be
// read as a number at all.
def parse_col(c: long, rows: long) -> long {
    let acc = 0;
    let nd = 0;
    let r = 0;
    while (r < rows) {
        let ch = cell(r, c);
        if (is_digit(ch)) {
            acc = acc * 10 + (ch - CH_ZERO);
            nd = nd + 1;
        } else if (ch != CH_SPACE && ch != OP_ADD && ch != OP_MUL) {
            perr = "unexpected character in a problem column";
            prow = r;
            pcol = c + 1;
            return -1;
        };
        r = r + 1;
    };
    if (nd == 0) {
        // Only the operator row has anything in this column, so the block is
        // wider than the numbers in it.  The statement never produces this;
        // report it instead of inventing an answer for it.
        perr = "a column of a problem holds no digits at all";
        prow = g_oprow;
        pcol = c + 1;
        return -1;
    };
    g_clen = nd;
    acc
}

// One problem: columns [s, e) hold, in every row, runs of non-space
// characters.  An operand row contributes one number per run (part 1); each
// column contributes one number (part 2); the operator row must contribute
// exactly one single-character operator.  Returns 1 on success, 0 with `perr`
// set otherwise.
def add_problem(s: long, e: long) -> long {
    let vstart = a_vals.length;
    let cstart = a_cvals.length;
    let opv = 0;
    let opn = 0;
    let r = 0;
    while (r < g_rows) {
        let c = s;
        while (c < e) {
            while (c < e && cell(r, c) == CH_SPACE) { c = c + 1 };
            if (c < e) {
                let ts = c;
                while (c < e && cell(r, c) != CH_SPACE) { c = c + 1 };
                if (r == g_oprow) {
                    if (c - ts != 1) {
                        perr = "an operator run is not a single character";
                        prow = r;
                        pcol = ts + 1;
                        return 0;
                    };
                    let ch = cell(r, ts);
                    if (ch != OP_ADD && ch != OP_MUL) {
                        perr = "unknown operator";
                        prow = r;
                        pcol = ts + 1;
                        return 0;
                    };
                    opv = ch;
                    opn = opn + 1;
                } else {
                    let v = parse_num(r, ts, c);
                    if (perr != "") { return 0 };
                    a_vals += v;
                    a_lens += c - ts;
                };
            };
        };
        r = r + 1;
    };
    if (opn != 1) {
        perr = "problem has " + tostring(opn) + " operators, expected 1";
        prow = g_oprow;
        pcol = s + 1;
        return 0;
    };
    let cnt = a_vals.length - vstart;
    if (cnt == 0) {
        perr = "problem has no numbers";
        prow = g_oprow;
        pcol = s + 1;
        return 0;
    };
    a_ops += opv;
    a_counts += cnt;

    // Part 2: every column of the block, right to left.  A block is a run of
    // columns that are not blank in every row, and the operator row puts
    // exactly one character in it, so every column here holds at least one
    // digit -- parse_col refuses the ones that do not rather than skipping
    // them silently.
    let cc = e - 1;
    while (cc >= s) {
        let v = parse_col(cc, g_rows);
        if (perr != "") { return 0 };
        a_cvals += v;
        a_clens += g_clen;
        cc = cc - 1;
    };
    a_ccounts += a_cvals.length - cstart;
    1
}

// The empty sheet, handed back on every parse-failure path so the caller
// tests `perr` rather than a half-built record.
def blank_sheet() -> Sheet {
    { rows: 0, oprow: -1, width: 0, nprob: 0, nadd: 0, nmul: 0, nruns: 0,
      nops: 0, ndig: 0, offs: [], vals: [], lens: [], ops: [], counts: [],
      coffs: [], cvals: [], clens: [], ccounts: [] }
}

// Start index of every problem in a flat array of per-problem runs.
def starts_of(counts: [long]) -> [long] {
    let o: [long] = [];
    let t = 0;
    let i = 0;
    while (i < len(counts)) {
        o += t;
        t = t + counts[i];
        i = i + 1;
    };
    o
}

// The worksheet `lines`, or a parse failure.  A row is classified by what it
// holds: digits make an operand row, only operators make the operator row,
// and the statement puts that row at the bottom of every problem.
def parse(lines: [str]) -> Sheet {
    g_lines = lines;
    g_rows = len(lines);
    g_oprow = -1;
    perr = "";
    a_vals = [];
    a_lens = [];
    a_ops = [];
    a_counts = [];
    a_cvals = [];
    a_clens = [];
    a_ccounts = [];

    let width = 0;
    let oprows = 0;
    let nruns = 0;
    let nops = 0;
    let ndig = 0;
    let r = 0;
    while (r < g_rows) {
        let c = 0;
        let nd = 0;
        let no = 0;
        let runs = 0;
        let inrun = false;
        let line = lines[r];
        while (c < line.length) {
            let ch = line[c];
            if (is_digit(ch)) {
                nd = nd + 1;
                if (!inrun) { runs = runs + 1; inrun = true };
            } else if (ch == OP_ADD || ch == OP_MUL) {
                no = no + 1;
                inrun = false;
            } else if (ch != CH_SPACE) {
                perr = "unexpected character in row " + tostring(r + 1);
                prow = r;
                pcol = c + 1;
                return blank_sheet();
            } else {
                inrun = false;
            };
            c = c + 1;
        };
        if (line.length > width) { width = line.length };
        if (nd == 0 && no == 0) {
            perr = "row " + tostring(r + 1) + " holds neither numbers nor operators";
            prow = r;
            pcol = 1;
            return blank_sheet();
        };
        if (nd == 0) {
            oprows = oprows + 1;
            g_oprow = r;
            nops = no;
        } else {
            if (no > 0) {
                perr = "row " + tostring(r + 1) + " holds both numbers and operators";
                prow = r;
                pcol = 1;
                return blank_sheet();
            };
            nruns = nruns + runs;
            ndig = ndig + nd;
        };
        r = r + 1;
    };

    if (oprows != 1) {
        perr = "found " + tostring(oprows) + " operator rows, expected exactly 1";
        return blank_sheet();
    };
    if (g_oprow != g_rows - 1) {
        perr = "the operator row is row " + tostring(g_oprow + 1)
             + ", expected it at the bottom (row " + tostring(g_rows) + ")";
        prow = g_oprow;
        pcol = 1;
        return blank_sheet();
    };

    // Columns, then the runs of columns that are not separators.  Leading
    // and trailing separator columns are the margin, not a problem.
    let sep: [bool] = [];
    let c = 0;
    while (c < width) {
        sep += col_blank(c);
        c = c + 1;
    };

    let nprob = 0;
    let nadd = 0;
    let nmul = 0;
    c = 0;
    while (c < width) {
        if (sep[c]) {
            c = c + 1;
        } else {
            let s = c;
            while (c < width && !sep[c]) { c = c + 1 };
            if (add_problem(s, c) == 0) { return blank_sheet() };
            nprob = nprob + 1;
            if (a_ops[nprob - 1] == OP_ADD) { nadd = nadd + 1 } else { nmul = nmul + 1 };
        };
    };

    if (nprob == 0) {
        perr = "the worksheet holds no problems";
        return blank_sheet();
    };
    { rows: g_rows, oprow: g_oprow, width: width, nprob: nprob, nadd: nadd,
      nmul: nmul, nruns: nruns, nops: nops, ndig: ndig,
      offs: starts_of(a_counts), vals: a_vals, lens: a_lens, ops: a_ops,
      counts: a_counts, coffs: starts_of(a_ccounts), cvals: a_cvals,
      clens: a_clens, ccounts: a_ccounts }
}

// ── evaluating a problem ─────────────────────────────────────────────────────

// Apply one operator to an accumulator: the only place the two operators are
// told apart, shared by every method below so a defect cannot hide in one of
// them alone.
def apply(op: long, acc: long, v: long) -> long {
    if (op == OP_MUL) { acc * v } else { acc + v }
}

// Part 1, method A: ordinary precedence -- multiplication binds tighter than
// addition, so a problem is a sum of products.  One left-to-right sweep,
// carrying the product of the run being built.
def prob_prec(sh: Sheet, p: long) -> long {
    let off = sh.offs[p];
    let total = 0;
    let term = sh.vals[off];
    let i = 0;
    while (i < sh.counts[p] - 1) {
        if (sh.ops[p] == OP_MUL) {
            term = term * sh.vals[off + i + 1];
        } else {
            total = total + term;
            term = sh.vals[off + i + 1];
        };
        i = i + 1;
    };
    total + term
}

// Part 1, method B: the same value reached from the other end.  Walk the
// operators right to left, carrying the sum of everything after them, so a
// forward/run-splitting slip cannot be present in both.
def prob_prec_rev(sh: Sheet, p: long) -> long {
    let off = sh.offs[p];
    let rest = 0;
    let term = sh.vals[off + sh.counts[p] - 1];
    let i = sh.counts[p] - 1;
    while (i > 0) {
        if (sh.ops[p] == OP_MUL) {
            term = term * sh.vals[off + i - 1];
        } else {
            rest = rest + term;
            term = sh.vals[off + i - 1];
        };
        i = i - 1;
    };
    rest + term
}

// Part 1, method C: no run bookkeeping at all -- fold from the operator's
// identity (0 for '+', 1 for '*').  A worksheet with one operator per problem
// cannot tell precedence apart, so this is a third opinion, not a fourth rule.
def prob_fold1(sh: Sheet, p: long) -> long {
    let acc = 1;
    if (sh.ops[p] == OP_ADD) { acc = 0 };
    let off = sh.offs[p];
    let i = 0;
    while (i < sh.counts[p]) {
        acc = apply(sh.ops[p], acc, sh.vals[off + i]);
        i = i + 1;
    };
    acc
}

// Part 2, method A: fold the column numbers in the order they were parsed,
// which is right to left -- the order the cephalopods read them in.
def prob_ceph(sh: Sheet, p: long) -> long {
    let acc = 1;
    if (sh.ops[p] == OP_ADD) { acc = 0 };
    let off = sh.coffs[p];
    let i = 0;
    while (i < sh.ccounts[p]) {
        acc = apply(sh.ops[p], acc, sh.cvals[off + i]);
        i = i + 1;
    };
    acc
}

// Part 2, method B: the same fold walked the other way, left to right.  '+'
// and '*' are commutative, so the total must not move -- which is the point:
// it says the order the cephalopods read in is carried by the parser, not by
// the arithmetic.
def prob_ceph_rev(sh: Sheet, p: long) -> long {
    let acc = 1;
    if (sh.ops[p] == OP_ADD) { acc = 0 };
    let off = sh.coffs[p];
    let i = sh.ccounts[p] - 1;
    while (i >= 0) {
        acc = apply(sh.ops[p], acc, sh.cvals[off + i]);
        i = i - 1;
    };
    acc
}

// Part 2, method C: part 1's run-splitting evaluator run over the column
// numbers instead -- same shape of code, different data.
def prob_ceph_runs(sh: Sheet, p: long) -> long {
    let off = sh.coffs[p];
    let total = 0;
    let term = sh.cvals[off];
    let i = 0;
    while (i < sh.ccounts[p] - 1) {
        if (sh.ops[p] == OP_MUL) {
            term = term * sh.cvals[off + i + 1];
        } else {
            total = total + term;
            term = sh.cvals[off + i + 1];
        };
        i = i + 1;
    };
    total + term
}

def total_prec(sh: Sheet) -> long {
    let t = 0;
    let p = 0;
    while (p < sh.nprob) { t = t + prob_prec(sh, p); p = p + 1 };
    t
}

def total_prec_rev(sh: Sheet) -> long {
    let t = 0;
    let p = 0;
    while (p < sh.nprob) { t = t + prob_prec_rev(sh, p); p = p + 1 };
    t
}

def total_fold1(sh: Sheet) -> long {
    let t = 0;
    let p = 0;
    while (p < sh.nprob) { t = t + prob_fold1(sh, p); p = p + 1 };
    t
}

def total_ceph(sh: Sheet) -> long {
    let t = 0;
    let p = 0;
    while (p < sh.nprob) { t = t + prob_ceph(sh, p); p = p + 1 };
    t
}

def total_ceph_rev(sh: Sheet) -> long {
    let t = 0;
    let p = 0;
    while (p < sh.nprob) { t = t + prob_ceph_rev(sh, p); p = p + 1 };
    t
}

def total_ceph_runs(sh: Sheet) -> long {
    let t = 0;
    let p = 0;
    while (p < sh.nprob) { t = t + prob_ceph_runs(sh, p); p = p + 1 };
    t
}

// Every column number of problem `p`, as one line, for the report.  The `;`
// inside the `if` arm is load-bearing: without it the arm is a value-used
// position, the emitter falls back from the amortised `y_str_app` to an exact
// `y_str_cat`, and the loop becomes quadratic in the block's width -- filed
// as "A `str +=` in a value-used position makes its whole loop O(n^2) in heap"
// in examples/BUGS.md.  Audited with -S: this function is 2 app / 0 cat.
def ceph_line(sh: Sheet, p: long) -> str {
    let s = "";
    let off = sh.coffs[p];
    let i = 0;
    while (i < sh.ccounts[p]) {
        s += tostring(sh.cvals[off + i]);
        if (i + 1 < sh.ccounts[p]) { s += " "; };
        i = i + 1;
    };
    s
}

def op_name(op: long) -> str { if_then(op == OP_ADD, "+", "*") }

// ── the answer ────────────────────────────────────────────────────────────────

const HELP = "day06 -- Advent of Code 2025 day 6 (Trash Compactor), in Y

usage:
  ./day06 [FILE]        solve FILE (default input.txt) and print both answers
  ./day06 --bench       solve FILE and also print elapsed time and heap used
  ./day06 --check       run the property battery and print every assertion
  ./day06 --help        this text

part 1: read each problem's numbers row by row (the human way), apply its
        operator, and add every answer up
part 2: read each problem's numbers column by column, top to bottom within a
        column and right to left across them (the cephalopod way), apply its
        operator, and add every answer up
";

def solve(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day06: cannot read " + path + "\n");
        return 1;
    };
    let sh = parse(lines!);
    if (perr != "") {
        if (prow >= 0) {
            eputs("day06: " + path + " row " + tostring(prow + 1) + " column "
                  + tostring(pcol) + ": " + perr + "\n");
        } else {
            eputs("day06: " + path + ": " + perr + "\n");
        };
        return 1;
    };
    let p1 = total_prec(sh);
    let p2 = total_ceph(sh);
    print("day06: Advent of Code 2025 day 6 -- Trash Compactor");
    print(f"input: {path}");
    print(f"rows: {sh.rows} (operator row {sh.oprow + 1}), width: {sh.width}");
    print(f"problems: {sh.nprob} ({sh.nadd} additions, {sh.nmul} multiplications)");
    print(f"part 1 reads {sh.nruns} row-numbers, part 2 reads "
          + f"{len(sh.cvals)} column-numbers, from {sh.ndig} digits");
    print(f"part 1 (grand total, each problem's rows read as numbers): {p1}");
    print(f"part 2 (grand total, each problem's columns read as numbers): {p2}");
    0
}

// ── the property check ────────────────────────────────────────────────────────
//
// No reference file is involved: every expectation here is either worked out
// by hand in README.md, published by the puzzle statement, published by a
// named write-up, or counted outside this program from the input file.

def expect(name: str, ok: bool, detail: str) -> long {
    checks_run = checks_run + 1;
    if (ok) {
        print("ok   " + name + ": " + detail);
    } else {
        checks_failed = checks_failed + 1;
        if (first_failure == "") { first_failure = name };
        print("FAIL " + name + ": " + detail);
    };
    0
}

// A tiny helper so a report line can read as a sentence.
def if_then(c: bool, a: str, b: str) -> str {
    if (c) { a } else { b }
}

// The statement's own worksheet, byte for byte.  The trailing spaces matter:
// they are what makes row 0's "64" end one column short of row 2's "314".
const EX0 = "123 328  51 64 ";
const EX1 = " 45 64  387 23 ";
const EX2 = "  6 98  215 314";
const EX3 = "*   +   *   +  ";

// Tier-1 anchor, part 1: the statement prints the four answers and the total.
def check_statement_example() -> long {
    print("-- the statement's worked example (part 1 anchor: the statement)");
    let sh = parse([EX0, EX1, EX2, EX3]);
    if (perr != "") {
        expect("example parses", false, perr);
        return 0;
    };
    expect("example parses", true, f"{sh.nprob} problems, width {sh.width}");
    expect("example problem count", sh.nprob == 4, f"{sh.nprob} == 4");
    expect("example problem 0", prob_prec(sh, 0) == 33210,
           f"123*45*6 = {prob_prec(sh, 0)}, the statement says 33210");
    expect("example problem 1", prob_prec(sh, 1) == 490,
           f"328+64+98 = {prob_prec(sh, 1)}, the statement says 490");
    expect("example problem 2", prob_prec(sh, 2) == 4243455,
           f"51*387*215 = {prob_prec(sh, 2)}, the statement says 4243455");
    expect("example problem 3", prob_prec(sh, 3) == 401,
           f"64+23+314 = {prob_prec(sh, 3)}, the statement says 401");
    let t1 = total_prec(sh);
    let t1r = total_prec_rev(sh);
    let t1f = total_fold1(sh);
    expect("part 1 grand total", t1 == 4277556,
           f"{t1}, the statement says 4277556");
    expect("part 1: three methods agree", t1 == t1r && t1 == t1f,
           f"{t1} == {t1r} == {t1f}");

    // Part 2 is not in the statement at all, so the numbers below are the
    // only thing standing between "self-consistent" and "right".
    print("-- part 2 anchors (published values, not the statement)");
    let line0 = ceph_line(sh, 0);
    expect("part 2 numbers of example problem 0", line0 == "356 24 1",
           f"read as [{line0}], the write-up says 356, 24, 1");
    expect("part 2 value of example problem 0", prob_ceph(sh, 0) == 8544,
           f"356*24*1 = {prob_ceph(sh, 0)}");
    expect("part 2 value of example problem 3", prob_ceph(sh, 3) == 1058,
           f"[{ceph_line(sh, 3)}] added = {prob_ceph(sh, 3)}; the published "
           + "numbers for this problem also come to 1058");
    let t2 = total_ceph(sh);
    let t2r = total_ceph_rev(sh);
    let t2u = total_ceph_runs(sh);
    expect("part 2 grand total", t2 == 3263827,
           f"{t2}; worked out by hand in README.md, no published total found");
    expect("part 2: three methods agree", t2 == t2r && t2 == t2u,
           f"{t2} == {t2r} == {t2u}");
    expect("part 1 and part 2 differ on the example", t1 != t2,
           f"{t1} != {t2}");
    0
}

// Transposition is an involution: presenting a block's digit grid with its
// rows and columns swapped turns part 2 into part 1 and part 1 into part 2.
// Nothing here recomputes the rule -- it feeds DIFFERENT worksheets through
// the same parse and solve entry points the default run uses.
def check_transpose() -> long {
    print("-- transposition is an involution (forward and reverse pass)");
    let upright = parse(["123", " 45", "  6", "*   "]);
    let transposed = parse(["1  ", "24 ", "356", "*  "]);
    if (perr != "") {
        expect("transpose fixtures parse", false, perr);
        return 0;
    };
    let a1 = total_prec(upright);
    let a2 = total_ceph(upright);
    let b1 = total_prec(transposed);
    let b2 = total_ceph(transposed);
    expect("upright parses to one problem", upright.nprob == 1,
           f"{upright.nprob} problem, {upright.counts[0]} row-numbers, "
           + f"{upright.ccounts[0]} column-numbers");
    expect("transposed parses to one problem", transposed.nprob == 1,
           f"{transposed.nprob} problem, {transposed.counts[0]} row-numbers, "
           + f"{transposed.ccounts[0]} column-numbers");
    expect("part 2 of the upright == part 1 of the transposed", a2 == b1,
           f"{a2} == {b1}");
    expect("part 1 of the upright == part 2 of the transposed", a1 == b2,
           f"{a1} == {b2}");
    expect("the two readings of the upright differ", a1 != a2, f"{a1} != {a2}");
    0
}

// Four tiny worksheets, each worked out by hand in README.md, fed through
// parse() and the totals exactly as the real input is.
def check_micro() -> long {
    print("-- hand-computed micro-cases (the arithmetic is in README.md)");

    // m1: one digit per cell, one operator per problem.
    let m1 = parse(["4 9", "2 3", "+ +"]);
    expect("m1 parses", perr == "", "2 problems");
    expect("m1 part 1", total_prec(m1) == 18,
           f"(4+2)+(9+3) = {total_prec(m1)}, hand says 18");
    expect("m1 part 2", total_ceph(m1) == 135,
           f"42+93 = {total_ceph(m1)}, hand says 135");

    // m2: two leading margin columns, ragged rows (row 1 is two columns short
    // at one end and contributes nothing at all to the last problem), a block
    // whose leftmost column holds a digit in one row only, and a
    // one-operand problem.
    let m2 = parse(["  12  7 4", "   3  5  ", "  +   + *"]);
    expect("m2 parses", perr == "", "3 problems");
    expect("m2 part 1", total_prec(m2) == 31,
           f"(12+3) + (7+5) + 4 = {total_prec(m2)}, hand says 31");
    expect("m2 part 2", total_ceph(m2) == 103,
           f"(23+1) + 75 + 4 = {total_ceph(m2)}, hand says 103");
    expect("m2 one-operand problem", m2.counts[2] == 1 && m2.counts[0] == 2,
           f"problem 2 has {m2.counts[2]} operand (hand says 1) and "
           + f"problem 0 has {m2.counts[0]} (hand says 2)");

    // m3: a '*' problem whose answer is 0, and a column of two zeros, which
    // is two digits long but the value 0.
    let m3 = parse(["10 2", " 0 3", "*  +"]);
    expect("m3 parses", perr == "", "2 problems");
    expect("m3 part 1", total_prec(m3) == 5,
           f"10*0 + 2+3 = {total_prec(m3)}, hand says 5");
    expect("m3 part 2", total_ceph(m3) == 23,
           f"1*00 + 23 = {total_ceph(m3)}, hand says 23");
    expect("m3 leading zeros keep their digit count", m3.clens[0] == 2,
           f"column '00' is {m3.clens[0]} digits, hand says 2");

    // m4: the shape the real input's widest problems have -- a four-column
    // block with all four operand rows contributing, plus a one-column block.
    let m4 = parse(["  91  7", " 238  5", "4756  1", "*     +"]);
    expect("m4 parses", perr == "", "2 problems");
    expect("m4 part 1", total_prec(m4) == 103005461,
           f"91*238*4756 + 7+5+1 = {total_prec(m4)}, hand says 103005461");
    expect("m4 part 2", total_ceph(m4) == 18783031,
           f"186*935*27*4 + 751 = {total_ceph(m4)}, hand says 18783031");

    expect("every micro-case separates the two readings",
           total_prec(m1) != total_ceph(m1) && total_prec(m2) != total_ceph(m2)
           && total_prec(m3) != total_ceph(m3) && total_prec(m4) != total_ceph(m4),
           "part 1 != part 2 on all four worksheets");
    0
}

// Every malformed worksheet must be rejected with a message and no trap: the
// harness only reaches the print after each one if parse() returned.
def check_bad_inputs() -> long {
    print("-- malformed worksheets are reported, never trapped");
    let names = ["operator row on top", "two operators in one problem",
                 "letter inside a number", "a row holding neither",
                 "an empty sheet", "operators among the numbers"];
    let bad = [
        ["*  ", "1 2", "+ "],
        ["1234", "1 2", "* + "],
        ["1x2", "1 2", "*  +"],
        ["1 2", "   ", "* +"],
        ["      ", "      ", "      "],
        ["1 2", "3*4", "+  "]
    ];
    let i = 0;
    while (i < len(names)) {
        parse(bad[i]);
        expect("rejects: " + names[i], perr != "", "\"" + perr + "\"");
        i = i + 1;
    };
    0
}

// The real input: facts counted outside this program, invariants that do not
// come out of the counting code, and the methods for each part agreeing.
def check_real(path: str) -> long {
    print("-- real input: facts from outside the program");
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        expect("real input readable", false, "cannot read " + path);
        return 0;
    };
    let sh = parse(lines!);
    if (perr != "") {
        expect("real input parses", false, perr);
        return 0;
    };
    let p1 = total_prec(sh);
    let p2 = total_ceph(sh);

    // Presence first: a check that compares two absent values passes, so both
    // answers are shown to be there before anything compares them.
    expect("part 1 present", p1 > 0, f"part 1 = {p1}");
    expect("part 2 present", p2 > 0, f"part 2 = {p2}");
    expect("part 2 present and different from part 1", p2 != p1,
           f"{p1} != {p2}");

    // These five were counted from input.txt by hand (and by an independent
    // throwaway script), never by this program: 5 rows, 3752 columns, 1000
    // operator characters, 466 '+' and 534 '*', 4000 digit runs, 9535 digits,
    // 2753 column numbers.
    expect("rows", sh.rows == 5, f"{sh.rows} == 5");
    expect("width", sh.width == 3752, f"{sh.width} == 3752");
    expect("problems == operator characters", sh.nprob == 1000 && sh.nops == 1000,
           f"{sh.nprob} problems == {sh.nops} operators == 1000");
    expect("operator split", sh.nadd == 466 && sh.nmul == 534,
           f"{sh.nadd} '+' and {sh.nmul} '*'");
    expect("digit characters", sh.ndig == 9535, f"{sh.ndig} == 9535");
    expect("operand numbers", sh.nruns == 4000, f"{sh.nruns} == 4000");
    expect("column numbers", len(sh.cvals) == 2753,
           f"{len(sh.cvals)} == 2753");
    expect("every operand row fills every problem",
           sh.nruns == (sh.rows - 1) * sh.nprob,
           f"{sh.nruns} == {sh.rows - 1} rows x {sh.nprob} problems");

    print("-- real input: invariants and cross-checks");
    // One row-number per run of digits: the row scan counted the runs, the
    // block walk counted the numbers.
    let runs = 0;
    let cols = 0;
    let mx = 0;
    let p = 0;
    while (p < sh.nprob) {
        runs = runs + sh.counts[p];
        cols = cols + sh.ccounts[p];
        let v = prob_prec(sh, p);
        if (v > mx) { mx = v };
        p = p + 1;
    };
    expect("one operand per run of digits", runs == sh.nruns,
           f"{runs} operands == {sh.nruns} digit-runs");
    expect("one column-number per column of a block", cols == len(sh.cvals),
           f"{cols} column-numbers == {len(sh.cvals)} parsed");
    expect("every problem has at least one column", cols >= sh.nprob,
           f"{cols} column-numbers over {sh.nprob} problems");
    expect("a block is never wider than its numbers' digits",
           cols <= sh.ndig, f"{cols} column-numbers <= {sh.ndig} digits");

    // The digit budget: the same digits, counted three ways.
    let dl1 = 0;
    let i = 0;
    while (i < len(sh.vals)) { dl1 = dl1 + sh.lens[i]; i = i + 1 };
    let dl2 = 0;
    i = 0;
    while (i < len(sh.cvals)) { dl2 = dl2 + sh.clens[i]; i = i + 1 };
    expect("digits read the row way == digits read the column way",
           dl1 == dl2 && dl1 == sh.ndig,
           f"{dl1} == {dl2} == {sh.ndig} digit characters");

    // Three methods per part, all over the same parsed sheet.
    let p1r = total_prec_rev(sh);
    let p1f = total_fold1(sh);
    expect("part 1: forward run-split == reverse run-split", p1 == p1r,
           f"{p1} == {p1r}");
    expect("part 1: run-split == identity fold", p1 == p1f, f"{p1} == {p1f}");
    let p2r = total_ceph_rev(sh);
    let p2u = total_ceph_runs(sh);
    expect("part 2: right-to-left == left-to-right", p2 == p2r, f"{p2} == {p2r}");
    expect("part 2: identity fold == run-split", p2 == p2u, f"{p2} == {p2u}");

    // Decomposition: the total is exactly the sum of the per-problem values.
    let diff = 0;
    p = 0;
    while (p < sh.nprob) {
        diff = diff + prob_ceph(sh, p) - prob_prec(sh, p);
        p = p + 1;
    };
    expect("part 2 == part 1 + the sum of the per-problem differences",
           p1 + diff == p2, f"{p1} + {diff} == {p2}");
    expect("the total is at least the largest single problem", p1 >= mx,
           f"{p1} >= {mx}");

    // Magnitude: everything has to fit a long with room to spare.
    expect("both totals inside 2^62", p1 < CEIL && p2 < CEIL,
           f"{p1} and {p2} < {CEIL}");

    // The widest problem, spelled out, so the answer can be read by hand.
    let widest = 0;
    p = 0;
    while (p < sh.nprob) {
        if (sh.ccounts[p] > sh.ccounts[widest]) { widest = p };
        p = p + 1;
    };
    print("     widest problem is #" + tostring(widest) + ": operator "
          + op_name(sh.ops[widest]) + ", " + tostring(sh.ccounts[widest])
          + " columns read as [" + ceph_line(sh, widest) + "]");
    0
}

def run_check() -> long {
    checks_run = 0;
    checks_failed = 0;
    first_failure = "";

    check_statement_example();
    check_transpose();
    check_micro();
    check_bad_inputs();
    check_real("input.txt");

    print("");
    if (checks_failed == 0) {
        print(f"property check: {checks_run} checks, all passed");
        return 0;
    };
    print(f"property check: {checks_failed} of {checks_run} FAILED "
          + f"(first: {first_failure})");
    1
}

// The same solve with the two numbers that describe its cost: elapsed
// microseconds and the heap the parse and both readings allocated.  The heap
// is an arena, so this is the whole cost of the run rather than a high-water
// mark -- which is exactly why it is worth printing.
def bench(path: str) -> long {
    let lines: [str]? = fs.read_lines(path);
    if (lines == none) {
        eputs("day06: cannot read " + path + "\n");
        return 1;
    };
    let h0 = heap_used();
    let t0 = clock_us();
    let sh = parse(lines!);
    if (perr != "") {
        eputs("day06: " + path + ": " + perr + "\n");
        return 1;
    };
    let p1 = total_prec(sh);
    let p2 = total_ceph(sh);
    let t1 = clock_us();
    let h1 = heap_used();
    print("day06: bench " + path);
    print(f"part 1: {p1}");
    print(f"part 2: {p2}");
    print(f"elapsed: {t1 - t0} us for {sh.rows} rows x {sh.width} columns, "
          + f"{sh.nprob} problems, {sh.nruns + len(sh.cvals)} numbers");
    print(f"heap: {h1 - h0} bytes allocated by the parse and both readings");
    0
}

def main() -> long {
    let args = argv();
    let path = "input.txt";
    let want_check = false;
    let want_bench = false;
    let have_path = false;
    let i = 1;
    while (i < len(args)) {
        let a = args[i];
        if (a == "--check") {
            want_check = true;
        } else if (a == "--bench") {
            want_bench = true;
        } else if (a == "--help" || a == "-h") {
            print(HELP);
            return 0;
        } else if (a == "--input") {
            if (i + 1 >= len(args)) {
                eputs("day06: --input needs a file name\n");
                return 1;
            };
            i = i + 1;
            path = args[i];
            have_path = true;
        } else if (a.starts_with("--")) {
            eputs("day06: unknown option " + a + " (try --help)\n");
            return 1;
        } else if (have_path) {
            eputs("day06: more than one input file given (try --help)\n");
            return 1;
        } else {
            path = a;
            have_path = true;
        };
        i = i + 1;
    };

    if (want_check) {
        return run_check();
    };
    if (want_bench) {
        return bench(path);
    };
    solve(path)
};
exit(main())