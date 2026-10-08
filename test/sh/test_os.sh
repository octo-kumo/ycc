#!/bin/bash
# test_os.sh — Y-OS, the system: os/build.sh builds the kernel image and the
# filesystem (the shell and its programs) with each engine, the two must agree
# byte for byte, and scripted shell sessions (os/session.py) are booted under
# qemu and compared with test/os/<name>.expected.
#
# A session is test/os/<name>.cmds, one command line per line; the transcript is
# the serial console from boot to halt, so the shell's echo of the commands is in
# it. A session must also END: the last command halts, and the machine stopping
# is part of what is checked.
set -u

source "$(dirname "$0")/lib.sh"   # ROOT, CYCC, colors, counters

YCC="${YCC:-$ROOT/ycc}"
CYCC="${CYCC:-$ROOT/cycc}"
QEMU="${QEMU:-qemu-system-x86_64}"
ODIR="$ROOT/test/os"
WORK="${YOUT:-$(mktemp -d)}"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

if ! command -v "$QEMU" >/dev/null 2>&1; then
    skip "os: no $QEMU, the whole suite" "install qemu-system-x86_64"
    print_summary "os"
    exit 0
fi

build() {   # build <compiler> <dir>
    ( cd "$ROOT" && OSOUT="$2" timeout "$((300 * YTIMEOUT_SCALE))" bash os/build.sh "$1" ) >"$2.log" 2>&1
}

if build "$YCC" "$WORK/y"; then
    pass "os builds with the built compiler"
else
    fail "os builds with the built compiler" "$(tail -3 "$WORK/y.log")"
    print_summary "os"
    exit 1
fi
if [ -x "$CYCC" ]; then
    if build "$CYCC" "$WORK/c"; then
        if cmp -s "$WORK/y/os.img" "$WORK/c/os.img" && cmp -s "$WORK/y/os.fs" "$WORK/c/os.fs"; then
            pass "os: the two engines build the same kernel image and filesystem"
        else
            fail "os: the two engines build the same kernel image and filesystem" "os.img or os.fs differ between $YCC and $CYCC"
        fi
    else
        fail "os builds with the C copy" "$(tail -3 "$WORK/c.log")"
    fi
fi

for cmds in "$ODIR"/*.cmds; do
    [ -f "$cmds" ] || continue
    name=$(basename "$cmds" .cmds)
    mapfile -t lines < "$cmds"
    got=$(cd "$ROOT" && timeout "$((120 * YTIMEOUT_SCALE))" python3 -I os/session.py --timeout "$((90 * YTIMEOUT_SCALE))" \
          --img "$WORK/y/os.img" --fs "$WORK/y/os.fs" "${lines[@]}" </dev/null 2>&1)
    rc=$?
    if [ "$rc" != 0 ]; then
        fail "$name: the session ran to a halt" "status $rc; transcript ends: $(printf '%s' "$got" | tail -3)"
    elif [ "$got" = "$(cat "$ODIR/$name.expected")" ]; then
        pass "$name: transcript matches"
    else
        fail "$name: transcript matches" "$(diff <(printf '%s\n' "$got") "$ODIR/$name.expected" | head -8)"
    fi
done

print_summary "os"
