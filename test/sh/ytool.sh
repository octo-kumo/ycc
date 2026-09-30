#!/bin/bash
# test/sh/ytool.sh — the suites' two-compiler shim.
#
# The toolchain is one implementation twice over (PORTING.md): $YREF is the
# reference ycc binary and $CYCC the C copy. Both compile .y straight to a
# static ELF, so this shim only forwards two invocations:
#
#   ytool.sh -q FILE              -> compile with the REFERENCE ycc, run it
#   ytool.sh --compile FILE -o B  -> compile with the C COPY (cycc), stop
#
# The flag names are historical: the suites were written when the two
# engines were "the VM" and "the compiled side", and they kept that shape
# (and their test content) when both sides became compilers. Retiring the
# shim is a separate cleanup, not this file's job.
#
# The byte-identical port gate lives in test_port.sh (lib.sh's run_parity
# checks it per program). Overridable: YREF, CYCC.
#
# NOTE: -q runs the program with the caller's stdin, so a suite can drive it
# (test_stdin_eof.sh feeds a FIFO). Do not add a </dev/null here.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YREF="${YREF:-$ROOT/refs/ycc.ref}"
CYCC="${CYCC:-$ROOT/cycc}"

case "${1:-}" in
-q)
    # reference side: compile, then run (stdin is the caller's).
    file="${2:?ytool: -q needs a file}"
    bin=$(mktemp /tmp/ytool_run_XXXXXX)
    if ! "$YREF" -o "$bin" "$file" </dev/null; then
        rm -f "$bin"
        exit 1
    fi
    "$bin"
    rc=$?
    rm -f "$bin"
    exit $rc
    ;;
--compile)
    # C-copy side: compile only, the suite runs the binary itself.
    file="${2:?ytool: --compile needs a file}"
    shift 2
    out="a.out"
    while [ $# -gt 0 ]; do
        case "$1" in
        -o)
            out="${2:?ytool: -o needs an argument}"
            shift 2
            ;;
        *) shift ;;
        esac
    done
    exec "$CYCC" -o "$out" "$file"
    ;;
*)
    echo "ytool: unsupported invocation: $*" >&2
    exit 2
    ;;
esac
