#!/bin/bash
# test/sh/test_prof.sh — `ycc --prof` instrumentation.
#
# Checks that profiling does not change what a program does (the report is
# extra output on STDERR only), that the report appears and closes, and
# that call counts are EXACT — the rows' times are inherently timing
# dependent, the counts are not.

source "$(dirname "$0")/lib.sh"

# The built ycc (override with $YCC, e.g. the ASan build for make test-asan).
YCC="${YCC:-$ROOT/ycc}"
if [ ! -x "$YCC" ]; then
    echo "error: $YCC not built — run 'make ycc' first" >&2
    exit 2
fi

TMPD="$(mktemp -d /tmp/yprof_test.XXXXXX)"
trap 'rm -rf "$TMPD"' EXIT

cat >"$TMPD/p.y" <<'EOF'
def leaf(n: long) -> long {
    n * 2
};

def mid(n: long) -> long {
    leaf(n) + leaf(n + 1)
};

print(mid(5));
print(mid(6));
EOF

# 1. the instrumented program prints exactly what the plain one does
CTO=$(( 120 * YTIMEOUT_SCALE ))
timeout "$CTO" "$YCC" -o "$TMPD/plain" "$TMPD/p.y" </dev/null >/dev/null 2>&1 || {
    fail "prof compile" "ycc failed"; print_summary "prof"; exit 1; }
timeout "$CTO" "$YCC" --prof -o "$TMPD/prof" "$TMPD/p.y" </dev/null >/dev/null 2>&1 || {
    fail "prof compile" "ycc --prof failed"; print_summary "prof"; exit 1; }

"$TMPD/plain" </dev/null >"$TMPD/plain.out" 2>"$TMPD/plain.err"
"$TMPD/prof" </dev/null >"$TMPD/prof.out" 2>"$TMPD/prof.err"

if [ ! -s "$TMPD/plain.err" ] && diff -q "$TMPD/plain.out" "$TMPD/prof.out" >/dev/null; then
    pass "stdout unchanged by instrumentation"
else
    fail "stdout unchanged by instrumentation" "$(head -c 200 "$TMPD/prof.out" | tr '\n' '|')"
fi

if grep -q '^prof-end$' "$TMPD/plain.err" 2>/dev/null; then
    fail "plain build stays quiet" "it printed a profile"
else
    pass "plain build stays quiet"
fi

# 2. the report is complete and shaped right
if grep -q '^prof: ' "$TMPD/prof.err" && grep -q '^prof-end$' "$TMPD/prof.err"; then
    pass "report framed by prof: / prof-end"
else
    fail "report framed by prof: / prof-end" "$(head -c 200 "$TMPD/prof.err" | tr '\n' '|')"
fi

if grep -q 'calls.*total_ns.*self_ns.*avg_ns.*max_ns' "$TMPD/prof.err"; then
    pass "column header present"
else
    fail "column header present" "no header row"
fi

# 3. call counts are exact (times are not — never assert on those)
calls_of() { awk -v fn="$1" '$1 ~ /^[0-9]+$/ && $6 == fn { print $1 }' "$TMPD/prof.err"; }
for spec in "leaf 4" "mid 2" "_start 1"; do
    fn="${spec% *}"; want="${spec#* }"
    got="$(calls_of "$fn")"
    if [ "$got" = "$want" ]; then
        pass "$fn called $want times"
    else
        fail "$fn called $want times" "report says '${got:-<absent>}'"
    fi
done

# 4. the rows carry the function names, not raw labels
if grep -q 'yfn_' "$TMPD/prof.err"; then
    fail "display names stripped" "raw yfn_ labels leaked into the report"
else
    pass "display names stripped"
fi

print_summary "prof"
