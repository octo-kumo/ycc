#!/bin/bash
# Build Y-OS into os/build/: the kernel (os.img) and its filesystem (os.fs).
#   os/build.sh [YCC]        YCC is the compiler (default ./ycc)
set -e
cd "$(dirname "$0")/.."
YCC=${1:-./ycc}
OUT=${OSOUT:-os/build}
PROGS="sh ls cat echo wc head cp rm mv write halt pwd"
mkdir -p "$OUT"
cap() { (ulimit -S -v 3670016; "$@" </dev/null); }

cap "$YCC" --kernel os/kernel/boot.y -o "$OUT/os.img"
cap "$YCC" os/tools/mkfs.y -o "$OUT/mkfs"
args=()
for p in $PROGS; do
    cap "$YCC" "os/uland/$p.y" -o "$OUT/$p"
    args+=("$p" "$OUT/$p")
done
"$OUT/mkfs" "$OUT/os.fs" "${args[@]}" 2>&1
echo "os: built $OUT/os.img ($(stat -c%s "$OUT/os.img") bytes) and $OUT/os.fs ($(stat -c%s "$OUT/os.fs") bytes)"
