#!/bin/bash
# runcheck.sh -- M1's gate: `ycc run FILE` must produce the same stdout and
# the same exit status as compiling FILE and executing it, over a corpus.
#
# usage: runcheck.sh [DIR ...]   (default: test/y/examples)
set -u
cd "$(dirname "$0")/../.."
K=${YCC_MEM_KB:-3670016}
YNEW=${YCC:-./ynew}
T=$(mktemp -d /tmp/opencode/rc_XXXXXX)
trap 'rm -rf "$T"' EXIT
dirs=${*:-test/y/examples}
n=0; bad=0
for d in $dirs; do
  for f in "$d"/*.y; do
    [ -f "$f" ] || continue
    n=$((n+1))
    bin="$T/prog"
    rm -f "$bin"
    if ! (ulimit -v $K; $YNEW "$f" -o "$bin") >"$T/c.err" 2>&1; then
      echo "SKIP (does not compile) $f"; continue
    fi
    # A file with a meta block is NOT comparable: compiling it already runs
    # the generator, whose top level is the program's own, so its prints land
    # on ycc's stdout -- the "top level runs twice" the warning in lint.y
    # names. Those fixtures are checked by test_native.sh (their .expected is
    # the program's own output) and by test_coverage.sh.
    case "$(basename "$f")" in
      t198_meta_basic.y|t199_meta_top_twice.y)
        echo "skip (meta block: the top level runs twice) $f"; continue;;
    esac
    (ulimit -v $K; "$bin" </dev/null >"$T/a.out" 2>"$T/a.err"); a=$?
    (ulimit -v $K; $YNEW run "$f" </dev/null >"$T/b.out" 2>"$T/b.err"); b=$?
    ok=1
    cmp -s "$T/a.out" "$T/b.out" || { ok=0; echo "STDOUT differs: $f"; }
    [ "$a" = "$b" ] || { ok=0; echo "STATUS differs: $f (compiled=$a run=$b)"; }
    # `ycc run` also prints the COMPILER's warnings on stderr; the compiled
    # binary's stderr has only the program's. Strip the warnings before cmp.
    grep -v ': warning: ' "$T/b.err" > "$T/b2.err"
    cmp -s "$T/a.err" "$T/b2.err" || { ok=0; echo "STDERR differs: $f"; }
    if [ $ok = 0 ]; then bad=$((bad+1)); else echo "ok   $f"; fi
  done
done
echo "--- $n programs, $bad mismatches"
[ $bad = 0 ]