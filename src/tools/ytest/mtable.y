// mtable.y -- test/math/ulp_table.txt against the correctly rounded references
// (mref.y), and new rows for it.
//
//   ytest math-table                  every row's answer against mref, per function
//   ytest math-table update           ... and rewrite the rows that disagree
//   ytest math-table row FN A [B [C]] one new row, the answer computed here
//
// The table is the checked-in gate (ulp_check.y measures std/math.y against
// it at tolerance 1); its answers came from the platform libm and from 60-digit
// Decimal references. This asks whether each answer IS the correctly rounded
// one, so a reference that was wrong -- six of them have been, and every one
// read as coverage -- shows up as a row that disagrees, with its gap, instead of
// certifying a defect. A disagreement is reported, not fixed: decide which side
// is right, then change the row.
//
// Every double on a row is its IEEE-754 bit pattern in decimal.
import math;
import yt;
import yc;
import mref;
import mstatic;

def path() -> str { yc.ROOT + "/test/math/ulp_table.txt" };

def ref_of(f: [str]) -> [float] {
    let name = f[0];
    let a = math.bitsf(yt.num(f[1], 0));
    if (f.length == 3) { return mref.one_arg(name, a); };
    let b = math.bitsf(yt.num(f[2], 0));
    if (f.length == 4) { return mref.two_arg(name, a, b); };
    if (name == "lerp") { return [mref.lerp(a, b, math.bitsf(yt.num(f[3], 0)))]; };
    []
};

// a row's answer field for the reference value r
def answer(name: str, r: float) -> str {
    if (name == "to_int" && !math.is_nan(r)) { tostring(math.to_int(r)) } else { tostring(math.fbits(r)) }
};

def check(update: bool) -> long {
    let out: [str] = [];
    let names: [str] = [];
    let rows: {str => long} = {};
    let bad: {str => long} = {};
    let worst: {str => long} = {};
    let first: {str => str} = {};
    let none: [str] = [];
    let n = 0;
    foreach (l in yt.lines(yt.read(path()))) {
        let keep = l;
        if (l != "" && !l.starts_with("#")) {
            let f = yt.words(l);
            let r = ref_of(f);
            if (r.length == 0) {
                if (!(f[0] in none)) { none += f[0]; };
            } else {
                if (!(f[0] in rows)) {
                    names += f[0];
                    rows[f[0]] = 0;
                    bad[f[0]] = 0;
                    worst[f[0]] = 0;
                };
                rows[f[0]] = rows[f[0]]! + 1;
                n += 1;
                // to_int's answer is the long itself, not a pattern
                let wl = yt.num(f[f.length - 1], 0);
                let want = if (f[0] == "to_int") { if (math.is_nan(r[0])) { r[0] } else { let w: float = wl; w + 0.0 } } else { math.bitsf(wl) };
                if (f[0] == "to_int" && r[0] == 0.0) { r[0] = 0.0; };
                let g = mref.gap(want, r[0]);
                if (g > 0) {
                    keep = join(f[:f.length - 1], " ") + " " + answer(f[0], r[0]);
                    bad[f[0]] = bad[f[0]]! + 1;
                    if (g > worst[f[0]]!) { worst[f[0]] = g; };
                    if (!(f[0] in first)) {
                        first[f[0]] = "row '" + l + "': the table says " + tostring(want) + ", the reference "
                            + tostring(r[0]) + " (" + tostring(math.fbits(r[0])) + ")";
                    };
                };
            };
        };
        out += keep;
    };
    if (update) { yt.write(path(), join(out, "\n") + "\n"); };
    let total_bad = 0;
    print("  " + tostring(n) + " rows against the correctly rounded references (mref.y)");
    print("  function      rows  disagree  worst ulp");
    foreach (k in names.sorted((a: str, b: str) => if (a < b) { -1 } else if (a > b) { 1 } else { 0 })) {
        total_bad += bad[k]!;
        print("  " + k.pad_right(12) + tostring(rows[k]!).pad_left(6) + tostring(bad[k]!).pad_left(10)
            + tostring(worst[k]!).pad_left(11));
    };
    if (none.length > 0) { print("  no reference here for: " + join(none, ", ")); };
    if (total_bad == 0) {
        print("  EVERY ROW IS CORRECTLY ROUNDED");
        return 0;
    };
    if (update) { print("  rewrote " + tostring(total_bad) + " rows of " + path()); };
    print("\n  FIRST DISAGREEMENT PER FUNCTION:");
    foreach (k in names) {
        if (k in first) { print("    " + k + ": " + first[k]!); };
    };
    1
};

def row(av: [str]) -> long {
    if (av.length < 2) {
        eputs("usage: ytest math-table row FN A [B [C]]   (the arguments as decimal doubles)\n");
        return 2;
    };
    let f = [av[0]];
    foreach (a in av[1:]) {
        let v = if (a == "nan") { mref.nan() } else if (a == "inf") { math.inf } else if (a == "-inf") { 0.0 - math.inf }
            else { mstatic.parse_float(a) };
        f += tostring(math.fbits(v));
    };
    let r = ref_of(f + "0");
    if (r.length == 0) {
        eputs("math-table: no reference for " + av[0] + "\n");
        return 2;
    };
    print(join(f, " ") + " " + tostring(math.fbits(r[0])));
    0
};

def main(av: [str]) -> long {
    if (av.length > 0 && av[0] == "row") { row(av[1:]) } else { check(av.length > 0 && av[0] == "update") }
};

export { main, check };
