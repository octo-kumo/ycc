#!/bin/bash
# Smoke-run every test/y/ycc/test_*.y fixture in the reference VM.
# Usage: ./test/sh/test_ycc_units.sh
# These are debug/unit fixtures for the self-hosted compiler's subcomponents
# (lexer/parser/codegen); the gate is "exits 0". Fixtures that cannot pass on
# the reference compiler are skiplisted below with reasons — not silently.

source "$(dirname "$0")/lib.sh"

skip_reason() {
    case "$1" in
        test_vm.y)
            echo "needs scope_new/scope_def/... builtins that only ycc's own vm.y provides (Undefined variable: scope_new)" ;;
        test_partial.y)
            echo "debug fixture: imports partial.y, a truncated WIP snapshot (export mid-file, unclosed body) — unparseable by design" ;;
        *) echo "" ;;
    esac
}

echo "═══════════════════════════════════════════"
echo "  ycc unit fixtures (VM smoke)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/ycc/test_*.y; do
    base=$(basename "$f")
    reason=$(skip_reason "$base")
    if [ -n "$reason" ]; then
        skip "$base" "$reason"
        continue
    fi
    out=$(timeout 20 "$YBOOT" -q "$f" </dev/null 2>&1); ec=$?
    if [ $ec -eq 0 ]; then
        pass "$base"
    elif [ $ec -eq 124 ]; then
        fail "$base" "hung (20s timeout) — re-examine, do not skiplist"
    else
        fail "$base" "exit=$ec: $(echo "$out" | tail -c 200 | tr '\n' '|')"
    fi
done

print_summary "ycc-units"
