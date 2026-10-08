#!/bin/bash
# bench/compile_ir.sh BASE_YCC NEW_YCC — the instructions each build
# executes (valgrind's cachegrind) compiling every bench/y program and the
# compiler itself. compare.sh's compile_us is wall time, with a few percent
# of noise; these counts are exact and repeatable, so they show a 0.1%
# change and belong in a commit message. A count does not depend on machine
# load, so the runs go side by side, YJOBS at a time (default: the number
# of CPUs), ycc.y (~1 min under valgrind) first. `make bench-ir`.

set -u
if [ $# -lt 2 ]; then
    echo "usage: bench/compile_ir.sh BASE_YCC NEW_YCC" >&2
    exit 2
fi
BASE="$(readlink -f "$1")"
NEW="$(readlink -f "$2")"
[ -x "$BASE" ] || { echo "bench: $BASE is not an executable" >&2; exit 2; }
[ -x "$NEW" ] || { echo "bench: $NEW is not an executable" >&2; exit 2; }
command -v valgrind >/dev/null || { echo "bench: valgrind not found" >&2; exit 2; }
# every run (valgrind and the compiler under it) below 4 GB of address
# space: past 4 GB this machine goes down (test/sh/capped.sh)
ulimit -S -v "${YMEM_CAP_KB:-3670016}" || exit 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${YJOBS:-$(nproc)}"
TMP="$(mktemp -d -t ybench-ir.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# The compiler derives std search dirs from its own path, and a count
# includes the instructions spent on them: both builds run as copies in
# one directory, under names of one length.
cp "$BASE" "$TMP/ycc_b" && cp "$NEW" "$TMP/ycc_n" || exit 2
BASE="$TMP/ycc_b"
NEW="$TMP/ycc_n"
cd "$ROOT" || exit 2   # where imports of std modules resolve (src/y/std/)

# ir <ycc> <file> <key>: <key>.ir = instructions <ycc> executes on <file>,
# or nothing when the compile fails (the report shows "-"): a compiler
# that runs out of its memory cap, or past the timeout, has no count
ir() {
    if timeout 900 valgrind --tool=cachegrind --cache-sim=no --cachegrind-out-file=/dev/null \
        "$1" -o "$TMP/$3.bin" "$2" </dev/null >"$TMP/$3.log" 2>&1; then
        awk '/I +refs:/ { gsub(/,/, "", $NF); print $NF }' "$TMP/$3.log" >"$TMP/$3.ir"
    else
        : >"$TMP/$3.ir"
    fi
    rm -f "$TMP/$3.bin" "$TMP/$3.log"
}

PROGS=("$ROOT/src/y/ycc.y" "$ROOT"/bench/y/*.y)
running=0
for i in "${!PROGS[@]}"; do
    # b and n: both builds write paths of one length (a count includes
    # the instructions spent on the path)
    for side in b n; do
        if [ $running -ge "$JOBS" ]; then
            wait -n
            running=$((running - 1))
        fi
        cc="$BASE"
        [ $side = n ] && cc="$NEW"
        ir "$cc" "${PROGS[$i]}" "$side.$i" &
        running=$((running + 1))
    done
done
wait

printf '%-14s %15s %15s %8s\n' program Ir_base Ir_new delta
for i in $(seq 1 $((${#PROGS[@]} - 1))) 0; do
    awk -v p="$(basename "${PROGS[$i]}")" -v a="$(cat "$TMP/b.$i.ir")" -v b="$(cat "$TMP/n.$i.ir")" 'BEGIN {
        if (a == "" || b == "") { printf "%-14s %15s %15s %8s\n", p, a == "" ? "-" : a, b == "" ? "-" : b, "?"; exit }
        printf "%-14s %15d %15d %+7.2f%%\n", p, a, b, (b - a) * 100.0 / a
    }'
done
