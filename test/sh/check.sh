#!/bin/bash
# test/sh/check.sh BASE NEW [ROUNDS] — `make check`: everything a compiler
# change needs before it is blessed, in one command and a few minutes. NEW
# is the change (make passes ./ynew: src/y built by the blessed compiler and
# already checked to rebuild itself), BASE what it is measured against
# (make's default: refs/ycc.ref, the last blessed compiler).
#
#  1. verify   ./cycc must build NEW from src/y/ycc.y byte for byte (the C
#              copy has the change too), then every suite runs with NEW as
#              both the reference and the built compiler, side by side
#              (run_all.sh -j). Meanwhile what is counted, not timed: the
#              instructions each build executes compiling the benchmarks
#              and ycc.y (bench/compile_ir.sh) and running each benchmark,
#              per function (bench/profile.sh).
#  2. compare  every test program compiled by both (corpus_diff.sh): which
#              compile to different code, which behave differently; then
#              the counts.
#  3. time     the benchmarks (bench/compare.sh: ROUNDS pairs of runs per
#              row at least, default 3) once nothing else runs: the SCORE,
#              every size that changed, every time of 40 ms or more that
#              moved 10% (a shorter one is noise; its count is step 2's).
#
# Each step prints its result as it ends; the full output of each is in
# _check/. Exit 1 when a verification fails (nothing is compared or timed
# then). Changes of behavior are listed, not fatal: the fixtures decide
# what is right, and an intended change shows here until it is blessed.

set -u
# Everything below runs under an address-space cap below 4 GB (lib.sh,
# test/sh/capped.sh): past 4 GB this machine goes down.
ulimit -S -v "${YMEM_CAP_KB:-3670016}" || exit 2
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
if [ $# -lt 2 ]; then
    echo "usage: test/sh/check.sh BASE NEW [ROUNDS]" >&2
    exit 2
fi
BASE_NAME="$1"
NEW_NAME="$2"
ROUNDS="${3:-3}"
JOBS="${YJOBS:-$(nproc)}"
# The counted jobs take a fifth of the CPUs each, the suites the rest.
CJOBS=$((JOBS / 5))
[ $CJOBS -ge 1 ] || CJOBS=1
SJOBS=$((JOBS - 2 * CJOBS))
[ $SJOBS -ge 1 ] || SJOBS=1

LOG="$ROOT/_check"
rm -rf "$LOG"
mkdir -p "$LOG"
T="$(mktemp -d /tmp/ycheck.XXXXXX)"
kill_tree() {
    local c
    for c in $(pgrep -P "$1"); do kill_tree "$c"; done
    kill "$1" 2>/dev/null
}
cleanup() {
    local j
    for j in $(jobs -p); do kill_tree "$j"; done
    rm -rf "$T"
}
trap cleanup EXIT
# Every compiler runs from a copy under /tmp: under WSL a binary on /mnt/c
# pages in through drvfs, ~30% slower; and a rebuild cannot change it mid-run.
# The std modules go along: a program outside the checkout (test_pkg.sh's
# projects) finds `import struct;` next to the compiler (std_resolve).
cp "$BASE_NAME" "$T/base" && cp "$NEW_NAME" "$T/new" && cp "${CYCC:-$ROOT/cycc}" "$T/cycc" || exit 2
cp -R "$ROOT/src/y/std" "$T/std" || exit 2
cd "$ROOT" || exit 2

START=$(date +%s)
since() {
    local s=$(( $(date +%s) - $1 ))
    printf '%dm%02ds' $((s / 60)) $((s % 60))
}
indent() { sed 's/\x1b\[[0-9;]*m//g; s/^/    /'; }

echo "check: new $NEW_NAME, base $BASE_NAME (full output: _check/)"

# ── 1. verify ──────────────────────────────────────────────────────────
echo
echo "== 1/3 verify"
t=$(date +%s)
# alone: cycc needs ~1.9 GB for the compiler, the rest of the check < 3 GB.
# NEW carries its std pack (the Makefile's PACK), so the build gets its own.
if (ulimit -v 3670016; "$T/cycc" -o "$T/self" "$ROOT/src/y/ycc.y" </dev/null) >"$LOG/self.log" 2>&1 \
    && "$T/self" --std-pack "$T/self.pack" >>"$LOG/self.log" 2>&1 \
    && cat "$T/self" "$T/self.pack" >"$T/selfp" \
    && cmp "$T/selfp" "$T/new" >>"$LOG/self.log" 2>&1; then
    echo "  ok      cycc builds $NEW_NAME from src/y/ycc.y, byte for byte ($(since $t))"
else
    echo "  FAILED  cycc does not build $NEW_NAME from src/y/ycc.y (_check/self.log):"
    tail -5 "$LOG/self.log" | indent
    exit 1
fi

YJOBS=$CJOBS "$ROOT/bench/compile_ir.sh" "$T/base" "$T/new" >"$LOG/compile_ir.log" 2>&1 &
IR=$!
YJOBS=$CJOBS "$ROOT/bench/profile.sh" "$T/base" "$T/new" >"$LOG/profile.log" 2>&1 &
PROF=$!

t=$(date +%s)
# the port gate on ycc.y was the step above (YPORT_SELF=0)
YREF="$T/new" YCC="$T/new" YSELF="$T/new" CYCC="$T/cycc" YQUIET=1 YPORT_SELF=0 \
    "$ROOT/test/sh/run_all.sh" -j "$SJOBS" >"$LOG/tests.log" 2>&1
if [ $? -eq 0 ]; then
    echo "  ok      every suite passes with $NEW_NAME as the reference and the built compiler ($(since $t))"
else
    echo "  FAILED  $(grep -a 'SOME SUITES FAILED' "$LOG/tests.log" | sed 's/^# //') ($(since $t), _check/tests.log):"
    grep -a 'FAIL' "$LOG/tests.log" | grep -av '^#' | head -30 | indent
    exit 1
fi

# ── 2. compare ─────────────────────────────────────────────────────────
echo
echo "== 2/3 compare with $BASE_NAME"
t=$(date +%s)
YJOBS=$SJOBS "$ROOT/test/sh/corpus_diff.sh" "$T/base" "$T/new" >"$LOG/corpus.log" 2>&1
echo "  $(tail -1 "$LOG/corpus.log") ($(since $t), _check/corpus.log)"
# behavior first: those need a look (an intended one, a fixture)
grep -a -E '^DIFF (behavior|compile)' "$LOG/corpus.log" | head -20 | indent
grep -a '^DIFF code' "$LOG/corpus.log" | head -10 | indent
shown=$(grep -a -E '^DIFF (behavior|compile)' "$LOG/corpus.log" | head -20 | wc -l)
shown=$((shown + $(grep -a '^DIFF code' "$LOG/corpus.log" | head -10 | wc -l)))
total=$(grep -a -c '^DIFF' "$LOG/corpus.log")
[ "$total" -le "$shown" ] || echo "    ... and $((total - shown)) more"

wait $IR
wait $PROF
echo
echo "  instructions executed compiling (bench/compile_ir.sh; + = more):"
indent <"$LOG/compile_ir.log"
echo
echo "  instructions executed running (bench/profile.sh; per function: _check/profile.log):"
if grep -q '^--- ' "$LOG/profile.log"; then
    printf '    %-14s %15s %15s %8s\n' program Ir_base Ir_new delta
    awk '/^--- / { b = $6; sub(/,$/, "", b); printf "    %-14s %15s %15s %8s\n", $2 ".y", b, $8, ($9 == "" ? "?" : $9) }' "$LOG/profile.log"
else
    indent <"$LOG/profile.log"
fi

# ── 3. time ────────────────────────────────────────────────────────────
echo
echo "== 3/3 time (bench/compare.sh: $ROUNDS or more pairs of runs per row)"
t=$(date +%s)
if ! BENCH_PROFILE=0 "$ROOT/bench/compare.sh" "$T/base" "$T/new" "$ROUNDS" >"$LOG/timing.log" 2>&1; then
    echo "  FAILED  a benchmark does not build or run (_check/timing.log):"
    tail -5 "$LOG/timing.log" | indent
    exit 1
fi
grep -a '^SCORE' "$LOG/timing.log" | indent
grep -a 'no rows, the base cannot build it' "$LOG/timing.log" | sed 's/^bench: /  /'
# Sizes are exact. A time is wall clock on a shared machine: the score
# holds to about ±2.5, a row of 40 ms or more to under 10%, but a shorter
# one swings by 20% and more between two runs of the same build (process
# start, which core it lands on). So only a long row that moved 10% or
# more is shown (a large loss in one benchmark barely moves the score);
# what a short one costs is its instruction count, in step 2.
awk '
    NF >= 5 && $NF ~ /%$/ && $3 ~ /^[0-9.]+$/ && $4 ~ /^[0-9.]+$/ {
        b = $3 + 0; n = $4 + 0;
        d = (b > 0) ? 100 * (n - b) / b : 0;
        if ($2 ~ /_us$/ ? (b >= 40000 && (d >= 10 || d <= -10)) : (b != n)) {
            if (!shown++) print "  rows that moved (+ = more; sizes: any change, times of 40 ms or more: 10% or more):";
            printf "    %-10s %-12s %14s %14s   %+6.2f%%\n", $1, $2, $3, $4, d;
        }
    }
    END { if (!shown) print "  no size changed, no time of 40 ms or more moved by 10% or more" }' "$LOG/timing.log"
echo "  every row: _check/timing.log ($(since $t))"

echo
echo "check passed in $(since $START). \`make rebless\` makes $NEW_NAME the reference."
