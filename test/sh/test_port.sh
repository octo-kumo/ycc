#!/bin/bash
# The port gate: the C copy of the compiler (cycc, see PORTING.md) must
# produce BYTE-IDENTICAL binaries to the reference compiler
# (refs/ycc.ref) — for every test program AND for the compiler's own
# sources (src/y/ycc.y). Rejection is behavior too: a program BOTH compilers
# reject (exit 1) passes; a one-sided rejection fails. Only exit 1 counts as
# a rejection — a timeout (124), a crash or a missing file is never
# "rejected by both", it is a bug or a wedged compiler.
# Usage: ./test/sh/test_port.sh

source "$(dirname "$0")/lib.sh"

port_check() {
    local file="$1"
    local name="${file#"$ROOT"/}"
    local binr binc
    binr=$(mktemp /tmp/yport_ref_XXXXXX)
    binc=$(mktemp /tmp/yport_cop_XXXXXX)

    # the compiler's own source is the heaviest input here by far
    local to=$(( 300 * YTIMEOUT_SCALE ))
    compile_ref "$file" "$binr" "$to"
    local rec=$?
    compile_copy "$file" "$binc" "$to"
    local cec=$?

    if [ $rec -eq 1 ] && [ $cec -eq 1 ]; then
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
