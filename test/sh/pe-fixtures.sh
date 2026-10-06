#!/usr/bin/env bash
# pe-fixtures.sh — every native t*.y fixture, compiled and run BOTH ways, and
# the difference reported per fixture.
#
#   ./test/sh/pe-fixtures.sh ./ynew            # all fixtures
#   ./test/sh/pe-fixtures.sh ./ynew t160 t183  # just these
#
# ELF is the reference: the fixture's own .expected/.exit is the truth, and a
# PE is "passing" only when it produces the same bytes and the same status as
# the ELF build does. So a fixture whose ELF run fails is reported separately
# rather than counted as a Windows failure -- otherwise a broken baseline
# looks like a target bug.
#
# Reads the worktree, writes only to $TMPDIR. Needs wine for the PE side.

set -u
YCC="${1:?usage: pe-fixtures.sh YCC [fixture...]}"; shift || true
# ROOT defaults to the tree this script lives in (test/sh/..), so it works in
# place; override it to run a copy from elsewhere.
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="${ROOT_OVERRIDE:-$(dirname "$(dirname "$HERE")")}"
NATIVE="$ROOT/test/y/native"
if [ ! -d "$NATIVE" ]; then
  echo "no fixture dir at $NATIVE -- set ROOT_OVERRIDE to the worktree root" >&2; exit 2
fi
T=$(mktemp -d "${TMPDIR:-/tmp}/pefix.XXXXXX")
trap 'rm -rf "$T"' EXIT
MEM=3670016

# YTIMEOUT / YTIMEOUT_PE are per-run seconds (YTIMEOUT_SCALE multiplies both, as
# in lib.sh); a hang is reported, never waited on.
YTIMEOUT_SCALE=${YTIMEOUT_SCALE:-1}
pass=0; pe_fail=0; base_fail=0; skip=0
: > "$T/table"

if [ "$#" -gt 0 ]; then
  files=""
  for n in "$@"; do
    for g in "$NATIVE/$n.y" "$NATIVE/$n"*.y; do [ -f "$g" ] && files="$files $g"; done
  done
  files=$(printf '%s\n' $files | sort -u)   # the exact path and the glob both match
else
  files=$(ls "$NATIVE"/t*.y 2>/dev/null)
fi

for src in $files; do
  base=$(basename "$src" .y)
  exp="$NATIVE/$base.expected"; ec=0
  [ -f "$NATIVE/$base.exit" ] && ec=$(cat "$NATIVE/$base.exit")
  inf=/dev/null; [ -f "$NATIVE/$base.stdin" ] && inf="$NATIVE/$base.stdin"

  # --- ELF reference run ---
  if ! (ulimit -v $MEM; "$YCC" "$src" -o "$T/e") >"$T/ce" 2>&1; then
    echo "$base|ELF-COMPILE-FAIL|$(head -1 "$T/ce" | tr -d '\r')" >> "$T/table"; base_fail=$((base_fail+1)); continue
  fi
  # A TIMEOUT ON EVERY RUN. This harness had none, on either side, so a single
  # fixture that hangs under wine wedges the WHOLE run -- which is what
  # happened: the round-54 run was still going after 40 minutes with an empty
  # table, and the only symptom was silence. A hanging fixture is a result.
  eto=$(( ${YTIMEOUT:-20} * YTIMEOUT_SCALE ))
  pto=$(( ${YTIMEOUT_PE:-20} * YTIMEOUT_SCALE ))
  ( cd "$T" && ulimit -v $MEM; timeout "$eto" ./e <"$inf" >"$T/e.out" 2>/dev/null ); eec=$?
  if [ "$eec" = 124 ]; then
    echo "$base|ELF-TIMEOUT|no exit within ${eto}s" >> "$T/table"; base_fail=$((base_fail+1)); continue
  fi
  if [ -f "$exp" ] && ! diff -q "$exp" "$T/e.out" >/dev/null 2>&1; then
    echo "$base|ELF-OUTPUT-DIFF|mismatch vs .expected" >> "$T/table"; base_fail=$((base_fail+1)); continue
  fi
  if [ "$eec" != "$ec" ]; then
    echo "$base|ELF-EXIT-DIFF|got $eec want $ec" >> "$T/table"; base_fail=$((base_fail+1)); continue
  fi

  # --- PE run ---
  if ! (ulimit -v $MEM; "$YCC" --target=windows "$src" -o "$T/p.exe") >"$T/cp" 2>&1; then
    echo "$base|PE-COMPILE-FAIL|$(head -1 "$T/cp" | tr -d '\r')" >> "$T/table"; pe_fail=$((pe_fail+1)); continue
  fi
  ( cd "$T" && ulimit -v $MEM; WINEARCH=win64 WINEDEBUG=-all \
      timeout "$pto" wine ./p.exe <"$inf" >"$T/p.out" 2>"$T/p.err" ); pec=$?
  # stdout and exit status only -- the same contract test_native.sh checks.
  # stderr is deliberately NOT a criterion: wine emits MESA-EGL and winediag
  # noise there on a perfectly successful run.
  why=""
  # SHOW THE DIFFERENCE. "output differs from .expected" cost an hour of
  # hand-reproduction that never reproduced it: the PE's actual bytes were in
  # $T/p.out the whole time and the harness was deleting them. A harness that
  # reports a mismatch without showing it is asking the next reader to guess.
  if [ "$pec" = 124 ]; then why="no exit within ${pto}s (HUNG)"
  elif [ -f "$exp" ] && ! diff -q "$exp" "$T/p.out" >/dev/null 2>&1; then
    why="output differs: want [$(head -3 "$exp" | tr '\n' '|')] got [$(head -3 "$T/p.out" | tr '\n' '|')] [stderr: $(grep -av 'MESA\|pci id' "$T/p.err" 2>/dev/null | head -1 | tr -d '\r')]"
  elif [ "$pec" != "$ec" ]; then why="exit $pec, want $ec"
  fi
  if [ -n "$why" ]; then
    echo "$base|PE-RUN-DIFF|$why" >> "$T/table"; pe_fail=$((pe_fail+1))
    printf 'FAIL %-34s %s\n' "$base" "$why"
  else
    echo "$base|PASS|" >> "$T/table"; pass=$((pass+1))
    [ -n "${PE_FIXTURES_VERBOSE:-}" ] && printf 'ok   %s\n' "$base"
  fi
done

total=$((pass + pe_fail + base_fail))
printf '\n=== %d fixtures: %d PASS both targets, %d PE-only failures, %d baseline failures ===\n' \
       "$total" "$pass" "$pe_fail" "$base_fail"
echo
echo "--- PE failures, each with its first differing byte or status ---"
grep '|PE-' "$T/table" 2>/dev/null | sort | awk -F'|' '{printf "  %-34s %s\n", $1, $3}' || echo "  none"
echo
echo "--- baseline failures (NOT a Windows problem; ELF itself disagrees) ---"
grep '|ELF-' "$T/table" 2>/dev/null | awk -F'|' '{printf "  %-34s %s\n", $1, $2}' || echo "  none"
echo
echo "table: $T/table"
[ "$pe_fail" -eq 0 ] && [ "$base_fail" -eq 0 ]
