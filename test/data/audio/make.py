#!/usr/bin/env python3
# Builds test/data/audio/fixtures.bin: signals written as WAV by hand (every
# sample format audio.y reads) and as FLAC by the `flac` encoder (levels,
# block sizes, bit depths, channel counts, wasted bits), each followed by the
# 16-bit PCM it must decode to, computed here. Record: u8 name length, name,
# u32 rate, u8 channels, u32 file length, file, u32 pcm length, pcm.
import math
import os
import random
import struct
import subprocess
import tempfile

tmp = tempfile.mkdtemp()
rng = random.Random(7)


def signal(n, ch, amp):
    out = []
    for i in range(n):
        for c in range(ch):
            v = amp * (0.5 * math.sin(i * 0.05 * (c + 1)) + 0.3 * math.sin(i * 0.31) + 0.1 * (rng.random() - 0.5))
            out.append(int(v))
    return out  # interleaved ints


def s16(v):
    return max(-32768, min(32767, v))


def wav(rate, ch, bits, samples, fmt=1):
    if bits == 8:
        data = bytes((v + 128) & 255 for v in samples)
    elif bits == 16:
        data = b"".join(struct.pack("<h", v) for v in samples)
    elif bits == 24:
        data = b"".join((v & 0xFFFFFF).to_bytes(3, "little") for v in samples)
    elif bits == 32 and fmt == 1:
        data = b"".join(struct.pack("<i", v) for v in samples)
    elif bits == 32:
        data = b"".join(struct.pack("<f", v) for v in samples)
    elif bits == 64:
        data = b"".join(struct.pack("<d", v) for v in samples)
    fm = struct.pack("<HHIIHH", fmt, ch, rate, rate * ch * bits // 8, ch * bits // 8, bits)
    body = b"WAVE" + b"fmt " + struct.pack("<I", 16) + fm + b"LIST" + struct.pack("<I", 4) + b"INFO" + b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


cases = []  # name, rate, ch, file, pcm16 ints
n = 3000
for ch in (1, 2):
    sig = signal(n, ch, 12000)
    cases.append(("wav16_%dch" % ch, 22050, ch, wav(22050, ch, 16, sig), sig))
    sig8 = [v >> 8 for v in sig]
    cases.append(("wav8_%dch" % ch, 8000, ch, wav(8000, ch, 8, sig8), [(v) << 8 for v in sig8]))
sig = signal(n, 2, 8000000)
cases.append(("wav24", 48000, 2, wav(48000, 2, 24, sig), [v >> 8 for v in sig]))
sig = signal(n, 2, 2000000000)
cases.append(("wav32", 44100, 2, wav(44100, 2, 32, sig), [v >> 16 for v in sig]))
fs = [v / 40000.0 for v in signal(n, 2, 30000)]
cases.append(("wavf32", 44100, 2, wav(44100, 2, 32, fs, 3), [s16(int(struct.unpack("<f", struct.pack("<f", v))[0] * 32768.0)) for v in fs]))
cases.append(("wavf64", 44100, 2, wav(44100, 2, 64, fs, 3), [s16(int(v * 32768.0)) for v in fs]))

# FLAC
flac_cases = [
    ("flac_l0", 1, 16, 44100, ["-0"]),
    ("flac_l5_stereo", 2, 16, 44100, ["-5"]),
    ("flac_l8", 2, 16, 44100, ["-8"]),
    ("flac_l8e", 2, 16, 32000, ["-8", "-e", "-p"]),
    ("flac_b256", 2, 16, 44100, ["-b", "256", "-5"]),
    ("flac_b4608", 2, 16, 48000, ["-b", "4608", "-6"]),
    ("flac_verbatim", 2, 16, 44100, ["-b", "16", "--lax", "-0", "-r", "0"]),
    ("flac_mono8", 1, 8, 8000, ["-5"]),
    ("flac_24", 2, 24, 96000, ["-5"]),
    ("flac_ms", 2, 16, 44100, ["-m", "-l", "12"]),
    ("flac_ind", 2, 16, 44100, ["-M", "-l", "0"]),
    ("flac_6ch", 6, 16, 44100, ["-5"]),
]
for name, ch, bits, rate, opts in flac_cases:
    amp = (1 << (bits - 1)) * 0.6
    sig = signal(n * 2 if "b4608" in name else n, ch, amp)
    if name == "flac_verbatim":
        sig = [rng.randint(-30000, 30000) for _ in range(n * ch)]
    if name == "flac_l8":  # wasted bits: every sample a multiple of 8
        sig = [v & ~7 for v in sig]
    wp = os.path.join(tmp, name + ".raw")
    fp = os.path.join(tmp, name + ".flac")
    nb = 1 if bits == 8 else 2 if bits == 16 else 3
    if bits == 8:
        raw = bytes(v & 255 for v in sig)
    elif bits == 16:
        raw = b"".join(struct.pack("<h", v) for v in sig)
    else:
        raw = b"".join((v & 0xFFFFFF).to_bytes(3, "little") for v in sig)
    open(wp, "wb").write(raw)
    args = ["flac", "-s", "-f", "--no-padding", "--force-raw-format", "--endian=little", "--sign=signed",
            "--channels=%d" % ch, "--bps=%d" % bits, "--sample-rate=%d" % rate] + opts + ["-o", fp, wp]
    subprocess.run(args, check=True, stderr=subprocess.DEVNULL)
    if bits == 8:
        pcm = [v << 8 for v in sig]
    elif bits == 16:
        pcm = sig
    elif bits == 20:
        pcm = [v >> 4 for v in sig]
    else:
        pcm = [v >> 8 for v in sig]
    cases.append((name, rate, ch, open(fp, "rb").read(), pcm))

buf = bytearray()
for name, rate, ch, f, pcm in cases:
    pb = b"".join(struct.pack("<h", s16(v)) for v in pcm)
    n_ = name.encode()
    buf += bytes([len(n_)]) + n_ + struct.pack("<IBI", rate, ch, len(f)) + f + struct.pack("<I", len(pb)) + pb
open("test/data/audio/fixtures.bin", "wb").write(buf)
print(len(buf), len(cases))
