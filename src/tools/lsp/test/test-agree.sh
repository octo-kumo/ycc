#!/bin/sh
# test-agree.sh -- scan.y's spans must be the compiler's own tokens.
#
# LSP.md §5.1: scan.y is an adapter over lexer.tokenize_lsp, so there is one
# scanner. What is left to check is the adapter's classification and spans, and
# every .y file in the tree goes through, because an adapter that agrees on
# hand-picked snippets agrees on nothing.
#
# Two properties, because they fail differently:
#
#   1. TOKEN AGREEMENT. For text the lexer accepts, every token has a span at
#      the same byte offset with a compatible kind. Comments and f-strings are
#      excluded from both sides -- tokenize discards the first and desugars the
#      second, which is *why* scan.y exists.
#
#   2. REPAIR. For text the lexer cannot lex at all (an unterminated string or
#      block comment makes it exit(1), which in a server is fatal), scan must
#      report it and repair() must produce text that lexes, so the rest of the
#      document still gets checked.
#
# Run: sh src/tools/lsp/test/test-agree.sh

set -u
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 1
OUT=${OUT:-/tmp/opencode/agree}
HERE=src/tools/lsp/test

mkdir -p "$OUT"

CANDIDATES=${YCC:-}
[ -n "$CANDIDATES" ] || CANDIDATES="./ycc ./refs/ycc.ref"
COMPILERS=""
for c in $CANDIDATES; do
    if [ -x "$c" ]; then COMPILERS="$COMPILERS $c"; fi
done
if [ -z "$COMPILERS" ]; then
    echo "error: no compiler found (looked: $CANDIDATES)" >&2
    exit 1
fi

FILES=$(find src/y src/tools bench test/y -name '*.y' -type f 2>/dev/null | sort)
COUNT=$(echo "$FILES" | grep -c .)
if [ "$COUNT" = "0" ]; then
    echo "error: no .y files found -- wrong ROOT ($ROOT)?" >&2
    exit 1
fi

echo "corpus: $COUNT .y files"

rc=0
for cc in $COMPILERS; do
    bin="$OUT/drv_agree.$(basename "$cc")"
    if ! "$cc" "$HERE/drv_scan_agree.y" -o "$bin" > "$OUT/cc.log" 2>&1; then
        echo "FAIL     compile t004_scan_agree [$cc]"
        sed 's/^/            /' "$OUT/cc.log" | head -5
        rc=1
        continue
    fi
    # echo the corpus in: the test takes the file list in argv
    # shellcheck disable=SC2086
    if echo "$FILES" | xargs "$bin" > "$OUT/out.$(basename "$cc").txt" 2>&1; then
        :
    fi
    echo "--- [$cc] ---"
    cat "$OUT/out.$(basename "$cc").txt"
    if grep -q '^MISMATCH\|^REPAIR-FAILED\|^SKIP (unreadable)' "$OUT/out.$(basename "$cc").txt"; then
        echo "FAIL     agreement [$cc]"
        rc=1
    else
        echo "ok       agreement [$cc]"
    fi
done

# the numbers themselves are worth pinning, so a silent drop in coverage is
# visible: `compared` must be the whole corpus bar the unlexable files
for cc in $COMPILERS; do
    f="$OUT/out.$(basename "$cc").txt"
    [ -f "$f" ] || continue
    compared=$(sed -n 's/^compared \([0-9]*\) .*/\1/p' "$f")
    unlex=$(sed -n 's/^unlexable \([0-9]*\) .*/\1/p' "$f")
    failed=$(sed -n 's/.*repair-failed \([0-9]*\)[[:space:]]*$/\1/p' "$f")
    if [ -n "$compared" ] && [ -n "$unlex" ]; then
        want=$((COUNT - unlex))
        if [ "$compared" != "$want" ]; then
            echo "FAIL     coverage [$cc]: compared $compared, expected $want"
            rc=1
        fi
    fi
    if [ -z "$failed" ]; then
        echo "FAIL     output [$cc]: could not read the summary line"
        rc=1
    elif [ "$failed" != "0" ]; then
        echo "FAIL     repair [$cc]: $failed files could not be repaired"
        rc=1
    fi
done

echo
if [ "$rc" = "0" ]; then
    echo "agreement: OK"
else
    echo "agreement: FAILED"
fi
exit $rc