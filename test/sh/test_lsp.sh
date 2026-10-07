#!/bin/bash
# test_lsp.sh — the language server's own suites (LSP.md, src/tools/lsp/).
#
# Three things, each cheap enough to run every time:
#
#   fixtures   tNNN_*.y under src/tools/lsp/test, compiled with BOTH compilers
#              and compared against their .expected. Same rule as every other
#              suite: a std module or a tool that behaves differently under cycc
#              and refs/ycc.ref is a compiler bug, and that is the point.
#   refs       check-refs.py, which resolves every symbol LSP.md cites. LSP.md
#              names symbols rather than line numbers on purpose (src/y line
#              numbers drift by hundreds between edits), so this is what keeps
#              those citations honest.
#   format     the formatter over the whole corpus, checking it is idempotent
#              and that it does not fire on a buffer that does not lex.
#
# test-e2e.sh (the server as a real process: fork containment, framing,
# persistence across messages) is NOT here — it needs a process and takes
# seconds per case, so it is run by hand, or by `make lsp-e2e` if that is ever
# added. See LSP.md §11.

set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1

YREF="${YREF:-$ROOT/refs/ycc.ref}"
LSP="$ROOT/src/tools/lsp"

# Scratch for the two drivers that build and run programs. A mktemp like every
# other suite's, NOT a fixed path: two `make test` runs at once (a worktree
# and the main tree, say) would otherwise build the same fixture into the same
# file, and the second one's `open(O_TRUNC)` lands on a binary the first is
# still running -- ETXTBSY, which the driver reports as
# `error: writing '...' failed`. `OUT` still wins when a caller sets it
# (test-e2e.sh does), and only a directory we made is removed.
SCRATCH=""
if [ -z "${OUT:-}" ]; then
    SCRATCH="$(mktemp -d /tmp/ylsp_test.XXXXXX)"
    OUT="$SCRATCH/json"
fi
if [ -n "$SCRATCH" ]; then
    FMT_OUT="$SCRATCH/fmt"
else
    FMT_OUT="${FMT_OUT:-/tmp/opencode/fmt}"
fi
cleanup_lsp() { [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"; return 0; }
trap cleanup_lsp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

rc=0
section() { echo ""; echo "---- $1"; }

# ── LSP.md's references ─────────────────────────────────────────────────
section "LSP.md references"
if ! command -v python3 >/dev/null 2>&1; then
    echo "skipped: no python3"
elif ! python3 "$LSP/check-refs.py"; then
    rc=1
fi

# ── no two path-imported modules may define one name ─────────────────────
# A path import flattens into a single namespace, so a shared name is either a
# confusing duplicate-definition error pointing at the wrong file, or -- worse --
# one definition silently shadowing the other. Five times, while building the
# server; the worst shadowed src/y/lexer.y's own token type and produced 60
# errors inside the compiler.
section "name collisions"
if ! command -v python3 >/dev/null 2>&1; then
    echo "skipped: no python3"
elif ! python3 "$LSP/check-names.py"; then
    rc=1
fi

# ── the fixtures ────────────────────────────────────────────────────────
section "fixtures"
if [ ! -x "$YREF" ]; then
    echo "error: no reference compiler at $YREF" >&2
    exit 1
fi
# CYCC is the C copy; YCC the built one. test-json.sh takes either and skips
# what is missing, exactly as the other suites do.
if ! YCC="$ROOT/cycc $YREF" OUT="$OUT" \
        sh "$LSP/test/test-json.sh"; then
    rc=1
fi

# ── the formatter over the corpus ────────────────────────────────────────
section "formatter"
if ! command -v python3 >/dev/null 2>&1; then
    echo "skipped: no python3"
elif ! YCC="$YREF" OUT="$FMT_OUT" sh "$LSP/test/test-fmt.sh"; then
    rc=1
fi

exit $rc
