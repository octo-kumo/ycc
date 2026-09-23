#!/bin/bash
# Run the full y test suite (or a subset).
# Usage: ./test/sh/run_all.sh [suite ...]
# Suites: loops comprehensive examples audit ycc-units ycc fixpoint native native-examples stdin-eof
# Default (no args): all suites. The ycc suite skips itself when
# ./ycc is not built (build it via `make ycc`).
# The native and native-examples suites need it too (hard error, not a skip).
# Exit 0 iff every executed suite passes.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS="$ROOT/test/sh"

if [ ! -x "$ROOT/yboot" ]; then
    echo "error: $ROOT/yboot not found — run 'make' first" >&2
    exit 1
fi

SUITES="${*:-loops comprehensive examples audit ycc-units ycc fixpoint native native-examples stdin-eof}"
declare -A SCRIPT_FOR=(
    [loops]="test_loops.sh"
    [comprehensive]="test_comprehensive.sh"
    [examples]="test_examples.sh"
    [audit]="test_audit.sh"
    [ycc-units]="test_ycc_units.sh"
    [ycc]="test_ycc.sh"
    [fixpoint]="test_fixpoint.sh"
    [native]="test_native.sh"
    [native-examples]="test_native_examples.sh"
    [stdin-eof]="test_stdin_eof.sh"
)

OVERALL=0
for s in $SUITES; do
    script="${SCRIPT_FOR[$s]}"
    if [ -z "$script" ]; then
        echo "error: unknown suite '$s' (pick from: loops comprehensive examples audit ycc-units ycc fixpoint native native-examples stdin-eof)" >&2
        exit 2
    fi
    # native needs the bootstrap binary; test-fast may not have built it.
    if [ "$s" = "native" ] || [ "$s" = "native-examples" ]; then
        if [ ! -x "$ROOT/ycc" ]; then
            echo ""
            echo "################################################################"
            echo "# suite: $s (SKIPPED: run 'make ycc' first)"
            echo "################################################################"
            continue
        fi
    fi
    echo ""
    echo "################################################################"
    echo "# suite: $s"
    echo "################################################################"
    if ! bash "$TESTS/$script"; then
        OVERALL=1
    fi
done

echo ""
echo "################################################################"
if [ $OVERALL -eq 0 ]; then
    echo "# ALL SUITES PASSED ($SUITES)"
else
    echo "# SOME SUITES FAILED (see above)"
fi
echo "################################################################"
exit $OVERALL
