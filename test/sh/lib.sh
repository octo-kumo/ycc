#!/bin/bash
# test/sh/lib.sh — shared helpers for the y test suites.
# Usage: source "$(dirname "$0")/lib.sh"
# Provides: ROOT, YBOOT, colors, PASS/FAIL/SKIP counters,
# pass/fail/skip reporters, run_parity(), print_summary().

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YBOOT="${YBOOT:-$ROOT/yboot}"  # overridable: make test-asan points this at yboot-asan

# A sanitized toolchain runs roughly 15x slower, so the default timeouts
# below would flag heavy tests (audit/t45_fib) as hangs. Scale them instead
# of weakening the limits for everyone.
YTIMEOUT_SCALE=1
case "$YBOOT" in
    *asan* | *msan* | *ubsan*) YTIMEOUT_SCALE=15 ;;
esac

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() {
    echo -e "${RED}FAIL${NC} $1"
    [ -n "$2" ] && echo "  $2"
    FAIL=$((FAIL + 1))
}
skip() { echo -e "${YELLOW}SKIP${NC} $1${2:+ ($2)}"; SKIP=$((SKIP + 1)); }

# run_parity <name> <file> [vm_timeout] [compile_timeout] [bin_timeout]
# Runs <file> in the VM (-q) and as a compiled binary (both fed from
# /dev/null), then requires identical stdout and a non-crashing exit (0/1).
# Returns 0 on parity, 1 otherwise; sets RUN_VM_OUT/RUN_BIN_OUT/RUN_VMEC/RUN_BINEC.
run_parity() {
    local name="$1" file="$2"
    local vm_to=$(( ${3:-10} * YTIMEOUT_SCALE ))
    local cc_to=$(( ${4:-60} * YTIMEOUT_SCALE ))
    local bin_to="${5:-10}"

    RUN_VM_OUT=$(timeout "$vm_to" "$YBOOT" -q "$file" </dev/null 2>&1)
    RUN_VMEC=$?
    local binf
    binf=$(mktemp /tmp/ytest_bin_XXXXXX)
    timeout "$cc_to" "$YBOOT" --compile "$file" -o "$binf" >/dev/null 2>&1
    local ce=$?
    if [ $ce -eq 0 ]; then
        RUN_BIN_OUT=$(timeout "$bin_to" "$binf" </dev/null 2>&1)
        RUN_BINEC=$?
    else
        RUN_BIN_OUT="(compile failed, exit=$ce)"
        RUN_BINEC="cf$ce"
    fi
    rm -f "$binf"

    if [ "$RUN_VM_OUT" = "$RUN_BIN_OUT" ] && [ "$RUN_VMEC" -le 1 ] 2>/dev/null \
        && { [ "$RUN_BINEC" = "0" ] || [ "$RUN_BINEC" = "1" ]; }; then
        return 0
    fi
    return 1
}

# print_summary <suite-name>: prints totals, returns 0 iff no failures.
print_summary() {
    local total=$((PASS + FAIL))
    echo ""
    echo "═══════════════════════════════════════════"
    echo -e "  [$1] ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} / $total total (plus $SKIP skipped)"
    echo "═══════════════════════════════════════════"
    [ $FAIL -eq 0 ]
}
