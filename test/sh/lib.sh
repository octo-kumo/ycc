#!/bin/bash
# test/sh/lib.sh — shared helpers for the y test suites.
# Usage: source "$(dirname "$0")/lib.sh"
# Provides: ROOT, CYCC, YREF, colors, PASS/FAIL/SKIP counters,
# pass/fail/skip reporters, run_parity(), print_summary().

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The toolchain is one language implementation twice over: $CYCC is the C
# copy of the compiler (PORTING.md) and $YREF the reference ycc binary.
# Both compile .y straight to static ELFs; every test requires the two to
# agree — byte-identical binaries and identical program behavior.
CYCC="${CYCC:-$ROOT/cycc}"
YREF="${YREF:-$ROOT/refs/ycc.ref}"

# A sanitized toolchain runs roughly 15x slower, so the default timeouts
# below would flag heavy tests (audit/t45_fib) as hangs. Scale them instead
# of weakening the limits for everyone.
YTIMEOUT_SCALE=1
case "$CYCC$YREF" in
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

# compile_ref <file> <bin> [timeout]  — compile with the reference ycc.
# compile_copy <file> <bin> [timeout] — compile with the C copy.
# Exit = the compiler's exit; diagnostics land in RUN_RERR / RUN_CERR.
compile_ref() {
    RUN_RERR=$(timeout "$3" "$YREF" -o "$2" "$1" </dev/null 2>&1)
    return $?
}
compile_copy() {
    RUN_CERR=$(timeout "$3" "$CYCC" -o "$2" "$1" </dev/null 2>&1)
    return $?
}

# run_parity <name> <file> [ref_timeout] [compile_timeout] [bin_timeout]
# Compiles <file> with BOTH compilers and requires:
#   - byte-identical binaries (the port gate),
#   - identical program output and exit code when run (fed /dev/null).
# Returns 0 on agreement, 1 otherwise.
# RUN_VM_OUT/RUN_VMEC carry the reference side, RUN_BIN_OUT/RUN_BINEC the
# C-copy side (historic names; the suites use them). On compile failure
# the outputs hold the compiler diagnostics and the exit codes are "cfN".
run_parity() {
    local name="$1" file="$2"
    local ref_to=$(( ${3:-10} * YTIMEOUT_SCALE ))
    local cc_to=$(( ${4:-60} * YTIMEOUT_SCALE ))
    local bin_to="${5:-10}"

    local binr binc
    binr=$(mktemp /tmp/ytest_ref_XXXXXX)
    binc=$(mktemp /tmp/ytest_cop_XXXXXX)

    compile_ref "$file" "$binr" "$cc_to"
    local rec=$?
    compile_copy "$file" "$binc" "$cc_to"
    local cec=$?

    RUN_VM_OUT=""
    RUN_BIN_OUT=""
    RUN_VMEC=0
    RUN_BINEC=0
    local ok=1

    if [ $rec -eq 0 ] && [ $cec -eq 0 ]; then
        # the port gate: the two compilers must agree byte for byte
        if ! cmp -s "$binr" "$binc"; then
            ok=0
            RUN_VM_OUT="(binaries differ between compilers)"
            RUN_BIN_OUT="(binaries differ between compilers)"
        fi
        RUN_VM_OUT=$(timeout "$bin_to" "$binr" </dev/null 2>&1)
        RUN_VMEC=$?
        RUN_BIN_OUT=$(timeout "$bin_to" "$binc" </dev/null 2>&1)
        RUN_BINEC=$?
    else
        ok=0
        RUN_VM_OUT="$RUN_RERR"
        RUN_BIN_OUT="$RUN_CERR"
        RUN_VMEC="cf$rec"
        RUN_BINEC="cf$cec"
    fi
    rm -f "$binr" "$binc"

    if [ $ok -eq 1 ] && [ "$RUN_VM_OUT" = "$RUN_BIN_OUT" ] \
        && [ "$RUN_VMEC" = "$RUN_BINEC" ] \
        && { [ "$RUN_VMEC" = "0" ] || [ "$RUN_VMEC" = "1" ]; }; then
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
