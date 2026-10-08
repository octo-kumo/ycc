#!/bin/bash
# fuzz.sh — throw mutated programs at both compilers and keep what breaks
# them. Not part of `make test` (it is random by design); run it after a
# change to the lexer, parser, checker or emitter, and turn each finding
# into a fixture under test/y/native/ once it is fixed.
#
#   test/fuzz/fuzz.sh [ITERATIONS] [SEED]      (defaults: 500, $RANDOM)
#
# Every input is compiled (never run) by $YCC and $CYCC (default ./ycc and
# ./cycc) under a memory cap and a timeout. A finding is:
#   crash      a signal, a timeout, or a trap of the compiler itself
#              ("runtime error: ..."), or an INTERNAL marker
#   diverge    the two compilers disagree: exit code, messages, or output
#              binary
# Each distinct finding (keyed by kind + first line of output) is saved
# once, with the input and both outputs, under $FUZZ_OUT (_check/fuzz).
# The corpus is every program under test/y/native, audit and examples;
# mutate.y explains the edits. Inputs are reproducible from the seed line
# printed for each finding.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YCC="${YCC:-$ROOT/ycc}"
CYCC="${CYCC:-$ROOT/cycc}"
OUT="${FUZZ_OUT:-$ROOT/_check/fuzz}"
ITER="${1:-500}"
SEED="${2:-$RANDOM}"
MEM_KB="${FUZZ_MEM_KB:-2000000}"
TMO="${FUZZ_TIMEOUT:-10}"

for b in "$YCC" "$CYCC"; do
    [ -x "$b" ] || { echo "fuzz: $b is not built (make ycc)"; exit 2; }
done
mkdir -p "$OUT"
cd "$ROOT" || exit 2
# Three levels down, like test/y/native: the corpus's relative imports
# (../../../src/y/std/io.y) resolve from here too.
W=$(mktemp -d "$ROOT/test/fuzz/work.XXXXXX")
trap 'rm -rf "$W"' EXIT

"$YCC" -o "$W/mutate" "$ROOT/test/fuzz/mutate.y" </dev/null || {
    echo "fuzz: cannot build mutate.y"; exit 2; }

mapfile -t CORPUS < <(ls "$ROOT"/test/y/native/*.y "$ROOT"/test/y/audit/*.y \
    "$ROOT"/test/y/examples/*.y)
N=${#CORPUS[@]}

# compile COMPILER FILE BIN -> sets RC and MSG
compile() {
    ( ulimit -v "$MEM_KB"; exec timeout "$TMO" "$1" --no-exec -o "$3" "$2" \
        </dev/null ) >"$W/msg" 2>&1
    RC=$?
    MSG=$(head -c 4000 "$W/msg" | tr -d '\000')
}

found=0
declare -A SEEN
echo "fuzz: $ITER inputs, seed $SEED, corpus $N files, findings in $OUT"
for i in $(seq 1 "$ITER"); do
    rng=$((SEED * 1000003 + i))
    a=${CORPUS[$(( ((rng * 7919) % N + N) % N ))]}
    b=${CORPUS[$(( ((rng * 104729 + 17) % N + N) % N ))]}
    "$W/mutate" "$a" "$b" "$rng" "$W/in.y" </dev/null || continue
    compile "$YCC" "$W/in.y" "$W/y.bin"; yrc=$RC; ymsg=$MSG
    compile "$CYCC" "$W/in.y" "$W/c.bin"; crc=$RC; cmsg=$MSG
    kind=""
    for r in "$yrc" "$crc"; do
        [ "$r" -ge 124 ] && kind="crash"
    done
    # A difference between the two compilers is a DIVERGENCE whatever else is
    # in the messages, and it is checked FIRST: a run where ycc reports the
    # meta cap and cycc reports "runtime error: out of memory" is a port bug
    # (see BUGS.md), not a crash of either compiler. (Reordered in round 9,
    # when seed 9432 produced exactly that and the old order called it a
    # crash.)
    if [ -z "$kind" ] && { [ "$yrc" != "$crc" ] || [ "$ymsg" != "$cmsg" ]; }; then
        kind="diverge"
    fi
    if [ -z "$kind" ]; then
        case "$ymsg$cmsg" in
            *"runtime error:"*|*INTERNAL*) kind="crash" ;;
        esac
    fi
    # A `#{ ... }#` meta block's generator runs in a FORKED CHILD, and a trap in
    # that child is a DIAGNOSTIC, not a compiler crash: the child's
    # "runtime error: ..." reaches the parent's stdout and ycc then prints its
    # own "the meta generator exited N" naming the block.
    # `test/y/native/e185_meta_gen_dies.y` exists to produce exactly that, so a
    # mutation landing in its shape was reported as a crash (seed 15900, round
    # 9). Suppress only when BOTH compilers printed the meta diagnostic and
    # agree on the message and the exit status -- a compiler trap that happened
    # to follow one would still differ in one of the three.
    if [ "$kind" = "crash" ] && [ "$ymsg" = "$cmsg" ] && [ "$yrc" = "$crc" ] &&
       printf '%s' "$ymsg" | grep -q 'the meta generator exited'; then
        kind=""
    fi
    if [ -z "$kind" ] && [ "$yrc" = 0 ] && ! cmp -s "$W/y.bin" "$W/c.bin"; then
        kind="diverge"
    fi
    rm -f "$W/y.bin" "$W/c.bin"
    [ -z "$kind" ] && continue
    # crashes dedupe on the trap line, divergences on the first message
    key=$(printf '%s\n%s\n' "$ymsg" "$cmsg" | grep -m1 -oE "runtime error:.*|INTERNAL.*")
    [ -z "$key" ] && key=$(echo "$ymsg" | head -1 | sed 's/^[0-9]*:[0-9]*: //')
    sig="$kind:$yrc:$crc:$key"
    [ -n "${SEEN[$sig]}" ] && continue
    SEEN[$sig]=1
    found=$((found + 1))
    f="$OUT/$kind-$SEED-$i"
    cp "$W/in.y" "$f.y"
    { echo "seed: mutate $a $b $rng"
      echo "ycc rc=$yrc"; echo "$ymsg"
      echo "cycc rc=$crc"; echo "$cmsg"; } > "$f.txt"
    echo "$kind: $f.y (ycc rc=$yrc, cycc rc=$crc) $(echo "$key" | cut -c1-100)"
done
echo "fuzz: $found distinct finding(s)"
[ "$found" -eq 0 ]
