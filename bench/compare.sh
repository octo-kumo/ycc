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
# above it is the detail behind the number.
#
# The last section compares the two builds' --prof reports function by
# function (self cpu ns and call counts) — that is where a regression gets
# explained rather than merely measured. See bench/README.md.

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

echo "base:  $BASE"
echo "new:   $NEW"
echo "runs:  $RUNS per metric (median), all metrics lower-is-better"
echo

"$ROOT/bench/run.sh" "$BASE" "$RUNS" >"$TMP/base.tsv" || exit 1
"$ROOT/bench/run.sh" "$NEW" "$RUNS" >"$TMP/new.tsv" || exit 1

# ── scalar metrics: one row per (benchmark, metric) ────────────────────
# join wants a single sorted key, and bench names carry no underscores,
# so `bench_metric` splits back cleanly at the first underscore.
awk -F '\t' '{ print $1 "_" $2 "\t" $3 }' "$TMP/base.tsv" | sort >"$TMP/base.k"
awk -F '\t' '{ print $1 "_" $2 "\t" $3 }' "$TMP/new.tsv" | sort >"$TMP/new.k"
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
# Compiled with --prof on both sides; joined by function name, worst-first
# by the base self time. Call counts should match exactly between builds
# (same program) — if they do not, the two builds are not comparable.
echo
echo "per-function profile (self cpu ns / calls, --prof):"
for src in "$ROOT"/bench/y/*.y; do
    name="$(basename "$src" .y)"
    "$BASE" --prof -o "$TMP/b.$name" "$src" </dev/null >/dev/null 2>"$TMP/b.$name.prof" || continue
    "$TMP/b.$name" </dev/null >/dev/null 2>>"$TMP/b.$name.prof"
    "$NEW" --prof -o "$TMP/n.$name" "$src" </dev/null >/dev/null 2>"$TMP/n.$name.prof" || continue
    "$TMP/n.$name" </dev/null >/dev/null 2>>"$TMP/n.$name.prof"
    echo
    echo "--- $name"
    printf "  %-16s %12s %12s %10s %14s %14s\n" "function" "self_base" "self_new" "delta" "calls_base" "calls_new"
    awk '
        FNR == NR && $1 ~ /^[0-9]+$/ { bs[$6] = $3; bc[$6] = $1; if (!($6 in seen)) { seen[$6] = 1; order[++k] = $6 }; next }
        FNR != NR && $1 ~ /^[0-9]+$/ { ns[$6] = $3; nc[$6] = $1; if (!($6 in seen)) { seen[$6] = 1; order[++k] = $6 }; next }
        END {
            for (i = 1; i <= k; i++) {
                nm = order[i];
                printf "%d %s %d %d %d\n", bs[nm] + 0, nm, ns[nm] + 0, bc[nm] + 0, nc[nm] + 0;
            }
        }
    ' "$TMP/b.$name.prof" "$TMP/n.$name.prof" | sort -rn | head -8 | \
    awk '{ printf "  %-16s %12d %12d %10s %14d %14d\n", $2, $1, $3, ($1 > 0 ? sprintf("%+.1f%%", 100 * ($3 - $1) / $1) : "n/a"), $4, $5 }'
    awk '/^prof: / { print "  " $0 }' "$TMP/b.$name.prof"
done
