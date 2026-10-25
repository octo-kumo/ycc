#!/usr/bin/env python3
"""Red-team checks for a ycc --obfuscate image.

This is deliberately a small, external tool: it does not import the compiler
and it does not try to be a full reverse-engineering suite.  It checks the
properties the obfuscation layer claims, so a regression is visible:

  scan    no fixed YOBFMAGI canary, no marker, no ELF symbols/sections
  tamper  a flipped sealed byte is refused (exit 127, no output)
  gdb     a full build refuses to start under gdb (exit 0177)

Usage: audit.py {scan,tamper,gdb} BIN [--marker TEXT] [--map PATH]
"""
import argparse
import os
import shutil
import struct
import subprocess
import sys
import tempfile

PT_LOAD = 1
PF_X = 1
PF_W = 2


def elf_header(b):
    if len(b) < 64 or b[:4] != b"\x7fELF" or b[4] != 2:
        raise SystemExit("not an ELF64 file")
    e_entry, e_phoff = struct.unpack_from("<QQ", b, 24)
    e_phentsize, e_phnum = struct.unpack_from("<HH", b, 54)
    e_shoff, e_shnum = struct.unpack_from("<QH", b, 40)
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags, p_offset, p_vaddr, _, p_filesz, p_memsz, _ = struct.unpack_from(
            "<IIQQQQQQ", b, off
        )
        if p_type == PT_LOAD:
            loads.append((p_offset, p_vaddr, p_filesz, p_memsz, p_flags))
    return e_entry, e_shoff, e_shnum, loads


def run(bin_path, timeout=20):
    try:
        p = subprocess.run(
            [bin_path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=timeout
        )
        return p.returncode, p.stdout
    except subprocess.TimeoutExpired:
        return 124, b""


def scan(path, marker, map_path):
    b = open(path, "rb").read()
    _, shoff, shnum, loads = elf_header(b)
    bad = False

    def report(ok, what, detail=""):
        nonlocal bad
        print(("ok   " if ok else "LEAK ") + what + ((" -- " + detail) if detail else ""))
        if not ok:
            bad = True

    report(shoff == 0 and shnum == 0, "no section headers")
    report(b"YOBFMAGI" not in b and b"IGAMFBOY" not in b, "no fixed canary")
    if marker:
        report(marker.encode() not in b, "marker literal absent")
    if map_path:
        report(os.path.isfile(map_path), "map written", map_path)
        if os.path.isfile(map_path):
            text = open(map_path, "r", errors="replace").read()
            report("build=" in text and "y_obf_" in text, "map has the build id and labels")
    print("loads: " + ", ".join(
        "off=%#x vaddr=%#x filesz=%#x flags=%#x" % (o, v, f, fl) for o, v, f, _, fl in loads
    ))
    return 1 if bad else 0


def tamper(path):
    b = bytearray(open(path, "rb").read())
    _, _, _, loads = elf_header(bytes(b))
    rx = [x for x in loads if x[4] & PF_X and not x[4] & PF_W]
    if not rx:
        print("no executable load segment")
        return 2
    off, vaddr, filesz, _, _ = rx[0]
    # The last byte before the file-backed end is in .rodata, which the seal
    # covers; it is not part of the ELF trailer.
    at = off + filesz - 9
    b[at] ^= 1
    d = tempfile.mkdtemp(prefix="obf-audit-")
    try:
        bad = os.path.join(d, "tampered")
        open(bad, "wb").write(b)
        os.chmod(bad, 0o755)
        rc, out = run(bad)
        ok = rc == 127 and out == b""
        print(("ok   " if ok else "FAIL ") + "tampered byte refused (exit %d, %d bytes of output)" % (rc, len(out)))
        if not ok:
            print(out[:300].decode("utf-8", "replace"))
        return 0 if ok else 1
    finally:
        shutil.rmtree(d, ignore_errors=True)


def gdb_check(path):
    gdb = shutil.which("gdb")
    if gdb is None:
        print("skip no gdb")
        return 0
    try:
        p = subprocess.run(
            [gdb, "-q", "-batch", "-ex", "handle SIGSEGV nostop noprint pass",
             "-ex", "run", path],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, timeout=30
        )
        text = p.stdout.decode("utf-8", "replace")
        ok = "0177" in text
        print(("ok   " if ok else "FAIL ") + "gdb refused the image")
        if not ok:
            print(text[-500:])
        return 0 if ok else 1
    except subprocess.TimeoutExpired:
        print("FAIL gdb timed out")
        return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["scan", "tamper", "gdb"])
    ap.add_argument("binary")
    ap.add_argument("--marker", default="")
    ap.add_argument("--map", dest="map_path", default="")
    a = ap.parse_args()
    if a.command == "scan":
        return scan(a.binary, a.marker, a.map_path)
    if a.command == "tamper":
        return tamper(a.binary)
    return gdb_check(a.binary)


if __name__ == "__main__":
    sys.exit(main())
