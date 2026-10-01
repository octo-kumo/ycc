#!/bin/bash
# Smoke-run every test/y/ycc/test_*.y fixture with the reference compiler.
# Usage: ./test/sh/test_ycc_units.sh
# These are debug/unit fixtures for the compiler's subcomponents
# (lexer/parser/codegen); the gate is "exits 0". Fixtures that cannot pass on
# the reference compiler are skiplisted below with reasons — not silently.

source "$(dirname "$0")/lib.sh"

skip_reason() {
    case "$1" in
        test_vm.y)
            echo "legacy snapshot: drives the old tree-walking vm.y fixture; it and vm.y use null plus the scope_*/map_set/map_get builtins, none of which exist now (first error: undefined variable 'null')" ;;
        test_partial.y)
            echo "debug fixture: imports partial.y, a truncated WIP snapshot — the file ends inside parse_postfix's body, so op_prec ends void and the parse_* calls it never defines are undefined" ;;
        *) echo "" ;;
    esac
}

echo "═══════════════════════════════════════════"
echo "  ycc unit fixtures (reference-compiler smoke)"
echo "═══════════════════════════════════════════"
echo ""

# Each fixture is compiled and run under a memory cap, not just a hang
# timeout. test_all_imports.y splices every std module and is the heaviest
# (~0.6 GB); a quadratic copy in the assembler once took it to tens of GB,
# which a timeout reports as a "hang" at best and as an OOM-killed machine at
# worst. Off (like YMEM_KB) for sanitized builds.
UNIT_MEM_KB="${UNIT_MEM_KB:-1572864}"
[ "$YMEM_KB" = unlimited ] && UNIT_MEM_KB=unlimited

for f in "$ROOT"/test/y/ycc/test_*.y; do
    base=$(basename "$f")
    reason=$(skip_reason "$base")
    if [ -n "$reason" ]; then
        skip "$base" "$reason"
        continue
    fi
    out=$( (ulimit -v "$UNIT_MEM_KB"; timeout $(( 20 * YTIMEOUT_SCALE )) "$YBOOT" -q "$f") </dev/null 2>&1); ec=$?
    if [ $ec -eq 0 ]; then
        pass "$base"
    elif [ $ec -eq 124 ]; then
        fail "$base" "hung ($(( 20 * YTIMEOUT_SCALE ))s timeout) — re-examine, do not skiplist"
    elif echo "$out" | grep -q "out of memory"; then
        fail "$base" "out of memory under the ${UNIT_MEM_KB} KB cap — a memory regression, do not raise the cap blindly"
    else
        fail "$base" "exit=$ec: $(echo "$out" | tail -c 200 | tr '\n' '|')"
    fi
done

print_summary "ycc-units"
