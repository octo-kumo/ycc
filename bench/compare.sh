#!/bin/bash
# bench/compare.sh BASE_YCC NEW_YCC [runs] — score two ycc builds against
# each other, e.g. another base against the current tree:
#
#     make ycc && cp ycc /tmp/ycc-base     # on the base
#     git switch - && make ycc             # back on the change
#     bench/compare.sh /tmp/ycc-base ./ycc
#
# Every metric is lower-is-better. Each time is the median of [runs] (5)
# runs per build or more, the two builds run in pairs (see below). The
# SCORE is 100 x the geometric mean of base/new over every (benchmark,
# metric) pair of compile time, run time and binary size: 100 = no change,
# 105 = 5% better overall. The table above it is the detail behind the
# number — it also carries asm_bytes, asm_lines and heap_kb, which are
# shown for detail but are NOT part of the score.
#
# The last section compares the two builds per function: each benchmark
# built with -g and run under valgrind's callgrind (instructions executed
# per function) — that is where a regression gets explained rather than
# merely measured. It is bench/profile.sh; BENCH_PROFILE=0 leaves it out
# (`make check` runs it beside the tests instead). See bench/README.md.

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
# every compile and run below 4 GB of address space: past 4 GB this
# machine goes down (test/sh/capped.sh)
ulimit -S -v "${YMEM_CAP_KB:-3670016}" || exit 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/ybench-cmp.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
: >"$TMP/ratios.txt"   # the scored ratios; created up front so the awk below
                         # never has to read a file that does not exist yet

echo "base:  $BASE"
echo "new:   $NEW"
echo "runs:  every time from $RUNS or more pairs of runs, base and new back to back (median per side); all metrics lower-is-better"
echo

# Every time row is sampled in pairs: a run of base and a run of new back
# to back, the order flipping every pair. Load on a shared machine comes in
# bursts of seconds (other tenants, background work), and measured in
# separate passes, one side caught a burst the other missed: two runs of
# the SAME binary differed by up to 37% per row that way, still by 25%
# with ten samples per pass. Paired, a burst lands on both sides alike.
# Compiles read a copy of the sources in $TMP (under WSL a read from /mnt/c
# goes over 9P: slow, and noisy), from its root, where imports of std
# modules resolve (src/y/std/); the benchmarks run in $TMP too.
TREE="$TMP/tree"
mkdir -p "$TREE/src" "$TREE/bench" && cp -r "$ROOT/src/y" "$TREE/src/" && cp -r "$ROOT/bench/y" "$TREE/bench/" || exit 2
cd "$TREE" || exit 2

# one SIDE KIND NAME SRC — one timed run, in us, of side b (base) or n
# (new): KIND compile builds $TMP/SIDE.NAME from SRC, KIND run runs it.
one() {
    local cc="$BASE" t0 t1
    [ "$1" = n ] && cc="$NEW"
    if [ "$2" = compile ]; then
        t0=${EPOCHREALTIME/./}
        "$cc" -o "$TMP/$1.$3" "$4" </dev/null >/dev/null 2>&1 \
            || { echo "bench: $cc failed on $4" >&2; return 1; }
        t1=${EPOCHREALTIME/./}
    else
        cd "$TMP" || return 1
        t0=${EPOCHREALTIME/./}
        "./$1.$3" </dev/null >/dev/null 2>&1 \
            || { echo "bench: $3 built by $cc exited nonzero" >&2; return 1; }
        t1=${EPOCHREALTIME/./}
    fi
    echo $((t1 - t0))
}

median() {
    sort -n | awk '{ a[NR] = $1 } END { print (NR % 2) ? a[(NR + 1) / 2] : (a[NR / 2] + a[NR / 2 + 1]) / 2 }'
}

# row KIND NAME SRC — "NAME:KIND_us<TAB>base<TAB>new": the medians of RUNS
# pairs, or of more while base's runs add up to under 0.2 s (10 at most):
# the shorter a program, the noisier one run of it (see bench/README.md).
# An even number of pairs, so each side goes first equally often.
row() {
    local k=0 total=0 tb tn
    : >"$TMP/sb"
    : >"$TMP/sn"
    while [ $k -lt "$RUNS" ] || { [ $total -lt 200000 ] && [ $k -lt 10 ]; } || ((k % 2)); do
        if ((k % 2 == 0)); then
            tb=$(one b "$@") && tn=$(one n "$@") || return 1
        else
            tn=$(one n "$@") && tb=$(one b "$@") || return 1
        fi
        echo "$tb" >>"$TMP/sb"
        echo "$tn" >>"$TMP/sn"
        total=$((total + tb))
        k=$((k + 1))
    done
    printf '%s:%s_us\t%s\t%s\n' "$2" "$1" "$(median <"$TMP/sb")" "$(median <"$TMP/sn")"
}

# Keys are bench:metric — a colon, because bench names (std_io) and metric
# names (run_us) both carry underscores. Sizes do not vary: measured once.
# BENCH_SELF=0 leaves out compiling the compiler (the `self` rows).
progs=("$TREE"/bench/y/*.y)
[ "${BENCH_SELF:-1}" = 0 ] || progs+=("$TREE/src/y/ycc.y")
J="$TMP/joined"
: >"$J"
for src in "${progs[@]}"; do
    name="$(basename "$src" .y)"
    [ "$src" = "$TREE/src/y/ycc.y" ] && name=self
    if ! row compile "$name" "$src" >>"$J"; then
        # a program only the base cannot build (the language changed
        # under it -- the new compiler's own source, say) has no rows;
        # one the new build cannot build is a failure
        if "$NEW" -o "$TMP/probe" "$src" </dev/null >/dev/null 2>&1; then
            echo "bench: $name: no rows, the base cannot build it (the new build can)" >&2
            continue
        fi
        exit 1
    fi
    "$BASE" -S "$src" </dev/null >"$TMP/b.s" 2>/dev/null
    "$NEW" -S "$src" </dev/null >"$TMP/n.s" 2>/dev/null
    {
        printf '%s:binary_bytes\t%s\t%s\n' "$name" "$(wc -c <"$TMP/b.$name")" "$(wc -c <"$TMP/n.$name")"
        printf '%s:asm_bytes\t%s\t%s\n' "$name" "$(wc -c <"$TMP/b.s")" "$(wc -c <"$TMP/n.s")"
    } >>"$J"
    if [ "$name" = self ]; then
        # heap: the arena high water of a whole compile, from --time's report
        hb="$("$BASE" --time -o "$TMP/b.self" "$src" </dev/null 2>&1 | awk '/TOTAL/ { print $4 }')"
        hn="$("$NEW" --time -o "$TMP/n.self" "$src" </dev/null 2>&1 | awk '/TOTAL/ { print $4 }')"
        {
            printf 'self:asm_lines\t%s\t%s\n' "$(wc -l <"$TMP/b.s")" "$(wc -l <"$TMP/n.s")"
            printf 'self:heap_kb\t%s\t%s\n' "$hb" "$hn"
        } >>"$J"
    else
        row run "$name" "$src" >>"$J" || exit 1
    fi
done
sort -t $'\t' -k1,1 "$J" -o "$J"

# ── the table and the score ────────────────────────────────────────────
awk -F '\t' '
    function fmt(v) { return (v >= 100000) ? sprintf("%d", v) : sprintf("%.1f", v) }
    {
        split($1, km, ":"); bench = km[1]; metric = km[2];
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

# ── per-function profiles: bench/profile.sh ─────────────────────────────
if [ "${BENCH_PROFILE:-1}" != 0 ]; then
    echo
    "$ROOT/bench/profile.sh" "$BASE" "$NEW"
fi
