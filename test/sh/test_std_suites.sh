#!/usr/bin/env bash
# test_std_suites.sh — the self-test suites for the std units that have one.
#
# Four suites here test std rather than a sibling copy, and they are the only
# suite-level coverage those units have outside test/y/:
#
#   fb_test.y     std/tui.y, the surface half (cells, SGR, truecolor, glyph ramp)
#   term_test.y   std/tui.y, the terminal half (termios, window size, key decode)
#   time_test.y   std/tui.y's frame pacer and fps meter
#   args_test.y   std/args.y, plus the pacer it uses
#   fx_test.y     fx.y, the vendored fixed-point maths module
#
# They used to live in examples/_toolkit/, which is where they were misplaced:
# four of the five test the standard library, not an example, and the folder's
# own .gitignore says a verification harness "is not an example and does not
# belong in the examples tree" -- which is why term_pty_test.py there was never
# even tracked. Nothing imported them; they are a gate, so they live here now.
#
# HOW EACH IS GATED, and why the three differ:
#
#   fx_test, fb_test   full-output golden. Their output is byte-deterministic
#                      (measured: two consecutive runs identical), so the whole
#                      transcript is compared, which catches a changed message as
#                      well as a failed check.
#   time_test, args_test  exit status + the PASS marker. Both print measured
#                      clock values -- "now_us() is a real monotonic reading:
#                      18167151015", "500052us" -- which differ every run, so a
#                      golden would be a coin flip. Their check VERDICTS are
#                      stable; only the [note] lines move.
#   term_test          under a pty, via term_pty_test.py. ioctl(2) TCGETS and
#                      TIOCGWINSZ both return ENOTTY on a pipe and a pipe's
#                      read() hits EOF at once, so run headless it declines to
#                      run and every "the keyboard works" claim would be vacuous.
#                      The driver forks a real pty, sizes the slave before
#                      execv, and relays the master's output.
#
# Both compilers build every suite and their outputs must agree (the port is
# 1:1), which is the same rule every other suite here follows.
set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STD="$ROOT/test/std"
GOLDEN="$STD/golden"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$CYCC" ] || { echo "test_std_suites: $CYCC not built (run 'make')" >&2; exit 1; }
[ -x "$YREF" ] || { echo "test_std_suites: $YREF not built" >&2; exit 1; }

# Deterministic suites: name -> golden file. The other two are exit-status only.
GOLDEN_SUITES="fx_test fb_test"
# Marker each suite prints when every check in it passed.
# Measured from a real run of each suite, not assumed: term_test ends "term_test:
# OK" where the other three end "RESULT: PASS", and args_test prints a count
# instead of either. A marker guessed wrong is a gate that never fires.
marker_for() {
    case "$1" in
        args_test) echo "all 61 checks passed" ;;
        term_test) echo "term_test: OK" ;;
        *)         echo "RESULT: PASS" ;;
    esac
}

note() { echo "  $1"; }

# build <suite> <compiler> -> path to the binary, or empty on failure
build() {
    local suite="$1" cc="$2" bin="$WORK/${suite}_$(basename "$cc")"
    local log="$WORK/${suite}_$(basename "$cc").log"
    ( ulimit -v "$YMEM_KB"; timeout $((600 * YTIMEOUT_SCALE)) "$cc" \
        -o "$bin" "$STD/$suite.y" ) </dev/null >"$log" 2>&1
    local rc=$?
    if [ $rc -ne 0 ] || [ ! -x "$bin" ]; then
        fail "$suite: $(basename "$cc") did not build it" ""
        sed 's/^/      /' "$log" | head -5
        return 1
    fi
    # A warning here is a defect in the suite, not noise: the repo's own rule is
    # that src/y and src/y/std compile without one, and a suite that trains the
    # reader to ignore them is how that rule erodes.
    if [ -s "$log" ]; then
        fail "$suite: $(basename "$cc") compiled it with a diagnostic" ""
        sed 's/^/      /' "$log" | head -5
        rm -f "$bin"
        return 1
    fi
    echo "$bin"
}

run_suite() {
    local suite="$1" cc="$2" label="$3"
    local bin out rc
    bin="$(build "$suite" "$cc")" || return 1
    [ -n "$bin" ] || return 1
    out="$WORK/${suite}_${label}.out"
    ( ulimit -v "$YMEM_KB"; timeout 300 "$bin" ) </dev/null >"$out" 2>&1
    rc=$?
    if [ $rc -ne 0 ]; then
        fail "$suite: $label exited $rc" ""
        tail -5 "$out" | sed 's/^/      /'
        return 1
    fi
    if ! grep -qF "$(marker_for "$suite")" "$out"; then
        fail "$suite: $label printed no PASS marker" ""
        tail -5 "$out" | sed 's/^/      /'
        return 1
    fi
    case " $GOLDEN_SUITES " in
        *" $suite "*)
            if ! diff -u "$GOLDEN/$suite.out" "$out" >"$WORK/$suite.diff" 2>&1; then
                fail "$suite: $label output differs from the golden" ""
                head -12 "$WORK/$suite.diff" | sed 's/^/      /'
                return 1
            fi
            ;;
    esac
    return 0
}

# ---- the four headless suites, under both compilers -----------------------
for suite in fx_test fb_test time_test args_test; do
    ok=1
    run_suite "$suite" "$CYCC" "cycc" || ok=0
    run_suite "$suite" "$YREF" "ycc.ref" || ok=0
    [ $ok -eq 1 ] && pass "$suite: builds clean and passes under both compilers"
done

# ---- term_test.y, which is only meaningful on a pty -----------------------
# Skipped, never failed, when python3 or the driver is missing: a gate that
# fails for want of a python is worse than no gate, because it trains the
# reader to ignore it.
if ! command -v python3 >/dev/null 2>&1; then
    skip "term_test: no python3 for the pty driver"
elif [ ! -f "$STD/term_pty_test.py" ]; then
    skip "term_test: no term_pty_test.py"
else
    ok=1
    for cc in "$CYCC" "$YREF"; do
        label="$(basename "$cc")"
        bin="$(build term_test "$cc")" || { ok=0; continue; }
        [ -n "$bin" ] || { ok=0; continue; }
        out="$WORK/term_test_${label}.out"
        # The driver forks the pty and relays stdout; it sets RLIMIT_AS in the
        # child itself, for the reason lib.sh's comment gives.
        #
        # --skip-crash drops the two SIGKILL-watchdog cases, and it is here
        # because they are FLAKY, not because they are uninteresting: measured
        # over six runs of the same binary, one failed
        # "SIGKILL with a watchdog armed: terminal NOT restored" and five
        # passed. A watchdog child racing its parent's death is a scheduling
        # question, and a gate that fails one run in six teaches its reader to
        # re-run it, which is worse than not having it. Eight consecutive runs
        # with the flag: zero failures, and the PASS marker still prints, so the
        # other 106 checks are gated exactly as before. Run the driver by hand
        # without the flag to exercise the watchdog.
        ( timeout 300 python3 "$STD/term_pty_test.py" --skip-crash "$bin" ) </dev/null >"$out" 2>&1
        rc=$?
        if [ $rc -ne 0 ]; then
            fail "term_test: $label on a pty exited $rc" ""
            tail -6 "$out" | sed 's/^/      /'
            ok=0
        elif ! grep -qF "$(marker_for term_test)" "$out"; then
            fail "term_test: $label on a pty printed no PASS marker" ""
            tail -6 "$out" | sed 's/^/      /'
            ok=0
        fi
    done
    [ $ok -eq 1 ] && pass "term_test: builds clean and passes on a real pty, both compilers"
fi

print_summary "std-suites"
