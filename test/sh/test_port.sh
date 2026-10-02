#!/bin/bash
# The port gate: the C copy of the compiler (cycc, see PORTING.md) must
# produce BYTE-IDENTICAL binaries to the reference compiler
# (refs/ycc.ref) — for every test program AND for the compiler's own
# sources (src/y/ycc.y) — and print the same warnings (lint.y) doing so.
# Rejection is behavior too: a program BOTH compilers
# reject (exit 1), printing the same diagnostics, passes; a one-sided
# rejection fails. Only exit 1 counts as
# a rejection — a timeout (124), a crash or a missing file is never
# "rejected by both", it is a bug or a wedged compiler.
# Usage: ./test/sh/test_port.sh   (YSHARD=K/N: one shard of it, see lib.sh)

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
        if [ "$RUN_RERR" = "$RUN_CERR" ]; then
            pass "$name (rejected by both)"
        else
            fail "$name" "rejected by both, with different diagnostics: reference '$(echo "$RUN_RERR" | head -c 200 | tr '\n' '|')', copy '$(echo "$RUN_CERR" | head -c 200 | tr '\n' '|')'"
        fi
    elif [ $rec -ne 0 ] || [ $cec -ne 0 ]; then
        fail "$name" "reference exit=$rec, copy exit=$cec"
    elif ! cmp -s "$binr" "$binc"; then
        fail "$name" "binaries differ: reference=$(stat -c%s "$binr") bytes, copy=$(stat -c%s "$binc") bytes"
    elif [ "$RUN_RERR" != "$RUN_CERR" ]; then
        fail "$name" "different warnings: reference '$(echo "$RUN_RERR" | head -c 200 | tr '\n' '|')', copy '$(echo "$RUN_CERR" | head -c 200 | tr '\n' '|')'"
    else
        pass "$name"
    fi
    rm -f "$binr" "$binc"
}

# every test program, then the compiler itself — the biggest and most
# important input. YPORT_SELF=0 leaves the compiler out, for a caller that
# has just compared the C copy's build of it with $YREF (`make test` after
# `make ycc`, `make check`, `make rebless`).
while IFS= read -r f; do
    next_case && port_check "$f"
done < <(find "$ROOT/test/y" -name '*.y' | sort
         [ "${YPORT_SELF:-1}" = 0 ] || echo "$ROOT/src/y/ycc.y")

print_summary "port"
