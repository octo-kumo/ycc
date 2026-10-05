# audio — an integer fixed-point synthesiser, a byte-exact WAV, and an ALSA PCM player

## What this is

A synthesiser written entirely in integer arithmetic, a RIFF/WAVE writer whose
output is reproducible to the byte, and a player that talks to a real ALSA PCM
device with raw syscalls and raw ioctls. No floats, no `sin`, no sound library,
no FFI.

```
cd examples/audio
../../refs/ycc.ref audio.y -o audio     # builds; zero warnings

./audio demo          # synthesise 1.5 s, write demo.wav, print a report
./audio demo --play --silence --ms 200 --device /dev/snd/pcmC3D0p
./audio check         # 167 property assertions
./audio devices       # enumerate and probe every PCM node under /dev/snd
./audio --help
```

`--play` without `--silence` **makes sound**. `--silence` pushes the same number
of frames through the same code path as digital silence, which is how the write
path is proved without a noise.

## The split, and why it is not a preference

**The default run does not touch the sound hardware at all.** It synthesises in
integers, writes a WAV, and prints a report whose sha256 pins every byte of that
file. Audio output cannot be deterministic — it depends on hardware that may be
absent, it depends on a sound server that may be running — and it produces no
bytes to diff, so a golden file cannot check it. So playback lives behind
`--play`, in the same way the campaign puts the live API behind `--live` and
randomness behind `--seed`. Hardware is a fourth category of nondeterminism and
it gets the same treatment.

The consequence worth stating: the acceptance gate can verify the synthesis to
the byte and can verify the *player* only through its arithmetic (see §5), so
the player is written to be **measurable** rather than to be pretty.

## The pinned compiler

`refs/ycc.ref`, sha256
**`1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3`**

The pin moved once during this example's work, from
`625efd81934531f6afee595bb47f5dbb680a6cb3f485b4856b9a9259ceea824b` to the sha
above. Everything was rebuilt from source with the new pin and re-run in full:
the build is clean, `EXPECTED` is reproduced byte for byte over two runs, the
property battery is 167/167, the device enumeration is 7 of 8, and the silence
write still succeeds. The earlier sha is recorded on purpose — this example has
been verified against each, and a reader who wants to know what changed should
be able to see it rather than infer it.

**Toolkit: `fx.y` and `args.y`, vendored byte-identical** from
`examples/_toolkit/`, frozen shas:

| file | sha256 |
|---|---|
| `fx.y` | `4b47a9bfef0c1e30aa2397a24e21ab43753e6994c298f7ccd43c418b87b62058` |
| `args.y` | `cdac36da1cf2cd8551bd06b1bf2a7b608736bc55106e64f5be3b7aa9332e9d28` |

Nothing was edited. `fb.y`, `term.y` and `time.y` are not vendored: there is no
terminal drawing, no raw mode and no in-process pacing here.

## What the synthesiser is

`dsp.y`, Q30 throughout (a `long` `v` holds the real number `v / 2^30`), with
**one** call into trigonometry in the whole program: `fx.sin`, once per
wavetable entry, at start-up. Everything after that is a table read, an integer
interpolate, a multiply and an add.

* **Four wavetables** of 4096 entries each — sine, triangle, sawtooth, square —
  in one flat array, built once. The sine table is exactly odd-symmetric
  (`sin(t+π) = −sin(t)`, checked over all 4096 entries) and `tab[1024]` is
  exactly `fx.ONE`, because it is one formula evaluated at one phase.
* **The oscillator** keeps a phase in Q30 *turns*. `t = phase * 4096` puts the
  turn at Q30 *cells*, so `t >> 30` is the cell and `t & (2^30−1)` is the
  position inside it — one multiply, no division. The two *discontinuous* waves
  (square, sawtooth) are sampled and the two continuous ones (sine, triangle)
  are interpolated; interpolating across a discontinuity is not an approximation
  of anything, and doing it anyway cost the square 56 LSB of RMS
  (19944 instead of 20000).
* **A linear ADSR** in Q30 with the slopes and the four segment boundaries
  precomputed per voice, so the per-sample cost is a compare and one multiply.
* **A one-pole lowpass**, `y += a·(x−y)`, with
  `a = 1 − exp(−2π·fc/fs)` taken to `x^7/5040` in Q30 — there is no `exp` in
  the language, so the series *is* the coefficient. At the largest cutoff this
  example accepts (12 kHz at 48 kHz) the first dropped term is 1.2e-4 of a
  coefficient near 0.79.
* **A nine-note score** in A minor: a triangle bass, a sine lead detuned a
  fraction of a sample between the channels for width, and one saw for edge.
  It is *data* (`wav.y`'s `demo_score`), not code, and it is written once — the
  demo and the property battery render from the same list, because a battery
  carrying its own copy of the score would be checking a different piece from
  the one the golden file records.

### The demo's numbers, and the commands that produced them

| quantity | value | command |
|---|---|---|
| file length | 288 044 bytes (44 + 72000·4) | `./audio demo` |
| sha256 of the file | `71adef7247385151b28646d0ac871b2fe076fb92d8d03753240dcad3be9b250f` | `./audio demo`, `sha256sum demo.wav` |
| peak | 21 635 of 32 767 (66%) | `./audio demo` |
| RMS | 4 763 | `./audio demo` |
| DC offset | 2 LSB (99 ppm of full scale) | `./audio demo` |
| zero crossings (left) | 485 | `./audio demo` |
| lowpass coefficient | 0.573 at 6500 Hz | `./audio demo` |
| `--check` | 167/167 in **0.13 s**, peak RSS 12 304 KiB | `/usr/bin/time -v ./audio check` |
| `./audio demo` | 0.02 s, peak RSS 6 400 KiB | `/usr/bin/time -v ./audio demo` |

The peak and RMS are computed from the s16 bytes that reached the disk, by a
decoder that shares nothing with the synthesiser. `71adef…` is the *whole file*,
header included: any single bit changed anywhere in those 288 044 bytes changes
the digest, which changes `EXPECTED`, which fails gate item 2. That is what makes
the golden file a byte-for-byte statement about the WAV rather than about the
program.

## The player

`pcm.y`. Six ioctls and two syscalls:

```
openat("/dev/snd/pcmC3D0p", O_WRONLY|O_NONBLOCK)
ioctl  SNDRV_PCM_IOCTL_INFO        0x81204101
ioctl  SNDRV_PCM_IOCTL_HW_PARAMS   0xc2604111
ioctl  SNDRV_PCM_IOCTL_SW_PARAMS   0xc0884113
ioctl  SNDRV_PCM_IOCTL_PREPARE     0x4140
fcntl  F_SETFL, 0                         (clear O_NONBLOCK)
write(2) x N
ioctl  SNDRV_PCM_IOCTL_DRAIN       0x4144
close
```

That is `strace` output from this program, not from `aplay`; it is identical in
shape to what a working `aplay -q -D hw:3,0 file.wav` does.

### The device it actually played through

Measured, on the machine this was built on, with `--device /dev/snd/pcmC3D0p`:

```
audio: negotiated on /dev/snd/pcmC3D0p (USB Audio.......................)
  rate            48000 Hz
  channels        2
  access          RW_INTERLEAVED (3)
  format          S16_LE (2)
  subformat       STD (0)
  period          480 frames (10 ms)
  buffer          1920 frames (40 ms)
  request shape   full -- every interval pinned and consistent
  sw_params       ioctl returned 0
audio: wrote 19200 frames (400 ms, 2ch s16le 48000 Hz) in 72 short write(s), 0 recovery, 176 stall(s)
```

Every one of those is read back out of the struct the kernel filled in
(`hw_ival` / `hw_mask_val`), not assumed. `pcmC3D0p` is the USB Audio
PLAYBACK 0 node (card 3). 400 ms of **digital silence** — `--silence` — so
nothing was audible.

### Device enumeration

`./audio devices`, measured, verbatim:

```
audio: 8 playback PCM node(s) under /dev/snd
  pcmC2D3p    card -1   no: open: EBUSY
  pcmC2D7p    card  2   usable
  pcmC2D8p    card  2   usable
  pcmC2D9p    card  2   usable
  pcmC3D0p    card  3   usable
  pcmC3D1p    card  3   usable
  pcmC3D2p    card  3   usable
  pcmC3D3p    card  3   usable

  7 of 8 usable at 48000 Hz s16le 2ch
```

**7 of 8**, which is exactly what the orchestrator measured with `aplay` before
this example was dispatched: only `pcmC2D3p` is EBUSY (the sound server holds
it). The enumeration is not hardcoded to a node: it walks `/dev/snd`, keeps
names matching `pcm*p` (the direction is in the node name), opens each,
`INFO`s it to confirm it really is a playback stream, negotiates `hw_params`,
and records *why* each was refused. `card -1` on the EBUSY line is honest: the
node never opened, so nothing was asked.

### Four things about the ALSA ABI that are not in the documentation

All four cost real time here, all four are measured rather than recalled, and
one of them is a claim this file made and then had to take back.

1. **These devices need *every* interval pinned to a consistent value.** Not
   the rate and the channel count — all nine of them, with the derived
   quantities agreeing: `SAMPLE_BITS`, `FRAME_BITS`, `CHANNELS`, `RATE`,
   `PERIOD_TIME`, `PERIOD_SIZE`, `PERIOD_BYTES`, `PERIODS`, `BUFFER_TIME`,
   `BUFFER_SIZE`, `BUFFER_BYTES`. Dropping *any one* turns `HW_PARAMS` into
   `EINVAL`, even though leaving a parameter out is supposed to mean "you
   choose", and even though `rmask` is 0 so nothing is formally requested.
   Measured across all seven openable nodes — four USB Audio and three NVidia
   HDMI — and confirmed by injecting the defect: remove
   `hw_pin(PARAM_PERIOD_BYTES, …)` and `audio devices` reports **0 of 8
   usable** instead of 7; change the frame-byte term from `channels * 2` to
   `channels * 3` and likewise 0 of 8.

   The honest thing to add is the claim this section first made and then had to
   retract. It asserted that the `integer` bit of `struct snd_interval` was what
   made the difference, and the evidence looked good: every C program that was
   refused had the bit clear and every one that was accepted had it set. **That
   was a confound.** Clearing the bit on every interval in the shipped program,
   with the real device, leaves `audio devices` reporting the same 7 of 8 —
   measured, and it is injection **M20** below. The bit stays set, because a
   real client sets it (alsa-lib's `snd_pcm_hw_params_any()` sets it on all of
   them) and because an exact integer rate is what this program asked for, but
   nothing here should be read as claiming it is load-bearing. `pcm.y`'s
   comment says the same thing, and says that it was wrong first.

2. **`hw_fill` therefore derives the whole set from the rate and the channel
   count** — frame bits from the channels, byte counts from the frame size, both
   times from the rate, the ring as four periods — and there are two looser
   shapes behind it (rate and channels only; the masks alone) which are still
   tried, in order, because the point of a player is to work on hardware nobody
   has measured. **Which shape was accepted is reported**, so a reader never has
   to guess which path ran:

   ```
   request shape   full -- every interval pinned and consistent
   ```

3. **A PCM node another process holds answers `EBUSY` to a non-blocking open and
   blocks for ever to a blocking one.** Measured on `pcmC2D3p`: `open(O_WRONLY)`
   had to be killed by a 10 s timeout; `open(O_WRONLY|O_NONBLOCK)` answered
   `EBUSY` at once. The first version of `devices` opened blocking and hung on
   the first busy node. But `SNDRV_PCM_IOCTL_DRAIN` is a *wait*, and on a
   non-blocking descriptor it answers `EAGAIN` every time. The two requirements
   are opposite and only one flag can hold them, so the program opens
   non-blocking — the only way to *learn* a node is busy — and clears
   `O_NONBLOCK` with `fcntl(F_SETFL, 0)` once the device is its own.

4. **`fcntl` is syscall 72**, not 55. `ORCHESTRATOR.md` §2.1 lists the syscall
   numbers it measured and `fcntl` is not among them; the first draft guessed
   55, which is `getsockopt`, and answered `−88 = ENOTSOCK` — a wonderfully
   unhelpful way to find out. Verified by `strace` on a C program making the
   same call, and by `F_GETFL` reporting the flag cleared afterwards.

### The ABI numbers, and how they were obtained

Every request is stored as the constant the code uses **and** as the
`(dir, nr, size)` the kernel's uapi header writes it as, and `--check`
recomputes one from the other and asserts they are equal — so a typo in either
representation is caught, which a bare table of magic hex could not do. The
struct layouts come from compiling `offsetof` against
`/usr/include/sound/asound.h`:

```
$ gcc -O0 -o m m.c && ./m
sizeof hw_params = 608
  0 flags    4 masks[3] (32B each)   100 mres[5]   260 intervals[12] (12B each)
  404 ires[9]  512 rmask  516 cmask  520 info  524 msbits  528 rate_num
  532 rate_den  536 fifo_size  544 sync[16]  560 reserved[48]
HW_PARAMS req = 0xc2604111    INFO req = 0x81204101    SW_PARAMS req = 0xc0884113
PREPARE req = 0x4140          DRAIN req = 0x4144       WRITEI req = 0x40184150
```

The `m.c` that produced that is a throwaway measurement script in `/tmp`, not
part of the folder — the numbers are in the code and the battery, which is where
a reader can check them.

## `--play` on a machine with no audio

The brief requires a clear one-line diagnostic on **stderr**, a non-zero exit,
and **no trap** — traps print to stdout and would corrupt a diff. Measured, with
`--play --silence --ms 40`:

| what | stdout | stderr | exit |
|---|---|---|---|
| `--dir /no/such/dir` | the demo report only | `audio: no usable playback device under /no/such/dir (no sound devices: /no/such/dir could not be read)` | 3 |
| `--device /dev/snd/controlC0` | the demo report only | `audio: /dev/snd/controlC0: INFO: ENOTTY` | 3 |
| `--device /dev/snd/pcmC0D0c` | the demo report only | `audio: /dev/snd/pcmC0D0c: not a playback stream (stream = 1)` | 3 |
| `--transfer writei` | negotiation report | `audio: playback failed: transfer: EFAULT` | 1 |
| `--ms 0` | the demo report only | `audio: --ms must be between 1 and 2000` | 1 |
| `--transfer bogus` | the demo report only | `audio: --transfer must be write or writei` | 2 |

**How those paths were tested without breaking this machine** — the second
question the brief asks. A machine with no sound hardware has no `/dev/snd` to
point at, so the degradation paths are exercised against directories that are
*not* `/dev/snd`, and that is what `--dir` is for. `check.y` §J builds four
under `./audio-check-tmp`, and removes them afterwards:

| directory | what is in it | what it proves |
|---|---|---|
| `./nope` | nothing | a missing directory is reported, not fatal |
| `./empty` | nothing | "no playback PCM node under … (looked for pcm*p)" |
| `./fake/pcmC9D9p` | a **regular file** | it opens, and `INFO` refuses it: `ENOTTY` |
| `./noacc/pcmC8D8p` | a regular file at **mode 000** | a real `EACCES` from `openat` — the path a machine whose POSIX ACL does not grant this user would take |

The `EACCES` case is the one that matters and it is genuinely exercised: the
nodes on this machine are `crw-rw----+ root:audio` with a POSIX ACL, and this
user is **not** in the `audio` group, so a machine without that ACL would fail
exactly here. A regular file named `pcm*p` gives the complementary case — the
name is right and the device is not — with a real ioctl refusal rather than a
simulated one.

## The property battery: `./audio check`

167 assertions, **0.13 s**, peak RSS 12.3 MiB, no reference file. A golden file
proves determinism and nothing else — `cube` cleared the whole gate while
rendering filled wedges, because its `EXPECTED` had been captured from the
broken output — so every expectation here is one of three things the program
does not compute for itself.

### 1. Analytic identities — the strongest checks

These are facts about mathematics, not about this code, so agreeing with them is
evidence. **Measured on the bytes of the written WAV, decoded independently:**

| wave | identity | expected | measured | tolerance |
|---|---|---|---|---|
| sine, A = 20 000, 1 kHz | RMS = A/√2 | 14 142 | 14 142 | ±20 (0.14 %) |
| square, A = 20 000 | RMS = A | = peak | equal to 1 LSB | ±2 (100 ppm) |
| triangle, A = 20 000, 375 Hz | RMS = A/√3 | 11 547 | 11 563 | ±60 (0.52 %) |
| sawtooth, A = 20 000, 375 Hz | RMS = A/√3 | 11 547 | 11 506 | ±60 |
| sine | peak = A | 20 000 | 20 000 | ±4 |
| sine | \|DC\| | ≤ 1 | 2 LSB (99 ppm) | ±4 |

The tolerances are derived, not guessed. The sine's is 0.14 % of pure margin
over a budget of ~1e-4 (Q30 table rounding, phase-increment truncation, one LSB
of `isqrt`); the square's is 1 LSB out of 20 000, which separates "this is a
square" from "this is not a square" — 1.41× — by three orders of magnitude; the
triangle's and the sawtooth's are the **discretisation** of a piecewise-linear
signal over 48 samples a period, and the fixtures use 375 Hz — 128 samples a
period, and exactly 32 wavetable cells a period, so every sample lands on a cell
the table holds — where that error falls to 0.011 % and the bound of 0.52 % is
five times the arithmetic.

`silence really silent` is **paired** with a negative control, because "every
sample is zero" also passes on an empty buffer: D40–D43 assert a zero-amplitude
render is exactly 48 000 frames of exact zeros, and D44 asserts the *same code
path* at amplitude A has 47 145 non-zero frames. If the render did nothing at
all, D44 fails.

### 2. The oscillator against a different algorithm

`tab_read` (a lookup and a linear interpolate over a 4096-point table) is
compared with `fx.sin` (a Taylor series on a reduced argument) over 3000
phases: **worst error 316 Q30 units, bound 400**. The bound is not arbitrary —
the interpolator's own error is `(h²)/8·sin` with `h = 2π/4096`, which is
2.9e-7 of full scale, or 311 Q30 units. 3000 phases rather than 2048 or 4096 on
purpose: a phase count that *divides* the table length puts every sample exactly
on a cell, and then the check would never touch the interpolator at all.

Plus the table's own invariants: 16 388 entries present, `tab[0] = 0`,
`tab[1024] = fx.ONE` exactly, `tab[3072] = −fx.ONE` exactly, **exactly**
odd-symmetric over all 4096 entries, and monotone over the first quarter.

Plus the phase accumulator: `osc_inc(1000, 48000) = 22 369 621`, and a whole
second of it accumulates to 1 073 741 808 000 against 1 073 741 824 000 wanted —
a drift of 16 000 units, under one sample step. This is the check that catches
`a / b` returning a **ratio** instead of a fixed-point quotient (ORCHESTRATOR.md
§2.15), which would make the increment 0 and the drift 2^30.

And zero crossings: one second of 1 kHz gives **1999**, and 1999 crossings over
both edges of a second is 999 Hz against a nominal 1000 — half a hertz in a
thousand, and the best any zero-crossing count can do on a signal that starts
at zero.

### 3. The container, the quantiser, the envelope, the filter, the mix

* **Container** — all four chunk ids and all eight numeric fields parsed back
  out of the image and checked against what the RIFF specification requires at
  those offsets; `data size == frames*4`; `riff size == 36 + data`;
  `total == 44 + data`; and **the file's sha256 equals the image's sha256**, so
  a truncated write cannot pass.
* **Quantiser** — `0 → 0`, `±1.0 → ±32767`, `±2.0` **clamps** at ±32767/−32768
  rather than wrapping, −32768 is reachable, and three values chosen to land on
  a fraction above one half, where truncating would answer one LSB lower.
* **Envelope** — the four segment boundaries in samples; zero outside the note
  and exactly zero at the sample *after* it; monotone attack / decay / release
  counted rather than stopped (there is no `break`); sustain held flat; the
  attack within two steps of unity and the release within two steps of zero;
  nothing outside `[0, 1]`; a 2 ms note with a 200 ms attack still ordered; and
  **more notes than the buffer holds refused and counted** (40 offered, 16
  taken, 24 refused, array length 16 — no silent drop, no write past the end).
* **Filter** — measured, not re-derived: the coefficient is inside `[0, 1]` and
  rises with the cutoff; a cutoff of 0 is a bypass; **a DC input arrives at its
  own value** after sixteen time constants; at the cutoff the measured gain is
  1/√2 within 2.5 %; and the response is monotone in the cutoff (measured RMS at
  200 Hz < 1 kHz < 5 kHz).
* **Mix** — two renders byte-identical, with the buffer poisoned to `0xFF` in
  between so a partial write cannot pass; no voice refused; every voice inside
  the render; nothing clipped (peak 21 635 of 32 767); DC small; the two
  channels differ; **a centred note puts the same mean in both channels** (the
  channel-swap check) and a hard-left note is louder on the left.
* **ABI** — every request recomputed from its `(dir, nr, size)` and compared
  with the compiled constant; the encoded sizes re-extracted from the request
  and checked against 608 / 136 / 288 / 24; `fcntl` is 72 and `F_SETFL` is 4;
  five errno names.

### 4. The transfer loop, against scripted sinks

`feed` takes its sink and its `prep` as **function values**, which is the only
way to test this on a machine with no sound card — and, since a real device
rarely behaves on demand, the only way to test it at all. Thirteen cases:

| what the sink does | expected |
|---|---|
| takes everything | one call, all frames, 0 short writes |
| half every time | all frames, in 2 calls, **1** short write |
| one frame at a time, 4800 times | terminates, all frames |
| EAGAIN five times, then everything | all frames, 5 stalls, **not** fatal |
| never progresses (0 frames) | given up on after 9, `EAGAIN`, no hang |
| EPIPE twice, then everything | all frames, 2 recoveries, 2 `PREPARE`s |
| EPIPE for ever | given up on after 9, `EPIPE`, 8 `PREPARE`s (the ninth gives up before its own) |
| `PREPARE` itself fails | reported with its errno, 0 frames written |
| `EINVAL` | reported, not retried |
| `ESTRPIPE` | reported rather than half-handled |
| over-reports 3× what it was asked | cannot invent frames: total = offered |
| zero frames to write | success, and the sink is never called |

The two that matter most are the ones the brief names, and both are the *real*
device's behaviour rather than a hypothesis. Here is `strace` of 60 ms of
silence through `/dev/snd/pcmC3D0p`, unedited:

```
openat(AT_FDCWD, "/dev/snd/pcmC3D0p", O_WRONLY|O_NONBLOCK) = 3
ioctl(3, SNDRV_PCM_IOCTL_INFO, …)       = 0
ioctl(3, SNDRV_PCM_IOCTL_HW_PARAMS, …)  = 0
ioctl(3, SNDRV_PCM_IOCTL_SW_PARAMS, …)  = 0
ioctl(3, SNDRV_PCM_IOCTL_PREPARE, 0)    = 0
write(3, "\0\0\0…", 11520) = 7680                       <-- SHORT WRITE
write(3, "\0\0\0…",  3840) = -1 EAGAIN (Resource temporarily unavailable)
write(3, "\0\0\0…",  3840) = -1 EAGAIN (Resource temporarily unavailable)
…
ioctl(3, SNDRV_PCM_IOCTL_DRAIN, 0)      = 0
```

**A short write is progress, not an error.** 11 520 bytes were offered into a
7680-byte ring and 7680 were taken; treating that as a failure stops playback
after the first period, which is the classic first bug. **And EAGAIN is a wait,
not a failure**: it is the normal state of a device being drained at the sample
rate, and the answer is to sleep 2 ms and ask again. 400 ms of silence came out
in **72 short writes and 176 EAGAIN stalls**; 150 ms came out in 22 and 55.
Those are the numbers a reader should expect, and the program reports them.

## Defect injection — 24 injected, 20 caught, 4 equivalent

Each case is **one exact single-occurrence string replacement in a copy** of the
sources. The copy is compiled with the pin and then three things are run against
it: `./audio check`, `./audio demo` (compared against `EXPECTED`) and
`./audio devices` (compared against the *unmutated* build's output, since it is
machine-dependent). A case counts as caught by whichever of the three noticed.
The harness itself had a bug worth recording: three cases first reported
`HARNESS ERROR: 100 occurrences` for a target that occurs exactly once, because
`grep -c -F` counts one line per pattern line on a multi-line target. The
occurrence count is now done in python, and "an injection harness that reports a
false target-not-unique is indistinguishable from a real one" is the standing
lesson.

| # | injected defect | caught by | first thing to notice |
|---|---|---|---|
| M1 | one sine table entry off by 1 Q30 unit | check | C05 the sine table is exactly odd-symmetric |
| M2 | the square's edge moved one cell (N/2 → N/2+1) | **no** | — |
| M3 | the interpolator's fraction mask halved (`& 0xFFFFF` → `& 0x7FFFF`) | check | C07 the oscillator tracks fx.sin — error 9.5e7 against a bound of 400 |
| M4 | `osc_step`'s wrap removed | check | C09 the phase stays in `[0, ONE)` — 11 further failures too |
| M5 | `osc_inc_chz` divided by `rate` instead of `rate * 100` | check | C10 the 1 kHz sine's crossing count — the voice was refused for an increment above 1.0 turn |
| M6 | the Q30 lift in `env_at` removed | check | E10 the attack reaches full scale — got 0 |
| M7 | the release's `if (e < 0)` clamp removed | **no** | — |
| M8 | `q_to_s16`'s upper clamp removed | check | B04 +2.0 clamps at full scale |
| M9 | `q_to_s16`'s lower clamp removed | check | B05 −2.0 clamps at −32768 |
| M10 | rounding replaced by truncation toward zero | check | B06 −32768 is reachable |
| M11 | a short write counted as a failure | check | H02 half-sized writes still reach every frame |
| M12 | the give-up on a device that never progresses removed | check | H06 a sink that never progresses is given up on — it now spins to the loop's guard |
| M13 | `EAGAIN` treated as a hard error | check | H06b EAGAIN is waited out |
| M14 | the `EPIPE` recovery no longer issues `PREPARE` | check | H07 two EPIPEs are recovered — 2 recoveries, 0 `PREPARE`s |
| M15 | the over-report clamp removed | check | H11 a sink that over-reports cannot invent frames |
| M16 | `wav_build` writes one frame fewer than it declares | check | A12 data size = frames·4 |
| M17 | `put_tag(0, "RIFF")` → `"RFCR"` (the first draft's actual bug) | check | A01 `'RIFF'` at 0 |
| M18 | both channels given the left pan | check | G11 a hard-left note is louder on the left |
| M19 | the strategy ladder reduced to the first shape | **no** | — |
| M20 | the `interval` integer flag cleared everywhere | **no** | — |
| M21 | one demo note transposed by 0.14 Hz | **golden only** | the digest in `EXPECTED` changed; not one of the 167 assertions moved |
| M22 | the header declares 3 channels | check | A07 channels |
| M23 | one derived pin dropped from the full set | **devices only** | `audio devices` reports 0 of 8 usable |
| M24 | the frame-byte term derived wrongly (`channels * 3`) | **devices only** | `audio devices` reports 0 of 8 usable |

**Where each one landed, and why that is the interesting part.** Seventeen were
caught by the battery. **M21 was caught only by the golden file** — a note 0.14 Hz
sharp changes every sample in the demo and moves no property: the RMS identities
are about *waveforms*, not about which note is playing, and a frequency error of
0.014 % is below every tolerance in §1. **M23 and M24 were caught only by
`devices`**, because `hw_params` cannot be exercised without hardware and the
battery deliberately never opens a device — which is exactly the split the design
demanded, and it is why the degradation tests point `--dir` at directories that
are not `/dev/snd`.

### The four that were not caught

I would rather give the proofs than drop them from the table.

* **M7 (the release clamp) is *provably* equivalent.** `ir = sus / ra`, so for
  every `n < snd` the release computes `r = (n − rel0) · ONE · ir / 2^30`, and
  `n − rel0 ≤ ra − 1`, hence `r ≤ sus·(ra−1)/ra < sus`, hence `e = sus − r > 0`
  always. The clamp is unreachable given the slope the code builds. It is
  defensive, and it is honest to say so rather than pretend a check found it.
* **M20 (the integer flag) is equivalent on this hardware, and that measurement
  corrected a claim this README used to make.** See §"Four things about the ALSA
  ABI", item 1.
* **M19 (the ladder reduced to one shape) is equivalent on every device
  measured** — all seven accept the full shape, so the two looser shapes are
  never reached. What it would break is a device that *needs* a looser request,
  which is the case the ladder exists for, and no assertion here can see that
  without such a device.
* **M2 (the square's edge one cell later) is below what any of these
  tolerances can resolve.** The square is sampled rather than interpolated, so
  moving the edge by one cell in 4096 changes the samples that land on that one
  cell: measured, the whole 167-line battery output is **byte-identical** between
  the two builds, and the square's RMS moves by under one LSB out of 20 000
  (0.005 %) — well inside the ±2 the identity is stated to. It is a real
  difference in the waveform and an undetectable one at this amplitude, which is
  the honest description.

**The honest limit of a hardware-free check.** Nothing here can verify that the
`hw_params` request is *correct*, only that the arithmetic around it is. The two
defects that actually broke the player (M23, M24) were both invisible to 167
assertions and both obvious to one command. That is not a flaw in the battery;
it is the shape of the problem, and it is why `audio devices` is a command rather
than a paragraph in the README.

## Language constraints worked around

Nothing was filed in `BUGS.md` for this example: I hit no compiler defect. The
obstacles were language facts, each handled in the code and written down rather
than papered over.

* **No `float` → `long` and no cast syntax** (`ORCHESTRATOR.md` §2.4a) — the
  whole synthesiser is Q30 integers. This is not a workaround, it is the
  design: `fx.mul`/`fx.fdiv` handle the scale, and the one place a plain integer
  division is wanted (`(freq * 2^30) / rate`) is written as one.
* **No math functions at all** (§2.4b) — `fx.y` is vendored for the one sine in
  the table; the lowpass coefficient is a Taylor series in Q30.
* **`a / b` on two fixed-point values returns the ratio** (§2.15) — `osc_inc` is
  written `(chz * fx.ONE) / (rate * 100)`, a scaled numerator over an integer,
  which is what a fixed-point quotient *is*. M5 above is the injected version of
  getting it wrong.
* **No `break` and no `continue`** (§2.9) — the strategy ladder, the node
  enumeration, the device walk and the transfer loop all use a guard variable
  with an explicit terminal assignment. Every loop's bound is spelled out in a
  comment above it, because the exit condition is the whole proof.
* **No out-parameters and no tuples** — `hw_negotiate` returns a record;
  `dev_probe`'s answer travels through the module-level `probe_why`; a helper
  that must report two numbers returns a record. §2.15's `sandfall` trap (a
  helper that writes a scalar parameter and changes nothing) does not apply
  here because nothing does that.
* **Scalars by value, arrays and records by reference** (§3) — the one place it
  bites is `dsp.stats` and `dsp.stats1`, which take the WAV image **by
  reference** as a `[byte]`; the caller passes one cached slice (`wav.image()`
  is memoised on the image length and invalidated by `wav_build`) rather than
  re-slicing per measurement, because four measurements per fixture over an arena
  that never frees is a slow leak.
* **`[byte; N]` does not unify with `[byte]`, and a `*byte` cannot be walked**
  (`SUGGESTIONS.md` #12, #19) — this is the one that shapes the whole player.
  The three ALSA structs are fixed module-level `[byte; N]` buffers with
  **offset-taking** accessors (`hw32(off, v)`, `hw_ival(param)`), because no
  helper can take them by parameter. It is also why `napms` builds its
  `timespec` in a `[byte; 16]`.
* **There is no pointer ↔ integer conversion** — filed as a suggestion; see
  below. This is the one hard limit: `SND_PCM_IOCTL_WRITEI_FRAMES` takes a
  `struct snd_xferi` whose `buf` is a user pointer that has to be *stored as an
  integer* in the struct the kernel reads, and `&rec` on a record is a pointer to
  its type descriptor rather than to its data, so a record cannot stand in for
  the struct either. Measured: the same ioctl issued from C writes (4 frames for
  480 requested — a textbook short write); issued from Y it answers `EFAULT`,
  because the struct the kernel reads holds zeros where the pointer should be.
  `--transfer writei` reproduces it on demand.
  **So the transfer uses `write(2)` on the same descriptor**, which the
  measurements show is the same ring and not a side channel: after `PREPARE` the
  stream is `PREPARED` with `appl_ptr = 0`; after `write(2)` of 480 frames it is
  `RUNNING` with `appl_ptr = 480` and `avail = 1440`; after two writes
  `appl_ptr = 960`; and 60 ms later `hw_ptr` has advanced to 2640 while
  `appl_ptr` is still 960, so the hardware really is consuming the ring.
  `DRAIN` then returns 0.
* **`argv`'s `.length` segfaults when the length is the only read of `argv`**
  (`BUGS.md`, "Argv's `.length` segfaults when the length is the only read of
  it") — `audio.y` binds `let av = argv();` and reads `av[0]` as the program
  name in its own usage text, so the tree shaker cannot drop the runtime's
  `argv_init` while keeping the call. The workaround is one line and visible.
* **`main()`'s return value is not the exit status** — the idiom is
  `def main() -> long { … }; exit(main())`, so every error path's `return 1` /
  `return 2` / `return 3` really is the process's exit status.
* **Runtime traps print to stdout** (§2.6) — no path can be allowed to trap.
  `frames_ok` is the only gate on a length; `tab_read` clamps its cell index;
  `voice_add` refuses past `MAXV` and counts the refusals; `render` refuses a
  voice whose increment has left `(0, 1)` and counts those too; `write2_sink`
  drops a partial frame rather than handing one on; every `--play` failure is a
  one-line message on stderr and a non-zero exit.
* **A `def` is a first-class value**, which is how the transfer loop is testable
  — `feed` takes `sink` and `prep` as function-typed parameters.
* **`>>` vs `>>>`** — `>>>` (logical) is never used anywhere in the folder.
* **No `sort`** — `fs.list_dir` sorts; nothing else needs to.
* **`[0; n]` needs a literal size** — every buffer in the folder has a literal
  size and every bound is checked by hand before anything indexes one.

## Filed

**One entry appended to `examples/SUGGESTIONS.md`** (append-only, nothing
renumbered, no duplicate — checked with `grep` first):

* **No pointer ↔ integer conversion**, so a syscall that takes a struct
  containing a user pointer cannot be issued at all. The worked example is
  `struct snd_xferi { unsigned long result; void *buf; }`: `buf` has to be
  stored as an integer in the buffer the kernel reads, `let n: long = p` where
  `p` is a `*byte` is a compile error (`expected long, got *byte`), and `&rec`
  on a record is a pointer to the record's *type descriptor* rather than to its
  data, so a record cannot stand in for the struct either. This is what stops
  `snd_pcm_writei` being reachable from Y, and it is the one hard limit in this
  example. `--transfer writei` reproduces the `-EFAULT` on demand.

**Found, not filed, and not fixed:**

* `fcntl` is syscall **72** and `ORCHESTRATOR.md` §2.1's syscall list does not
  include it. That list is the campaign's shared reference and the omission cost
  this example a wrong guess (55, which is `getsockopt`, answering
  `−88 = ENOTSOCK`). Adding `fcntl = 72`, `getdents64 = 217`, `fcntl(F_SETFL,
  0)` clears `O_NONBLOCK` and `ioctl` argument order to §2.1 would save the next
  agent the same hour. That is a change to `ORCHESTRATOR.md`, which is outside
  this folder, so it is reported rather than made.
* A PCM node another process holds answers `EBUSY` to a non-blocking `open` and
  **blocks for ever** to a blocking one, while `SNDRV_PCM_IOCTL_DRAIN` is a wait
  that only works on a blocking descriptor. Anything in this campaign that
  enumerates hardware needs both halves of that.
* `examples/gate.py`'s item 2 does not diff the WAV `audio demo` writes; it
  diffs stdout, which *contains* the file's sha256. That is a strong substitute
  and it caught 10 of the 24 injected defects, but the substitution is worth
  naming: a defect that changed the WAV and then also changed the digest line
  consistently would not be caught by item 2 alone. It would be caught by item 8.

## Files

| file | what |
|---|---|
| `audio.y` | the entry point: CLI, the demo report, `devices`, `--play` |
| `dsp.y` | the synthesiser — tables, oscillator, envelope, one-pole filter, render, analysis |
| `wav.y` | the RIFF container: build, write, parse back, and the demo score |
| `pcm.y` | the ALSA player: enumeration, hw_params negotiation, the transfer loop |
| `check.y` | the property battery, 167 assertions |
| `fx.y` | vendored, byte-identical, `4b47a9bfef0c1e3…` |
| `args.y` | vendored, byte-identical, `cdac36da1cf2cd85…` |
| `gate.conf` | `build=`, `run=`, `check=`, `gold=` |
| `EXPECTED` | the exact stdout of `./audio demo` |
| `demo.wav` | the WAV `demo` writes; gitignored, and regenerated by every run |

Self-containment: the folder builds and passes with every other folder in
`examples/` deleted. It imports nothing from a sibling, and its only data file
is the one it writes.

## What to look at

* **`dsp.y`'s `tab_read`** — the oscillator in eight lines, and the one place
  the discontinuous waves are treated differently from the continuous ones.
* **`dsp.y`'s `env_at`** — and the comment above it about `fx.mul` taking two Q30
  values while a sample count is not one. That one line cost this example its
  entire envelope, silently, and the symptom was not a wrong envelope but a
  silent one — invisible in a golden file, because silent is deterministic.
* **`pcm.y`'s `hw_fill`** — the strategy ladder, and the comment on why the
  full consistent set is tried first.
* **`pcm.y`'s `feed`** — the three cases everybody gets wrong, all handled and
  all measured: a short write is progress, `EAGAIN` is a wait, and `EPIPE` needs
  a `PREPARE`.
* **`check.y`'s §D** — four analytic identities measured from the bytes on disk,
  with the tolerances derived rather than chosen.
* **Run `./audio demo` and then `xxd -l 48 demo.wav`.** The header is 44 bytes
  and every field of it is in `EXPECTED`.
* **Run `./audio devices`.** Seven of eight usable, and the eighth says why.

## Pin re-verification: `31808ddc21adfa31` (orchestrator, 2026-10-05)

`refs/ycc.ref` moved again, `1d28b3dbcc546b5fc0e3f9d541b56777f746cd3e10122b45ba42f4904fd191d3` -> **`31808ddc21adfa31398f6337fa6dd6bfe585d25beceab20498b6914b89485755`**. This folder was
**rebuilt from source with the new pin and re-gated in full**: items 1-8 all
pass and `EXPECTED` is reproduced **byte for byte** over two runs. Gate item
0 caught the stale record and nothing else did -- across all 39 folders at
once, which is the signature of a pin move rather than of a regression.

Earlier shas above are kept on purpose: this example has been verified
against each of them, and a reader who wants to know what changed should be
able to see the history rather than infer it from one number.
