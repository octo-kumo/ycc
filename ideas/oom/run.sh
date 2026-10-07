#!/bin/sh
# Build and run every s*.y under the 3.5 GB cap (AGENTS.md), then print the
# line each program reports.  Optionally run just one program at one size:
#   ./run.sh                     all, default sizes
#   ./run.sh s05_arr_concat 31000
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
CAP=${YMEM_CAP_KB:-3670016}
prog=${1:-}
n=${2:-}
for f in "$(dirname "$0")"/s*.y; do
    name=$(basename "$f" .y)
    if [ -n "$prog" ] && [ "$name" != "$prog" ]; then continue; fi
    log="/tmp/oomprog_$name.log"
    out="/tmp/oomprog_$name.out"
    if ! "$ROOT/ycc" "$f" -o "/tmp/oomprog_$name" >"$log" 2>&1; then
        echo "$name: COMPILE FAILED"
        sed 's/^/    /' "$log"
        continue
    fi
    if [ -s "$log" ]; then
        echo "$name: compiler diagnostics:"
        sed 's/^/    /' "$log"
    fi
    if [ -n "$n" ]; then
        ( ulimit -S -v "$CAP"; timeout 120 "/tmp/oomprog_$name" "$n" ) >"$out" 2>&1
    else
        ( ulimit -S -v "$CAP"; timeout 120 "/tmp/oomprog_$name" ) >"$out" 2>&1
    fi
    st=$?
    sed "s/^/$name: /" "$out"
    if [ "$st" -ne 0 ]; then
        echo "$name: exit $st (heap cap $CAP KB)"
    fi
done
exit 0
