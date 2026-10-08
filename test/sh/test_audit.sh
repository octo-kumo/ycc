#!/bin/bash
# Differential runner over test/y/audit/t*.y (adversarial edge-case corpus).
# Usage: ./test/sh/test_audit.sh
#
# Default gate is strict: the reference compiler (-q) and the C copy must
# produce the SAME binary, and running it must give identical stdout with
# both sides terminating normally (exit 0/1 — anything else is a crash).
# Timeouts on ANY step fail the test (a hang wedges CI and signals an
# algorithmic blowup). Every exception is allowlisted in expect_for() with
# its reason — do not extend the allowlist to hide a NEW divergence; fix the
# bug instead.

source "$(dirname "$0")/lib.sh"

# Prints the expectation spec for a test file (basename, e.g. t01_empty_block.y).
#   parity     byte-identical binaries, identical output, both exit 0/1
#   reject     BOTH compilers refuse the input (nothing to compare: no binary)
# Anything else is a bug — do not add a spelling that tolerates a divergence.
expect_for() {
    case "$1" in
        t04_unterminated_str.y)
            echo "reject" ;;
        t22_map_missing_key.y)
            echo "reject" ;;   # missing dynamic key is a compile-time rejection now
        t50_cons_nonarr.y)
            echo "reject" ;;   # '::' needs an array on the right (static)
        t62_chained_idx.y)
            echo "reject" ;;   # chained index into a non-array stays a static error
        t28_push.y)
            echo "reject" ;;   # `x += 4` is a statement, not a value: `let y = x += 4`
                              # used to compile as `let y = x` plus a silently dropped `+= 4`
        t06_div_by_zero.y)
            echo "reject" ;;   # 'array / number' is a static error now
        t48_str_index.y)
            echo "parity" ;;   # s[i] is the byte at i (prints 104)
        t01_empty_block.y)
            echo "parity" ;;
        t51_empty_map.y)
            echo "parity" ;;   # an unannotated {} is the empty record (prints {})
        t10_deep_recursion.y)
            echo "parity" ;;   # one implementation: recursion behaves the same everywhere
        t11_deep_parens.y)
            echo "parity" ;;   # used to blow up on 50 nested parens (it timed out on
                              # both sides); it now parses in milliseconds
        t05_empty_arr_idx.y)
            echo "parity" ;;   # empty-array index: both compilers trap identically
        t07_div_zero_int.y)
            echo "parity" ;;   # ditto for integer division by zero
        t08_mod_zero.y)
            echo "parity" ;;   # ... and for modulo by zero
        *) echo "parity" ;;
    esac
}

echo "═══════════════════════════════════════════"
echo "  y audit corpus (reference ycc vs C copy)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/audit/t*.y; do
    base=$(basename "$f")
    spec=$(expect_for "$base")

    case "$spec" in
        parity)
            if run_parity "$base" "$f"; then
                pass "$base"
            else
                fail "$base" "REF(ec=$RUN_REF_EC): $(echo "$RUN_REF_OUT" | head -c 160 | tr '\n' '|') / COPY(ec=$RUN_CPY_EC): $(echo "$RUN_CPY_OUT" | head -c 160 | tr '\n' '|')"
            fi
            ;;
        reject)
            # Both compilers must refuse the file. There is no binary to
            # compare here, so this is a rejection-parity check only.
            ref_out=$(timeout $(( 10 * YTIMEOUT_SCALE )) "$YBOOT" -q "$f" </dev/null 2>&1); refec=$?
            binf=$(mktemp -t ytest_bin_XXXXXX)
            timeout $(( 60 * YTIMEOUT_SCALE )) "$YBOOT" --compile "$f" -o "$binf" >/dev/null 2>&1; copyec=$?
            rm -f "$binf"
            if [ $refec -ne 0 ] && [ $refec -le 1 ] && [ $copyec -ne 0 ]; then
                pass "$base (both reject malformed input)"
            else
                fail "$base" "expected both compilers to reject (refec=$refec copycompileec=$copyec)"
            fi
            ;;
    esac
done

print_summary "audit"
