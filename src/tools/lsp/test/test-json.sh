#!/bin/sh
# test-json.sh -- run the json.y fixtures. M-json (LSP.md §15).
#
# Each tNNN_*.y is compiled with a chosen compiler, run, and its stdout+stderr
# compared against tNNN_*.expected. Both compilers in the tree are tried when
# they exist, because a std module must compile and behave identically under
# either -- they read the same source, so any difference is a compiler bug and
# exactly the thing this suite exists to catch.
#
#   sh src/tools/lsp/test/test-json.sh              # both compilers
#   YCC=./ycc sh src/tools/lsp/test/test-json.sh    # just one
#
# Not wired into make test: test/sh/ and the Makefile are the compiler's, and
# adding to either needs the compiler agent (LSP.md §12, M5). Run it by hand.

set -u
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 1
HERE=src/tools/lsp/test
OUT=${OUT:-/tmp/opencode/json-tests}

pass=0; fail=0; skip=0
failed=""

mkdir -p "$OUT"

# compilers to try, in order; skip any that is not there
CANDIDATES=${YCC:-}
[ -n "$CANDIDATES" ] || CANDIDATES="./ycc ./refs/ycc.ref"
COMPILERS=""
for c in $CANDIDATES; do
    if [ -x "$c" ]; then COMPILERS="$COMPILERS $c"; fi
done
if [ -z "${COMPILERS:-}" ]; then
    echo "error: no compiler found (looked: $CANDIDATES)" >&2
    exit 1
fi

for src in "$HERE"/t[0-9][0-9][0-9]_*.y; do
    [ -f "$src" ] || continue
    base=$(basename "$src" .y)
    exp="$HERE/$base.expected"
    if [ ! -f "$exp" ]; then
        echo "MISSING  $base (no .expected)"
        skip=$((skip + 1))
        continue
    fi

    for cc in $COMPILERS; do
        [ -x "$cc" ] || continue
        bin="$OUT/$base.$(basename "$cc")"
        if ! "$cc" "$src" -o "$bin" > "$OUT/$base.cc.log" 2>&1; then
            echo "FAIL     $base [$cc] compile"
            sed 's/^/            /' "$OUT/$base.cc.log" | head -5
            fail=$((fail + 1))
            failed="$failed $base"
            continue
        fi
        # a warning on a std module or a fixture is itself a failure:
        # test_fixpoint requires the compiler's own source warning-free
        if grep -q ': warning: ' "$OUT/$base.cc.log"; then
            echo "WARN     $base [$cc] compiled with a warning"
            grep ': warning: ' "$OUT/$base.cc.log" | sed 's/^/            /' | head -3
            fail=$((fail + 1))
            failed="$failed $base"
            continue
        fi
        "$bin" > "$OUT/$base.out" 2>&1
        got=$?
        echo "$got" > "$OUT/$base.code"
        if [ "$got" != "0" ]; then
            echo "FAIL     $base [$cc] exit $got"
            fail=$((fail + 1))
            failed="$failed $base"
            continue
        fi
        if diff -u "$exp" "$OUT/$base.out" > "$OUT/$base.diff" 2>&1; then
            echo "ok       $base [$cc]"
            pass=$((pass + 1))
        else
            echo "FAIL     $base [$cc] output"
            head -20 "$OUT/$base.diff" | sed 's/^/            /'
            fail=$((fail + 1))
            failed="$failed $base"
        fi
    done
done

echo
echo "passed $pass, failed $fail, skipped $skip"
if [ "$fail" != "0" ]; then
    echo "failed:$failed"
    exit 1
fi
exit 0