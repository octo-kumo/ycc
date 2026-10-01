#!/bin/bash
# bench/run.sh YCC [runs] — benchmark ONE ycc build. Prints one metric per
# line on stdout, tab separated, so bench/compare.sh can diff two runs:
#
#   <bench> <metric> <value>
#
# where <bench> is a file stem from bench/y/ (or "self" for compiling the
# compiler's own source) and metric is one of:
#   compile_us    wall time to compile the benchmark, median of [runs] runs
#                 (or more, see samples() below)
#   run_us        wall time to run the produced binary, likewise
#   binary_bytes  size of the produced executable
#   asm_bytes     size of `ycc -S` output
#   heap_kb       arena high water of the compile (--time, self only)
#   asm_lines     lines of `ycc -S` output (self only)
#
# These programs are benchmarks, not tests: nothing under bench/ runs in
# the test suites. See bench/README.md; bench/compare.sh measures two
# builds side by side.

set -u
if [ $# -lt 1 ]; then
    echo "usage: bench/run.sh YCC [runs]" >&2
    exit 2
fi
YCC="$(readlink -f "$1")"
RUNS="${2:-5}"
[ -x "$YCC" ] || { echo "bench: $YCC is not an executable" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d /tmp/ybench.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

median() {
    sort -n | awk '{ a[NR] = $1 } END {
        if (NR == 0) { print 0 }
        else if (NR % 2) { print a[(NR + 1) / 2] }
        else { print (a[NR / 2] + a[NR / 2 + 1]) / 2 }
    }'
}

# samples CMD...: the wall times of CMD in us, one per line — RUNS runs,
# and more while they add up to under 0.2 s (10 at most). One run of a
# 20 ms program swings by 20% on a busy machine; the median of ten by a
# few percent. Fails if CMD does.
samples() {
    local t0 t1 n=0 total=0
    while [ $n -lt "$RUNS" ] || { [ $total -lt 200000 ] && [ $n -lt 10 ]; }; do
        t0=${EPOCHREALTIME/./}
        "$@" </dev/null >/dev/null 2>&1 || return 1
        t1=${EPOCHREALTIME/./}
        echo $((t1 - t0))
        total=$((total + t1 - t0))
        n=$((n + 1))
    done
}

# compile_us SOURCE OUTBIN
compile_us() {
    local t
    t=$(samples "$YCC" -o "$2" "$1") || { echo "bench: ycc failed on $1" >&2; return 1; }
    printf '%s\n' "$t" | median
}

# run_us BIN
run_us() {
    local t
    t=$(samples "$1") || { echo "bench: $1 exited nonzero" >&2; return 1; }
    printf '%s\n' "$t" | median
}

# (an `exit` inside $(...) would leave only the subshell: failures return)
bench_one() {
    local name="$1" src="$2" t
    local bin="$TMP/$name"
    t=$(compile_us "$src" "$bin") || exit 1
    echo -e "$name\tcompile_us\t$t"
    echo -e "$name\tbinary_bytes\t$(wc -c <"$bin" | tr -d ' ')"
    echo -e "$name\tasm_bytes\t$("$YCC" -S "$src" </dev/null 2>/dev/null | wc -c | tr -d ' ')"
    t=$(run_us "$bin") || exit 1
    echo -e "$name\trun_us\t$t"
}

for src in "$ROOT"/bench/y/*.y; do
    bench_one "$(basename "$src" .y)" "$src"
done

# BENCH_SELF=0 skips the self-compile rows (for a base build that cannot
# finish compiling the current sources at all, e.g. one that runs out of
# memory there); compare.sh then scores the bench/y/ programs only.
[ "${BENCH_SELF:-1}" = "0" ] && exit 0

# The compiler benchmark: ycc compiling its own source (the workload that
# dominates development time). Heap and asm size come from --time's report.
src="$ROOT/src/y/ycc.y"
bin="$TMP/self"
t=$(compile_us "$src" "$bin") || exit 1
echo -e "self\tcompile_us\t$t"
echo -e "self\tbinary_bytes\t$(wc -c <"$bin" | tr -d ' ')"
asm="$("$YCC" -S "$src" </dev/null 2>/dev/null)"
echo -e "self\tasm_bytes\t$(printf '%s' "$asm" | wc -c | tr -d ' ')"
echo -e "self\tasm_lines\t$(printf '%s' "$asm" | wc -l | tr -d ' ')"
tm="$("$YCC" --time -o "$bin" "$src" </dev/null 2>&1)"
echo -e "self\theap_kb\t$(printf '%s\n' "$tm" | awk '/TOTAL/ { print $4 }')"
