#!/bin/bash
# test/sh/lib.sh — shared helpers for the y test suites.
# Usage: source "$(dirname "$0")/lib.sh"
# Provides: ROOT, CYCC, YREF, YBOOT, YTIMEOUT_SCALE, colors, PASS/FAIL/SKIP
# counters, pass/fail/skip reporters, next_case (YSHARD), run_parity(),
# print_summary().

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The toolchain is one language implementation twice over: $CYCC is the C
# copy of the compiler (PORTING.md) and $YREF the reference ycc binary.
# Both compile .y straight to static ELFs; every test requires the two to
# agree — byte-identical binaries and identical program behavior.
CYCC="${CYCC:-$ROOT/cycc}"
# The two-engine helper the older suites call as `$YBOOT -q` /
# `$YBOOT --compile`; it maps those flags onto $YREF and $CYCC (ytool.sh).
# Defined here so every suite that sources lib.sh gets it.
YBOOT="${YBOOT:-$ROOT/test/sh/ytool.sh}"
YREF="${YREF:-$ROOT/refs/ycc.ref}"

# A sanitized COMPILER runs roughly 15x slower, so the default timeouts
# below would flag heavy tests (audit/t45_fib) as hangs. Scale them instead
# of weakening the limits for everyone. Only the compiler steps scale: the
# binaries the compilers emit are plain static ELFs, so their run timeout
# (run_parity's $3) is deliberately NOT scaled.
YTIMEOUT_SCALE=1
case "$CYCC$YREF" in
    *asan* | *msan* | *ubsan*) YTIMEOUT_SCALE=15 ;;
esac

# Every compile (and every compiled program) a suite runs is under a
# virtual-memory cap, in KB (`ulimit -v`, set once here for the whole suite
# process). Past it the allocator fails and the compiler or program exits 1
# with "out of memory", so a memory regression is a FAILED test rather than a
# machine pushed into swap or the OOM killer: the self-compile once peaked at
# 32 GB, `make test` ran it twice, and every run "passed". The cap stays
# below 4 GB, past which this machine goes down. The heaviest legitimate
# input is cycc compiling src/y/ycc.y (~1.9 GB RSS; ./ycc needs ~1.1 GB for
# the same file). Sanitized builds reserve terabytes of virtual address
# space up front, so for them the cap is ASan's own RSS limit instead.
YMEM_KB="${YMEM_KB:-3670016}"
case "$CYCC$YREF" in
    *asan* | *msan* | *ubsan*)
        YMEM_KB=unlimited
        export ASAN_OPTIONS="${ASAN_OPTIONS:+$ASAN_OPTIONS:}hard_rss_limit_mb=3500"
        ;;
esac
ulimit -v "$YMEM_KB"

# The programs the compilers emit keep a cap even when the suite-wide one is
# off: only a sanitized COMPILER needs the address space, and a test like
# native t71 (a 16 GB array, the largest `[0; n]` there is) must see its
# allocation fail, not page until the timeout. run_bin <timeout> <bin>
# [args...] runs a compiled program.
YPROG_MEM_KB="${YPROG_MEM_KB:-3670016}"
run_bin() {
    local to=$1
    shift
    if [ "$(ulimit -v)" = unlimited ]; then
        (ulimit -v "$YPROG_MEM_KB"; exec timeout "$to" "$@")
    else
        timeout "$to" "$@"
    fi
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

# YQUIET=1 lists only failures and skips (and the summary), not each pass.
pass() { [ -n "${YQUIET:-}" ] || echo -e "${GREEN}PASS${NC} $1"; PASS=$((PASS + 1)); }
fail() {
    echo -e "${RED}FAIL${NC} $1"
    [ -n "${2:-}" ] && echo "  $2"
    FAIL=$((FAIL + 1))
}
skip() { echo -e "${YELLOW}SKIP${NC} $1${2:+ ($2)}"; SKIP=$((SKIP + 1)); }

# YSHARD=K/N (run_all.sh -j sets it for the long suites): N runs of one
# suite split its cases, each taking every Nth case from the Kth (0-based).
# A shardable suite calls next_case before each case: true iff the case is
# this run's. Without YSHARD every case is.
_YCASE=-1
next_case() {
    _YCASE=$((_YCASE + 1))
    [ -z "${YSHARD:-}" ] || (( _YCASE % ${YSHARD#*/} == ${YSHARD%/*} ))
}

# $YFLAGS rides on every compile a suite drives (e.g. YFLAGS="-W 1"). Empty by
# default, so a suite behaves exactly as before unless it asks. The port gate
# uses it to compare the two copies at warning level 1, where the level-1 lint
# runs: without that pass a divergence in any level-1 check is invisible,
# because at the default level those checks draw nothing (lint.y's
# `wlevel >= 1` guards).
YFLAGS=${YFLAGS:-}

# compile_ref <file> <bin> [timeout]  — compile with the reference ycc.
# compile_copy <file> <bin> [timeout] — compile with the C copy.
# Exit = the compiler's exit; diagnostics land in RUN_RERR / RUN_CERR.
compile_ref() {
    RUN_RERR=$(timeout "${3:-60}" "$YREF" ${YFLAGS:+$YFLAGS} -o "$2" "$1" </dev/null 2>&1)
    return $?
}
compile_copy() {
    RUN_CERR=$(timeout "${3:-60}" "$CYCC" ${YFLAGS:+$YFLAGS} -o "$2" "$1" </dev/null 2>&1)
    return $?
}

# run_parity <name> <file> [compile_timeout] [bin_timeout]
# Compiles <file> with BOTH compilers and requires:
#   - byte-identical binaries (the port gate) and the same warnings (what a
#     compile that succeeds prints: lint.y),
#   - identical program output and exit code when run (fed /dev/null).
# Returns 0 on agreement, 1 otherwise.
# RUN_REF_OUT/RUN_REF_EC carry the reference side, RUN_CPY_OUT/RUN_CPY_EC
# the C-copy side (the suites read those). On compile failure the outputs
# hold the compiler diagnostics and the exit codes are "cfN".
# A program may only exit 0 or 1: anything else is a crash, a hang or an
# abort and never an agreed-upon result.
run_parity() {
    local name="$1" file="$2"
    # One compile budget for both compilers: they are the same program and
    # cost the same, so a per-side timeout (the third argument this helper
    # used to take) had nothing left to say.
    local cc_to=$(( ${3:-60} * YTIMEOUT_SCALE ))
    local bin_to="${4:-10}"

    local binr binc
    binr=$(mktemp -t ytest_ref_XXXXXX)
    binc=$(mktemp -t ytest_cop_XXXXXX)
    # Each run's output goes to a FILE, not $(...): command substitution drops
    # NUL bytes (bash even warns about it), so a program that prints NULs
    # (test/y/audit/t61_null_byte2.y) was compared on truncated output. The
    # variables are filled in by reading those files afterwards.
    local outr outc
    outr=$(mktemp -t ytest_outr_XXXXXX)
    outc=$(mktemp -t ytest_outc_XXXXXX)

    compile_ref "$file" "$binr" "$cc_to"
    local rec=$?
    compile_copy "$file" "$binc" "$cc_to"
    local cec=$?

    RUN_REF_OUT=""
    RUN_CPY_OUT=""
    RUN_REF_EC=0
    RUN_CPY_EC=0
    local ok=1
    local differ=0

    if [ $rec -eq 0 ] && [ $cec -eq 0 ]; then
        # the port gate: the two compilers must agree byte for byte
        if ! cmp -s "$binr" "$binc"; then
            ok=0
            differ=1
        fi
        local wdiffer=0
        if [ "$RUN_RERR" != "$RUN_CERR" ]; then
            ok=0
            wdiffer=1
        fi
        run_bin "$bin_to" "$binr" </dev/null >"$outr" 2>&1
        RUN_REF_EC=$?
        run_bin "$bin_to" "$binc" </dev/null >"$outc" 2>&1
        RUN_CPY_EC=$?
        if cmp -s "$outr" "$outc"; then
            RUN_REF_OUT=$(cat "$outr")
            RUN_CPY_OUT=$(cat "$outc")
        else
            # differ: cmp is the real check (NUL-safe), the strings are only
            # for the report
            ok=0
            RUN_REF_OUT="$(printf '(output differs)\n'; od -c <"$outr" | head -5)"
            RUN_CPY_OUT="$(printf '(output differs)\n'; od -c <"$outc" | head -5)"
        fi
        if [ $differ -eq 1 ]; then
            # Both programs behaved identically yet the binaries differ.
            # Keep that in the reported output, or the failure reads as
            # "identical output" and hides the one thing that broke.
            RUN_REF_OUT="(binaries differ between compilers)"$'\n'"$RUN_REF_OUT"
            RUN_CPY_OUT="(binaries differ between compilers)"$'\n'"$RUN_CPY_OUT"
        fi
        if [ $wdiffer -eq 1 ]; then
            RUN_REF_OUT="(warnings differ between compilers)"$'\n'"$RUN_RERR"$'\n'"$RUN_REF_OUT"
            RUN_CPY_OUT="(warnings differ between compilers)"$'\n'"$RUN_CERR"$'\n'"$RUN_CPY_OUT"
        fi
    else
        ok=0
        RUN_REF_OUT="$RUN_RERR"
        RUN_CPY_OUT="$RUN_CERR"
        RUN_REF_EC="cf$rec"
        RUN_CPY_EC="cf$cec"
    fi
    rm -f "$binr" "$binc" "$outr" "$outc"

    # the byte comparison already happened above (cmp on the output files);
    # here we only re-check the exit codes and the "only 0 or 1 is a result"
    # rule, since the strings may have been summarised for a diff report.
    if [ $ok -eq 1 ] && [ "$RUN_REF_EC" = "$RUN_CPY_EC" ] \
        && { [ "$RUN_REF_EC" = "0" ] || [ "$RUN_REF_EC" = "1" ]; }; then
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
