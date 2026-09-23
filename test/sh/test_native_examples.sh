#!/bin/bash
# Every example that the NATIVE compiler accepts must behave like the VM.
# Usage: ./test/sh/test_native_examples.sh
#
# This is a ratchet, not a parity suite: examples listed in UNSUPPORTED are
# expected to be rejected (each line says why), everything else must compile
# with ./ycc and print what the VM prints. An example that starts compiling
# must be removed from UNSUPPORTED, and one that stops compiling fails here.
#
# Stdin is /dev/null (shell.y is interactive; EOF ends it cleanly).
# Known cosmetic divergence: the VM has no return-type inference and prints
# `<inferred>` where the native backend prints the real type. A test passes
# if the outputs differ ONLY on such signature lines.

source "$(dirname "$0")/lib.sh"

YCC="$ROOT/ycc"

# example -> reason it cannot compile natively (yet)
declare -A UNSUPPORTED=(
    [ysh.y]="needs heap maps with dynamic string keys (map_get), the :: operator, spawn(), and higher-order dispatch through a map"
)

# Line-by-line comparison that tolerates the VM's missing return-type
# inference: a differing line is acceptable only when the VM's version of
# that line is a signature placeholder (`<inferred>` / `<function ...>`).
cosmetic_match() {
    local vm="$1" nat="$2" n i a b
    n=$(printf '%s\n' "$vm" | wc -l)
    [ "$n" = "$(printf '%s\n' "$nat" | wc -l)" ] || return 1
    i=1
    while [ "$i" -le "$n" ]; do
        a=$(printf '%s\n' "$vm" | sed -n "${i}p")
        b=$(printf '%s\n' "$nat" | sed -n "${i}p")
        if [ "$a" != "$b" ]; then
            case "$a" in
                *'<inferred>'* | *'<function'*) ;;
                *) return 1 ;;
            esac
        fi
        i=$((i + 1))
    done
    return 0
}

echo "═══════════════════════════════════════════"
echo "  y examples under the native compiler"
echo "═══════════════════════════════════════════"
echo ""

if [ ! -x "$YCC" ]; then
    echo "error: $YCC not found — run 'make ycc' first" >&2
    exit 1
fi

for f in "$ROOT"/test/y/examples/*.y; do
    name=$(basename "$f")
    binf=$(mktemp /tmp/ynatex_XXXXXX)
    cc_out=$(timeout 120 "$YCC" -o "$binf" "$f" 2>&1)
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

    nat_out=$(timeout 10 "$binf" </dev/null 2>&1)
    nat_ec=$?
    rm -f "$binf"
    vm_out=$(timeout 10 "$YBOOT" -q "$f" </dev/null 2>&1)
    vm_ec=$?

    if [ "$nat_ec" -gt 1 ]; then
        fail "$name" "native binary exited $nat_ec (crash?): $(echo "$nat_out" | tail -c 200)"
    elif [ "$nat_out" = "$vm_out" ]; then
        pass "$name"
    elif cosmetic_match "$vm_out" "$nat_out"; then
        pass "$name (cosmetic signature-printing diff only)"
    else
        fail "$name" "VM(ec=$vm_ec): $(echo "$vm_out" | head -c 200 | tr '\n' '|') / NATIVE(ec=$nat_ec): $(echo "$nat_out" | head -c 200 | tr '\n' '|')"
    fi
done

print_summary "native-examples"
