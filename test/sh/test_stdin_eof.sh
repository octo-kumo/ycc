#!/bin/bash
# EOF must not be latched: after readline() returns none, a later call has to
# attempt a fresh read. Proven with a FIFO — the first writer closes (EOF),
# a second one opens once the program has printed what it read up to that
# EOF, and writes more. No step depends on timing: the program can take as
# long as it likes to start (the reference side compiles first), and phase b
# polls on a wall-clock budget the second writer is well within.
set -u

source "$(dirname "$0")/lib.sh"   # ROOT, YBOOT, YTIMEOUT_SCALE

FIFO=$(mktemp -u -t yeof_XXXXXX)
PROG=$(mktemp -t yeof_XXXXXX.y)
mkfifo "$FIFO"

cat > "$PROG" <<'EOF'
def drain(tag: str) -> long {
    let n = 0;
    let go = true;
    while (go) {
        let l = readline();
        if (l == none) { go = false; } else { n = n + 1; puts(tag + ":" + unwrap(l) + "\n"); };
    };
    n
};
// Phase a stops at the first EOF. Phase b keeps polling for a few seconds:
// if EOF were latched every retry would return none and this would print 0.
print(drain("a"));
let t0 = clock_us();
let got = 0;
let go = true;
while (go) {
    let l = readline();
    if (l == none) {
        if (clock_us() - t0 > 8000000) { go = false; };
    } else {
        got = got + 1;
        puts("b:" + unwrap(l) + "\n");
        go = false;
    };
};
print(got);
EOF

expected='a:one
a:two
2
b:three
1'

rc=0
check() {
    local name="$1"; shift
    local out
    out=$(mktemp -t yeof_out_XXXXXX)
    # The second write waits for phase a's count: written at a fixed delay
    # instead, it reached a program still being compiled (a busy machine)
    # and the two writes read as one stream.
    ( timeout 30 bash -c 'printf "one\ntwo\n" > "$1"
        until grep -qx 2 "$2"; do sleep 0.05; done
        printf "three\n" > "$1"' _ "$FIFO" "$out" ) &
    local wpid=$! got
    timeout 30 "$@" < "$FIFO" > "$out" 2>&1   # stdin IS the fifo here
    wait "$wpid" 2>/dev/null
    got=$(cat "$out")
    rm -f "$out"
    wait "$wpid" 2>/dev/null
    if [ "$got" = "$expected" ]; then
        echo "PASS $name"
    else
        echo "FAIL $name"
        echo "  expected: $(echo "$expected" | tr '\n' '|')"
        echo "  got:      $(echo "$got" | tr '\n' '|')"
        rc=1
    fi
}

# Three builds of the same program: the reference compiler, the C copy, and
# the built ./ycc ($YSELF if set). Stdin is the fifo for all three — that is
# the whole test.
CTO=$(( 120 * YTIMEOUT_SCALE ))
check "reference" "$YBOOT" -q "$PROG"

BINC=$(mktemp -t yeof_bin_XXXXXX)
if timeout "$CTO" "$YBOOT" --compile "$PROG" -o "$BINC" </dev/null >/dev/null 2>&1; then
    check "C copy" "$BINC"
else
    echo "FAIL C copy (compile failed)"; rc=1
fi

YSELF_BIN="${YSELF:-$ROOT/ycc}"
if [ -x "$YSELF_BIN" ]; then
    BINN=$(mktemp -t yeof_bin_XXXXXX)
    if timeout "$CTO" "$YSELF_BIN" -o "$BINN" "$PROG" </dev/null >/dev/null 2>&1; then
        check "built ycc" "$BINN"
    else
        echo "FAIL built ycc (compile failed)"; rc=1
    fi
    rm -f "$BINN"
else
    echo "SKIP built ycc (run 'make ycc' first)"
fi

rm -f "$FIFO" "$PROG" "$BINC"
exit $rc
