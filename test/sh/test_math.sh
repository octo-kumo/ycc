#!/usr/bin/env bash
# test_math.sh — the ulp harness: std/math.y against the checked-in reference
# table, in ulps.
#
# test/math/ulp_table.txt holds one case per line — the function, its
# argument(s) and the correctly-rounded answer, all as IEEE-754 bit patterns.
# test/math/ulp_check.y reads it, calls std/math.y, and prints every case whose
# answer is more than one ulp from the reference. The gate is that nothing does,
# and the tolerance is 1: "within 1 ulp" is the whole promise, and a table of
# cases is the only way to keep it honest as the functions change. It was 3, over
# four cases, while this header already claimed 1 -- a comment that says
# something the code does not check. All four are closed; test/math/ulp_check.y
# says what each one was.
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

# The GENERATED polynomial kernels, against src/y/std/math.y itself.
#
# The ulp table below sees ANSWERS, so a kernel that drifts by half an ulp can
# hide inside a final rounding; and a chain hand-edited out of step with the
# arrays still answers within an ulp, because the coefficients are right and only
# the arrangement moved. So two separate questions, both asked here:
#
#   --verify   is every generated chain still byte-identical to what
#              gen_split_unroll.py writes? Four of the eight were carrying a
#              signpost to a gate file that did not exist, and the generator was
#              still emitting the dead name after the fix -- both invisible to
#              every other check in this suite.
#   t328      do all eight chains agree TO THE BIT with poly_split, the loop they
#              replaced, over 32024 arguments? That is t328_split_unrolled.y,
#              which runs under test_native.sh; here it is the same file through
#              both compilers, so a port that made one of them emit a different
#              chain would show up as a disagreement rather than as nothing.
if ! python3 "$ROOT/test/math/gen_split_unroll.py" --verify; then
    fail "the generated kernels have drifted from the generator"
fi

# Under mktemp, not _check/: that directory belongs to `make check` and to
# whatever else is running in this tree, and a suite must not write into it.
t328_tmp=$(mktemp -d)
trap 'rm -rf "$t328_tmp"' EXIT
for cc in "$CYCC" "$YCC"; do
    name=$(basename "$cc")
    # diffed as files, not compared as strings: $(cat) strips trailing newlines
    # and tr leaves a trailing space, so the string form fails on whitespace
    # alone -- which is how this check first reported FAIL on a correct answer.
    if "$cc" "$ROOT/test/y/native/t328_split_unrolled.y" -o "$t328_tmp/$name" 2>"$t328_tmp/$name.err" \
       && "$t328_tmp/$name" </dev/null >"$t328_tmp/$name.out" 2>&1 \
       && diff -q "$t328_tmp/$name.out" "$ROOT/test/y/native/t328_split_unrolled.expected" >/dev/null; then
        pass "$name: the 8 unrolled kernels match poly_split to the bit"
    else
        fail "$name: t328_split_unrolled: $(tr '\n' ' ' < "$t328_tmp/$name.out" 2>/dev/null) $(head -2 "$t328_tmp/$name.err" 2>/dev/null)"
    fi
done

# The ratchet on REPEATED COMPUTATIONS, which is a different question from every
# other one in this suite and the only one that is static.
#
# The defect class is "a behaviour decided by an accident of expression order",
# and the accident need not be in the order -- it can be in the SPELLING. Two
# places meaning the same thing and written differently means a later change
# reaches one and not the other, which is how sin_cos_k came to compute x*x three
# times and have the multiplier and the kernel's argument agree only by
# coincidence. find_repeats.py looks for that, and it is a RATCHET: the two
# findings it reports are in its KNOWN with the reason each is acceptable, and
# anything new fails. A new entry has to arrive with a reason.
if out=$(python3 "$ROOT/test/math/find_repeats.py" "$ROOT/src/y/std/math.y" 2>&1); then
    echo "$out" | sed 's/^/  /'
    pass "no new repeated computation in src/y/std/math.y"
else
    echo "$out" | sed 's/^/  /'
    fail "a new repeated computation in src/y/std/math.y (above); it is a defect, or it needs a reason in KNOWN"
fi

# And the finder itself, or it proves nothing: each detector must find a plant of
# the thing it claims to find. A detector that silently stops detecting is worse
# than no detector, because the ratchet above would then read as coverage.
if python3 "$ROOT/test/math/find_repeats.py" --selftest >/dev/null 2>&1; then
    pass "each repeated-computation detector finds its plant"
else
    fail "a detector in find_repeats.py stopped finding its plant"
    python3 "$ROOT/test/math/find_repeats.py" --selftest 2>&1 | sed 's/^/  /'
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