#!/bin/bash
# Every example must compile with the BUILT ycc and behave like the same
# example compiled with the reference compiler.
# Usage: ./test/sh/test_native_examples.sh
#
# This is a ratchet, not a parity suite: examples listed in UNSUPPORTED are
# expected to be REJECTED (each line says why), everything else must compile
# with ./ycc and print what the reference compiler's build prints. An
# example that starts compiling must be removed from UNSUPPORTED, and one
# that stops compiling fails here. The list is empty: every example in
# test/y/examples/ compiles today.
#
# Stdin is /dev/null (shell.y is interactive; EOF ends it cleanly).
# Outputs must match exactly. The old "a differing line is fine if the
# reference side printed a `<inferred>`/`<function>` placeholder" allowance
# is gone: both sides are the same compiler now (and print the same real
# signature), so any difference is a regression, not decoration. The
# byte-identity half of the gate lives in test_port.sh / lib.sh run_parity.

source "$(dirname "$0")/lib.sh"

# The built ycc (override with $YCC, e.g. the ASan build for make test-asan).
YCC="${YCC:-$ROOT/ycc}"

# example -> reason ycc cannot compile it (yet)
declare -A UNSUPPORTED=(
)

echo "═══════════════════════════════════════════"
echo "  y examples: built ycc vs the reference compiler"
echo "═══════════════════════════════════════════"
echo ""

if [ ! -x "$YCC" ]; then
    echo "error: $YCC not found — run 'make ycc' first" >&2
    exit 1
fi

for f in "$ROOT"/test/y/examples/*.y; do
    name=$(basename "$f")
    binf=$(mktemp -t ynatex_XXXXXX)
    cc_out=$(timeout $(( 120 * YTIMEOUT_SCALE )) "$YCC" -o "$binf" "$f" </dev/null 2>&1)
    cc_ec=$?
    reason="${UNSUPPORTED[$name]}"

    if [ -n "$reason" ]; then
        if [ $cc_ec -eq 0 ]; then
            fail "$name" "listed as unsupported but compiles now — drop it from UNSUPPORTED ($reason)"
        else
            skip "$name" "$reason"
        fi
        rm -f "$binf"
        continue
    fi

    if [ $cc_ec -ne 0 ]; then
        fail "$name" "ycc rejected it: $(echo "$cc_out" | head -1)"
        rm -f "$binf"
        continue
    fi

    built_out=$(run_bin 10 "$binf" </dev/null 2>&1)
    built_ec=$?
    rm -f "$binf"
    # the same example through the reference compiler (compile, then run)
    ref_out=$(timeout 10 "$YBOOT" -q "$f" </dev/null 2>&1)
    ref_ec=$?

    if [ "$built_ec" -gt 1 ]; then
        fail "$name" "ycc-built binary exited $built_ec (crash?): $(echo "$built_out" | tail -c 200)"
    elif [ "$built_out" = "$ref_out" ]; then
        pass "$name"
    else
        fail "$name" "REF(ec=$ref_ec): $(echo "$ref_out" | head -c 200 | tr '\n' '|') / BUILT(ec=$built_ec): $(echo "$built_out" | head -c 200 | tr '\n' '|')"
    fi
done

print_summary "native-examples"
