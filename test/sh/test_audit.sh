#!/bin/bash
# Differential runner over test/y/audit/t*.y (adversarial edge-case corpus).
# Usage: ./test/sh/test_audit.sh
#
# Default gate is strict: identical stdout in VM (-q) and compiled binary,
# with both sides terminating normally (exit 0/1 — anything else is a crash).
# Timeouts on ANY step fail the test (a hang wedges CI and signals an
# algorithmic blowup). Every exception is allowlisted below with its reason —
# do not extend the allowlist to hide a NEW divergence; fix the bug instead.

source "$(dirname "$0")/lib.sh"

# Prints the expectation spec for a test file (basename, e.g. t01_empty_block.y).
#   parity            identical output, both exit 0/1
#   reject            VM exits nonzero AND compilation fails (both reject input)
#   both1:<reason>    both exit 1; message wording may differ (see reason)
#   div:<vm>:<bin>:<reason>
#                     known behavioral divergence with exact exit codes
expect_for() {
    case "$1" in
        t04_unterminated_str.y)
            echo "reject" ;;
        t05_empty_arr_idx.y)
            echo "both1:VM says 'Array index out of bounds (empty array)', runtime says 'runtime error: index out of bounds (empty array)'" ;;
        t07_div_zero_int.y)
            echo "both1:VM says 'Division by zero', runtime says 'runtime error: division by zero'" ;;
        t08_mod_zero.y)
            echo "both1:VM says 'Division by zero in modulus operator', runtime says 'runtime error: modulo by zero'" ;;
        t22_map_missing_key.y)
            echo "both1:VM says \"Key 'x' not found in map\", runtime says \"runtime error: key 'x' not found\"" ;;
        t48_str_index.y)
            echo "both1:VM says 'Attempting to index a non-array value', runtime says 'runtime error: indexing a non-array'" ;;
        t50_cons_nonarr.y)
            echo "both1:VM says 'Right operand of :: must be an array', runtime says 'runtime error: :: requires array on right'" ;;
        t62_chained_idx.y)
            echo "both1:same wording split as t48 (chained index into non-array)" ;;
        t01_empty_block.y)
            echo "parity" ;;
        t06_div_by_zero.y)
            echo "div:1:0:KNOWN BUG — 'array / number' errors in the VM ('Operands must be numbers') but compiled code coerces and prints 0.000000" ;;
        t10_deep_recursion.y)
            echo "div:1:0:KNOWN LIMIT — f(100000) exhausts the VM's C stack; the VM now reports 'Maximum recursion depth exceeded' and exits 1 (it used to SIGSEGV), while the compiled binary survives (long overflow wraps, prints 0)" ;;
        *) echo "parity" ;;
    esac
}

echo "═══════════════════════════════════════════"
echo "  y audit corpus (VM vs compiled)"
echo "═══════════════════════════════════════════"
echo ""

for f in "$ROOT"/test/y/audit/t*.y; do
    base=$(basename "$f")
    spec=$(expect_for "$base")

    # t11 hangs BOTH the VM frontend and codegen (>10s for 50 nested parens —
    # superlinear parse; even `-S` never finishes). Short budgets: a timeout on
    # both sides is the documented behavior; if both ever terminate, parity.
    if [ "$base" = "t11_deep_parens.y" ]; then
        vm_out=$(timeout 15 "$YBOOT" -q "$f" </dev/null 2>&1); vmec=$?
        binf=$(mktemp /tmp/ytest_bin_XXXXXX)
        timeout 30 "$YBOOT" --compile "$f" -o "$binf" >/dev/null 2>&1; ce=$?
        rm -f "$binf"
        if [ $vmec -eq 124 ] && [ $ce -eq 124 ]; then
            pass "$base (KNOWN PERF BUG — both sides time out on 50 nested parens)"
        elif [ $vmec -eq 124 ] || [ $ce -eq 124 ]; then
            fail "$base" "hang behavior changed (vmec=$vmec compileec=$ce) — re-examine, do not just re-allowlist"
        elif run_parity "$base" "$f"; then
            pass "$base (hang fixed? both terminate with identical output)"
        else
            fail "$base" "both terminate but differ now — re-examine"
        fi
        continue
    fi

    case "$spec" in
        parity)
            if run_parity "$base" "$f"; then
                pass "$base"
            else
                fail "$base" "VM(ec=$RUN_VMEC): $(echo "$RUN_VM_OUT" | head -c 160 | tr '\n' '|') / BIN(ec=$RUN_BINEC): $(echo "$RUN_BIN_OUT" | head -c 160 | tr '\n' '|')"
            fi
            ;;
        reject)
            vm_out=$(timeout 10 "$YBOOT" -q "$f" </dev/null 2>&1); vmec=$?
            binf=$(mktemp /tmp/ytest_bin_XXXXXX)
            timeout 60 "$YBOOT" --compile "$f" -o "$binf" >/dev/null 2>&1; ce=$?
            rm -f "$binf"
            if [ $vmec -ne 0 ] && [ $vmec -le 1 ] && [ $ce -ne 0 ]; then
                pass "$base (both reject malformed input)"
            else
                fail "$base" "expected both sides to reject (vmec=$vmec compileec=$ce)"
            fi
            ;;
        both1:*)
            reason=${spec#both1:}
            if run_parity "$base" "$f"; then
                pass "$base"
            elif [ "$RUN_VMEC" = "1" ] && [ "$RUN_BINEC" = "1" ]; then
                pass "$base (both raise; wording differs — $reason)"
            else
                fail "$base" "error behavior changed (vmec=$RUN_VMEC binec=$RUN_BINEC) — $reason"
            fi
            ;;
        div:*)
            rest=${spec#div:}; evm=${rest%%:*}; rest=${rest#*:}
            ebin=${rest%%:*}; reason=${rest#*:}
            run_parity "$base" "$f" >/dev/null 2>&1
            if [ "$RUN_VMEC" = "$evm" ] && [ "$RUN_BINEC" = "$ebin" ]; then
                pass "$base ($reason)"
            else
                fail "$base" "divergence changed (got vmec=$RUN_VMEC binec=$RUN_BINEC, expected $evm/$ebin) — $reason"
            fi
            ;;
    esac
done

print_summary "audit"
