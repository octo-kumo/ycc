#!/bin/bash
# Run the full y test suite (or a subset).
# Usage: ./test/sh/run_all.sh [-j N] [suite ...]
# Suites: port native native-examples examples audit ycc-units ycc fixpoint loops comprehensive debug link pkg stdin-eof net lsp coverage
# Default (no args): all suites. They compare the C copy ($CYCC, default
# ./cycc) with the reference ($YREF, default refs/ycc.ref); the ycc,
# fixpoint, native, native-examples, debug, link and pkg suites also drive a
# built compiler ($YSELF, default ./ycc — build it via `make ycc`) and skip
# themselves when it is absent.
# -j N (or YJOBS=N): up to N suites at once, the long ones split into shards
# (SHARDS below, YSHARD in lib.sh); each one's output is held until all are
# done, then printed in suite order. Default 1: one at a time, output live.
# Exit 0 iff every executed suite passes.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TESTS="$ROOT/test/sh"

JOBS="${YJOBS:-1}"
case "${1:-}" in
    -j) JOBS="$2"; shift 2 ;;
    -j*) JOBS="${1#-j}"; shift ;;
esac

if [ ! -x "${CYCC:-$ROOT/cycc}" ]; then
    echo "error: ${CYCC:-$ROOT/cycc} not found — run 'make' first" >&2
    exit 1
fi
if [ ! -x "${YREF:-$ROOT/refs/ycc.ref}" ]; then
    echo "error: ${YREF:-$ROOT/refs/ycc.ref} not found — the reference binary is the port's ground truth (see refs/)" >&2
    exit 1
fi
YSELF_BIN="${YSELF:-$ROOT/ycc}"

ALL="port native native-examples examples audit ycc-units ycc fixpoint loops comprehensive debug link pkg stdin-eof net lsp coverage"
SUITES="${*:-$ALL}"
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
    [link]="test_link.sh"
    [pkg]="test_pkg.sh"
    [stdin-eof]="test_stdin_eof.sh"
    [net]="test_net.sh"
    [lsp]="test_lsp.sh"
    [coverage]="test_coverage.sh"
)
# Under -j these run as this many shards at once: alone they take ~80, ~40
# and ~16 s, the others 13 s at most.
declare -A SHARDS=([port]=8 [comprehensive]=3 [native]=2)

for s in $SUITES; do
    if [ -z "${SCRIPT_FOR[$s]:-}" ]; then
        echo "error: unknown suite '$s' (pick from: $ALL)" >&2
        exit 2
    fi
done

# these suites exercise the built ycc binary itself.
skipped() {
    case "$1" in
        ycc | fixpoint | native | native-examples | debug | link | pkg) [ ! -x "$YSELF_BIN" ] ;;
        *) return 1 ;;
    esac
}

banner() {
    echo ""
    echo "################################################################"
    echo "# suite: $1"
    echo "################################################################"
}

FAILED=""
if [ "$JOBS" -le 1 ]; then
    for s in $SUITES; do
        if skipped "$s"; then
            banner "$s (SKIPPED: run 'make ycc' first)"
            continue
        fi
        banner "$s"
        bash "$TESTS/${SCRIPT_FOR[$s]}" || FAILED="$FAILED $s"
    done
else
    OUT="$(mktemp -d /tmp/yrun_all.XXXXXX)"
    trap 'rm -rf "$OUT"' EXIT
    # the sharded suites are the longest: they start first
    order=""
    for s in $SUITES; do [ -n "${SHARDS[$s]:-}" ] && order="$order $s"; done
    for s in $SUITES; do [ -z "${SHARDS[$s]:-}" ] && order="$order $s"; done
    running=0
    for s in $order; do
        skipped "$s" && continue
        n="${SHARDS[$s]:-1}"
        for ((k = 0; k < n; k++)); do
            if [ "$running" -ge "$JOBS" ]; then
                wait -n
                running=$((running - 1))
            fi
            (
                t0=$(date +%s%N)
                part=""
                if [ "$n" -gt 1 ]; then
                    export YSHARD="$k/$n"
                    part=" $((k + 1))/$n"
                fi
                bash "$TESTS/${SCRIPT_FOR[$s]}" >"$OUT/$s.$k" 2>&1
                rc=$?
                echo "$rc" >"$OUT/$s.$k.rc"
                ms=$(( ($(date +%s%N) - t0) / 1000000 ))
                verdict=ok
                [ "$rc" -eq 0 ] || verdict=FAILED
                printf '  %-6s %-20s %3d.%ds\n' "$verdict" "$s$part" $((ms / 1000)) $((ms % 1000 / 100))
            ) &
            running=$((running + 1))
        done
    done
    wait
    for s in $SUITES; do
        if skipped "$s"; then
            banner "$s (SKIPPED: run 'make ycc' first)"
            continue
        fi
        banner "$s"
        n="${SHARDS[$s]:-1}"
        ok=1
        for ((k = 0; k < n; k++)); do
            cat "$OUT/$s.$k"
            [ "$(cat "$OUT/$s.$k.rc" 2>/dev/null)" = 0 ] || ok=0
        done
        [ $ok -eq 1 ] || FAILED="$FAILED $s"
    done
fi

echo ""
echo "################################################################"
if [ -z "$FAILED" ]; then
    echo "# ALL SUITES PASSED ($SUITES)"
else
    echo "# SOME SUITES FAILED:$FAILED (see above)"
fi
echo "################################################################"
[ -z "$FAILED" ]
