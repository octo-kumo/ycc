#!/bin/sh
# The differential corpus for std/regex.y, driven from where its generator lives.
#
# test/y/native/t195_regex_corpus.y is an ordinary fixture now: the native suite
# runs it (stdout against its .expected) and the port gate compiles it with both
# compilers.  What this script adds is the *other* half of the check — that the
# expected output still says what Python's re says about the same bytes — which
# needs Python, so it is not a suite.
#
#   ./ideas/regex/run.sh            check the fixture against the committed output
#   ./ideas/regex/run.sh --regen    regenerate the fixture, then check it
#
# pdiff.py says where the two disagree, case by case, when they do.

set -u
root=$(cd "$(dirname "$0")/../.." && pwd)
here=$root/ideas/regex
fixture=$root/test/y/native/t195_regex_corpus
out=${TMPDIR:-/tmp}/regex-corpus
mkdir -p "$out"
fail=0

if [ "${1:-}" = "--regen" ]; then
    note() { printf '%s\n' "$*"; }
    note "regenerating from gen.py (Python's re over the same bytes)"
    python3 "$here/gen.py" || exit 1
fi

# both compilers, and the bytes they must agree on
for cc in ycc cycc; do
    if ! "$root/./$cc" "$fixture.y" -o "$out/corpus.$cc" > "$out/$cc.log" 2>&1; then
        printf 'FAIL: ./%s did not compile\n' "$cc"
        head -5 "$out/$cc.log"
        exit 1
    fi
    if [ -s "$out/$cc.log" ]; then
        printf 'FAIL: ./%s wrote to stderr\n' "$cc"
        head -5 "$out/$cc.log"
        fail=1
    fi
done
if ! cmp -s "$out/corpus.ycc" "$out/corpus.cycc"; then
    printf 'FAIL: ycc and cycc built different binaries\n'
    fail=1
fi

# run it, under the tree's cap, and diff
( ulimit -S -v 3670016; "$out/corpus.ycc" > "$out/corpus.out" 2>&1 )
if diff -u "$fixture.expected" "$out/corpus.out" > "$out/corpus.diff" 2>&1; then
    printf 'ok   %s cases, engine == Python re\n' "$(grep -c '^pat=' "$fixture.expected")"
else
    printf 'FAIL: the engine no longer agrees with the expected output\n'
    head -30 "$out/corpus.diff"
    fail=1
fi

exit $fail