#!/bin/bash
# bench/run.sh YCC [runs] — benchmark ONE ycc build. Prints one metric per
# line on stdout, tab separated, so bench/compare.sh can diff two runs:
#
#   <bench> <metric> <value>
#
# where <bench> is a file stem from bench/y/ (or "self" for compiling the
# compiler's own source) and metric is one of:
#   compile_us    wall time to compile the benchmark, median of [runs]
#   run_us        wall time to run the produced binary, median of [runs]
#   binary_bytes  size of the produced executable
#   asm_bytes     size of `ycc -S` output
#   heap_kb       arena high water of the compile (--time, self only)
#   asm_lines     lines of `ycc -S` output (self only)
#
# These programs are benchmarks, not tests: nothing under bench/ runs in
# the test suites. See bench/README.md.

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

now_us() { echo $(( $(date +%s%N) / 1000 )); }

median() {
    sort -n | awk '{ a[NR] = $1 } END {
        if (NR == 0) { print 0 }
        else if (NR % 2) { print a[(NR + 1) / 2] }
        else { print (a[NR / 2] + a[NR / 2 + 1]) / 2 }
    }'
}

# compile_us SOURCE OUTBIN
compile_us() {
    local t0 t1
    for ((i = 0; i < RUNS; i++)); do
        t0=$(now_us)
        if ! "$YCC" -o "$2" "$1" </dev/null >/dev/null 2>&1; then
            echo "bench: ycc failed on $1" >&2
            exit 1
        fi
        t1=$(now_us)
        echo $((t1 - t0))
    done | median
}

# run_us BIN
run_us() {
    local t0 t1
    for ((i = 0; i < RUNS; i++)); do
        t0=$(now_us)
        if ! "$1" </dev/null >/dev/null 2>&1; then
            echo "bench: $1 exited nonzero" >&2
            exit 1
        fi
        t1=$(now_us)
        echo $((t1 - t0))
    done | median
}

bench_one() {
    local name="$1" src="$2"
    local bin="$TMP/$name"
    echo -e "$name\tcompile_us\t$(compile_us "$src" "$bin")"
    echo -e "$name\tbinary_bytes\t$(wc -c <"$bin" | tr -d ' ')"
    echo -e "$name\tasm_bytes\t$("$YCC" -S "$src" </dev/null 2>/dev/null | wc -c | tr -d ' ')"
    echo -e "$name\trun_us\t$(run_us "$bin")"
}

for src in "$ROOT"/bench/y/*.y; do
    bench_one "$(basename "$src" .y)" "$src"
done

# The compiler benchmark: ycc compiling its own source (the workload that
# dominates development time). Heap and asm size come from --time's report.
src="$ROOT/src/y/ycc.y"
bin="$TMP/self"
echo -e "self\tcompile_us\t$(compile_us "$src" "$bin")"
echo -e "self\tbinary_bytes\t$(wc -c <"$bin" | tr -d ' ')"
asm="$("$YCC" -S "$src" </dev/null 2>/dev/null)"
echo -e "self\tasm_bytes\t$(printf '%s' "$asm" | wc -c | tr -d ' ')"
echo -e "self\tasm_lines\t$(printf '%s' "$asm" | wc -l | tr -d ' ')"
tm="$("$YCC" --time -o "$bin" "$src" </dev/null 2>&1)"
echo -e "self\theap_kb\t$(printf '%s\n' "$tm" | awk '/TOTAL/ { print $4 }')"
