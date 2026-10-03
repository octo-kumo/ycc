#!/bin/bash
# bench/profile.sh BASE_YCC NEW_YCC — where each benchmark's run time goes
# under the two builds. Every bench/y program is built with -g by both and
# run once under valgrind's callgrind: instructions executed per function
# (self Ir). Counts are exact and repeatable where times are noisy, so this
# is where a regression gets explained rather than merely measured. Joined
# by function name, worst first; `-` = absent on that side (inlined,
# renamed, or a build without -g). The last section of bench/compare.sh,
# and a step of `make check`. A count does not depend on machine load, so
# the runs go side by side, YJOBS at a time (default: the number of CPUs).

set -u
if [ $# -lt 2 ]; then
    echo "usage: bench/profile.sh BASE_YCC NEW_YCC" >&2
    exit 2
fi
BASE="$(readlink -f "$1")"
NEW="$(readlink -f "$2")"
[ -x "$BASE" ] || { echo "bench: $BASE is not an executable" >&2; exit 2; }
[ -x "$NEW" ] || { echo "bench: $NEW is not an executable" >&2; exit 2; }
if ! command -v valgrind >/dev/null 2>&1 || ! command -v callgrind_annotate >/dev/null 2>&1; then
    echo "per-function profile: skipped (needs valgrind and callgrind_annotate)"
    exit 0
fi
# every run (valgrind and the program under it) below 4 GB of address
# space: past 4 GB this machine goes down (test/sh/capped.sh)
ulimit -S -v "${YMEM_CAP_KB:-3670016}" || exit 2
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${YJOBS:-$(nproc)}"
TMP="$(mktemp -d /tmp/ybench-prof.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
cd "$ROOT" || exit 2   # where imports of std modules resolve (src/y/std/)

# ir_table <callgrind.out> — "function<TAB>Ir" lines, plus "TOTAL<TAB>Ir".
# A row is "1,234 ( 5.67%)  file:function [object]"; recursion levels
# (callgrind's name'2) fold into their function. --auto=no: a -g build has
# line info, and annotated source lines would look like rows.
ir_table() {
    callgrind_annotate --threshold=100 --auto=no "$1" 2>/dev/null | awk -v q="'" '
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

# prof <ycc> <src> <key>: <key>.ir = the function table of <src> built by
# <ycc>, run in a directory of its own (a benchmark may write files there)
prof() {
    : >"$TMP/$3.ir"
    mkdir "$TMP/$3.d"
    timeout 300 "$1" -g -o "$TMP/$3.d/bin" "$2" </dev/null >/dev/null 2>&1 || return
    (cd "$TMP/$3.d" && timeout 900 valgrind --tool=callgrind --show-below-main=yes --callgrind-out-file=cg.out \
        ./bin </dev/null >/dev/null 2>&1)
    ir_table "$TMP/$3.d/cg.out" >"$TMP/$3.ir"
    rm -rf "$TMP/$3.d"
}

running=0
for src in "$ROOT"/bench/y/*.y; do
    name="$(basename "$src" .y)"
    for side in b n; do
        if [ $running -ge "$JOBS" ]; then
            wait -n
            running=$((running - 1))
        fi
        cc="$NEW"
        [ "$side" = b ] && cc="$BASE"
        prof "$cc" "$src" "$side.$name" &
        running=$((running + 1))
    done
done
wait

echo "per-function profile (instructions executed, self; callgrind on -g builds):"
for src in "$ROOT"/bench/y/*.y; do
    name="$(basename "$src" .y)"
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
