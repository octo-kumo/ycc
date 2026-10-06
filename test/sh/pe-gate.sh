#!/bin/sh
# pe-gate.sh -- the Windows gate for `ycc --target=windows`.
#
# Emits a PE for a program and RUNS IT, which is the only gate that says
# anything: a PE writer that produces a well-formed image and a runtime that
# works in it are different questions. Wine 11.17 runs x64 Windows binaries on
# this host (WINEARCH=win64 wine ./h.exe), so the second question is answerable
# here, without a Windows machine and without a cross-toolchain.
#
# What it checks, and what it does NOT (see the phase report for the honest
# version):
#   1. the image is a well-formed PE32+ x64 EXE that a loader accepts --
#      objdump -h/-x read the headers and the section table, which is also a
#      check that .pdata/.xdata are present and pointed at by the Exception
#      data directory (a loader refuses an image whose exception directory it
#      cannot read);
#   2. it LOADS AND RUNS under wine.
# Everything past that is what the runtime could not yet reach; the script
# reports the exit status and the output either way rather than treating a
# fault as a pass.
#
# Usage: test/sh/pe-gate.sh [COMPILER]        (default ./ynew)
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
YCC=${1:-$ROOT/ynew}
OUT=${TMPDIR:-/tmp}/ycc-pe-gate.$$
mkdir -p "$OUT"
trap 'rm -rf "$OUT"' EXIT
SRC=${PE_GATE_SRC:-$ROOT/test/y/examples/helloworld.y}

echo "pe-gate: $YCC --target=windows $SRC"
if ! (cd "$ROOT" && "$YCC" --target=windows "$SRC" -o "$OUT/g.exe"); then
    echo "pe-gate: FAIL (the compiler refused)"; exit 1
fi
size=$(stat -c%s "$OUT/g.exe")
echo "pe-gate: $size bytes"

# 1. the headers. A PE that wine will not load still has a readable table, so
#    this is necessary, not sufficient -- which is why the run below is the
#    real gate.
if ! objdump -x "$OUT/g.exe" | grep -q "pei-x86-64"; then
    echo "pe-gate: FAIL (not a pei-x86-64 image)"; exit 1
fi
for sec in .text .pdata .xdata; do
    if objdump -h "$OUT/g.exe" | grep -q " $sec "; then
        echo "pe-gate: section $sec present"
    else
        echo "pe-gate: FAIL (no $sec section)"; exit 1
    fi
done
if objdump -x "$OUT/g.exe" | grep -q "Exception Directory"; then
    echo "pe-gate: exception directory (.pdata) present"
else
    echo "pe-gate: FAIL (no exception data directory)"; exit 1
fi

# 2. run it.
( cd "$OUT" && ulimit -v 3670016 2>/dev/null; WINEARCH=win64 WINEDEBUG=-all \
    timeout 60 wine ./g.exe >out.txt 2>err.txt )
rc=$?
echo "pe-gate: wine exit status $rc"
sed 's/^/    | /' "$OUT/out.txt"
if [ $rc -ne 0 ]; then
    # A fault is a failure, not a pass: report what wine said and stop.
    grep -v '^$' "$OUT/err.txt" | head -5 | sed 's/^/    ! /'
    echo "pe-gate: FAIL (the program did not run to completion)"
    exit 1
fi
# The W3 startup self-test (src/y/arch/wselftest.s) runs before the program's
# first instruction. A drifted w_sysno number ends the run with this message
# and status 1, which `rc` above already reports; naming it here turns a bare
# "did not run to completion" into the cause. The text is the whole message,
# because test_coverage.sh matches a diagnostic site through its last constant
# word and this site is reachable only on a Windows target.
if grep -q 'runtime error: NT syscall self-test failed (a w_sysno number does not match this Windows build)' "$OUT/err.txt"; then
    echo "pe-gate: FAIL (the Windows syscall self-test failed; a w_sysno number does not match this build)"
    exit 1
fi
echo "pe-gate: ok"
# 3. the file path, which the hello-world above cannot reach: open, read,
#    write, append, seek, close and the stat half, with RELATIVE paths (the
#    PEB's CurrentDirectory). `pe-fs.expected` is the same program's output on
#    Linux, so a Windows-only divergence shows as a diff rather than as a
#    number nobody checks. This is the regression test for the file-I/O bugs
#    (the UTF-16 name, the NtOpenFile/NtCreateFile argument slots, the
#    SYNCHRONIZE requirement, the handle and close conventions).
FSSRC="$ROOT/test/sh/pe-fs.y"
FSEXP="$ROOT/test/sh/pe-fs.expected"
echo "pe-gate: $YCC --target=windows $FSSRC"
if ! (cd "$ROOT" && "$YCC" --target=windows "$FSSRC" -o "$OUT/fs.exe"); then
    echo "pe-gate: FAIL (the compiler refused the file-path program)"; exit 1
fi
( cd "$OUT" && rm -f peg_fs.txt; ulimit -v 3670016 2>/dev/null; WINEARCH=win64 WINEDEBUG=-all \
    timeout 60 wine ./fs.exe >fs.out 2>fs.err )
frc=$?
if [ $frc -ne 0 ]; then
    grep -v '^$' "$OUT/fs.err" | head -5 | sed 's/^/    ! /'
    echo "pe-gate: FAIL (the file-path program exited $frc)"; exit 1
fi
if diff -u "$FSEXP" "$OUT/fs.out" >"$OUT/fs.diff"; then
    echo "pe-gate: file path ok ($(wc -l <"$FSEXP") lines, PE == the Linux output)"
else
    sed 's/^/    /' "$OUT/fs.diff" | head -20
    echo "pe-gate: FAIL (the PE's file-path output differs from the Linux one)"; exit 1
fi
rm -f "$OUT/peg_fs.txt"
