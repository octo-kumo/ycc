#!/bin/bash
# Self-hosted compiler check: ycc must produce binaries that behave exactly
# like the same programs compiled by the reference compiler (refs/ycc.ref).
# Usage: ./test/sh/test_ycc.sh
# Skips (exit 0) if ./ycc is not built; build it with `make ycc`.

source "$(dirname "$0")/lib.sh"   # ROOT, YBOOT, PASS/FAIL/SKIP, colors

# The built ycc (override with $YCC, e.g. the ASan build for make test-asan).
YCC_BIN="${YCC:-$ROOT/ycc}"

echo "═══════════════════════════════════════════"
echo "  ycc self-hosted compiler check"
echo "═══════════════════════════════════════════"
echo ""

if [ ! -x "$YCC_BIN" ]; then
    echo "  (skipped: run 'make ycc' first)"
    echo ""
    echo "═══════════════════════════════════════════"
    echo -e "  Results: 0 passed, 0 failed / 0 total (skipped)"
    echo "═══════════════════════════════════════════"
    exit 0
fi

# Parity: each program compiled by the reference compiler (through the shim)
# must print exactly what the ycc-built binary prints.
for prog in 'def f(n: long) -> long { if (n < 2) { n } else { self(n-1) + self(n-2) } }; print(f(10));' \
            'let m = 0; let i = 1; while (i <= 10) { m = m + i; i = i + 1; }; print(m);' \
            'def add(a: long, b: long) -> long { a + b }; print(add(20, 22));' \
            'def outer() -> long { def h(x: long) -> long { x * 2 }; h(21) }; print(outer());'; do
    echo "$prog" > /tmp/sh.y
    c_out=$(timeout $(( 10 * YTIMEOUT_SCALE )) "$YBOOT" -q /tmp/sh.y </dev/null 2>&1)
    if timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" -o /tmp/sh_bin /tmp/sh.y </dev/null >/dev/null 2>&1; then
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
        echo "  reference: $c_out"
        echo "  self-built ycc: $y_out"
        FAIL=$((FAIL + 1))
    fi
done

# test/y/examples/ysh.y's `eval` shells out to the `ycc` next to the ysh
# binary; the examples suite runs ysh with stdin at EOF, so this is the
# only place it is driven.
YSH_DIR=$(mktemp -d /tmp/ysh_test.XXXXXX)
ln -s "$YCC_BIN" "$YSH_DIR/ycc"
if timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC_BIN" -o "$YSH_DIR/ysh" "$ROOT/test/y/examples/ysh.y" </dev/null >/dev/null 2>&1; then
    ysh_out=$(timeout $(( 60 * YTIMEOUT_SCALE )) "$YSH_DIR/ysh" -c 'eval print(6 * 7)' </dev/null 2>&1)
    ysh_bad=$(timeout $(( 60 * YTIMEOUT_SCALE )) "$YSH_DIR/ysh" -c 'eval exec("true")' </dev/null 2>&1)
else
    ysh_out="(ycc failed on ysh.y)"
    ysh_bad=""
fi
rm -rf "$YSH_DIR"
if [ "$ysh_out" = "42" ]; then
    echo -e "${GREEN}PASS${NC} ysh eval compiles and runs through ycc"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC} ysh eval compiles and runs through ycc"
    echo "  got: $(echo "$ysh_out" | head -c 300)"
    FAIL=$((FAIL + 1))
fi
if echo "$ysh_bad" | grep -q "undefined function 'exec'" &&
   echo "$ysh_bad" | grep -q "compile failed"; then
    echo -e "${GREEN}PASS${NC} ysh eval compiles with --no-exec"
    PASS=$((PASS + 1))
else
    echo -e "${RED}FAIL${NC} ysh eval compiles with --no-exec"
    echo "  got: $(echo "$ysh_bad" | head -c 300)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
