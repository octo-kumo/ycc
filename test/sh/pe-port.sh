#!/bin/bash
# The WINDOWS half of the port gate: the C copy of the compiler (cycc) must
# produce BYTE-IDENTICAL **PE** binaries to the reference (refs/ycc.ref), for
# every test program, with and without -g.
#
# Why this exists, in one line: the Linux port suite cannot see the PE
# walkers, and round 52 proved it -- asm.c's pe_prologue_insn read b[0] before
# its `n < 1` guard, so a zero-byte item (a line marker, which is exactly what
# -g adds) trapped, and `cycc --target=windows -g` failed on EVERY program for
# ten rounds while every suite was green. The port suite compiles the corpus for
# Linux only; pe-gate.sh builds one -g PE with ./cycc now, and this is the
# corpus-wide version of that check.
#
# No wine: this is the writer, not the loader. `-g` is run over the whole corpus
# rather than a sample, because a line marker is what triggered the bug and
# which programs carry one is not something to guess at.
#
# Usage: ./test/sh/pe-port.sh   (YSHARD=K/N: one shard, see lib.sh)

source "$(dirname "$0")/lib.sh"

pe_port_check() {
    local file="$1" flags="$2"
    local name="${file#"$ROOT"/}${flags:+ ($flags)}"
    local binr binc rerr cerr rec cec
    binr=$(mktemp /tmp/ype_ref_XXXXXX)
    binc=$(mktemp /tmp/ype_cop_XXXXXX)
    local to=$(( 300 * YTIMEOUT_SCALE ))
    rerr=$(timeout "$to" "$YREF" --target=windows $flags -o "$binr" "$file" </dev/null 2>&1); rec=$?
    cerr=$(timeout "$to" "$CYCC" --target=windows $flags -o "$binc" "$file" </dev/null 2>&1); cec=$?
    if [ "$rec" -eq 1 ] && [ "$cec" -eq 1 ]; then
        if [ "$rerr" = "$cerr" ]; then
            pass "$name (rejected by both)"
        else
            fail "$name" "rejected by both, with different diagnostics: reference '$(echo "$rerr" | head -c 200 | tr '\n' '|')', copy '$(echo "$cerr" | head -c 200 | tr '\n' '|')'"
        fi
    elif [ "$rec" -ne 0 ] || [ "$cec" -ne 0 ]; then
        fail "$name" "reference exit=$rec, copy exit=$cec: $(echo "$cerr" | head -c 200 | tr '\n' '|')"
    elif ! cmp -s "$binr" "$binc"; then
        fail "$name" "PEs differ: reference=$(stat -c%s "$binr") bytes, copy=$(stat -c%s "$binc") bytes"
    elif [ "$rerr" != "$cerr" ]; then
        fail "$name" "different warnings: reference '$(echo "$rerr" | head -c 200 | tr '\n' '|')', copy '$(echo "$cerr" | head -c 200 | tr '\n' '|')'"
    else
        pass "$name"
    fi
    rm -f "$binr" "$binc"
}

while IFS= read -r f; do
    next_case && pe_port_check "$f" ""
done < <(find "$ROOT/test/y" -name '*.y' | sort)

while IFS= read -r f; do
    next_case && pe_port_check "$f" "-g"
done < <(find "$ROOT/test/y" -name '*.y' | sort)

print_summary "pe-port"
