#!/usr/bin/env bash
# test_math.sh — the ulp harness: std/math.y against the checked-in reference
# table, in ulps.
#
# test/math/ulp_table.txt holds one case per line — the function, its
# argument(s) and the correctly-rounded answer, all as IEEE-754 bit patterns.
# test/math/ulp_check.y reads it, calls std/math.y, and prints every case whose
# answer is more than one ulp from the reference. The gate is that nothing is:
# "within 1 ulp" is the whole promise, and a table of cases is the only way to
# keep it honest as the functions change.
#
# Both compilers run it and their output must agree (the port is 1:1), and the
# table's cases are the ones the harness dispatches on, so a function nobody
# tested fails here rather than silently passing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

CYCC="${CYCC:-$ROOT/cycc}"
YCC="${YCC:-$ROOT/ycc}"
TABLE="$ROOT/test/math/ulp_table.txt"
PROG="$ROOT/test/math/ulp_check.y"

[ -x "$CYCC" ] || { echo "test_math: $CYCC not built (run 'make')" >&2; exit 1; }
[ -x "$YCC" ]  || { echo "test_math: $YCC not built (run 'make ycc')" >&2; exit 1; }
[ -f "$TABLE" ] || { echo "test_math: no table at $TABLE" >&2; exit 1; }

if [ ! -t 1 ] && [ -z "${VERBOSE:-}" ]; then
    RED=$'\033[31m'; GREEN=$'\033[32m'; OFF=$'\033[0m'
else
    RED=''; GREEN=''; OFF=''
fi
pass() { echo "${GREEN}PASS${OFF} $1"; }
fail() { echo "${RED}FAIL${OFF} $1"; rc=1; }
rc=0

# Both compilers, and the two must say the same thing (the twin is 1:1, and a
# divergence here is a bug in one of them rather than in the math).
out_cycc=$(mktemp); out_ycc=$(mktemp)
trap 'rm -f "$out_cycc" "$out_ycc" /tmp/ymath_bin_$$' EXIT

rc_cycc=0
"$CYCC" -o /tmp/ymath_bin_$$ "$PROG" 2>"$out_cycc.err" </dev/null || rc_cycc=$?
if [ "$rc_cycc" != 0 ]; then
    fail "the C copy does not compile test/math/ulp_check.y"
    cat "$out_cycc.err" >&2
else
    rm -f /tmp/ymath_bin_$$
    "$CYCC" -o /tmp/ymath_bin_$$ "$PROG" 2>/dev/null </dev/null || rc_cycc=$?
    /tmp/ymath_bin_$$ "$TABLE" >"$out_cycc" 2>&1
    ec_cycc=$?
    rm -f /tmp/ymath_bin_$$
    if [ "$ec_cycc" = 0 ]; then
        pass "the C copy: $(tail -1 "$out_cycc")"
    else
        fail "the C copy: $(tail -1 "$out_cycc")"
        grep '^OVER' "$out_cycc" | head -20
    fi
fi

rc_ycc=0
"$YCC" -o /tmp/ymath_bin_$$ "$PROG" 2>"$out_ycc.err" </dev/null || rc_ycc=$?
if [ "$rc_ycc" != 0 ]; then
    fail "the built compiler does not compile test/math/ulp_check.y"
    cat "$out_ycc.err" >&2
else
    rm -f /tmp/ymath_bin_$$
    "$YCC" -o /tmp/ymath_bin_$$ "$PROG" 2>/dev/null </dev/null || rc_ycc=$?
    /tmp/ymath_bin_$$ "$TABLE" >"$out_ycc" 2>&1
    ec_ycc=$?
    rm -f /tmp/ymath_bin_$$
    if [ "$ec_ycc" = 0 ]; then
        pass "the built compiler: $(tail -1 "$out_ycc")"
    else
        fail "the built compiler: $(tail -1 "$out_ycc")"
        grep '^OVER' "$out_ycc" | head -20
    fi
fi

if [ -s "$out_cycc" ] && [ -s "$out_ycc" ] && ! cmp -s "$out_cycc" "$out_ycc"; then
    fail "the two compilers disagree about the table"
    diff "$out_cycc" "$out_ycc" | head -20
fi

# A function in the table the harness cannot dispatch would pass silently, so
# every name in the table has to be one it knows.
missing=$(awk '!/^#/ && NF {print $1}' "$TABLE" | sort -u | while read -r fn; do
    grep -q "\"$fn\"" "$PROG" || echo "$fn"
done)
if [ -n "$missing" ]; then
    fail "the harness does not dispatch: $(echo "$missing" | tr '\n' ' ')"
fi

exit $rc