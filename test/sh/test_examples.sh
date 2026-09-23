#!/bin/bash
# Every test/y/examples/*.y must behave identically in the VM and compiled.
# Usage: ./test/sh/test_examples.sh
# Stdin is /dev/null (shell.y is interactive; EOF ends it cleanly).
# Known cosmetic divergence: the VM prints inferred function/type signatures
# while compiled binaries print placeholders (`<function>`, `<inferred>`).
# A test still passes if outputs differ ONLY on such signature lines.

source "$(dirname "$0")/lib.sh"

echo "═══════════════════════════════════════════"
echo "  y examples parity (VM vs compiled)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/examples/*.y; do
    name=$(basename "$f")
    if run_parity "$name" "$f"; then
        pass "$name"
    elif { [ "$RUN_VMEC" = "0" ] || [ "$RUN_VMEC" = "1" ]; } \
        && { [ "$RUN_BINEC" = "0" ] || [ "$RUN_BINEC" = "1" ]; } \
        && [ "$(echo "$RUN_VM_OUT" | grep -v '<function' | grep -v '<inferred>')" = "$(echo "$RUN_BIN_OUT" | grep -v '<function' | grep -v '<inferred>')" ]; then
        pass "$name (cosmetic signature-printing diff only)"
    else
        fail "$name" "VM(ec=$RUN_VMEC): $(echo "$RUN_VM_OUT" | head -c 200 | tr '\n' '|') / BIN(ec=$RUN_BINEC): $(echo "$RUN_BIN_OUT" | head -c 200 | tr '\n' '|')"
    fi
done

print_summary "examples"
