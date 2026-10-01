#!/bin/bash
# bench/compare.sh BASE_YCC NEW_YCC [runs] — score two ycc builds against
# each other, e.g. two branches:
#
#     make ycc && cp ycc /tmp/ycc-base     # on the base branch
#     git switch my-change && make ycc     # on the proposal branch
#     bench/compare.sh /tmp/ycc-base ./ycc
#
# Every metric is lower-is-better. The SCORE is 100 x the geometric mean
# of base/new over every (benchmark, metric) pair of compile time, run time
# and binary size: 100 = no change, 105 = 5% better overall. The table
# above it is the detail behind the number — it also carries asm_bytes and
# asm_lines, which are shown for detail but are NOT part of the score.
#
# The last section compares the two builds per function: each benchmark
# built with -g and run under valgrind's callgrind (instructions executed
# per function) — that is where a regression gets explained rather than
# merely measured. See bench/README.md.

set -u
if [ $# -lt 2 ]; then
    echo "usage: bench/compare.sh BASE_YCC NEW_YCC [runs]" >&2
    exit 2
fi
BASE="$(readlink -f "$1")"
NEW="$(readlink -f "$2")"
RUNS="${3:-5}"
[ -x "$BASE" ] || { echo "bench: $BASE is not an executable" >&2; exit 2; }
[ -x "$NEW" ] || { echo "bench: $NEW is not an executable" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/ybench-cmp.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/ratios.txt"   # the scored ratios; created up front so the awk below
                         # never has to read a file that does not exist yet

echo "base:  $BASE"
echo "new:   $NEW"
echo "runs:  $RUNS rounds, base and new interleaved (median per metric), all metrics lower-is-better"
echo

# The two sides take turns, one sample of every metric per turn, and the
# order flips every round (base-new, new-base, ...). Machine load drifts
# (other tenants, background work), and run back to back, whichever side
# went second absorbed all of it: two runs of the SAME binary differed by
# up to 37% per row that way, the second slower on 10 of 14 time rows.
: >"$TMP/base.tsv"
: >"$TMP/new.tsv"
for ((r = 0; r < RUNS; r++)); do
    if ((r % 2 == 0)); then
        "$ROOT/bench/run.sh" "$BASE" 1 >>"$TMP/base.tsv" || exit 1
        "$ROOT/bench/run.sh" "$NEW" 1 >>"$TMP/new.tsv" || exit 1
    else
        "$ROOT/bench/run.sh" "$NEW" 1 >>"$TMP/new.tsv" || exit 1
        "$ROOT/bench/run.sh" "$BASE" 1 >>"$TMP/base.tsv" || exit 1
    fi
done

# ── scalar metrics: one row per (benchmark, metric) ────────────────────
# medians <tsv> — "bench_metric<TAB>median over the rounds", sorted for
# join. Bench names carry no underscores, so `bench_metric` splits back
# cleanly at the first underscore.
medians() {
    awk -F '\t' '{ print $1 "_" $2 "\t" $3 }' "$1" | sort -t $'\t' -k1,1 -k2,2n | awk -F '\t' '
        function flush() {
            if (n) print key "\t" ((n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2);
        }
        $1 != key { flush(); key = $1; n = 0 }
        { v[++n] = $2 }
        END { flush() }'
}
medians "$TMP/base.tsv" >"$TMP/base.k"
medians "$TMP/new.tsv" >"$TMP/new.k"
join -t $'\t' "$TMP/base.k" "$TMP/new.k" >"$TMP/joined"

awk -F '\t' '
    function fmt(v) { return (v >= 100000) ? sprintf("%d", v) : sprintf("%.1f", v) }
    {
        split($1, km, "_"); bench = km[1];
        metric = substr($1, length(bench) + 2);
        b = $2 + 0; n = $3 + 0;
        pct = (b > 0) ? (100 * (b - n) / b) : 0;
        sign = (pct >= 0) ? "+" : "";
        printf "%-10s %-12s %14s %14s   %s%5.1f%%\n", bench, metric, fmt(b), fmt(n), sign, pct;
        if (metric == "compile_us" || metric == "run_us" || metric == "binary_bytes") {
            print (n > 0 ? b / n : 1) >> ratios;
        }
    }
' ratios="$TMP/ratios.txt" "$TMP/joined"

echo
SCORE=$(awk '{ s += log($1); n++ } END { if (n) printf "%.2f", 100 * exp(s / n); else print "100.00" }' "$TMP/ratios.txt")
echo "SCORE: $SCORE   (100 = base, >100 = the new build is better overall)"

# ── per-function profiles ──────────────────────────────────────────────
# Each benchmark is built with -g on both sides and run once under
# valgrind's callgrind: instructions executed per function (self Ir).
# Counts are exact and repeatable where times are noisy, so this is where
# a regression gets explained rather than merely measured. Joined by
# function name, worst first; `-` = absent on that side (inlined, renamed,
# or a build without -g).
echo
if ! command -v valgrind >/dev/null 2>&1 || ! command -v callgrind_annotate >/dev/null 2>&1; then
    echo "per-function profile: skipped (needs valgrind and callgrind_annotate)"
    exit 0
fi

# ir_table <callgrind.out> — "function<TAB>Ir" lines, plus "TOTAL<TAB>Ir".
# A row is "1,234 ( 5.67%)  file:function [object]"; recursion levels
# (callgrind's name'2) fold into their function.
ir_table() {
    callgrind_annotate --threshold=100 "$1" 2>/dev/null | awk -v q="'" '
        /^ *[0-9,]+ +\( *[0-9.]+%\)/ {
            ir = $1; gsub(/,/, "", ir);
            fn = $0;
            sub(/^ *[0-9,]+ +\( *[0-9.]+%\) +/, "", fn);
            sub(/ +\[[^]]*\] *$/, "", fn);
            if (fn == "PROGRAM TOTALS") { fn = "TOTAL" }
            else { sub(/^[^:]*:/, "", fn); sub(q "[0-9]+$", "", fn); gsub(/ /, "_", fn) }
            sum[fn] += ir;
        }
        END { for (f in sum) printf "%s\t%.0f\n", f, sum[f] }'
}

echo "per-function profile (instructions executed, self; callgrind on -g builds):"
for src in "$ROOT"/bench/y/*.y; do
    name="$(basename "$src" .y)"
    for side in b n; do
        cc="$NEW"
        [ "$side" = b ] && cc="$BASE"
        : >"$TMP/$side.$name.ir"
        "$cc" -g -o "$TMP/$side.$name" "$src" </dev/null >/dev/null 2>&1 || continue
        valgrind --tool=callgrind --show-below-main=yes --callgrind-out-file="$TMP/$side.$name.cg" \
            "$TMP/$side.$name" </dev/null >/dev/null 2>&1
        ir_table "$TMP/$side.$name.cg" >"$TMP/$side.$name.ir"
    done
    echo
    awk -F '\t' -v name="$name" '
        FILENAME == ARGV[1] { b[$1] = $2; next }
        { n[$1] = $2 }
        END {
            bt = ("TOTAL" in b) ? b["TOTAL"] : "-"; nt = ("TOTAL" in n) ? n["TOTAL"] : "-";
            d = (bt != "-" && nt != "-" && bt > 0) ? sprintf("  %+.2f%%", 100 * (nt - bt) / bt) : "";
            printf "--- %s   total Ir: base %s, new %s%s\n", name, bt, nt, d;
        }' "$TMP/b.$name.ir" "$TMP/n.$name.ir"
    printf "  %-20s %14s %14s %10s\n" "function" "Ir_base" "Ir_new" "delta"
    awk -F '\t' '
        FILENAME == ARGV[1] { b[$1] = $2; seen[$1] = 1; next }
        { n[$1] = $2; seen[$1] = 1 }
        END {
            for (f in seen) {
                if (f == "TOTAL") continue;
                key = (f in b) ? b[f] : n[f];
                d = ((f in b) && (f in n) && b[f] > 0) ? sprintf("%+.1f%%", 100 * (n[f] - b[f]) / b[f]) : "n/a";
                printf "%.0f\t%s\t%s\t%s\t%s\n", key, f, (f in b) ? b[f] : "-", (f in n) ? n[f] : "-", d;
            }
        }' "$TMP/b.$name.ir" "$TMP/n.$name.ir" | sort -t $'\t' -k1,1nr | head -8 | \
    awk -F '\t' '{ printf "  %-20s %14s %14s %10s\n", $2, $3, $4, $5 }'
done
