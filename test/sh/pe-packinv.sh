#!/usr/bin/env bash
# pe-packinv.sh -- the std pack must carry no target.
#
# `./test/sh/pe-packinv.sh [COMPILER] [file.y ...]` (default ./ynew, default the
# whole fixture corpus).
#
# The rule this checks is the one the whole named syscall layer exists for: the
# std pack is written by ONE compiler, for ONE target, because `ycc
# --std-pack` never passes a target -- so anything a std unit resolves while it
# is being compiled (a syscall number, a struct layout, a branch on the target)
# is baked into that pack and served to every program compiled from it,
# whatever --target the consuming compiler was given.
#
# The check needs no Windows machine and no wine: it compares two PE files this
# compiler produced from the same source, one linked against the attached pack
# and one against the embedded sources (--std-src). If any std unit still
# depends on the target, the two differ, and the difference is a real defect in
# the pack rather than a runtime mystery.
#
# The ELF path has the same property and the same check (drop --target), but it
# was never at risk: an ELF pack carries ELF numbers, which is what the
# consumer wants.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT="${ROOT_OVERRIDE:-$(dirname "$(dirname "$HERE")")}"
YCC="${1:-$ROOT/ynew}"; shift || true

files=("$@")
if [ ${#files[@]} -eq 0 ]; then
    mapfile -t files < <(ls "$ROOT"/test/y/native/t*.y "$ROOT"/test/y/examples/*.y 2>/dev/null)
fi

ok=0; skipped=0; bad=0
for f in "${files[@]}"; do
    a=$(mktemp /tmp/pepackinv_a.XXXXXX.exe); b=$(mktemp /tmp/pepackinv_b.XXXXXX.exe)
    if ! timeout 300 "$YCC" --target=windows "$f" -o "$a" </dev/null >/dev/null 2>&1; then
        skipped=$((skipped+1)); rm -f "$a" "$b"; continue
    fi
    if ! timeout 300 "$YCC" --target=windows --std-src "$f" -o "$b" </dev/null >/dev/null 2>&1; then
        skipped=$((skipped+1)); rm -f "$a" "$b"; continue
    fi
    if cmp -s "$a" "$b"; then
        ok=$((ok+1))
    else
        bad=$((bad+1))
        echo "PACK!=SRC  $f"
        cmp -l "$a" "$b" 2>/dev/null | head -3 | sed 's/^/    /'
    fi
    rm -f "$a" "$b"
done
echo "=== pe-packinv: $ok identical, $bad differ, $skipped skipped (of ${#files[@]})"
[ "$bad" -eq 0 ]