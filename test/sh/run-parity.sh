#!/usr/bin/env bash
# run-parity.sh — `ycc run` must behave exactly like compiling then executing.
#   ./run-parity.sh ./ynew [N]
# NOTE: pass the compiler IN TREE. A copy elsewhere changes the result: std
# modules resolve against the compiler's OWN directory (self_dir/res_roots), so
# a snapshot at /tmp has no std/ beside it and every `import fs`-style fixture
# fails to resolve. That produced 11 phantom differences here before it was
# spotted. `make ynew` finishes with `mv _ynewp ynew`, an atomic rename, so
# execing the in-tree ./ynew while a rebuild is running is safe.
set -u
YCC="${1:?}"; LIMIT="${2:-0}"
ROOT="${ROOT_OVERRIDE:-$(pwd)}"; MEM=3670016
T=$(mktemp -d "${TMPDIR:-/tmp}/runpar.XXXXXX"); trap 'rm -rf "$T"' EXIT
same=0; diff=0
for src in $(ls "$ROOT"/test/y/native/t*.y 2>/dev/null | sort); do
  b=$(basename "$src" .y); ec=0
  [ -f "$ROOT/test/y/native/$b.exit" ] && ec=$(cat "$ROOT/test/y/native/$b.exit")
  inf=/dev/null; [ -f "$ROOT/test/y/native/$b.stdin" ] && inf="$ROOT/test/y/native/$b.stdin"
  ( cd "$ROOT" && ulimit -v $MEM; "$YCC" "$src" -o "$T/c" ) >/dev/null 2>&1 || continue
  # Both runs happen from the tree root, so module resolution sees the same
  # roots for the compiled binary and for `ycc run`. cwd-sensitive fixtures
  # still behave the same on both sides, which is what parity means here.
  ( cd "$ROOT" && ulimit -v $MEM; "$T/c" <"$inf" >"$T/c.out" 2>/dev/null ); cec=$?
  ( cd "$ROOT" && ulimit -v $MEM; "$YCC" run "$src" <"$inf" >"$T/r.out" 2>/dev/null ); rec=$?
  if cmp -s "$T/c.out" "$T/r.out" && [ "$cec" = "$rec" ]; then same=$((same+1))
  else diff=$((diff+1)); echo "  DIFFERS $b  exit $cec vs $rec  $(cmp -s "$T/c.out" "$T/r.out" && echo 'stdout same' || echo 'STDOUT DIFFERS')"; fi
  if [ "$LIMIT" -gt 0 ] && [ $((same+diff)) -ge "$LIMIT" ]; then break; fi
done
printf '\n=== ycc run vs compile-and-execute: %d identical, %d differ ===\n' "$same" "$diff"
[ "$diff" -eq 0 ]
