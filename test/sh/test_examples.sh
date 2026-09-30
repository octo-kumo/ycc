#!/bin/bash
# Every test/y/examples/*.y must compile to the SAME binary with both
# compilers and behave identically.
# Usage: ./test/sh/test_examples.sh
# Stdin is /dev/null (shell.y is interactive; EOF ends it cleanly).
# The gate is lib.sh's run_parity: byte-identical binaries, then identical
# output and exit status. There is deliberately no "cosmetic signature
# printing" allowance: when the two sides printed different inferred
# signatures that was a real divergence between the compilers, and hiding it
# behind a grep -v would also hide every byte-identity break.

source "$(dirname "$0")/lib.sh"

echo "═══════════════════════════════════════════"
echo "  y examples parity (reference ycc vs C copy)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/examples/*.y; do
    name=$(basename "$f")
    if run_parity "$name" "$f"; then
        pass "$name"
    else
        fail "$name" "REF(ec=$RUN_REF_EC): $(echo "$RUN_REF_OUT" | head -c 200 | tr '\n' '|') / COPY(ec=$RUN_CPY_EC): $(echo "$RUN_CPY_OUT" | head -c 200 | tr '\n' '|')"
    fi
done

print_summary "examples"
