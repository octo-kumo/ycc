#!/bin/bash
# mem.sh -- peak RSS (KB) of compiling and of `ycc run`, over a few programs.
# /usr/bin/time -v is not always present; use the kernel's own accounting via
# a wrapper that reads /proc/<pid>/status VmHWM after the process ends is not
# possible, so use `\time -f %M` (bash builtin time, needs /usr/bin/time) or
# getrusage through a tiny helper. Try /usr/bin/time first.
set -u
cd "$(dirname "$0")/../.."
K=${YCC_MEM_KB:-3670016}
T=$(mktemp -d -t ymem.XXXXXX)
trap 'rm -rf "$T"' EXIT
peak() {  # peak <label> <cmd...>
  local label="$1"; shift
  local out
  out=$( { /usr/bin/time -f '%M' "$@" >/dev/null 2>/dev/null; } 2>&1 )
  # /usr/bin/time writes %M to stderr; the cmd's own stderr is dropped above,
  # so run again capturing only time's line
  out=$( /usr/bin/time -f 'PEAK %M' "$@" 2>&1 >/dev/null | grep '^PEAK' | tail -1 )
  echo "$label: ${out#PEAK } KB"
}
for f in "$@"; do
  echo "== $f"
  (ulimit -v $K; /usr/bin/time -f 'compile %M KB' ${YCC:-./ynew} "$f" -o $T/p 2>&1 >/dev/null | tail -1)
  (ulimit -v $K; /usr/bin/time -f 'run     %M KB' ${YCC:-./ynew} run "$f" 2>&1 >/dev/null | tail -1)
  (ulimit -v $K; /usr/bin/time -f 'native  %M KB' $T/p 2>&1 >/dev/null | tail -1)
done