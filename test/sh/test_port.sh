#!/bin/bash
# The port gate: the C copy of the compiler (cycc, see PORTING.md) must
# produce BYTE-IDENTICAL binaries to the reference compiler
# (refs/ycc.ref) — for every test program AND for the compiler's own
# sources (src/y/ycc.y). Rejection is behavior too: a program both
# compilers reject passes; a one-sided rejection fails.
# Usage: ./test/sh/test_port.sh

source "$(dirname "$0")/lib.sh"

port_check() {
    local file="$1"
    local name="${file#"$ROOT"/}"
    local binr binc
    binr=$(mktemp /tmp/yport_ref_XXXXXX)
    binc=$(mktemp /tmp/yport_cop_XXXXXX)

    compile_ref "$file" "$binr" 300
    local rec=$?
    compile_copy "$file" "$binc" 300
    local cec=$?

    if [ $rec -ne 0 ] && [ $cec -ne 0 ]; then
        pass "$name (rejected by both)"
    elif [ $rec -ne 0 ] || [ $cec -ne 0 ]; then
        fail "$name" "reference exit=$rec, copy exit=$cec"
    elif cmp -s "$binr" "$binc"; then
        pass "$name"
    else
        fail "$name" "binaries differ: reference=$(stat -c%s "$binr") bytes, copy=$(stat -c%s "$binc") bytes"
    fi
    rm -f "$binr" "$binc"
}

# every test program
while IFS= read -r f; do
    port_check "$f"
done < <(find "$ROOT/test/y" -name '*.y' | sort)

# and the compiler itself — the biggest and most important input
port_check "$ROOT/src/y/ycc.y"

print_summary "port"
