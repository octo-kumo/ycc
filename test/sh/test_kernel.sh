#!/bin/bash
# test_kernel.sh — `ycc --kernel`: the ELF32 Multiboot image, its serial
# console and its `irq N def` handlers, booted under qemu-system-x86_64.
#
# The kernel target has no reference binary to compare against the way every
# other suite compares $CYCC with $YREF: refs/ycc.ref only learns --kernel
# when a compiler carrying it is blessed.  So the two engines here are the
# built compiler ($YCC) and the C copy ($CYCC), and each is used only if it
# answers --kernel; a tree whose ycc predates the feature skips instead of
# failing.
#
# Every `t*` case is booted for real: the image runs in qemu, its serial
# output is captured, and the first bytes of it must be the case's
# `.expected` (a kernel that halts or idles never exits, so qemu is killed by
# a timeout and the output is compared as a prefix).  `e*` cases are
# rejections compiled with --kernel, `h*` are rejections compiled without it;
# each needs every `// expect-error:` line it carries to appear in the
# compiler's output.
set -u

source "$(dirname "$0")/lib.sh"   # ROOT, CYCC, YREF, colors, counters

YCC="${YCC:-$ROOT/ycc}"
CYCC="${CYCC:-$ROOT/cycc}"
QEMU="${QEMU:-qemu-system-x86_64}"
KDIR="$ROOT/test/kernel"
QTIME="${QTIME:-6}"
WORK="${YOUT:-$(mktemp -d)}"
# lib.sh's fail takes an optional second line, and with `set -u` an omitted
# one is an unbound variable; this suite always has one line to say.
kfail() { fail "$1" "${2:-}"; }
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

if ! command -v "$QEMU" >/dev/null 2>&1; then
    skip "kernel: no $QEMU, the whole suite" "install qemu-system-x86_64"
    print_summary "kernel"
    exit 0
fi

# Does this compiler know --kernel?  A tree built before the feature answers
# "unknown flag".
kernel_ok() {
    local c=$1
    [ -x "$c" ] || return 1
    ( cd "$ROOT" && timeout "$((30 * YTIMEOUT_SCALE))" "$c" --kernel "$KDIR/t001_hello.y" -o "$WORK/probe.elf" ) >/dev/null 2>&1
}

Y_OK=0
C_OK=0
kernel_ok "$YCC" && Y_OK=1
kernel_ok "$CYCC" && C_OK=1
if [ "$Y_OK" = 0 ]; then
    skip "kernel: $YCC has no --kernel" "build the kernel branch's ycc"
    print_summary "kernel"
    exit 0
fi
[ "$C_OK" = 1 ] && echo "kernel: two engines ($YCC, $CYCC)" || echo "kernel: one engine ($YCC; $CYCC has no --kernel yet)"

# ── the booted cases ────────────────────────────────────────────────────
for src in "$KDIR"/[tx]*.y; do
    base=$(basename "$src" .y)
    exp="$KDIR/$base.expected"
    [ -f "$exp" ] || { kfail "$base: no .expected"; continue; }
    yimg="$WORK/$base.y.elf"
    if ! ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$YCC" --kernel "$src" -o "$yimg" ) >"$WORK/$base.y.log" 2>&1; then
        kfail "$base: $YCC --kernel failed"
        sed 's/^/    /' "$WORK/$base.y.log"
        continue
    fi
    if [ "$C_OK" = 1 ]; then
        cimg="$WORK/$base.c.elf"
        if ! ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$CYCC" --kernel "$src" -o "$cimg" ) >"$WORK/$base.c.log" 2>&1; then
            kfail "$base: $CYCC --kernel failed"
            sed 's/^/    /' "$WORK/$base.c.log"
            continue
        fi
        if ! cmp -s "$yimg" "$cimg"; then
            kfail "$base: $CYCC and $YCC images differ"
            continue
        fi
        # -S is the same program in text; the two compilers must render it the
        # same way too (this is what catches a ported encoder arm).
        ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$YCC" --kernel -S "$src" ) >"$WORK/$base.y.s" 2>&1
        ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$CYCC" --kernel -S "$src" ) >"$WORK/$base.c.s" 2>&1
        if ! cmp -s "$WORK/$base.y.s" "$WORK/$base.c.s"; then
            kfail "$base: -S listings differ"
            continue
        fi
    fi
    # The "kernel must be small" ratchet: the image is ONE 2 MB page of
    # kernel mapping, and a kernel that outgrows this budget is a design
    # regression rather than a slow build.
    imgsz=$(wc -c <"$yimg")
    if [ "$imgsz" -gt 262144 ]; then
        kfail "$base: image is $imgsz bytes (budget 262144)"
        continue
    fi
    stdin=/dev/null
    [ -f "$KDIR/$base.stdin" ] && stdin="$KDIR/$base.stdin"
    # The input is fed a second in: the guest's serial_init clears the UART's
    # receive FIFO, so a byte that arrived before it ran would be discarded --
    # which is exactly what the first version of this case measured.  A
    # person types after the machine is up; this is that.
    if [ -f "$KDIR/$base.stdin" ]; then
        { sleep 1; cat "$stdin"; } | timeout "$QTIME" "$QEMU" -kernel "$yimg" -serial stdio \
            -display none -no-reboot -device isa-debug-exit -monitor none >"$WORK/$base.out" 2>/dev/null
    else
        timeout "$QTIME" "$QEMU" -kernel "$yimg" -serial stdio -display none \
            -no-reboot -device isa-debug-exit -monitor none </dev/null >"$WORK/$base.out" 2>/dev/null
    fi
    qrc=$?
    n=$(wc -c <"$exp")
    head -c "$n" "$WORK/$base.out" >"$WORK/$base.head"
    if cmp -s "$WORK/$base.head" "$exp"; then
        pass "$base: boots, serial output matches"
    else
        kfail "$base: serial output differs"
        echo "    expected:"; sed 's/^/      /' "$exp"
        echo "    got:"; sed 's/^/      /' "$WORK/$base.head"
        continue
    fi
    # A case with a `.exit` leaves the machine through kexit, and qemu's own
    # status is the verdict: (code << 1) | 1 through the isa-debug-exit port.
    if [ -f "$KDIR/$base.exit" ]; then
        want=$(cat "$KDIR/$base.exit")
        if [ "$qrc" = "$want" ]; then
            pass "$base: kexit -> qemu status $qrc"
        else
            kfail "$base: qemu status $qrc, wanted $want"
        fi
    fi
done

# ── the userland cases: a real ycc-compiled Linux program in ring 3 ─────
# One driver (uland.y, compiled with --kernel) and one program per case
# (`u*.user.y`, compiled by the ORDINARY target, which is the point: the
# kernel implements the ABI the program already speaks, so the fixture is also
# a program that runs on Linux).
for usrc in "$KDIR"/u*.user.y; do
    [ -e "$usrc" ] || continue
    base=$(basename "$usrc" .user.y)
    kimg="$WORK/$base.elf"
    pimg="$WORK/$base.prog"
    if ! ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$YCC" --kernel "$KDIR/uland.y" -o "$kimg" ) >"$WORK/$base.k.log" 2>&1; then
        kfail "$base: the driver failed to compile"
        sed 's/^/    /' "$WORK/$base.k.log"
        continue
    fi
    if ! ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$YCC" "$usrc" -o "$pimg" ) >"$WORK/$base.p.log" 2>&1; then
        kfail "$base: the program failed to compile (ordinary target)"
        sed 's/^/    /' "$WORK/$base.p.log"
        continue
    fi
    if [ "$C_OK" = 1 ]; then
        cimg="$WORK/$base.c.elf"
        cprog="$WORK/$base.c.prog"
        ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$CYCC" --kernel "$KDIR/uland.y" -o "$cimg" ) >/dev/null 2>&1
        ( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$CYCC" "$usrc" -o "$cprog" ) >/dev/null 2>&1
        if ! cmp -s "$kimg" "$cimg"; then
            kfail "$base: the driver's images differ between the compilers"
            continue
        fi
        if ! cmp -s "$pimg" "$cprog"; then
            kfail "$base: the programs differ between the compilers"
            continue
        fi
    fi
    exp="$KDIR/$base.expected"
    [ -f "$exp" ] || { kfail "$base: no .expected"; continue; }
    if [ "$(wc -c <"$kimg")" -gt 262144 ]; then
        kfail "$base: the driver's image is over budget"
        continue
    fi
    timeout "$QTIME" "$QEMU" -kernel "$kimg" -initrd "$pimg" -serial stdio \
        -display none -no-reboot -device isa-debug-exit -monitor none </dev/null >"$WORK/$base.out" 2>/dev/null
    qrc=$?
    n=$(wc -c <"$exp")
    head -c "$n" "$WORK/$base.out" >"$WORK/$base.head"
    if cmp -s "$WORK/$base.head" "$exp"; then
        pass "$base: the program runs in ring 3"
    else
        kfail "$base: serial output differs"
        echo "    expected:"; sed 's/^/      /' "$exp"
        echo "    got:"; sed 's/^/      /' "$WORK/$base.head"
        continue
    fi
    if [ -f "$KDIR/$base.exit" ]; then
        want=$(cat "$KDIR/$base.exit")
        if [ "$qrc" = "$want" ]; then
            pass "$base: kexit -> qemu status $qrc"
        else
            kfail "$base: qemu status $qrc, wanted $want"
        fi
    fi
done

# ── the rejected cases ──────────────────────────────────────────────────
check_reject() {
    local src=$1 base=$2 mode=$3
    local flags=""
    [ "$mode" = kernel ] && flags="--kernel"
    local out
    out=$( cd "$ROOT" && timeout "$((60 * YTIMEOUT_SCALE))" "$YCC" $flags "$src" -o "$WORK/$base.out.bin" 2>&1 )
    local rc=$?
    local bad=0
    if [ "$mode" = kernel ] && [ "$rc" = 0 ]; then
        kfail "$base: --kernel accepted it"
        return
    fi
    if [ "$mode" = hosted ] && [ "$rc" = 0 ]; then
        kfail "$base: the hosted compiler accepted it"
        return
    fi
    while IFS= read -r line; do
        case "$line" in
            *"// expect-error: "*)
                msg="${line#*// expect-error: }"
                case "$out" in
                    *"$msg"*) : ;;
                    *) kfail "$base: missing diagnostic '$msg'"; bad=1 ;;
                esac
                ;;
        esac
    done <"$src"
    [ "$bad" = 0 ] && pass "$base: rejected with its diagnostics"
}

# ── the driver's own refusals ───────────────────────────────────────────
# Inline rather than fixtures: each is a flag combination, not a program, and
# the expected text is quoted here because the coverage suite reads the
# suites for the messages their tests assert.
driver_reject() {
    local what=$1 want=$2; shift 2
    local out
    out=$( cd "$ROOT" && timeout "$((30 * YTIMEOUT_SCALE))" "$YCC" "$@" 2>&1 )
    case "$out" in
        *"$want"*) pass "driver: $what" ;;
        *) kfail "driver: $what" "wanted '$want', got: $out" ;;
    esac
}

driver_reject "--kernel with -g" "-g is not supported with --kernel" \
    --kernel -g "$KDIR/t001_hello.y" -o "$WORK/g.elf"
driver_reject "--kernel run" "--kernel cannot run its image (boot it with 'qemu-system-x86_64 -kernel')" \
    --kernel run "$KDIR/t001_hello.y"
driver_reject "unknown target" "unknown target 'os2' (linux, windows, kernel)" \
    --target=os2 "$KDIR/t001_hello.y" -o "$WORK/x.elf"

for src in "$KDIR"/e*.y; do
    check_reject "$src" "$(basename "$src" .y)" kernel
done
for src in "$KDIR"/h*.y; do
    check_reject "$src" "$(basename "$src" .y)" hosted
done

print_summary "kernel"
