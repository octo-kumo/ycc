#!/bin/bash
# EOF must not be latched: after readline() returns null, a later call has to
# attempt a fresh read. Proven with a FIFO — the first writer closes (EOF),
# a second one opens later and writes more. Phase b polls on a wall-clock
# budget, so the check never depends on which side wins the race.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
YBOOT="${YBOOT:-$ROOT/yboot}"
FIFO=$(mktemp -u /tmp/yeof_XXXXXX)
PROG=$(mktemp /tmp/yeof_XXXXXX.y)
mkfifo "$FIFO"

cat > "$PROG" <<'EOF'
def drain(tag: str) -> long {
    let n = 0;
    let go = true;
    while (go) {
        let l = readline();
        if (l == null) { go = false; } else { n = n + 1; puts(tag + ":" + unwrap(l) + "\n"); };
    };
    n
};
// Phase a stops at the first EOF. Phase b keeps polling for a few seconds:
// if EOF were latched every retry would return null and this would print 0.
print(drain("a"));
let t0 = clock_us();
let got = 0;
let go = true;
while (go) {
    let l = readline();
    if (l == null) {
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
    ( timeout 30 bash -c 'printf "one\ntwo\n" > "$1"; sleep 0.2; printf "three\n" > "$1"' _ "$FIFO" ) &
    local wpid=$! got
    got=$(timeout 30 "$@" < "$FIFO" 2>&1)
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

check "VM" "$YBOOT" -q "$PROG"

BINC=$(mktemp /tmp/yeof_bin_XXXXXX)
if "$YBOOT" --compile "$PROG" -o "$BINC" >/dev/null 2>&1; then
    check "C backend" "$BINC"
else
    echo "FAIL C backend (compile failed)"; rc=1
fi

if [ -x "$ROOT/ycc" ]; then
    BINN=$(mktemp /tmp/yeof_bin_XXXXXX)
    if "$ROOT/ycc" -o "$BINN" "$PROG" >/dev/null 2>&1; then
        check "native" "$BINN"
    else
        echo "FAIL native (compile failed)"; rc=1
    fi
    rm -f "$BINN"
else
    echo "SKIP native (run 'make ycc' first)"
fi

rm -f "$FIFO" "$PROG" "$BINC"
exit $rc
