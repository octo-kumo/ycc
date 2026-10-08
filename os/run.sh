#!/bin/bash
# Boot Y-OS under qemu with the serial console on this terminal.
# Ctrl-A X leaves qemu; `halt` in the shell stops the machine.
cd "$(dirname "$0")/.."
[ -f os/build/os.img ] || bash os/build.sh || exit 1
exec qemu-system-x86_64 -kernel os/build/os.img -initrd os/build/os.fs \
    -serial mon:stdio -display none -no-reboot -device isa-debug-exit -m 128
