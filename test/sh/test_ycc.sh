#!/bin/bash
# Self-hosted compiler check: ycc must produce binaries that behave identically
# to the reference C compiler's VM for representative programs.
# Usage: ./test/sh/test_ycc.sh
# Skips (exit 0) if ./ycc is not built; build it with `make`.

PASS=0
FAIL=0
SKIP=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YBOOT="${YBOOT:-$ROOT/yboot}"
YCC_BIN="$ROOT/ycc"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "═══════════════════════════════════════════"
echo "  ycc self-hosted compiler check"
echo "═══════════════════════════════════════════"
echo ""

if [ ! -f "$YCC_BIN" ]; then
    echo "  (skipped: run 'make ycc' first)"
    echo ""
    echo "═══════════════════════════════════════════"
    echo -e "  Results: 0 passed, 0 failed / 0 total (skipped)"
    echo "═══════════════════════════════════════════"
    exit 0
fi

# Native parity: programs in the native subset must behave identically
# under the C VM and under ycc-compiled binaries.
for prog in 'def f(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(f(10));' \
            'let m = 0; let i = 1; while (i <= 10) { m = m + i; i = i + 1; }; print(m);' \
            'def add(a: long, b: long) -> long { a + b }; print(add(20, 22));' \
            'def outer() -> long { def h(x: long) -> long { x * 2 }; h(21) }; print(outer());'; do
    echo "$prog" > /tmp/sh.y
    c_out=$(timeout 10 "$YBOOT" -q /tmp/sh.y </dev/null 2>&1)
    if timeout 120 "$YCC_BIN" -o /tmp/sh_bin /tmp/sh.y </dev/null >/dev/null 2>&1; then
        y_out=$(timeout 10 /tmp/sh_bin </dev/null 2>&1)
    else
        y_out="(ycc failed)"
    fi
    rm -f /tmp/sh.y /tmp/sh_bin
    if [ "$c_out" = "$y_out" ]; then
        echo -e "${GREEN}PASS${NC} self-hosted: $(echo "$prog" | cut -c1-40)..."
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} self-hosted: $(echo "$prog" | cut -c1-40)..."
        echo "  C compiler: $c_out"
        echo "  self-hosted: $y_out"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
