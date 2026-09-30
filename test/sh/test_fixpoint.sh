#!/bin/bash
# Self-hosting fixpoint check: ycc compiling its own source must reproduce
# ycc byte-for-byte, and the binary it produces must itself be a working
# compiler (a compiler that miscompiles itself can still be bit-stable, so
# generation 3 is checked too).
#
# `make ycc` runs a cmp as part of the bootstrap; this suite proves the same
# property from an already-built ./ycc, so `./test/sh/run_all.sh fixpoint`
# catches a regression without a full rebuild.
#
# Usage: ./test/sh/test_fixpoint.sh
# Skips (exit 0) if ./ycc is not built; build it with `make ycc`.

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YCC_BIN="$ROOT/ycc"
SRC="$ROOT/src/y/ycc.y"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo "═══════════════════════════════════════════"
echo "  ycc self-hosting fixpoint"
echo "═══════════════════════════════════════════"
echo ""

if [ ! -x "$YCC_BIN" ]; then
    echo "  (skipped: run 'make ycc' first)"
    echo ""
    echo "═══════════════════════════════════════════"
    echo "  Results: 0 passed, 0 failed / 0 total (skipped)"
    echo "═══════════════════════════════════════════"
    exit 0
fi

GEN2=$(mktemp /tmp/ycc_gen2.XXXXXX)
GEN3=$(mktemp /tmp/ycc_gen3.XXXXXX)
trap 'rm -f "$GEN2" "$GEN3" /tmp/yfp_probe.y /tmp/yfp_probe_bin' EXIT

check() {
    if [ "$2" = "ok" ]; then
        echo -e "${GREEN}PASS${NC} $1"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} $1"
        [ -n "$3" ] && echo "  $3"
        FAIL=$((FAIL + 1))
    fi
}

# Generation 2: ./ycc (built by cycc) compiles its own source.
if timeout 600 "$YCC_BIN" -o "$GEN2" "$SRC" </dev/null >/tmp/yfp_err 2>&1; then
    check "ycc compiles its own source" ok
else
    check "ycc compiles its own source" bad "$(head -c 200 /tmp/yfp_err)"
fi

# The fixpoint itself: same bytes.
if [ -s "$GEN2" ] && cmp -s "$YCC_BIN" "$GEN2"; then
    check "generation 2 is byte-identical to ./ycc" ok
else
    check "generation 2 is byte-identical to ./ycc" bad \
        "sizes: $(stat -c%s "$YCC_BIN" 2>/dev/null) vs $(stat -c%s "$GEN2" 2>/dev/null)"
fi

# Generation 3: the self-built compiler must itself compile ycc, identically.
if [ -s "$GEN2" ] && timeout 600 "$GEN2" -o "$GEN3" "$SRC" </dev/null >/dev/null 2>&1 \
   && cmp -s "$GEN2" "$GEN3"; then
    check "generation 3 reproduces generation 2" ok
else
    check "generation 3 reproduces generation 2" bad "self-built compiler is not stable"
fi

# A bit-stable compiler still has to work: compile and run a real program
# with the self-built binary.
cat > /tmp/yfp_probe.y <<'PROBE'
def fib(n: long) -> long { if (n < 2) { n } else { self(n - 1) + self(n - 2) } };
let xs = [];
let i = 0;
while (i < 8) { xs = push(xs, fib(i)); i = i + 1; };
print(len(xs));
print(xs[7]);
puts("ok\n");
PROBE
if [ -s "$GEN2" ] && timeout 120 "$GEN2" -o /tmp/yfp_probe_bin /tmp/yfp_probe.y </dev/null >/dev/null 2>&1; then
    got=$(timeout 30 /tmp/yfp_probe_bin </dev/null 2>&1)
    want=$(printf '8\n13\nok')
    if [ "$got" = "$want" ]; then
        check "self-built compiler produces working binaries" ok
    else
        check "self-built compiler produces working binaries" bad "got: $got"
    fi
else
    check "self-built compiler produces working binaries" bad "compile failed"
fi

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
