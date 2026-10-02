#!/bin/bash
# test/sh/test_loops.sh — loop coverage, plus the operator-precedence
# regressions the audit turned up.
# Usage: ./test/sh/test_loops.sh
#
# Every test runs the program twice: compiled by the reference compiler
# (-q through the shim) and compiled by the C copy. The two must print the
# same bytes and exit the same way. There is no "both produced output, call
# it a pass" allowance: the two sides are the same compiler, so a difference
# is a regression.

source "$(dirname "$0")/lib.sh"   # ROOT, YBOOT, YTIMEOUT_SCALE, PASS/FAIL, colors

VM_TO=$(( 10 * YTIMEOUT_SCALE ))    # compile + run, reference side
CC_TO=$(( 60 * YTIMEOUT_SCALE ))    # compile, C-copy side
RUN_TO=10                           # run the produced binary (never sanitized)

run_test() {
    local name="$1"
    local file="$2"
    local bin
    bin=$(mktemp /tmp/ylops_bin_XXXXXX)

    # Reference side: compile with the reference compiler, then run it.
    local vm_out vm_exit
    vm_out=$(timeout "$VM_TO" "$YBOOT" -q "$file" </dev/null 2>&1)
    vm_exit=$?

    # C-copy side: compile with the C copy, then run what it produced.
    local compile_out compile_exit bin_out bin_exit
    compile_out=$(timeout "$CC_TO" "$YBOOT" --compile "$file" -o "$bin" </dev/null 2>&1)
    compile_exit=$?
    if [ $compile_exit -ne 0 ]; then
        echo -e "${RED}FAIL${NC} $name (compilation failed)"
        echo "$compile_out" | tail -3
        FAIL=$((FAIL + 1))
        rm -f "$bin"
        return
    fi

    bin_out=$(run_bin "$RUN_TO" "$bin" </dev/null 2>&1)
    bin_exit=$?
    rm -f "$bin"

    if [ $vm_exit -ne 0 ] && [ $vm_exit -ne 1 ]; then
        echo -e "${RED}FAIL${NC} $name (reference side crashed/hung, exit=$vm_exit)"
        FAIL=$((FAIL + 1))
        return
    fi

    if [ $bin_exit -ne 0 ] && [ $bin_exit -ne 1 ]; then
        echo -e "${RED}FAIL${NC} $name (binary crashed/hung, exit=$bin_exit)"
        FAIL=$((FAIL + 1))
        return
    fi

    if [ "$vm_out" = "$bin_out" ] && [ "$vm_exit" = "$bin_exit" ]; then
        pass "$name"
    else
        # Identical compilers: a differing byte here is the regression, not
        # a cosmetic wobble. Fail it.
        echo -e "${RED}FAIL${NC} $name (reference vs C copy differ)"
        echo "  REF(ec=$vm_exit): $(echo "$vm_out" | head -3 | tr '\n' '|')"
        echo "  CPY(ec=$bin_exit): $(echo "$bin_out" | head -3 | tr '\n' '|')"
        FAIL=$((FAIL + 1))
    fi
}

# Inline test: write the snippet to a .y file, run it through both compilers
# and require the expected text on each side — checked separately, so a test
# still fails when one engine regresses alone.
inline_test() {
    local name="$1"
    local code="$2"
    local expected="$3"

    local tmpfile bin vm_out bin_out
    tmpfile=$(mktemp /tmp/ylops_src_XXXXXX.y)
    bin=$(mktemp /tmp/ylops_bin_XXXXXX)
    echo "$code" > "$tmpfile"

    # Reference side (quiet: only program output), then the C copy's build.
    vm_out=$(timeout "$VM_TO" "$YBOOT" -q "$tmpfile" </dev/null 2>&1)
    if timeout "$CC_TO" "$YBOOT" --compile "$tmpfile" -o "$bin" </dev/null >/dev/null 2>&1; then
        bin_out=$(run_bin "$RUN_TO" "$bin" </dev/null 2>&1)
    else
        # Never fall through to a stale binary: a failed compile is the output.
        bin_out="(compilation failed)"
    fi

    rm -f "$tmpfile" "$bin"

    local vm_ok=0
    local bin_ok=0

    if echo "$vm_out" | grep -qF -- "$expected"; then vm_ok=1; fi
    if echo "$bin_out" | grep -qF -- "$expected"; then bin_ok=1; fi

    if [ $vm_ok -eq 1 ] && [ $bin_ok -eq 1 ]; then
        pass "$name"
    else
        echo -e "${RED}FAIL${NC} $name"
        [ $vm_ok -eq 0 ] && echo "  REF missing: $expected (got: $vm_out)"
        [ $bin_ok -eq 0 ] && echo "  CPY missing: $expected (got: $bin_out)"
        FAIL=$((FAIL + 1))
    fi
}

echo "═══════════════════════════════════════════"
echo "  y compiler test suite"
echo "═══════════════════════════════════════════"
echo ""

# ── File-based tests ──
echo "── File-based tests ──"
for f in test_while.y test_for.y test_foreach.y test_forrange.y; do
    run_test "$f" "$ROOT/test/y/examples/$f"
done

# Regression: existing examples
echo ""
echo "── Regression tests ──"
for f in helloworld.y pi.y array.y leftfold.y; do
    run_test "$f" "$ROOT/test/y/examples/$f"
done

# ── Inline tests: while ──
echo ""
echo "── while loop tests ──"

inline_test "while: basic counter" \
    'let i = 0; while (i < 5) { i = i + 1; }; print(i);' \
    '5'

inline_test "while: accumulator" \
    'let s = 0; let i = 1; while (i <= 100) { s = s + i; i = i + 1; }; print(s);' \
    '5050'

inline_test "while: zero iterations" \
    'let x = 42; while (false) { x = 0; }; print(x);' \
    '42'

inline_test "while: nested" \
    'let total = 0; let i = 0; while (i < 3) { let j = 0; while (j < 3) { total = total + 1; j = j + 1; }; i = i + 1; }; print(total);' \
    '9'

# ── Inline tests: for (C-style) ──
echo ""
echo "── for loop tests ──"

inline_test "for: basic" \
    'let s = 0; for (let i = 0; i < 5; i = i + 1) { s = s + i; }; print(s);' \
    '10'

inline_test "for: countdown" \
    'let s = ""; for (let i = 5; i > 0; i = i - 1) { s = s + tostring(i); }; print(s);' \
    '54321'

inline_test "for: step by 3" \
    'let c = 0; for (let i = 0; i < 10; i = i + 3) { c = c + 1; }; print(c);' \
    '4'

inline_test "for: no init" \
    'let i = 3; let s = 0; for (; i > 0; i = i - 1) { s = s + i; }; print(s);' \
    '6'

inline_test "for: zero iterations" \
    'let x = 99; for (let i = 10; i < 5; i = i + 1) { x = 0; }; print(x);' \
    '99'

inline_test "for: nested" \
    'let s = 0; for (let i = 0; i < 4; i = i + 1) { for (let j = 0; j < 4; j = j + 1) { s = s + 1; }; }; print(s);' \
    '16'

# ── Inline tests: foreach ──
echo ""
echo "── foreach loop tests ──"

inline_test "foreach: sum array" \
    'let s = 0; foreach (x in [10, 20, 30]) { s = s + x; }; print(s);' \
    '60'

inline_test "foreach: string concat" \
    'let r = ""; foreach (w in ["a", "b", "c"]) { r = r + w; }; print(r);' \
    'abc'

inline_test "foreach: empty array" \
    'let x = 42; foreach (i in []) { x = 0; }; print(x);' \
    '42'

inline_test "foreach: over range()" \
    'let s = 0; foreach (i in range(5)) { s = s + i; }; print(s);' \
    '10'

inline_test "foreach: nested" \
    'let s = 0; foreach (a in [1, 2]) { foreach (b in [10, 20]) { s = s + a * b; }; }; print(s);' \
    '90'

inline_test "foreach: single element" \
    'let s = 0; foreach (x in [7]) { s = x; }; print(s);' \
    '7'

# ── Inline tests: for..in range ──
echo ""
echo "── for..in range tests ──"

inline_test "range: 0..5" \
    'let s = 0; for i in 0..5 { s = s + i; }; print(s);' \
    '10'

inline_test "range: 3..7" \
    'let s = 0; for i in 3..7 { s = s + i; }; print(s);' \
    '18'

inline_test "range: empty (start==end)" \
    'let x = 42; for i in 5..5 { x = 0; }; print(x);' \
    '42'

inline_test "range: empty (start>end)" \
    'let x = 42; for i in 10..3 { x = 0; }; print(x);' \
    '42'

inline_test "range: nested" \
    'let s = 0; for i in 0..3 { for j in 0..3 { s = s + i + j; }; }; print(s);' \
    '18'

inline_test "range: expression bounds" \
    'let n = 3; let s = 0; for i in 0..n*2 { s = s + 1; }; print(s);' \
    '6'

inline_test "range: variable used after loop" \
    'let last = 0; for i in 0..10 { last = i; }; print(last);' \
    '9'

# ── Inline tests: loops + functions ──
echo ""
echo "── loops + functions ──"

inline_test "loop in function" \
    'def sum_to(n: long) -> long { let s = 0; for i in 0..n+1 { s = s + i; }; s }; print(sum_to(10));' \
    '55'

inline_test "function with while" \
    'def fib(n: long) -> long { let a = 0; let b = 1; let i = 0; while (i < n) { let t = a + b; a = b; b = t; i = i + 1; }; a }; print(fib(10));' \
    '55'

inline_test "foreach with function call" \
    'def double(x: long) -> long { x * 2 }; let s = 0; foreach (v in [1, 2, 3]) { s = s + double(v); }; print(s);' \
    '12'

inline_test "loop building array result" \
    'let s = 0; for i in 1..6 { s = s + i * i; }; print(s);' \
    '55'

# ── Regression tests: audit findings ──
echo ""
echo "── Audit regression tests ──"

inline_test "precedence: mul before add" \
    'print(2 * 3 + 4);' \
    '10'

inline_test "precedence: left-assoc subtraction" \
    'print(10 - 2 - 3);' \
    '5'

inline_test "precedence: left-assoc division" \
    'print(100 / 10 / 2);' \
    '5'

inline_test "precedence: mixed" \
    'print(2 + 3 * 4 - 1);' \
    '13'

inline_test "precedence: comparison lower than arithmetic" \
    'print(2 + 3 > 4);' \
    'true'

inline_test "precedence: parens override" \
    'print((2 + 3) * 4);' \
    '20'

inline_test "negative float" \
    'print(-3.14);' \
    '-3.14'

inline_test "negative float: -0.5" \
    'print(-0.5);' \
    '-0.5'

inline_test "else if chain" \
    'let x = 2; if (x == 1) { print("one"); } else if (x == 2) { print("two"); } else { print("other"); };' \
    'two'

inline_test "else if: falls to else" \
    'let x = 9; if (x == 1) { print("one"); } else if (x == 2) { print("two"); } else { print("other"); };' \
    'other'

inline_test "if without else" \
    'if (true) { print("yes"); };' \
    'yes'

inline_test "cons operator" \
    'print(0 :: [1, 2, 3]);' \
    '[0, 1, 2, 3]'

inline_test "empty array slice" \
    'let a: [long] = []; print(a[0:1]);' \
    '[]'

inline_test "modulo precedence" \
    'print(10 % 3 + 1);' \
    '2'

# ── Summary ──
echo ""
echo "═══════════════════════════════════════════"
TOTAL=$((PASS + FAIL))
echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $TOTAL total"
echo "═══════════════════════════════════════════"

[ $FAIL -eq 0 ] && exit 0 || exit 1