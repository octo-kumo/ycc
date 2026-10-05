// audio.y -- an integer fixed-point synthesiser that writes a byte-exact WAV,
// and an ALSA PCM player that plays it.
//
//     audio demo       synthesise and write demo.wav, print a report
//     audio check      the property battery
//     audio devices    list the PCM nodes under /dev/snd and probe each
//     audio --help     usage
//
// THE SPLIT, and it is the whole design.  The default run **does not touch
// the sound hardware**: it synthesises in integer arithmetic, writes a WAV,
// and prints a report whose sha256 pins every byte of that WAV.  Audio output
// cannot be deterministic -- it depends on hardware that may be absent -- and
// it produces no bytes to diff, so a golden file cannot check it at all.
// Playback therefore lives behind `--play`, exactly as the network examples
// put the live API behind `--live` and randomness behind `--seed`.  Hardware
// is a fourth category of nondeterminism and it gets the same treatment.
//
// Everything is in integer fixed point.  Y has no `float` -> `long` and no
// cast syntax, and no `sin` / `exp` / `sqrt` at all (ORCHESTRATOR.md 2.4), so
// `dsp.y` is Q30 throughout and the only trigonometry in the whole program is
// one `fx.sin` per table entry, at start-up.

import args;
import fx;
import fs;
import dsp;
import wav;
import pcm;
import check;

// ── the report ────────────────────────────────────────────────────────────
//
// Every number printed here is measured out of the written bytes or read back
// out of the ioctl struct, never assumed.  `micro` renders a Q30 value as
// integer millionths so the output carries no float and no lost digits.

def micro(q: long) -> long { (q * 1000000) / fx.ONE };

// fixed3(q): a Q30 value as a decimal string with three places, e.g.
// -1 -> "-1.000", 0.572953 -> "0.572".  No float is involved: the integer
// part and the fraction are taken separately, so nothing is rounded twice and
// nothing depends on tostring's float format.
def fixed3(q: long) -> str {
    let neg = q < 0;
    let v = if (neg) { 0 - q } else { q };
    let whole = v >>> 30;
    let frac = ((v & 1073741823) * 1000 + 536870912) >> 30;
    let carry = frac == 1000;
    if (carry) { frac = 0; whole = whole + 1; };
    let t = tostring(frac);
    let pad = "";
    if (len(t) == 1) { pad = "00"; };
    if (len(t) == 2) { pad = "0"; };
    let sign = if (neg && (whole != 0 || frac != 0)) { "-" } else { "" };
    sign + tostring(whole) + "." + pad + t
};

// ── `demo`: the deterministic default run ─────────────────────────────────
def do_demo(path: str) -> long {
    let total = wav.render_demo(wav.DEMO_CUTOFF);
    if (total <= 0) {
        eputs("audio: the render was refused (out of range)\n");
        return 1;
    };
    if (!wav.save_bytes(path, wav.image())) {
        eputs("audio: cannot write " + path + "\n");
        return 1;
    };
    let frames = wav.wav_frames;
    let st = dsp.stats(wav.image(), wav.HDR, frames);
    // Present-and-non-zero BEFORE anything is compared.  This is the
    // campaign's standing rule: a check that compares two absent values
    // passes, and a demo that printed numbers from an empty buffer would look
    // like a demo that worked.
    if (frames <= 0 || st.nonzero <= 0) {
        eputs("audio: rendered nothing\n");
        return 1;
    };
    let rms = fx.isqrt(st.sumsq / (frames * 2));
    print("audio -- integer fixed-point synthesiser and ALSA PCM player");
    print("");
    print("  format          s16le, " + tostring(dsp.CHANNELS) + " channels, " +
          tostring(dsp.RATE) + " Hz");
    print("  length          " + tostring(wav.DEMO_MS) + " ms = " +
          tostring(frames) + " frames");
    print("  wavetable       4 waves x " + tostring(dsp.TBL_N) +
          " entries, built once from fx.sin in Q30");
    print("  lowpass         one-pole, " + tostring(wav.DEMO_CUTOFF) +
          " Hz, coefficient " + fixed3(dsp.lp_a));
    print("  voices          " + tostring(dsp.nvoices) + " (" +
          tostring(dsp.voices_refused) + " refused)");
    print("");
    print("wrote " + path);
    print("  file bytes      " + tostring(wav.wav_bytes));
    print("  sha256          " + wav.image_sha());
    print("  sha256 on disk  " + wav.file_sha(path));
    print("  peak            " + tostring(st.peak) + " of " +
          tostring(dsp.FULL));
    print("  rms             " + tostring(rms));
    print("  dc offset       " + tostring(st.sum / (frames * 2)));
    print("  zero crossings  " + tostring(st.cross));
    print("  channel means   L " + tostring(st.lsum / frames) + " / R " +
          tostring(st.rsum / frames));
    print("  hardware        not touched -- this run never opens /dev/snd");
    0
};

// ── `devices`: what is there, and why each node was refused ────────────────
def do_devices(dir: str) -> long {
    let n = pcm.enumerate(dir, dsp.RATE, dsp.CHANNELS, true);
    if (n < 0) {
        eputs("audio: " + dir + " could not be read: " +
              pcm.errno_name(n) + "\n");
        return 3;
    };
    if (n == 0) {
        eputs("audio: no playback PCM node under " + dir +
              " (looked for pcm*p)\n");
        return 3;
    };
    print("audio: " + tostring(n) + " playback PCM node(s) under " + dir);
    let i = 0;
    let usable = 0;
    while (i < pcm.nnodes) {
        let d: pcm.Node = pcm.nodes[i];
        if (d.playable) { usable = usable + 1; };
        let verdict = "usable";
        if (!d.playable) { verdict = "no: " + d.why; };
        print("  " + d.name.pad_right(12, " ") + "card " +
              tostring(d.card).pad_left(2, " ") + "   " + verdict);
        i = i + 1;
    };
    print("");
    print("  " + tostring(usable) + " of " + tostring(n) + " usable at " +
          tostring(dsp.RATE) + " Hz s16le " + tostring(dsp.CHANNELS) + "ch");
    if (usable == 0) { return 3; };
    0
};

// ── `--play`: the only path in the program that touches a device ──────────
def do_play(dir: str, dev: str, silence: bool, ms: long, how: str) -> long {
    let rate = dsp.RATE;
    if (how != "write" && how != "writei") {
        eputs("audio: --transfer must be write or writei\n");
        return 2;
    };
    let frames = (ms * rate) / 1000;
    if (frames <= 0 || frames > dsp.MAXF) {
        eputs("audio: --ms must be between 1 and " +
              tostring(dsp.MAXF * 1000 / rate) + "\n");
        return 1;
    };
    if (wav.render_demo(wav.DEMO_CUTOFF) <= 0) {
        eputs("audio: the render was refused (out of range)\n");
        return 1;
    };
    let fd = 0 - 1;
    if (dev == "") {
        fd = pcm.pick(dir, rate, dsp.CHANNELS);
        if (fd < 0) {
            eputs("audio: no usable playback device under " + dir);
            if (pcm.pick_why != "") { eputs(" (" + pcm.pick_why + ")"); };
            eputs("\n");
            return 3;
        };
    } else {
        fd = pcm.open_dev(dev);
        if (fd < 0) {
            eputs("audio: " + dev + ": " + pcm.errno_name(fd) + "\n");
            return 3;
        };
        let ir = pcm.io_query(fd);
        if (ir < 0) {
            eputs("audio: " + dev + ": INFO: " + pcm.errno_name(ir) + "\n");
            syscall(3, fd);
            return 3;
        };
        if (pcm.io_stream() != pcm.PC_STREAM_PLAYBACK) {
            eputs("audio: " + dev + ": not a playback stream (stream = " +
                  tostring(pcm.io_stream()) + ")\n");
            syscall(3, fd);
            return 3;
        };
        let h = pcm.hw_negotiate(fd, rate, dsp.CHANNELS);
        if (!h.ok) {
            eputs("audio: " + dev + ": hw_params: " +
                  pcm.errno_name(h.err) + "\n");
            syscall(3, fd);
            return 3;
        };
        let sw = pcm.sw_setup(fd, h);
        if (sw < 0) {
            eputs("audio: " + dev + ": sw_params: " +
                  pcm.errno_name(sw) + "\n");
            syscall(3, fd);
            return 3;
        };
        let pr = syscall(16, fd, pcm.REQ_PREPARE, 0);
        if (pr < 0) {
            eputs("audio: " + dev + ": PREPARE: " + pcm.errno_name(pr) + "\n");
            syscall(3, fd);
            return 3;
        };
        report_hw(dev, h, sw);
    };
    // The bytes to write: the WAV image's data chunk, or digital silence.
    // `payload` starts as an empty slice and is replaced; a `let` with no
    // initialiser is a syntax error, and the two branches have different
    // lengths so they cannot be merged into one expression cheaply.
    let payload: [byte] = [0; 4];
    if (silence) {
        payload = silence_frames(frames);
    } else {
        payload = wav.image()[wav.HDR:wav.wav_bytes];
    };
    // Clear O_NONBLOCK now that the device is ours: a write that has to wait
    // for the ring should wait, and DRAIN is a wait.  See pcm.y's set_blocking.
    let nb = pcm.set_blocking(fd);
    if (nb < 0) {
        eputs("audio: fcntl(F_SETFL): " + pcm.errno_name(nb) + "\n");
        syscall(3, fd);
        return 3;
    };
    pcm.xfer_load(payload);
    // `write(2)` is the transfer that works; `writei` is ALSA's own ioctl,
    // kept selectable so its failure (EFAULT, from the pointer Y cannot put in
    // the struct) can be reproduced rather than believed.  See pcm.y.
    let sink: pcm.Sink = pcm.write2_sink;
    if (how == "writei") { sink = pcm.writei_sink; };
    let x = pcm.feed(fd, frames, sink, pcm.real_prep);
    if (!x.ok) {
        eputs("audio: playback failed: " + x.why + "\n");
        syscall(16, fd, pcm.REQ_DROP, 0);
        syscall(3, fd);
        return 1;
    };
    let dr = pcm.real_drain(fd);
    syscall(3, fd);
    if (dr < 0) {
        eputs("audio: drain failed: " + pcm.errno_name(dr) + "\n");
        return 1;
    };
    eputs("audio: wrote " + tostring(x.frames_written) + " frames (" +
          tostring(ms) + " ms, " + tostring(dsp.CHANNELS) + "ch s16le " +
          tostring(rate) + " Hz) in " + tostring(x.short_writes) +
          " short write(s), " + tostring(x.recoveries) + " recovery, " +
          tostring(x.stalls) + " stall(s)\n");
    0
};

// silence_frames(frames): `frames` frames of digital silence, from a fixed
// module-level buffer so the path allocates nothing.  This is how the write
// path is proved without making a sound: `--play --silence` negotiates
// hw_params and pushes the frames through the real writei loop, and the only
// thing missing is a signal.  Its length is asserted by the property battery,
// because "all zero" on a buffer of the wrong length is a vacuous pass.
let silence_buf: [byte; 384000] = [0; 384000];

def silence_frames(frames: long) -> [byte] {
    silence_buf[0:frames * 4]
};

// The negotiated parameters, read out of the struct the kernel filled in.
def report_hw(path: str, h: pcm.Hw, sw: long) -> void {
    print("audio: negotiated on " + path + " (" + pcm.io_name() + ")");
    print("  rate            " + tostring(h.rate) + " Hz");
    print("  channels        " + tostring(h.channels));
    print("  access          " + access_name(h.access));
    print("  format          " + format_name(h.format));
    print("  subformat       " + subformat_name(h.subformat));
    print("  period          " + tostring(h.period_size) + " frames (" +
          tostring(h.period_size * 1000 / dsp.RATE) + " ms)");
    print("  buffer          " + tostring(h.buffer_size) + " frames (" +
          tostring(h.buffer_size * 1000 / dsp.RATE) + " ms)");
    print("  request shape   " + strategy_name(h.strategy));
    print("  sw_params       ioctl returned " + tostring(sw));
};

def strategy_name(v: long) -> str {
    if (v == pcm.STRATEGY_FULL) {
        "full -- every interval pinned and consistent"
    } else if (v == pcm.STRATEGY_RATE) {
        "rate and channels only -- the device chose the rest"
    } else if (v == pcm.STRATEGY_MIN) {
        "masks only -- the device chose everything"
    } else { "none accepted" }
};

def access_name(v: long) -> str {
    if (v == pcm.ACCESS_RW_INTERLEAVED) { "RW_INTERLEAVED (3)" }
    else { "mask bit " + tostring(v) }
};

def format_name(v: long) -> str {
    if (v == pcm.FORMAT_S16_LE) { "S16_LE (2)" } else { "mask bit " + tostring(v) }
};

def subformat_name(v: long) -> str {
    if (v == pcm.SUBFORMAT_STD) { "STD (0)" } else { "mask bit " + tostring(v) }
};

def main() -> long {
    let av = argv();
    // av[0] is read on purpose.  `argv`'s `.length` segfaults when it is the
    // ONLY read of argv in the whole program -- the tree shaker drops the
    // runtime's argv_init call and the emitter still emits the call, so the
    // program dereferences an uninitialised pointer (BUGS.md, "Argv's
    // `.length` segfaults when the length is the only read of it").  Reading
    // argv[0] and using it as the program name avoids the trap, and makes the
    // program's own name in its usage text come from the command line.
    let prog = av[0];
    let base = prog;
    let cut = base.last_index_of("/");
    if (cut >= 0) { base = base[cut + 1:]; };
    const OPTS: [args.Opt] = [
        { long: "out", short: "o", kind: args.STR,
          help: "where `demo` writes its WAV (default demo.wav)" },
        { long: "play", short: "p", kind: args.BOOL,
          help: "stream the render to a PCM device -- this makes sound" },
        { long: "silence", short: "", kind: args.BOOL,
          help: "with --play, send digital silence instead: proves the" +
                " write path without making a sound" },
        { long: "ms", short: "", kind: args.NUM,
          help: "how much --play writes, in ms (default 600, max 2000)" },
        { long: "device", short: "d", kind: args.STR,
          help: "play through this node instead of probing --dir" },
        { long: "dir", short: "", kind: args.STR,
          help: "look for PCM nodes under DIR (default /dev/snd)" },
        { long: "transfer", short: "", kind: args.STR,
          help: "write | writei -- how frames reach the device (default" +
                " write; writei is ALSA's own ioctl and cannot work from Y," +
                " see the README)" }
    ];
    args.init(base, "integer fixed-point synthesiser: writes a byte-exact" +
              " WAV, and plays it through ALSA only with --play", OPTS,
              "[demo|check|devices]");
    args.parse_or_exit(av);
    let pos = args.positional();
    let mode = "demo";
    if (len(pos) > 0) { mode = pos[0]; };
    let dir = args.get_str("dir", pcm.SND_DIR);
    if (mode == "demo") {
        // `demo --play` writes the WAV, prints the report, and THEN plays it,
        // so the deterministic half of the run is the same bytes either way and
        // the playback can never change what is written.
        let rc = do_demo(args.get_str("out", "demo.wav"));
        if (rc != 0) { return rc; };
        if (!args.has("play")) { return 0; };
    };
    if (mode == "check") {
        return check.do_check();
    };
    if (mode == "devices") {
        return do_devices(dir);
    };
    if (mode == "demo" || mode == "play" || args.has("play")) {
        return do_play(dir, args.get_str("device", ""),
                       args.has("silence"), args.get_long("ms", 600),
                       args.get_str("transfer", "write"));
    };
    eputs("audio: unknown command '" + mode + "' (demo, check, devices)\n");
    args.print_usage();
    2
};
exit(main());