#!/bin/bash
# test/sh/ytool.sh — the suites' engine shim.
#
# The toolchain is one implementation twice over (PORTING.md). The suites
# were written against a two-engine world ("VM" vs "compiled"); the two
# engines are now the two compilers:
#
#   ytool.sh -q FILE              -> compile with the REFERENCE ycc and
#                                    run it (the old "VM" side)
#   ytool.sh --compile FILE -o B  -> compile with the C COPY (cycc)
#                                    (the old "compiled" side)
#
# so every suite's test content is preserved unchanged. The byte-identical
# port gate lives in test_port.sh. Overridable: YREF, CYCC.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
YREF="${YREF:-$ROOT/refs/ycc.ref}"
CYCC="${CYCC:-$ROOT/cycc}"

case "${1:-}" in
-q)
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
