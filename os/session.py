#!/usr/bin/env python3 -I
"""Drive a Y-OS session under qemu: boot, then send one command line at a time,
each only after the shell has printed its prompt, and print the transcript.

    os/session.py [--timeout S] [--img os/build/os.img] [--fs os/build/os.fs] CMD...

The transcript is exactly what the serial console showed (the shell echoes what
it reads, so the commands are in it). Exit status: 0 when every command got its
prompt back and the machine halted, 1 on a timeout.
"""
import os, select, subprocess, sys, time

def main(argv):
    timeout = 60.0
    img, fs = "os/build/os.img", "os/build/os.fs"
    cmds = []
    i = 0
    while i < len(argv):
        if argv[i] == "--timeout": timeout = float(argv[i + 1]); i += 2
        elif argv[i] == "--img": img = argv[i + 1]; i += 2
        elif argv[i] == "--fs": fs = argv[i + 1]; i += 2
        else: cmds.append(argv[i]); i += 1
    p = subprocess.Popen(
        ["qemu-system-x86_64", "-kernel", img, "-initrd", fs, "-serial", "stdio",
         "-display", "none", "-no-reboot", "-device", "isa-debug-exit", "-m", "128"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    out = b""
    sent = 0
    deadline = time.time() + timeout
    fd = p.stdout.fileno()
    ok = True
    while True:
        left = deadline - time.time()
        if left <= 0:
            ok = False
            break
        r, _, _ = select.select([fd], [], [], min(left, 0.2))
        if r:
            chunk = os.read(fd, 4096)
            if not chunk:
                break                      # qemu exited: the machine halted
            out += chunk
        # a prompt at the end of the output means the shell is waiting for a line
        if sent < len(cmds) and out.endswith(b"$ "):
            p.stdin.write(cmds[sent].encode() + b"\r")
            p.stdin.flush()
            sent += 1
    if p.poll() is None:
        p.kill()
    p.wait()
    sys.stdout.write(out.decode("utf-8", "replace").replace("\r\n", "\n"))
    return 0 if ok and sent == len(cmds) else 1

sys.exit(main(sys.argv[1:]))
