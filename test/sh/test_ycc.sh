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

# Driver failures: each diagnostic must be identical in the self-hosted
# compiler and its C copy, and each compiler must exit with status 1.
expect_cli_error() {
    local name="$1" expected="$2"
    shift 2
    local compiler output ec
    for compiler in "$YCC_BIN" "$CYCC"; do
        output=$(timeout $(( 120 * YTIMEOUT_SCALE )) "$compiler" "$@" </dev/null 2>&1)
        ec=$?
        if [ "$ec" -eq 1 ] && grep -Fqx -- "$expected" <<< "$output"; then
            pass "CLI error $name (${compiler##*/})"
        else
            fail "CLI error $name (${compiler##*/})" \
                "exit=$ec, expected '$expected', got: $(printf '%s' "$output" | tr '\n' '|')"
        fi
    done
}

expect_cli_error "unknown flag" "ycc: unknown flag '--bad' (see ycc -h)" --bad
expect_cli_error "no input file" "error: no input file (see ycc -h)"
expect_cli_error "multiple input files" "error: ycc compiles one program; use imports to combine files" \
    "$ROOT/test/y/native/t01_arith.y" "$ROOT/test/y/native/t02_recursion.y"
expect_cli_error "cannot read input" "error: cannot read file '/no-such-cov-ycc-input.y'" \
    /no-such-cov-ycc-input.y
expect_cli_error "assembly write failure" "error: writing '/nonexistent/dir/out' failed" \
    -S -o /nonexistent/dir/out "$ROOT/test/y/native/t01_arith.y"
expect_cli_error "executable write failure" "error: writing '/nonexistent/dir/out' failed" \
    -o /nonexistent/dir/out "$ROOT/test/y/native/t01_arith.y"

# Import depth: a chain of 33 nested imports is fatal. Only a chain reaches
# the limit -- the resolver's `seen` list stops a cycle first.
DEPTH_DIR=$(mktemp -d /tmp/ycc_depth.XXXXXX)
for i in $(seq 0 31); do
    echo "import d$((i + 1));" > "$DEPTH_DIR/d$i.y"
done
: > "$DEPTH_DIR/d32.y"
printf 'import d0;\nprint("unreachable");\n' > "$DEPTH_DIR/main.y"
expect_cli_error "import depth" "error: native import depth exceeded (cycle?)" \
    -o "$DEPTH_DIR/a.out" "$DEPTH_DIR/main.y"
rm -rf "$DEPTH_DIR"

echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1
