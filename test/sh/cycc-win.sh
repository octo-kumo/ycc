#!/bin/bash
# cycc-win.sh — W1's gate: the C copy, cross-compiled for Windows, must compile
# exactly what the Linux C copy compiles.
#
#   make cycc.exe && test/sh/cycc-win.sh [FILE ...]
#
# Default corpus: every test/y/**.y (the port suite's own set). For each file
# Linux `cycc` and `cycc.exe` under wine both compile it, and the gate requires
# the same exit status, the same diagnostics, and — when both accept it — the
# same ELF bytes. `-S` is compared the same way, because a text-mode stdout on
# Windows turns every '\n' into CRLF and the listing is part of what the
# compiler promises.
#
# `-g` is deliberately NOT compared across hosts: DWARF records the source's
# absolute path, which is `/home/...` on Linux and `Z:\home\...` (or `C:\...`)
# under Windows, so the two differ by construction. test_debug.sh compares the
# two compilers on ONE host and is the gate for that.
#
# Usage: test/sh/cycc-win.sh            (the whole corpus)
#        test/sh/cycc-win.sh a.y b.y    (just these)
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
LIN="${LIN:-$ROOT/cycc}"
WIN="${WIN:-$ROOT/cycc.exe}"
WINE="${WINE:-wine}"
MEM=3670016
# A STALE cycc.exe is the one way this gate lies, and it did: with the binary
# from before a round's changes it compared those changes' absence against the
# Linux build of NOW and printed 53 "DIFF ... (ELF bytes differ)" lines that
# read as a port regression. The header says "make cycc.exe &&" -- but a gate
# that depends on the reader remembering is not a gate, so with the DEFAULT
# paths (an overridden $LIN/$WIN is somebody else's build and not ours to
# touch) make is asked, and a rebuild is SAID rather than silent.
if [ "$LIN" = "$ROOT/cycc" ] && [ "$WIN" = "$ROOT/cycc.exe" ] &&
   command -v make >/dev/null 2>&1; then
    lb=$(stat -c %Y "$LIN" 2>/dev/null || echo 0)
    wb=$(stat -c %Y "$WIN" 2>/dev/null || echo 0)
    ( cd "$ROOT" && make cycc cycc.exe >/dev/null 2>&1 ) || true
    [ "$(stat -c %Y "$LIN" 2>/dev/null || echo 0)" = "$lb" ] || echo "cycc-win: rebuilt a stale cycc"
    [ "$(stat -c %Y "$WIN" 2>/dev/null || echo 0)" = "$wb" ] || echo "cycc-win: rebuilt a stale cycc.exe"
fi
if [ ! -x "$LIN" ]; then echo "no Linux cycc at $LIN — run make" >&2; exit 2; fi
if [ ! -x "$WIN" ]; then echo "no cycc.exe at $WIN — run make cycc.exe" >&2; exit 2; fi
if ! command -v "$WINE" >/dev/null 2>&1; then echo "skipped: no wine"; exit 0; fi

T=$(mktemp -d "${TMPDIR:-/tmp}/cyccwin.XXXXXX")
trap 'rm -rf "$T"' EXIT

if [ "$#" -gt 0 ]; then
    files="$*"
else
    files=$(ls test/y/examples/*.y test/y/audit/*.y test/y/native/*.y \
               test/y/ycc/*.y test/y/net/*.y 2>/dev/null)
fi

same=0; diff=0; n=0
failed=""
for f in $files; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    base=$(basename "$f" .y)
    # Linux side
    ( ulimit -v $MEM; timeout 120 "$LIN" "$f" -o "$T/$base.lin" ) \
        >"$T/$base.lin.out" 2>"$T/$base.lin.err"
    le=$?
    # Windows side
    ( WINEARCH=win64 WINEDEBUG=-all timeout 180 "$WINE" "$WIN" "$f" -o "$T/$base.win" ) \
        >"$T/$base.win.out" 2>"$T/$base.win.err"
    we=$?
    why=""
    if [ "$le" != "$we" ]; then
        why="exit $le vs $we"
    elif ! cmp -s "$T/$base.lin.err" "$T/$base.win.err"; then
        why="diagnostics differ"
    elif [ "$le" = "0" ] && ! cmp -s "$T/$base.lin" "$T/$base.win"; then
        why="ELF bytes differ"
    fi
    if [ -z "$why" ]; then
        same=$((same + 1))
    else
        diff=$((diff + 1))
        echo "DIFF  $f ($why)"
        failed="$failed $f"
        sed 's/^/        lin: /' "$T/$base.lin.err" | head -3
        sed 's/^/        win: /' "$T/$base.win.err" | head -3
    fi
done

# -S over a handful, because the listing is stdout and stdout's mode is the
# one host difference the ELF path cannot see.
sfiles=$(ls test/y/examples/*.y test/y/audit/t4*.y 2>/dev/null | head -8)
for f in $sfiles; do
    [ -f "$f" ] || continue
    "$LIN" -S "$f" >"$T/s.lin" 2>/dev/null
    ( WINEARCH=win64 WINEDEBUG=-all timeout 180 "$WINE" "$WIN" -S "$f" ) >"$T/s.win" 2>/dev/null
    if ! cmp -s "$T/s.lin" "$T/s.win"; then
        echo "DIFF  $f (-S listing)"
        diff=$((diff + 1))
        failed="$failed $f(-S)"
    else
        same=$((same + 1))
    fi
done

echo
echo "cycc-win: $same same, $diff different, over $n files (+ $(echo "$sfiles" | wc -w) -S)"
if [ "$diff" != "0" ]; then
    echo "failed:$failed"
    exit 1
fi
exit 0
