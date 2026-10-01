#!/bin/bash
# Run the full y test suite (or a subset).
# Usage: ./test/sh/run_all.sh [suite ...]
# Suites: port native native-examples examples audit ycc-units ycc fixpoint loops comprehensive debug stdin-eof
# Default (no args): all suites. The port suite needs both compilers
# (./cycc and refs/ycc.ref); the ycc/fixpoint suites need ./ycc (build it
# via `make ycc`) and skip themselves when it is absent.
# Exit 0 iff every executed suite passes.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS="$ROOT/test/sh"

if [ ! -x "$ROOT/cycc" ]; then
    echo "error: $ROOT/cycc not found — run 'make' first" >&2
    exit 1
fi
if [ ! -x "$ROOT/refs/ycc.ref" ]; then
    echo "error: $ROOT/refs/ycc.ref not found — the reference binary is the port's ground truth (see refs/)" >&2
    exit 1
fi

SUITES="${*:-port native native-examples examples audit ycc-units ycc fixpoint loops comprehensive debug stdin-eof}"
declare -A SCRIPT_FOR=(
    [port]="test_port.sh"
    [native]="test_native.sh"
    [native-examples]="test_native_examples.sh"
    [examples]="test_examples.sh"
    [audit]="test_audit.sh"
    [ycc-units]="test_ycc_units.sh"
    [ycc]="test_ycc.sh"
    [fixpoint]="test_fixpoint.sh"
    [loops]="test_loops.sh"
    [comprehensive]="test_comprehensive.sh"
    [debug]="test_debug.sh"
    [stdin-eof]="test_stdin_eof.sh"
)

OVERALL=0
for s in $SUITES; do
    script="${SCRIPT_FOR[$s]}"
    if [ -z "$script" ]; then
        echo "error: unknown suite '$s' (pick from: port native native-examples examples audit ycc-units ycc fixpoint loops comprehensive debug stdin-eof)" >&2
        exit 2
    fi
    # these suites exercise the built ycc binary itself.
    if [ "$s" = "ycc" ] || [ "$s" = "fixpoint" ] || [ "$s" = "native" ] \
        || [ "$s" = "native-examples" ] || [ "$s" = "debug" ]; then
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
