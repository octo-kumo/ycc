#!/bin/sh
# test-fmt.sh -- the formatter: it must be idempotent, and it must leave
# src/y/ alone as far as it can.
#
# Two properties, because only one of them is a hard requirement:
#
#   1. IDEMPOTENCE (LSP.md R3.5). format(format(x)) == format(x), byte for
#      byte, over every .y file in the tree. This is the acceptance test.
#
#   2. THE src/y FIXED POINT (R3.2). src/y/ is the style the formatter targets,
#      so reformatting it should be very nearly a no-op. It is a signal, not a
#      gate: what is left is the author's own layout -- column-aligned record
#      literals, aligned trailing comments -- which the formatter copies through
#      on purpose. The counts are printed so the trend is visible.
#
# Run: sh src/tools/lsp/test/test-fmt.sh

set -u
ROOT=$(cd "$(dirname "$0")/../../../.." && pwd)
cd "$ROOT" || exit 1
OUT=${OUT:-/tmp/opencode/fmt}
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
[ "$COUNT" = "0" ] && { echo "error: no .y files (wrong ROOT?)" >&2; exit 1; }

rc=0
for cc in $COMPILERS; do
    tag=$(basename "$cc")

    # 1. idempotence
    idem="$OUT/idem.$tag"
    if ! "$cc" "$HERE/drv_fmt_idempotent.y" -o "$idem" > "$OUT/idemcc.log" 2>&1; then
        echo "FAIL     build idem [$cc]"
        head -5 "$OUT/idemcc.log" | sed 's/^/            /'
        rc=1
        continue
    fi
    # shellcheck disable=SC2086
    echo "$FILES" | xargs "$idem" > "$OUT/idem.$tag.txt" 2>&1
    ibad=$(grep -c '^NOT-IDEMPOTENT' "$OUT/idem.$tag.txt")
    isum=$(grep '^checked ' "$OUT/idem.$tag.txt" | tail -1)
    if [ "$ibad" != "0" ]; then
        echo "FAIL     idempotence [$cc]: $ibad files"
        grep '^NOT-IDEMPOTENT' "$OUT/idem.$tag.txt" | head -5 | sed 's/^/            /'
        rc=1
    else
        echo "ok       idempotence [$cc] -- $isum"
    fi

    # 2. the src/y fixed point
    one="$OUT/one.$tag"
    if ! "$cc" "$HERE/drv_fmt_fixedpoint.y" -o "$one" > "$OUT/fmtcc.log" 2>&1; then
        echo "FAIL     build fmtall [$cc]"
        head -5 "$OUT/fmtcc.log" | sed 's/^/            /'
        rc=1
        continue
    fi
    same=0; diffs=0; n=0
    for f in src/y/*.y src/y/std/*.y; do
        [ -f "$f" ] || continue
        n=$((n + 1))
        r=$("$one" "$f" "$OUT/x.$tag" 2>/dev/null)
        if [ "$r" = "SAME" ]; then
            same=$((same + 1))
        else
            c=$(diff "$f" "$OUT/x.$tag" | grep -c '^[<>]')
            diffs=$((diffs + c))
        fi
        rm -f "$OUT/x.$tag"
    done
    echo "ok       src/y fixed point [$cc] -- $same/$n byte-identical, $diffs lines differ"
done

echo
[ "$rc" = "0" ] && echo "formatter: OK" || echo "formatter: FAILED"
exit $rc